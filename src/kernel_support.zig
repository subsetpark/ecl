//! Shared contracts for the closed M5 kernel surface.
const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const machine = @import("machine.zig");
const flat = @import("kernel_flat.zig");
const idioms = @import("idioms.zig");
const env = @import("env.zig");
const poll = @import("poll.zig");

pub const Value = value.Value;
pub const HeapKind = value.HeapKind;
pub const Unit = machine.Unit;
pub const MachineError = machine.MachineError;

/// A kernel word's primitive, wrapped when the idiom registry has phrases it
/// heads: the wrapper first asks whether the words after it continue one,
/// which then runs in its place. A word that heads no phrase keeps its
/// primitive unchanged, so it pays nothing. Every kernel family binds its
/// words through this, so a phrase entry is the only change a new phrase
/// needs, and recognition compares the same pointer the binding holds.
pub fn headed(comptime spelling: []const u8, comptime primitive: env.PrimitiveImpl) env.PrimitiveImpl {
    const found = comptime idioms.firstPhraseEntry(spelling);
    if (found == null) return primitive;
    const first = found.?;
    return struct {
        fn run(evaluator: *Unit) MachineError!void {
            if (try evaluator.continuesPhrase(first)) return;
            return @call(.always_inline, primitive, .{evaluator});
        }
    }.run;
}

pub const max_depth: usize = 256;

pub const PervasiveSelectorProgress = union(enum) {
    pending,
    leaf: Value,
    depth_exceeded,
    complete,
};

/// Walk a nested list selector in left-to-right leaf order without assigning
/// meaning to its leaves. Collection kernels own leaf validation because an
/// index selector requires integers while a dictionary selector admits every
/// whole-value atom.
pub const PervasiveSelectorCursor = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    const Frame = union(enum) {
        node: struct { selector: Value, depth: usize },
        children: struct { selectors: Value, depth: usize, index: usize },
    };

    frames: poll.ChunkStack(Frame),

    pub fn init(
        allocator: std.mem.Allocator,
        selector: Value,
    ) error{OutOfMemory}!PervasiveSelectorCursor {
        var frames = poll.ChunkStack(Frame).init(allocator);
        errdefer frames.deinit();
        try frames.push(.{ .node = .{ .selector = selector, .depth = 0 } });
        return .{ .frames = frames };
    }

    pub fn retire(self: *PervasiveSelectorCursor, releases: *heap.ReleaseDomain) void {
        self.frames.retire(releases);
    }

    pub fn advanceOne(self: *PervasiveSelectorCursor) error{OutOfMemory}!PervasiveSelectorProgress {
        const frame = self.frames.pop() orelse return .complete;
        return switch (frame) {
            .node => |node| node_result: {
                if (node.selector != .list) break :node_result .{ .leaf = node.selector };
                if (node.depth >= max_depth) break :node_result .depth_exceeded;
                try self.frames.push(.{ .children = .{
                    .selectors = node.selector,
                    .depth = node.depth + 1,
                    .index = 0,
                } });
                break :node_result .pending;
            },
            .children => |children| children_result: {
                if (children.index == children.selectors.list.length())
                    break :children_result .pending;
                try self.frames.reserve(2);
                self.frames.pushReserved(.{ .children = .{
                    .selectors = children.selectors,
                    .depth = children.depth,
                    .index = children.index + 1,
                } });
                self.frames.pushReserved(.{ .node = .{
                    .selector = list.atUnchecked(children.selectors, children.index),
                    .depth = children.depth,
                } });
                break :children_result .pending;
            },
        };
    }
};

/// The scheduler's kernel interval, re-exported so typed loops can bound a
/// range without importing the machine. The unit's `advanceKernel` remains the
/// only door to the budget itself.
pub const poll_quantum: usize = machine.kernel_poll_quantum;

