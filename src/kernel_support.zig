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
const WorkBudget = poll.WorkBudget;

pub const Value = value.Value;
pub const HeapKind = value.HeapKind;
pub const Machine = machine.Machine;
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
        fn run(evaluator: *Machine) MachineError!void {
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
/// range without importing the machine. `Context` remains the only door to the
/// budget itself.
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

/// The budget seam for every kernel cursor.
///
/// Every charge lands on the unit's one kernel budget, which only the machine
/// refills at the boundary where it polls cancellation. A kernel that calls
/// bare `pollKernel` with a private budget instead is invisible to that
/// accounting, which is what this type exists to prevent: typed cursors accept
/// only the narrow `Context` capability.
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

        /// Runs the kernel. When the remaining budget covers `length`, every
        /// range runs here as one, charged as one, with the operands read
        /// under the caller's references, which the caller releases after
        /// the result is pushed. Otherwise the references move into a driver
        /// that computes one budgeted range per step.
        pub fn run(evaluator: *Machine, owners: Owners, params: Spec.Params, length: usize) MachineError!void {
            // SAFETY: the loop below writes every element before any is read.
            var operands: Operands = undefined;
            inline for (&operands, owners) |*operand, owner| operand.* = owner.borrow();
            var output = try Spec.prepare(evaluator, operands, params, length);
            if (comptime stepwise) return runStepwise(evaluator, owners, operands, params, output, length);
            if (length > evaluator.remainingKernelFuel()) return startDriver(evaluator, owners, params, output, .init(length));
            // An unfinished result is abandoned exactly as its `heap.Owned`
            // disposal would abandon it in a driver.
            errdefer output.retire(evaluator.releaseDomain());
            const context = Context{ .evaluator = evaluator };
            try context.advance(length);
            try Spec.chunk(params, operands, &output, .{ .start = 0, .end = length }, context);
            return publish(evaluator, owners, &output);
        }

        fn adoptedOperand(output: *const Spec.Output) ?usize {
            return if (@hasDecl(Spec, "adopted")) Spec.adopted(output) else null;
        }

        const early = @hasDecl(Spec, "done");
        const phased = @hasDecl(Spec, "next");
        /// Its work is known only as it goes, so it is charged range by range.
        const stepwise = early or phased;

        /// Whether positions remain, opening the next phase when the current
        /// one is over.
        fn pending(context: Context, output: *Spec.Output, cursor: *flat.FlatCursor) MachineError!bool {
            while (true) {
                const over = cursor.complete() or (early and Spec.done(output));
                if (!over) return true;
                if (comptime !phased) return false;
                cursor.* = .init(try Spec.next(context, output) orelse return false);
            }
        }

        /// A kernel whose work is known only as it goes runs one charged range
        /// at a time, as its driver would, so it pays only for what it reads.
        /// A turn that runs out first continues as the driver from the same
        /// position.
        fn runStepwise(
            evaluator: *Machine,
            owners: Owners,
            operands: Operands,
            params: Spec.Params,
            prepared: Spec.Output,
            length: usize,
        ) MachineError!void {
            var output = prepared;
            var cursor = flat.FlatCursor.init(length);
            const context = Context{ .evaluator = evaluator };
            while (pending(context, &output, &cursor) catch |err| {
                output.retire(evaluator.releaseDomain());
                return err;
            }) {
                if (evaluator.remainingKernelFuel() == 0) return startDriver(evaluator, owners, params, output, cursor);
                const range = (cursor.nextRange(context) catch |err| {
                    output.retire(evaluator.releaseDomain());
                    return err;
                }).?;
                Spec.chunk(params, operands, &output, range, context) catch |err| {
                    output.retire(evaluator.releaseDomain());
                    return err;
                };
            }
            return publish(evaluator, owners, &output);
        }

        /// Publishes a finished kernel's result. When the result republished
        /// an operand's buffer, that operand's reference is the result's now,
        /// not the caller's to release.
        fn publish(evaluator: *Machine, owners: Owners, output: *Spec.Output) MachineError!void {
            const consumed = adoptedOperand(output);
            const result = Spec.finish(output);
            if (comptime @hasDecl(Spec, "adopted")) if (consumed) |position| {
                _ = owners[position].take();
            };
            return evaluator.pushOwned(result);
        }

        /// Kept out of line, so the common inline path carries none of the
        /// driver's construction.
        noinline fn startDriver(
            evaluator: *Machine,
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
            evaluator: *Machine,
            operands: Operands,
            root: ?*heap.OwnedValue,
            params: Spec.Params,
            length: usize,
        ) MachineError!NestedOutcome {
            comptime std.debug.assert(!stepwise); // Pervasion's leaves read every position, once.
            var output = try Spec.prepare(evaluator, operands, params, length);
            if (length > evaluator.remainingKernelFuel()) return .{ .frame = try boxDriver(evaluator, operands, root, params, output, length) };
            errdefer output.retire(evaluator.releaseDomain());
            const context = Context{ .evaluator = evaluator };
            try context.advance(length);
            try Spec.chunk(params, operands, &output, .{ .start = 0, .end = length }, context);
            const consumed = adoptedOperand(&output);
            const result = Spec.finish(&output);
            if (consumed) |position| {
                std.debug.assert(position == 0);
                _ = root.?.take();
            }
            return .{ .value = result };
        }

        noinline fn boxDriver(
            evaluator: *Machine,
            operands: Operands,
            root: ?*heap.OwnedValue,
            params: Spec.Params,
            output: Spec.Output,
            length: usize,
        ) error{OutOfMemory}!ErasedDriver {
            const held: Held = .{ .values = operands };
            const driver = evaluator.allocator().create(Driver) catch |err| {
                var abandoned = output;
                abandoned.retire(evaluator.releaseDomain());
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

            pub fn advance(evaluator: *Machine, self: *Driver) MachineError!machine.WorkProgress {
                const context = Context{ .evaluator = evaluator };
                if (try self.cursor.nextRange(context)) |range|
                    try Spec.chunk(self.params, self.operands.borrow().values, self.output.borrowMut(), range, context);
                if (try pending(context, self.output.borrowMut(), &self.cursor)) return .stepped;
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
    advance_fn: *const fn (*anyopaque, *Machine) MachineError!machine.WorkProgress,
    destroy_fn: *const fn (*anyopaque, *heap.ReleaseDomain, std.mem.Allocator) void,

    fn of(comptime Driver: type, driver: *Driver) ErasedDriver {
        return .{
            .context = driver,
            .advance_fn = struct {
                fn advance(context: *anyopaque, evaluator: *Machine) MachineError!machine.WorkProgress {
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
    pub fn advance(self: *ErasedDriver, evaluator: *Machine) MachineError!?Value {
        const progress = try self.advance_fn(self.context, evaluator);
        return switch (progress) {
            .stepped => null,
            .output => |result| result: {
                self.destroy_fn(self.context, evaluator.releaseDomain(), evaluator.allocator());
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

pub const Context = struct {
    evaluator: *Machine,

    pub fn allocator(self: Context) std.mem.Allocator {
        return self.evaluator.allocator();
    }

    /// Typed capabilities retire through the domain, never through the
    /// allocator directly, so reclamation stays bounded and off the hot path.
    pub fn releaseDomain(self: Context) *@import("heap.zig").ReleaseDomain {
        return self.evaluator.releaseDomain();
    }

    /// The remaining charge this turn may spend before the machine wants the
    /// unit back. A typed cursor bounds each half-open range by this and by the
    /// kernel quantum, which is what keeps one ready task from monopolizing a
    /// worker without paying a scheduler turn per element.
    pub fn remaining(self: Context) usize {
        return self.evaluator.remainingKernelFuel();
    }

    /// The unit's budget itself, for a cursor that draws element by element
    /// and hands the same allowance to the cursors it drives.
    pub fn budget(self: Context) *WorkBudget {
        return self.evaluator.workBudget();
    }

    pub fn advance(self: Context, logical_elements: usize) MachineError!void {
        try self.evaluator.advanceKernel(logical_elements);
    }

    pub fn poll(self: Context) MachineError!void {
        try self.advance(1);
    }

    pub fn failAt(
        self: Context,
        kind: machine.ErrorKind,
        message: []const u8,
        index: usize,
    ) MachineError {
        return self.evaluator.failAtIndex(kind, message, index);
    }

    /// The indexless counterpart, for a fault whose position is not part of the
    /// contract the caller is reporting against.
    pub fn fail(self: Context, kind: machine.ErrorKind, message: []const u8) MachineError {
        return self.evaluator.fail(kind, message);
    }

    pub fn conformError(self: Context, left: usize, right: usize) MachineError {
        return self.evaluator.conformError(left, right);
    }
};