/// Whether the selected target can execute packed i64 multiplication without
/// scalarizing the vector loop. Benchmark classification and kernel dispatch
/// share this predicate so `--explicit-simd-only` describes the loop that will
/// actually run.
pub fn targetHasNativePackedI64Multiply() bool {
    return switch (builtin.cpu.arch) {
        .aarch64 => builtin.cpu.has(.aarch64, .sve),
        .x86, .x86_64 => builtin.cpu.has(.x86, .avx512dq),
        .riscv32, .riscv64 => builtin.cpu.has(.riscv, .v),
        .wasm32, .wasm64 => std.simd.suggestVectorLength(i64) != null,
        else => false,
    };
}

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    int_div,
    mod,
    pow,
    atan2,
    min,
    max,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    and_word,
    or_word,
    band,
    bor,
    bxor,
    bsl,
    bsr,
    wrap_add,
    wrap_sub,
    wrap_mul,

    pub fn spelling(self: BinaryOp) []const u8 {
        return switch (self) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .int_div => "div",
            .mod => "mod",
            .pow => "pow",
            .atan2 => "atan2",
            .min => "min",
            .max => "max",
            .eq => "=",
            .ne => "<>",
            .lt => "<",
            .gt => ">",
            .le => "<=",
            .ge => ">=",
            .and_word => "and",
            .or_word => "or",
            .band => "band",
            .bor => "bor",
            .bxor => "bxor",
            .bsl => "bsl",
            .bsr => "bsr",
            .wrap_add => "+%",
            .wrap_sub => "-%",
            .wrap_mul => "*%",
        };
    }
};

pub const UnaryOp = enum {
    neg,
    abs,
    sqrt,
    floor,
    ceil,
    round,
    exp,
    log,
    sin,
    cos,
    not_word,
    bnot,

    pub fn spelling(self: UnaryOp) []const u8 {
        return switch (self) {
            .neg => "neg",
            .abs => "abs",
            .sqrt => "sqrt",
            .floor => "floor",
            .ceil => "ceil",
            .round => "round",
            .exp => "exp",
            .log => "log",
            .sin => "sin",
            .cos => "cos",
            .not_word => "not",
            .bnot => "bnot",
        };
    }
};

/// The kernel operation families. Each family's enum is the same one its
/// installer iterates.
pub const SequenceOp = enum {
    at,
    where,
    first_where,
    in_word,
    raze,
    cat,
    take,
    drop,
    reverse,
    first,
    rest,
    range,
    shape,
    len,
    flip,
    reshape,
    cut,
    rotate,

    pub fn spelling(self: SequenceOp) []const u8 {
        return switch (self) {
            .at => "at",
            .where => "where",
            .first_where => "first-where",
            .in_word => "in?",
            .raze => "raze",
            .cat => "cat",
            .take => "take",
            .drop => "drop",
            .reverse => "reverse",
            .first => "first",
            .rest => "rest",
            .range => "range",
            .shape => "shape",
            .len => "len",
            .flip => "flip",
            .reshape => "reshape",
            .cut => "cut",
            .rotate => "rotate",
        };
    }
};

pub const OrderOp = enum {
    cmp,
    grade,
    distinct,
    group,
    group_columns,

    pub fn spelling(self: OrderOp) []const u8 {
        return switch (self) {
            .cmp => "cmp",
            .grade => "grade",
            .distinct => "distinct",
            .group => "group",
            .group_columns => "group-columns",
        };
    }
};

pub const TextOp = enum {
    put,
    del,
    split,
    join,
    str,
    format,

    pub fn spelling(self: TextOp) []const u8 {
        return switch (self) {
            .put => "put",
            .del => "del",
            .split => "split",
            .join => "join",
            .str => "str",
            .format => "format",
        };
    }
};

pub const RandomOp = enum {
    rand_int,
    rand_ints,
    rand_float,
    entropy,

    pub fn spelling(self: RandomOp) []const u8 {
        return switch (self) {
            .rand_int => "rand.int",
            .rand_ints => "rand.ints",
            .rand_float => "rand.float",
            .entropy => "rand.entropy",
        };
    }
};

/// A typed kernel: `length` result positions computed range by range. A
/// kernel defines only what one range computes; when it runs inline or as a
/// driver, how it is charged, who holds its operands, and what happens to
/// its output when it fails are this executor's, written once.
///
/// `Spec` declares:
/// - `arity`: how many values it reads. Each spec names exactly its own, so
///   no call carries an operand it does not use.
/// - `Params`: what it needs besides its operands.
/// - `Output`: the result being built; `retire(releases)` abandons it
///   unfinished, which is also its `heap.Owned` disposal in a driver.
/// - `prepare(evaluator, operands, params, length) !Output`: allocates or
///   adopts the result before any range runs.
/// - `chunk(params, operands, *Output, range, context)`: computes one range,
///   reporting its first fault.
/// - `finish(*Output) Value`: publishes the result.
/// - optional `adopted(*const Output) ?usize`: the operand whose buffer the
///   result took over, whose reference therefore becomes the result's.
/// - optional `result: ?ResultShape`: the kernel's result is one leaf, which
///   this executor prepares, taking over an operand's buffer whenever the
///   shape says the loop permits it and the call alone holds that buffer.
///   `prepare` then takes the prepared `LeafResult` as a fifth argument, and
///   `leafResult(*Output) *LeafResult` finds it when it is not the whole
///   output. An optional `resultLength(params, operands, length) usize`
///   gives its length when that is not `length`, and an optional
///   `mayOverwrite(params, position) bool` narrows the declared operands for
///   a kernel whose structure depends on its parameters, and an optional
///   `positions(params, aliased, length) usize` gives the work left when the
///   result took over an operand that already holds most of it. Every kernel whose result
///   fits this shape declares it: reuse is decided here, once, for all of
///   them, and no kernel claims a buffer itself.
/// - optional `done(*const Output) bool`: the kernel can finish its positions
///   early, as a search does. It then runs range by range, charged for each
///   range as it goes, and leaves its positions as soon as `done` holds.
/// - optional `next(context, *Output) !?usize`: the kernel runs in phases.
///   Once a phase's positions are computed (or `done` holds), `next` opens
///   the following phase's positions, or returns null when the result is
///   ready. A phase's length can depend on what earlier phases computed, as
///   a fill's does on its counting pass. `length` is the first phase's.
///
/// Operands are `Value` views, stable while their references are held, so a
/// slice is re-derived for every range.
pub fn Kernel(comptime Spec: type) type {
    return struct {
        pub const Operands = [Spec.arity]Value;
        /// The caller's references to the operands.
        pub const Owners = [Spec.arity]*heap.OwnedValue;

        const shape: ?ResultShape = if (@hasDecl(Spec, "result")) Spec.result else null;
        const Result = if (shape) |declared| LeafResult(declared.kind) else void;

        /// Which operands this call owns, and so may take a buffer from: all
        /// of them at top level, only the caller's root inside pervasion.
        const Ownership = enum { all, first, none };

        /// The output, with the result leaf prepared here when the kernel
        /// declares one.
        inline fn prepareOutput(evaluator: *Unit, operands: Operands, ownership: Ownership, params: Spec.Params, length: usize) MachineError!Spec.Output {
            if (comptime shape == null) return Spec.prepare(evaluator, operands, params, length);
            const result_length = if (comptime @hasDecl(Spec, "resultLength")) Spec.resultLength(params, operands, length) else length;
            var result = try prepareResult(evaluator, operands, ownership, params, result_length);
            if (comptime Spec.Output == Result) return result;
            return Spec.prepare(evaluator, operands, params, length, result) catch |err| {
                result.retire(evaluator.releases);
                return err;
            };
        }

        /// The one place a kernel's result takes over an operand's buffer: an
        /// overwritable operand the call owns, held only through the call's
        /// own references (one operand may appear more than once), wide
        /// enough and of the result's element width. Otherwise a fresh leaf.
        inline fn prepareResult(evaluator: *Unit, operands: Operands, ownership: Ownership, params: Spec.Params, length: usize) error{OutOfMemory}!Result {
            const declared = shape.?;
            inline for (declared.overwritable) |position| reuse: {
                switch (ownership) {
                    .all => {},
                    .first => if (position != 0) break :reuse,
                    .none => break :reuse,
                }
                if (comptime @hasDecl(Spec, "mayOverwrite")) if (!Spec.mayOverwrite(params, position)) break :reuse;
                const operand = operands[position];
                if (operand != .list) break :reuse;
                // The list may appear at several positions; the loop's
                // promise covers it only if it does at every one of them.
                var references: u32 = 0;
                var covered = true;
                inline for (operands, 0..) |other, other_position| {
                    if (other == .list and other.list == operand.list) {
                        references += 1;
                        if (comptime !contains(declared.overwritable, other_position)) covered = false;
                        if (comptime @hasDecl(Spec, "mayOverwrite")) {
                            if (!Spec.mayOverwrite(params, other_position)) covered = false;
                        }
                    }
                }
                if (!covered) break :reuse;
                // Inside pervasion the other operands are the structure's.
                if (ownership == .first and references != 1) break :reuse;
                if (adopt(declared.kind, operand, references, length)) |claimed| {
                    var result = claimed;
                    result.adopted = position;
                    return result;
                }
            }
            return allocate(declared.kind, evaluator, length);
        }

        /// The positions left to compute once the output is prepared.
        fn workLength(params: Spec.Params, output: *const Spec.Output, length: usize) usize {
            if (comptime shape == null or !@hasDecl(Spec, "positions")) return length;
            return Spec.positions(params, resultOf(output).aliased(), length);
        }

        fn contains(comptime positions: []const usize, comptime position: usize) bool {
            for (positions) |candidate| if (candidate == position) return true;
            return false;
        }

        fn resultOf(output: *const Spec.Output) *const Result {
            if (comptime Spec.Output == Result) return output;
            return Spec.leafResult(@constCast(output));
        }

        /// Runs the kernel. When the remaining budget covers `length`, every
        /// range runs here as one, charged as one, with the operands read
        /// under the caller's references, which the caller releases after
        /// the result is pushed. Otherwise the references move into a driver
        /// that computes one budgeted range per step.
        pub fn run(evaluator: *Unit, owners: Owners, params: Spec.Params, length: usize) MachineError!void {
            // SAFETY: the loop below writes every element before any is read.
            var operands: Operands = undefined;
            inline for (&operands, owners) |*operand, owner| operand.* = owner.borrow();
            var output = try prepareOutput(evaluator, operands, .all, params, length);
            const work = workLength(params, &output, length);
            if (comptime stepwise) return runStepwise(evaluator, owners, operands, params, output, work);
            if (work > evaluator.remainingKernelFuel()) return startDriver(evaluator, owners, params, output, .init(work));
            // An unfinished result is abandoned exactly as its `heap.Owned`
            // disposal would abandon it in a driver.
            errdefer output.retire(evaluator.releases);
            try evaluator.advanceKernel(work);
            try Spec.chunk(params, operands, &output, .{ .start = 0, .end = work }, evaluator);
            return publish(evaluator, owners, &output);
        }

        fn adoptedOperand(output: *const Spec.Output) ?usize {
            if (comptime shape != null) return resultOf(output).adopted;
            return if (@hasDecl(Spec, "adopted")) Spec.adopted(output) else null;
        }

        const early = @hasDecl(Spec, "done");
        const phased = @hasDecl(Spec, "next");
        /// Its work is known only as it goes, so it is charged range by range.
        const stepwise = early or phased;

        /// Whether positions remain, opening the next phase when the current
        /// one is over.
        fn pending(evaluator: *Unit, output: *Spec.Output, cursor: *flat.FlatCursor) MachineError!bool {
            while (true) {
                const over = cursor.complete() or (early and Spec.done(output));
                if (!over) return true;
                if (comptime !phased) return false;
                cursor.* = .init(try Spec.next(evaluator, output) orelse return false);
            }
        }

        /// A kernel whose work is known only as it goes runs one charged range
        /// at a time, as its driver would, so it pays only for what it reads.
        /// A turn that runs out first continues as the driver from the same
        /// position.
        fn runStepwise(
            evaluator: *Unit,
            owners: Owners,
            operands: Operands,
            params: Spec.Params,
            prepared: Spec.Output,
            length: usize,
        ) MachineError!void {
            var output = prepared;
            var cursor = flat.FlatCursor.init(length);
            while (pending(evaluator, &output, &cursor) catch |err| {
                output.retire(evaluator.releases);
                return err;
            }) {
                if (evaluator.remainingKernelFuel() == 0) return startDriver(evaluator, owners, params, output, cursor);
                const range = (cursor.nextRange(evaluator) catch |err| {
                    output.retire(evaluator.releases);
                    return err;
                }).?;
                Spec.chunk(params, operands, &output, range, evaluator) catch |err| {
                    output.retire(evaluator.releases);
                    return err;
                };
            }
            return publish(evaluator, owners, &output);
        }

        /// Publishes a finished kernel's result. When the result republished
        /// an operand's buffer, that operand's reference is the result's now,
        /// not the caller's to release.
        fn publish(evaluator: *Unit, owners: Owners, output: *Spec.Output) MachineError!void {
            const consumed = adoptedOperand(output);
            const result = Spec.finish(output);
            if (comptime Spec.arity != 0) if (consumed) |position| {
                _ = owners[position].take();
            };
            return evaluator.pushOwned(result);
        }

        /// Kept out of line, so the common inline path carries none of the
        /// driver's construction.
        noinline fn startDriver(
            evaluator: *Unit,
            owners: Owners,
            params: Spec.Params,
            output: Spec.Output,
            cursor: flat.FlatCursor,
        ) MachineError!void {
            // SAFETY: the loop below writes every value before any is read.
            var held: Held = .{ .values = undefined };
            inline for (&held.values, owners) |*operand, owner| operand.* = owner.take();
            var driver = Driver{
                .operands = .init(held),
                .params = params,
                .output = .init(output),
                .cursor = cursor,
            };
            return evaluator.runDriverAt(&driver);
        }

        /// Runs the kernel for a leaf inside pervasion, where the operands
        /// belong to the structure being descended. `root` is the caller's
        /// owner of operand 0 when that operand is the operation's own and
        /// may be reused; every other operand is only borrowed, so a driver
        /// retains its own references to them. The result is returned rather
        /// than pushed.
        pub fn nested(
            evaluator: *Unit,
            operands: Operands,
            root: ?*heap.OwnedValue,
            params: Spec.Params,
            length: usize,
        ) MachineError!NestedOutcome {
            comptime std.debug.assert(!stepwise); // Pervasion's leaves read every position, once.
            var output = try prepareOutput(evaluator, operands, if (root != null) .first else .none, params, length);
            const work = workLength(params, &output, length);
            if (work > evaluator.remainingKernelFuel()) return .{ .frame = try boxDriver(evaluator, operands, root, params, output, work) };
            errdefer output.retire(evaluator.releases);
            try evaluator.advanceKernel(work);
            try Spec.chunk(params, operands, &output, .{ .start = 0, .end = work }, evaluator);
            const consumed = adoptedOperand(&output);
            const result = Spec.finish(&output);
            if (consumed) |position| {
                std.debug.assert(position == 0);
                _ = root.?.take();
            }
            return .{ .value = result };
        }

        noinline fn boxDriver(
            evaluator: *Unit,
            operands: Operands,
            root: ?*heap.OwnedValue,
            params: Spec.Params,
            output: Spec.Output,
            length: usize,
        ) error{OutOfMemory}!ErasedDriver {
            const held: Held = .{ .values = operands };
            const driver = evaluator.allocator.create(Driver) catch |err| {
                var abandoned = output;
                abandoned.retire(evaluator.releases);
                return err;
            };
            // Only now can nothing fail: the driver takes its references.
            for (held.values, 0..) |item, position| {
                if (position == 0 and root != null) {
                    _ = root.?.take();
                } else heap.retainValue(item);
            }
            driver.* = .{
                .operands = .init(held),
                .params = params,
                .output = .init(output),
                .cursor = flat.FlatCursor.init(length),
            };
            return ErasedDriver.of(Driver, driver);
        }

        /// A driver's own references to the operands, less any the result
        /// took over.
        const Held = struct {
            values: Operands,
            consumed: ?usize = null,

            pub fn retire(self: *Held, releases: *heap.ReleaseDomain) void {
                for (self.values, 0..) |item, position| {
                    if (self.consumed != position) releases.releaseValue(item);
                }
            }
        };

        /// The kernel past its turn: it owns its operands and output and
        /// computes one budgeted range per step.
        pub const Driver = struct {
            pub const ownership: heap.DriverOwnership = .fields;
            /// It lives for one operation and releases the slot when it
            /// publishes.
            pub const inline_driver = true;

            operands: heap.Owned(Held),
            params: Spec.Params,
            output: heap.Owned(Spec.Output),
            cursor: flat.FlatCursor,

            pub fn advance(evaluator: *Unit, self: *Driver) MachineError!machine.WorkProgress {
                if (try self.cursor.nextRange(evaluator)) |range|
                    try Spec.chunk(self.params, self.operands.borrow().values, self.output.borrowMut(), range, evaluator);
                if (try pending(evaluator, self.output.borrowMut(), &self.cursor)) return .stepped;
                var finished = self.output.take();
                self.operands.borrowMut().consumed = adoptedOperand(&finished);
                return .{ .output = Spec.finish(&finished) };
            }
        };
    };
}

/// What a kernel made of a typed leaf inside pervasion.
pub const NestedOutcome = union(enum) {
    /// The leaf finished within the turn.
    value: Value,
    /// The leaf continues as a boxed driver, which the caller's frame
    /// advances and, if abandoned, destroys.
    frame: ErasedDriver,
};

/// A kernel driver behind a pointer, for a frame that holds one of many
/// kernels and must stay small: pervasion moves its frames by value.
pub const ErasedDriver = struct {
    context: *anyopaque,
    advance_fn: *const fn (*anyopaque, *Unit) MachineError!machine.WorkProgress,
    destroy_fn: *const fn (*anyopaque, *heap.ReleaseDomain, std.mem.Allocator) void,

    fn of(comptime Driver: type, driver: *Driver) ErasedDriver {
        return .{
            .context = driver,
            .advance_fn = struct {
                fn advance(context: *anyopaque, evaluator: *Unit) MachineError!machine.WorkProgress {
                    return Driver.advance(evaluator, @ptrCast(@alignCast(context)));
                }
            }.advance,
            .destroy_fn = struct {
                fn destroy(context: *anyopaque, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
                    const boxed: *Driver = @ptrCast(@alignCast(context));
                    heap.deinitDriverFields(releases, allocator, boxed);
                    allocator.destroy(boxed);
                }
            }.destroy,
        };
    }

    /// One budgeted range. Returns the result when the kernel completes, and
    /// then the driver is already destroyed.
    pub fn advance(self: *ErasedDriver, evaluator: *Unit) MachineError!?Value {
        const progress = try self.advance_fn(self.context, evaluator);
        return switch (progress) {
            .stepped => null,
            .output => |result| result: {
                self.destroy_fn(self.context, evaluator.releases, evaluator.allocator);
                break :result result;
            },
            else => unreachable, // A kernel driver only steps or publishes.
        };
    }

    /// Abandons the kernel before it completes.
    pub fn retire(self: *ErasedDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        self.destroy_fn(self.context, releases, allocator);
    }
};

/// What a kernel declares about its one leaf result so the executor can
/// prepare it: the result's representation, and the operands whose buffers
/// the result may occupy. An operand is overwritable when the kernel's loop
/// never reads one of its positions after storing the result's position of
/// the same index, and writes nothing past the result's length: elementwise
/// operations, scans, and folds into a prefix all qualify.
pub const ResultShape = struct {
    kind: value.HeapKind,
    overwritable: []const usize,
};

/// A kernel's leaf result as the executor prepared it: a fresh buffer, or an
/// operand's buffer taken over in place. The kernel writes through it either
/// way; `aliased` tells a loop that must read a position's operands before
/// storing it that they share storage.
pub fn LeafResult(comptime kind: value.HeapKind) type {
    return struct {
        const Self = @This();
        pub const Element = heap.LeafElement(kind);

        storage: union(enum) {
            fresh: heap.LeafWriter(kind),
            reuse: heap.UniqueLeafAdoption(kind),
        },
        /// The operand whose buffer this is, whose reference becomes the
        /// result's when it is published.
        adopted: ?usize = null,

        pub fn aliased(self: *const Self) bool {
            return self.storage == .reuse;
        }

        /// Positions `offset..offset + count`, writable in place.
        pub fn range(self: *Self, offset: usize, count: usize) []Element {
            return switch (self.storage) {
                .fresh => |*writer| writer.unpublishedRange(offset, count),
                .reuse => |*adoption| adoption.inPlaceRange(offset, count),
            };
        }

        /// Stores `items` at `offset`. Over an operand, `items` may be that
        /// operand's own later positions: a kernel only declares an operand
        /// overwritable when it moves elements to the same or a lower index.
        pub fn store(self: *Self, offset: usize, items: []const Element) void {
            switch (self.storage) {
                .fresh => |*writer| writer.writeRange(offset, items),
                .reuse => |*adoption| adoption.writeRange(offset, items),
            }
        }

        pub fn finish(self: *Self) Value {
            return switch (self.storage) {
                inline else => |*capability| capability.finish(),
            };
        }

        pub fn retire(self: *Self, releases: *heap.ReleaseDomain) void {
            switch (self.storage) {
                .fresh => |*writer| writer.retirePartial(releases),
                // The operand's reference is still the caller's; positions
                // already stored hold results, and only it is released.
                .reuse => |*adoption| adoption.abandon(),
            }
        }
    };
}

/// The one decision that lets a result take over an operand's buffer: the
/// operand must be a list the caller holds through exactly `references` of
/// its own references, with room for `length` elements of the result's width.
/// Every producer that can write its result over an input asks here, whether
/// it runs as a `Kernel` or not.
pub fn adopt(comptime kind: value.HeapKind, operand: Value, references: u32, length: usize) ?LeafResult(kind) {
    if (operand != .list) return null;
    const claimed = heap.UniqueLeafAdoption(kind).claimHeld(operand.list, length, references) orelse return null;
    return .{ .storage = .{ .reuse = claimed } };
}

/// A fresh result of `length` elements.
pub fn allocate(comptime kind: value.HeapKind, evaluator: *Unit, length: usize) error{OutOfMemory}!LeafResult(kind) {
    return .{ .storage = .{ .fresh = try .init(evaluator.allocator, length) } };
}
