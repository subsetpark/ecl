//! Checked scalar and flat-leaf arithmetic plus pervasive descent.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const equal = @import("equal.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const poll = @import("poll.zig");
const support = @import("kernel_support.zig");
const flat = @import("kernel_flat.zig");

const Value = value.Value;
const Fiber = support.Fiber;
const MachineError = support.MachineError;
pub const BinaryOp = support.BinaryOp;
pub const UnaryOp = support.UnaryOp;

const ScalarError = error{ Type, Overflow, Domain, ShiftCount };
const ScalarBinary = *const fn (Value, Value) ScalarError!Value;
const ScalarUnary = *const fn (Value) ScalarError!Value;
pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    inline for (comptime std.meta.tags(BinaryOp)) |operation| {
        try core.installBuiltin(comptime binaryDefinition(operation));
    }
    inline for (comptime std.meta.tags(UnaryOp)) |operation| {
        try core.installBuiltin(comptime unaryDefinition(operation));
    }
    try core.installBuiltin(.{ .name = "sum", .primitive = totalPrimitive(.add, 0), .effect = "list -- total", .doc = "Add every element of a numeric list; 0 when the list is empty. A nonempty list's total starts from its first element: a list of rows sums to a row, and a sum of negative zeros is `-0.0`." });
    try core.installBuiltin(.{ .name = "product", .primitive = totalPrimitive(.mul, 1), .effect = "list -- product", .doc = "Multiply every element of a numeric list; 1 when the list is empty. A nonempty list's product starts from its first element, so a list of rows multiplies to a row." });
}

/// `sum` and `product`: the empty seed, or a reduction from the first
/// element, so no seed copies a first row or turns a -0.0 total into 0.0.
fn totalPrimitive(comptime operation: BinaryOp, comptime empty: i64) env.PrimitiveImpl {
    return struct {
        fn run(evaluator: *Fiber) MachineError!void {
            try evaluator.require(1);
            const input = evaluator.stack.items[evaluator.stack.items.len - 1];
            if (input != .list) {
                var item = try evaluator.popValue();
                defer item.deinit();
                return evaluator.typeError("a list");
            }
            if (input.list.length() == 0) {
                evaluator.discard(1);
                return evaluator.pushOwned(.{ .int = empty });
            }
            return startReduction(evaluator, operation, false, input, list.atUnchecked(input, 0), 1, 1);
        }
    }.run;
}

fn binaryDefinition(comptime operation: BinaryOp) env.BuiltinWord {
    return switch (operation) {
        .add => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Add. Acts ordinally on chars: `char int +` (either order) is a char; `char char +` is `` `type ``. Integer overflow is `` `overflow ``." },
        .sub => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Subtract. Acts ordinally on chars: `char char -` is an int, `char int -` is a char, `int char -` is `` `type ``. Integer overflow is `` `overflow ``." },
        .mul => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Multiply. Integer overflow is `` `overflow ``." },
        .div => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Float division under IEEE rules: a nonzero number over zero is an infinity signed by both operands, and `0 0 /` is `` `domain `` (NaN)." },
        .int_div => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Checked integer division. Division by zero is `` `domain ``." },
        .atan2 => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "y x -- z", .doc = "Two-argument arctangent; returns float." },
        .pow => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Exponentiation; returns float." },
        .min => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "The lesser of two comparable atoms." },
        .max => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "The greater of two comparable atoms." },
        .eq => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- bool", .doc = "Equality; numbers compare numerically across int and float. Whole-value equality is `match?`." },
        .lt => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- bool", .doc = "Ascending comparison, producing 0/1 masks." },
        .gt => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- bool", .doc = "Descending comparison, producing 0/1 masks." },
        .band => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Bitwise and over the two's-complement bit patterns of ints. Non-int leaves are `` `type ``." },
        .bor => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Bitwise or. See `band`." },
        .bxor => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Bitwise exclusive or. On 0/1 masks `<>` does the same job on any leaf type; `bxor` is for whole patterns." },
        .bsl => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x count -- y", .doc = "Shift the bit pattern left by `count` places, truncating bits shifted off the top rather than raising `` `overflow ``: `maxint 1 bsl` is `-2`. A `count` outside `0..63` is `` `domain ``." },
        .bsr => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x count -- y", .doc = "Shift the bit pattern right by `count` places, filling zeros from the top. The logical shift makes `-1 1 bsr` produce `maxint`. A `count` outside `0..63` is `` `domain ``." },
        .wrap_add => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Add integers modulo 2^64 in two's complement, wrapping where `+` raises `` `overflow ``. Int-only: a float or a char is `` `type ``." },
        .wrap_sub => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Subtract integers modulo 2^64 in two's complement, wrapping where `-` raises `` `overflow ``. Int-only: a float or a char is `` `type ``." },
        .wrap_mul => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Multiply integers modulo 2^64 in two's complement, wrapping where `*` raises `` `overflow ``. Int-only: a float or a char is `` `type ``. With `band`, arithmetic modulo any power of two." },
        .mod => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Compute remainder of `x` / `y`." },
        .ne => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- bool", .doc = "Compare conforming values for inequality." },
        .le => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- bool", .doc = "Compare conforming values for less-than-or-equal order." },
        .ge => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- bool", .doc = "Compare conforming values for greater-than-or-equal order." },
        .and_word => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- bool", .doc = "Compute boolean and over 0 and 1 values." },
        .or_word => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- bool", .doc = "Compute boolean or over 0 and 1 values." },
    };
}

fn bindBinary(comptime operation: BinaryOp) env.PrimitiveImpl {
    return support.headed(operation.spelling(), struct {
        fn run(evaluator: *Fiber) MachineError!void {
            // Each operation already has its own specialized copy, so
            // inlining it removes only the trampoline.
            return @call(.always_inline, binaryPrimitive, .{ evaluator, operation });
        }
    }.run);
}

pub fn binaryPrimitiveFor(comptime operation: BinaryOp) env.PrimitiveImpl {
    return bindBinary(operation);
}

fn unaryDefinition(comptime operation: UnaryOp) env.BuiltinWord {
    return switch (operation) {
        .sqrt => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Square root. `` `domain `` on negative inputs (the result would be NaN)." },
        .floor => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- integer", .doc = "Round down; the result is int64, `` `overflow `` outside its range." },
        .ceil => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- integer", .doc = "Round up; the result is int64, `` `overflow `` outside its range." },
        .round => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- integer", .doc = "Round to nearest; the result is int64, `` `overflow `` outside its range." },
        .exp => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Natural exponential; float transcendental." },
        .log => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Natural logarithm; float transcendental. Edges follow the Numbers rules: `0 log` is `-inf`, `-1 log` is `` `domain `` (NaN)." },
        .sin => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Sine; float transcendental." },
        .cos => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Cosine; float transcendental." },
        .not_word => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "bool -- bool", .doc = "Invert 0/1 values." },
        .bnot => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Invert every bit. `bnot bnot` is identity; `0 bnot` is `-1`." },
        .neg => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Negate a numeric value." },
        .abs => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Return the absolute value of `x`." },
    };
}

fn bindUnary(comptime operation: UnaryOp) env.PrimitiveImpl {
    return support.headed(operation.spelling(), struct {
        fn run(evaluator: *Fiber) MachineError!void {
            return @call(.always_inline, unaryPrimitive, .{ evaluator, operation });
        }
    }.run);
}

pub fn unaryPrimitiveFor(comptime operation: UnaryOp) env.PrimitiveImpl {
    return bindUnary(operation);
}

/// The operand shape the pervade cursor treats as a leaf: everything it does
/// not descend into. Lists and dicts are the two it does.
fn isPervadeScalar(item: Value) bool {
    return item != .list and item != .dict;
}

fn binaryPrimitive(evaluator: *Fiber, comptime operation: BinaryOp) MachineError!void {
    var left, var right = try evaluator.popPair();
    defer right.deinit();
    defer left.deinit();
    // Two scalars are the whole operation. `PervadeCursor.startBinary` reaches
    // this same call for its leaf case, so routing there costs one cursor and
    // one driver allocation to arrive at a value already in hand. A scalar at
    // top level carries no logical index, exactly as the cursor reports it.
    // Typed kernels need a list leaf, so they never take this pair: testing it
    // first skips their classification.
    if (isPervadeScalar(left.borrow()) and isPervadeScalar(right.borrow())) {
        const result = scalarBinary(operation, left.borrow(), right.borrow()) catch |fault|
            return scalarFailure(evaluator, fault, null);
        return evaluator.pushIntoFreed(result);
    }
    if (try startTypedBinary(evaluator, operation, &left, &right, .{})) return;

    const cursor = try PervadeCursor.initBinary(
        evaluator.releases,
        evaluator.allocator,
        operation,
        left.borrow(),
        right.borrow(),
    );
    try evaluator.startDriver(PervadeDriver{
        .left = .init(left.take()),
        .right = .init(right.take()),
        .cursor = .init(cursor),
    });
}

fn unaryPrimitive(evaluator: *Fiber, comptime operation: UnaryOp) MachineError!void {
    var operand = try evaluator.popValue();
    defer operand.deinit();
    // As for binary operations, a scalar never takes a typed kernel.
    if (isPervadeScalar(operand.borrow())) {
        const result = scalarUnary(operation, operand.borrow()) catch |fault|
            return scalarFailure(evaluator, fault, null);
        return evaluator.pushIntoFreed(result);
    }
    if (try startTypedUnary(evaluator, operation, &operand, .{})) return;
    const cursor = try PervadeCursor.initUnary(
        evaluator.releases,
        evaluator.allocator,
        operation,
        operand.borrow(),
    );
    try evaluator.startDriver(PervadeDriver{
        .left = .init(operand.take()),
        .cursor = .init(cursor),
    });
}

const PervadeDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    left: heap.Owned(Value),
    right: ?heap.Owned(Value) = null,
    cursor: heap.Owned(PervadeCursor),

    pub fn advance(evaluator: *Fiber, self: *PervadeDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.cursor.borrowMut().advance(evaluator, evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |result| .{ .output = result },
        };
    }
};

pub const PervadeProgress = poll.Progress(Value);

pub const PervadeCursor = struct {
    releases: *heap.ReleaseDomain,
    allocator: std.mem.Allocator,
    frames: poll.ChunkStack(Frame),
    last: ?Value = null,
    /// The depth-0 left operand, when the caller handed its ownership over
    /// rather than lending it. Only this value may be offered as a reuse
    /// candidate: a descended element with one reference is owned by its
    /// spine, not by this operation.
    root: ?heap.OwnedValue = null,
    /// The whole operation, until the first `advance` starts it.
    root_child: ?Child = null,

    /// One pervasion step: an operation over operands that may themselves be
    /// containers. Starting it either finishes it at once or leaves exactly one
    /// frame on top that will.
    const Child = union(enum) { binary: BinaryNode, unary: UnaryNode };
    const Started = enum { finished, framed };
    /// What one list child is charged: the units its node frame and its
    /// parent's return visit cost when every child was pushed and popped.
    /// Started in place, a child keeps that weight rather than changing the
    /// turn length; its real weight is a separate measurement.
    const list_child_units = 2;

    const BinaryNode = struct {
        operation: BinaryOp,
        left: Value,
        right: Value,
        depth: usize,
        logical_index: ?usize,
    };
    const UnaryNode = struct {
        operation: UnaryOp,
        operand: Value,
        depth: usize,
        logical_index: ?usize,
    };
    const ListFrame = struct {
        operation: union(enum) { binary: BinaryOp, unary: UnaryOp },
        left: Value,
        right: ?Value,
        left_scalar: bool,
        right_scalar: bool,
        depth: usize,
        values: heap.OwnedValueBuffer,
        index: usize = 0,
        waiting: bool = false,
        /// Whether every child result so far is a list. A list of lists has no
        /// leaf representation to choose, so it publishes as a spine without
        /// profiling its children.
        all_lists: bool = true,
        /// Whether every child of this binary frame pairs two scalars: each
        /// operand is a scalar or a leaf. Such a child is exactly one scalar
        /// operation, so the frame applies it in place rather than starting a
        /// child node per element.
        scalar_children: bool = false,
        materializer: ?list.ValueMaterializer = null,

        fn deinit(self: *ListFrame, releases: *heap.ReleaseDomain) void {
            if (self.materializer) |*materializer| materializer.retire(releases);
            self.values.deinit();
        }
    };
    const DictMode = union(enum) {
        unary: UnaryOp,
        left: BinaryOp,
        right: BinaryOp,
        both: BinaryOp,
    };
    const DictFrame = struct {
        mode: DictMode,
        left: Value,
        right: ?Value,
        depth: usize,
        pairs: []dict.Pair,
        values: heap.OwnedValueBuffer,
        phase: enum { left, right, materialize } = .left,
        index: usize = 0,
        candidate: usize = 0,
        pair_count: usize = 0,
        waiting: bool = false,
        /// The keys at `index` and `candidate` matched, and their child has
        /// not yet paid its start unit. Kept so a comparison that spent the
        /// turn's last unit is not repeated when the frame resumes.
        matched: bool = false,
        match_cursor: ?equal.MatchCursor = null,
        materializer: ?dict.Materializer = null,

        fn deinit(self: *DictFrame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
            if (self.match_cursor) |*cursor| cursor.deinit();
            if (self.materializer) |*materializer| materializer.retire(releases);
            self.values.deinit();
            allocator.free(self.pairs);
        }
    };
    /// Every pervasion step moves frames by value, so the union's size is a
    /// per-element cost. A dictionary frame carries a match cursor and a
    /// materializer inline and is several times larger than the rest, so it
    /// lives behind a pointer; dictionary pervasion already allocates its
    /// pairs, and list and typed frames stay small.
    const Frame = union(enum) {
        list: ListFrame,
        dictionary: *DictFrame,
        typed: support.ErasedDriver,

        fn deinit(self: *Frame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .list => |*frame| frame.deinit(releases),
                .dictionary => |frame| {
                    frame.deinit(releases, allocator);
                    allocator.destroy(frame);
                },
                .typed => |*typed| typed.retire(releases, allocator),
            }
        }
    };

    /// What advancing the top frame did. `done` means the frame left its result
    /// in `last` and is popped and torn down; `progressed` leaves it in place,
    /// possibly under children it pushed; `pending` ends the turn.
    const FrameStep = enum { pending, progressed, done };

    /// Typed frames charge the unit through `advanceKernel`. A list frame spends one
    /// unit per child it starts and lends the budget to its materializer, and a
    /// dict frame that is materializing or comparing hands its work to that
    /// cursor.
    fn delegates(frame: *const Frame) bool {
        return switch (frame.*) {
            .typed, .list => true,
            .dictionary => |dict_frame| dict_frame.phase == .materialize or
                dict_frame.match_cursor != null or dict_frame.matched,
        };
    }

    pub fn initBinary(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        operation: BinaryOp,
        left: Value,
        right: Value,
    ) error{OutOfMemory}!PervadeCursor {
        var cursor = initIdle(releases, allocator);
        cursor.rearmBinary(operation, left, right);
        return cursor;
    }

    /// A cursor with no operation yet. A caller pervading many independent
    /// operands arms one cursor in place for each, rather than building and
    /// moving a cursor, whose frame stack holds its first frame inline, per
    /// operand.
    pub fn initIdle(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) PervadeCursor {
        return .{
            .releases = releases,
            .allocator = allocator,
            .frames = poll.ChunkStack(Frame).init(allocator),
        };
    }

    /// Starts an operation on a cursor that is idle or whose last operation
    /// completed. The operands are borrowed, as for `initBinary`.
    pub fn rearmBinary(self: *PervadeCursor, operation: BinaryOp, left: Value, right: Value) void {
        self.assertIdle();
        self.root_child = .{ .binary = .{
            .operation = operation,
            .left = left,
            .right = right,
            .depth = 0,
            .logical_index = null,
        } };
    }

    pub fn rearmUnary(self: *PervadeCursor, operation: UnaryOp, operand: Value) void {
        self.assertIdle();
        self.root_child = .{ .unary = .{
            .operation = operation,
            .operand = operand,
            .depth = 0,
            .logical_index = null,
        } };
    }

    fn assertIdle(self: *const PervadeCursor) void {
        std.debug.assert(self.frames.isEmpty() and self.last == null and self.root == null and self.root_child == null);
    }

    /// Like `initBinary`, but consumes `left`: the cursor owns it on success
    /// and on failure. An admitted typed root leaf may then be claimed as the
    /// step's output buffer; otherwise the cursor releases it at `deinit`.
    pub fn initBinaryOwningLeft(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        operation: BinaryOp,
        left: heap.OwnedValue,
        right: Value,
    ) error{OutOfMemory}!PervadeCursor {
        var owned = left;
        errdefer owned.deinit();
        var cursor = try initBinary(releases, allocator, operation, owned.borrow(), right);
        cursor.root = owned;
        return cursor;
    }

    pub fn initUnary(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        operation: UnaryOp,
        operand: Value,
    ) error{OutOfMemory}!PervadeCursor {
        var cursor = initIdle(releases, allocator);
        cursor.rearmUnary(operation, operand);
        return cursor;
    }

    pub fn deinit(self: *PervadeCursor) void {
        if (self.root) |*root| root.deinit();
        if (self.last) |last| self.releases.releaseValue(last);
        while (self.frames.pop()) |frame_value| {
            var frame = frame_value;
            frame.deinit(self.releases, self.allocator);
        }
        self.frames.deinit();
        self.* = undefined;
    }

    pub fn advance(
        self: *PervadeCursor,
        evaluator: *Fiber,
        work: *poll.WorkBudget,
    ) MachineError!PervadeProgress {
        while (true) {
            // The top frame is advanced where it lies. The stack never moves an
            // entry, so it stays put while children are pushed above it, and it
            // is popped only once it is finished; until then the stack owns it,
            // and an error leaves it for `deinit` like every other frame.
            const top = self.frames.topPtr() orelse {
                if (self.root_child) |child| {
                    if (!work.spend()) return .pending;
                    self.root_child = null;
                    _ = try self.start(evaluator, child);
                    continue;
                }
                const result = self.last.?;
                self.last = null;
                return .{ .complete = result };
            };
            // A frame handing work to a nested cursor is charged by that
            // cursor; spending first would starve it at a one-unit grain.
            if (!delegates(top) and !work.spend()) return .pending;
            const step: FrameStep = switch (top.*) {
                .list => |*list_frame| try self.advanceList(evaluator, list_frame, work),
                .dictionary => |dict_frame| try self.advanceDict(evaluator, dict_frame, work),
                .typed => |*typed| typed: {
                    self.last = try typed.advance(evaluator) orelse break :typed .pending;
                    // A completed kernel has already destroyed its driver and
                    // published its output; there is nothing left to retire.
                    _ = self.frames.pop();
                    break :typed .progressed;
                },
            };
            switch (step) {
                .pending => return .pending,
                .progressed => {},
                .done => {
                    var finished = self.frames.pop().?;
                    finished.deinit(self.releases, self.allocator);
                },
            }
        }
        return .pending;
    }

    fn start(self: *PervadeCursor, evaluator: *Fiber, child: Child) MachineError!Started {
        return switch (child) {
            .binary => |node| self.startBinary(evaluator, node),
            .unary => |node| self.startUnary(evaluator, node),
        };
    }

    /// A typed leaf runs as soon as it is built. Only one that suspends becomes
    /// a frame; one that finishes leaves its value in `last` with no frame.
    fn runTyped(self: *PervadeCursor, outcome: support.NestedOutcome) error{OutOfMemory}!Started {
        switch (outcome) {
            .value => |result| {
                self.last = result;
                return .finished;
            },
            .frame => |driver| {
                var typed = driver;
                errdefer typed.retire(self.releases, self.allocator);
                try self.frames.reserve(1);
                self.frames.pushReserved(.{ .typed = typed });
                return .framed;
            },
        }
    }

    fn startBinary(self: *PervadeCursor, evaluator: *Fiber, node: BinaryNode) MachineError!Started {
        if (node.depth >= support.max_depth and
            (node.left == .list or node.left == .dict or node.right == .list or node.right == .dict))
            return evaluator.fail(.domain, "pervasion nesting exceeds 256 levels");
        if (node.left == .dict or node.right == .dict) {
            try self.pushDictBinary(node);
            return .framed;
        }
        if (node.left == .list or node.right == .list) {
            if (try startNestedBinary(
                evaluator,
                node.operation,
                node.left,
                node.right,
                self.rootCandidate(node),
                .{},
            )) |typed| return self.runTyped(typed);
            const left_count: usize = if (node.left == .list) @intCast(node.left.list.length()) else 0;
            const right_count: usize = if (node.right == .list) @intCast(node.right.list.length()) else 0;
            if (node.left == .list and node.right == .list and left_count != right_count)
                return evaluator.conformError(left_count, right_count);
            const count = if (node.left == .list) left_count else right_count;
            var values = try heap.OwnedValueBuffer.init(self.releases, count);
            errdefer values.deinit();
            try self.frames.reserve(1);
            self.frames.pushReserved(.{ .list = .{
                .operation = .{ .binary = node.operation },
                .left = node.left,
                .right = node.right,
                .left_scalar = node.left != .list,
                .right_scalar = node.right != .list,
                .depth = node.depth,
                .values = values.take(),
                .scalar_children = holdsScalars(node.left) and holdsScalars(node.right),
            } });
            return .framed;
        }
        self.last = selectScalar(node.operation)(node.left, node.right) catch |fault|
            return scalarFailure(evaluator, fault, node.logical_index);
        return .finished;
    }

    /// Descended nodes are always deeper than zero, so only the initial node
    /// can be the owned root.
    fn rootCandidate(self: *PervadeCursor, node: BinaryNode) ?*heap.OwnedValue {
        if (node.depth != 0) return null;
        const root = if (self.root) |*owned| owned else return null;
        // A scalar root meeting a list has no buffer to offer.
        if (root.item == null or node.left != .list) return null;
        std.debug.assert(root.borrow() == .list and node.left.list == root.borrow().list);
        return root;
    }

    fn startUnary(self: *PervadeCursor, evaluator: *Fiber, node: UnaryNode) MachineError!Started {
        if (node.depth >= support.max_depth and (node.operand == .list or node.operand == .dict))
            return evaluator.fail(.domain, "pervasion nesting exceeds 256 levels");
        if (node.operand == .dict) {
            const count: usize = @intCast(node.operand.dict.length());
            const pairs = try self.allocator.alloc(dict.Pair, count);
            errdefer self.allocator.free(pairs);
            var values = try heap.OwnedValueBuffer.init(self.releases, count);
            errdefer values.deinit();
            const frame = try self.allocator.create(DictFrame);
            errdefer self.allocator.destroy(frame);
            try self.frames.reserve(1);
            frame.* = .{
                .mode = .{ .unary = node.operation },
                .left = node.operand,
                .right = null,
                .depth = node.depth,
                .pairs = pairs,
                .values = values.take(),
            };
            self.frames.pushReserved(.{ .dictionary = frame });
            return .framed;
        }
        if (node.operand == .list) {
            if (try startNestedUnary(evaluator, node.operation, node.operand, .{})) |typed|
                return self.runTyped(typed);
            const count: usize = @intCast(node.operand.list.length());
            var values = try heap.OwnedValueBuffer.init(self.releases, count);
            errdefer values.deinit();
            try self.frames.reserve(1);
            self.frames.pushReserved(.{ .list = .{
                .operation = .{ .unary = node.operation },
                .left = node.operand,
                .right = null,
                .left_scalar = false,
                .right_scalar = false,
                .depth = node.depth,
                .values = values.take(),
            } });
            return .framed;
        }
        self.last = selectUnary(node.operation)(node.operand) catch |fault|
            return scalarFailure(evaluator, fault, node.logical_index);
        return .finished;
    }

    fn advanceList(
        self: *PervadeCursor,
        evaluator: *Fiber,
        frame: *ListFrame,
        work: *poll.WorkBudget,
    ) MachineError!FrameStep {
        if (frame.waiting) {
            frame.waiting = false;
            self.acceptListChild(frame);
        }
        // Children start where they are found. One that finishes is appended
        // without touching the stack; one that leaves a frame is waited on.
        while (frame.index != frame.values.capacity()) {
            if (work.take(list_child_units) == 0) return .pending;
            const index = frame.index;
            if (frame.scalar_children) {
                // Exactly the scalar path `startBinary` takes for this child.
                const left = if (frame.left_scalar) frame.left else list.atUnchecked(frame.left, index);
                const right = if (frame.right_scalar) frame.right.? else list.atUnchecked(frame.right.?, index);
                const result = selectScalar(frame.operation.binary)(left, right) catch |fault|
                    return scalarFailure(evaluator, fault, index);
                frame.all_lists = false;
                frame.values.appendOwned(result);
                frame.index += 1;
                continue;
            }
            const child: Child = switch (frame.operation) {
                .binary => |operation| .{ .binary = .{
                    .operation = operation,
                    .left = if (frame.left_scalar) frame.left else list.atUnchecked(frame.left, index),
                    .right = if (frame.right_scalar) frame.right.? else list.atUnchecked(frame.right.?, index),
                    .depth = frame.depth + 1,
                    .logical_index = index,
                } },
                .unary => |operation| .{ .unary = .{
                    .operation = operation,
                    .operand = list.atUnchecked(frame.left, index),
                    .depth = frame.depth + 1,
                    .logical_index = index,
                } },
            };
            const started = switch (child) {
                .binary => |node| try self.startNumericRow(evaluator, node),
                .unary => null,
            } orelse try self.start(evaluator, child);
            switch (started) {
                .finished => self.acceptListChild(frame),
                .framed => {
                    frame.waiting = true;
                    return .progressed;
                },
            }
        }
        if (frame.all_lists and frame.values.capacity() != 0) {
            self.last = frame.values.takeList();
            return .done;
        }
        if (frame.materializer == null)
            frame.materializer = .init(self.allocator, frame.values.values());
        switch (try frame.materializer.?.advance(work)) {
            .pending => return .pending,
            .complete => |result| {
                self.last = result;
                return .done;
            },
        }
    }

    /// A list child whose operands are a numeric leaf and a numeric leaf or
    /// scalar runs its kernel here, without a child node or frame: exactly
    /// what `startBinary` would run for it, with the same conformance check
    /// and fault report. A kernel the turn cannot finish becomes the typed
    /// frame `runTyped` would push. Null leaves every other child to `start`.
    fn startNumericRow(self: *PervadeCursor, evaluator: *Fiber, node: BinaryNode) MachineError!?Started {
        // A leaf is still a list to the depth guard, which `startBinary` owns.
        if (node.depth >= support.max_depth) return null;
        const left_leaf = leafNumber(node.left);
        const right_leaf = leafNumber(node.right);
        const shape: Shape = if (left_leaf != null and right_leaf != null)
            .leaf_leaf
        else if (left_leaf != null and scalarNumber(node.right) != null)
            .leaf_scalar
        else if (right_leaf != null and scalarNumber(node.left) != null)
            .scalar_leaf
        else
            return null;
        const length = try conformingLength(evaluator, shape, node.left, node.right);
        if (length == 0) return null;
        const plan = NumericBinaryPlan.select(
            node.operation,
            left_leaf orelse scalarNumber(node.left).?,
            right_leaf orelse scalarNumber(node.right).?,
            shape,
        ) orelse return null;
        const data: *const NumericBinaryPlan.Data = @ptrCast(@alignCast(plan));
        return try self.runTyped(try data.startNested(evaluator, .{ node.left, node.right }, null, .{}, length));
    }

    fn acceptListChild(self: *PervadeCursor, frame: *ListFrame) void {
        if (self.last.? != .list) frame.all_lists = false;
        frame.values.appendOwned(self.last.?);
        self.last = null;
        frame.index += 1;
    }

    fn pushDictBinary(self: *PervadeCursor, node: BinaryNode) error{OutOfMemory}!void {
        const both = node.left == .dict and node.right == .dict;
        const dictionary = if (node.left == .dict) node.left else node.right;
        const capacity: usize = if (both)
            @as(usize, @intCast(node.left.dict.length())) + @as(usize, @intCast(node.right.dict.length()))
        else
            @intCast(dictionary.dict.length());
        const pairs = try self.allocator.alloc(dict.Pair, capacity);
        errdefer self.allocator.free(pairs);
        var values = try heap.OwnedValueBuffer.init(self.releases, capacity);
        errdefer values.deinit();
        const frame = try self.allocator.create(DictFrame);
        errdefer self.allocator.destroy(frame);
        try self.frames.reserve(1);
        frame.* = .{
            .mode = if (both)
                .{ .both = node.operation }
            else if (node.left == .dict)
                .{ .left = node.operation }
            else
                .{ .right = node.operation },
            .left = node.left,
            .right = node.right,
            .depth = node.depth,
            .pairs = pairs,
            .values = values.take(),
        };
        self.frames.pushReserved(.{ .dictionary = frame });
    }

    fn advanceDict(
        self: *PervadeCursor,
        evaluator: *Fiber,
        frame: *DictFrame,
        work: *poll.WorkBudget,
    ) MachineError!FrameStep {
        if (frame.waiting) {
            frame.waiting = false;
            self.acceptDictChild(frame);
        }
        if (frame.phase == .materialize) {
            if (frame.materializer == null) frame.materializer = try .init(
                self.allocator,
                frame.pairs[0..frame.pair_count],
                false,
            );
            switch (try frame.materializer.?.advance(work)) {
                .pending => return .pending,
                .duplicate_key => unreachable,
                .complete => |result| {
                    frame.materializer.?.deinit();
                    frame.materializer = null;
                    self.last = result;
                    return .done;
                },
            }
        }
        switch (frame.mode) {
            .unary, .left, .right => {
                const dictionary = switch (frame.mode) {
                    .unary, .left => frame.left,
                    .right => frame.right.?,
                    .both => unreachable,
                };
                const count: usize = @intCast(dictionary.dict.length());
                if (frame.index == count) {
                    frame.phase = .materialize;
                    return .progressed;
                }
                const index = frame.index;
                frame.pairs[frame.pair_count][0] = dict.keyAt(dictionary.dict, index);
                const child: Child = switch (frame.mode) {
                    .unary => |operation| .{ .unary = .{
                        .operation = operation,
                        .operand = dict.valueAt(dictionary.dict, index),
                        .depth = frame.depth + 1,
                        .logical_index = index,
                    } },
                    .left => |operation| .{ .binary = .{
                        .operation = operation,
                        .left = dict.valueAt(dictionary.dict, index),
                        .right = frame.right.?,
                        .depth = frame.depth + 1,
                        .logical_index = index,
                    } },
                    .right => |operation| .{ .binary = .{
                        .operation = operation,
                        .left = frame.left,
                        .right = dict.valueAt(dictionary.dict, index),
                        .depth = frame.depth + 1,
                        .logical_index = index,
                    } },
                    .both => unreachable,
                };
                return self.startDictChild(evaluator, frame, child, work);
            },
            .both => |operation| {
                const left_count: usize = @intCast(frame.left.dict.length());
                const right_count: usize = @intCast(frame.right.?.dict.length());
                const source = if (frame.phase == .left) frame.left else frame.right.?;
                const source_count = if (frame.phase == .left) left_count else right_count;
                const other = if (frame.phase == .left) frame.right.? else frame.left;
                const other_count = if (frame.phase == .left) right_count else left_count;
                if (frame.index == source_count) {
                    if (frame.phase == .left) {
                        frame.phase = .right;
                        frame.index = 0;
                        frame.candidate = 0;
                    } else frame.phase = .materialize;
                    return .progressed;
                }
                if (frame.candidate == other_count) {
                    const key = dict.keyAt(source.dict, frame.index);
                    const item = dict.valueAt(source.dict, frame.index);
                    frame.values.appendBorrowed(item);
                    frame.pairs[frame.pair_count] = .{ key, item };
                    frame.pair_count += 1;
                    frame.index += 1;
                    frame.candidate = 0;
                    return .progressed;
                }
                if (!frame.matched) {
                    if (frame.match_cursor == null) frame.match_cursor = try .init(
                        self.allocator,
                        dict.keyAt(source.dict, frame.index),
                        dict.keyAt(other.dict, frame.candidate),
                    );
                    switch (try frame.match_cursor.?.advance(work)) {
                        .pending => return .pending,
                        .complete => |matches| {
                            frame.match_cursor.?.deinit();
                            frame.match_cursor = null;
                            if (!matches) {
                                frame.candidate += 1;
                                return .progressed;
                            }
                            if (frame.phase == .right) {
                                frame.index += 1;
                                frame.candidate = 0;
                                return .progressed;
                            }
                            frame.matched = true;
                        },
                    }
                }
                const index = frame.index;
                const candidate = frame.candidate;
                frame.pairs[frame.pair_count][0] = dict.keyAt(frame.left.dict, index);
                return self.startDictChild(evaluator, frame, .{ .binary = .{
                    .operation = operation,
                    .left = dict.valueAt(frame.left.dict, index),
                    .right = dict.valueAt(frame.right.?.dict, candidate),
                    .depth = frame.depth + 1,
                    .logical_index = index,
                } }, work);
            },
        }
    }

    /// A dict frame still pays for its own visit; this is the unit the child's
    /// node frame used to cost.
    fn startDictChild(self: *PervadeCursor, evaluator: *Fiber, frame: *DictFrame, child: Child, work: *poll.WorkBudget) MachineError!FrameStep {
        if (!work.spend()) return .pending;
        frame.matched = false;
        switch (try self.start(evaluator, child)) {
            .finished => self.acceptDictChild(frame),
            .framed => frame.waiting = true,
        }
        return .progressed;
    }

    /// Records the value of the child whose key is staged at `pair_count`.
    fn acceptDictChild(self: *PervadeCursor, frame: *DictFrame) void {
        frame.values.appendOwned(self.last.?);
        frame.pairs[frame.pair_count][1] = self.last.?;
        self.last = null;
        frame.pair_count += 1;
        frame.index += 1;
        frame.candidate = 0;
    }
};

/// Whether every element of `item`, taken as a pervasion operand, is a scalar:
/// it is a scalar itself or a leaf. A dict never reaches a list frame.
fn holdsScalars(item: Value) bool {
    return item != .list or item.list.kind() != .generic_spine;
}

fn selectScalar(operation: BinaryOp) ScalarBinary {
    return switch (operation) {
        inline else => |comptime_operation| struct {
            fn run(left: Value, right: Value) ScalarError!Value {
                return scalarBinary(comptime_operation, left, right);
            }
        }.run,
    };
}

fn selectUnary(operation: UnaryOp) ScalarUnary {
    return switch (operation) {
        inline else => |comptime_operation| struct {
            fn run(operand: Value) ScalarError!Value {
                return scalarUnary(comptime_operation, operand);
            }
        }.run,
    };
}

/// The element count a binary shape conforms to, or the conformance failure
/// that shape reports. `leaf_only` is a unary shape and never reaches here.
fn conformingLength(
    evaluator: *Fiber,
    shape: Shape,
    left_item: Value,
    right_item: Value,
) MachineError!usize {
    return switch (shape) {
        .leaf_leaf => blk: {
            const left_count: usize = @intCast(left_item.list.length());
            const right_count: usize = @intCast(right_item.list.length());
            if (left_count != right_count) return evaluator.conformError(left_count, right_count);
            break :blk left_count;
        },
        .leaf_scalar => @intCast(left_item.list.length()),
        .scalar_leaf => @intCast(right_item.list.length()),
        .leaf_only => unreachable,
    };
}

const ScalarDiagnostic = struct {
    kind: machine.ErrorKind,
    message: []const u8,
};

/// One mapping from a scalar kernel fault to the diagnostic that reports it.
/// The three reporting surfaces — the evaluator, an indexed kernel context, and
/// a sequential fold — differ in where they send the diagnostic, never in what
/// it says.
fn scalarDiagnostic(fault: ScalarError) ScalarDiagnostic {
    return switch (fault) {
        error.Type => .{ .kind = .type, .message = "kernel received incompatible scalar operands" },
        error.Overflow => .{ .kind = .overflow, .message = "kernel arithmetic overflow" },
        error.Domain => .{ .kind = .domain, .message = "kernel arithmetic is outside its domain" },
        error.ShiftCount => .{ .kind = .domain, .message = "a shift count must be from 0 to 63" },
    };
}

fn scalarFailure(evaluator: *Fiber, fault: ScalarError, index: ?usize) MachineError {
    const diagnostic = scalarDiagnostic(fault);
    if (index) |logical_index|
        return evaluator.failAtIndex(diagnostic.kind, diagnostic.message, logical_index);
    return evaluator.fail(diagnostic.kind, diagnostic.message);
}

/// A char as its codepoint: the scalar authority sees chars as ints.
fn ordinal(item: Value) Value {
    return switch (item) {
        .char => |codepoint| .{ .int = codepoint },
        else => item,
    };
}

fn scalarBinary(comptime operation: BinaryOp, left_item: Value, right_item: Value) ScalarError!Value {
    const left = ordinal(left_item);
    const right = ordinal(right_item);
    return switch (operation) {
        .add => add(left, right),
        .sub => sub(left, right),
        .mul => numericBinary(left, right, operation),
        .div => divide(left, right),
        .int_div => integerDivision(left, right, false),
        .mod => integerDivision(left, right, true),
        .pow => power(left, right),
        .atan2 => atan2(left, right),
        .min, .max => minMax(left, right, operation == .min),
        .eq, .ne, .lt, .gt, .le, .ge => comparison(left, right, operation),
        .and_word, .or_word => booleanBinary(left, right, operation == .and_word),
        .band, .bor, .bxor => bitwiseBinary(left, right, operation),
        .bsl, .bsr => bitwiseShift(left, right, operation == .bsl),
        .wrap_add, .wrap_sub, .wrap_mul => wrappingBinary(left, right, operation),
    };
}

fn scalarUnary(comptime operation: UnaryOp, operand_item: Value) ScalarError!Value {
    const operand = ordinal(operand_item);
    return switch (operation) {
        .not_word => .{ .int = @intFromBool(!(try boolean(operand))) },
        .neg => switch (operand) {
            .int => |integer| .{ .int = std.math.sub(i64, 0, integer) catch return error.Overflow },
            .float => |number| .{ .float = -number },
            .char, .symbol, .list, .dict, .task, .port, .address => error.Type,
        },
        .abs => switch (operand) {
            .int => |integer| if (integer == std.math.minInt(i64))
                error.Overflow
            else
                .{ .int = if (integer < 0) -integer else integer },
            .float => |number| .{ .float = @abs(number) },
            .char, .symbol, .list, .dict, .task, .port, .address => error.Type,
        },
        .sqrt => switch (operand) {
            .int => |integer| if (integer < 0)
                error.Domain
            else
                .{ .float = @sqrt(@as(f64, @floatFromInt(integer))) },
            .float => |number| if (number < 0.0)
                error.Domain
            else
                .{ .float = @sqrt(number) },
            .char, .symbol, .list, .dict, .task, .port, .address => error.Type,
        },
        .floor, .ceil, .round => switch (operand) {
            .int => operand,
            .float => |number| floatToInt(switch (operation) {
                .floor => @floor(number),
                .ceil => @ceil(number),
                .round => @round(number),
                else => unreachable,
            }),
            .char, .symbol, .list, .dict, .task, .port, .address => error.Type,
        },
        .exp, .log, .sin, .cos => transcendental(operation, operand),
        .bnot => switch (operand) {
            .int => |integer| .{ .int = ~integer },
            .char, .float, .symbol, .list, .dict, .task, .port, .address => error.Type,
        },
    };
}

/// Bitwise words are *pattern* words: they read the i64 two's-complement bit
/// pattern and cannot overflow, which is why they carry no overflow arm while
/// every arithmetic word does. Int-only, following `integerDivision`.
fn bitwiseBinary(left: Value, right: Value, operation: BinaryOp) ScalarError!Value {
    if (left != .int or right != .int) return error.Type;
    return .{ .int = switch (operation) {
        .band => left.int & right.int,
        .bor => left.int | right.int,
        .bxor => left.int ^ right.int,
        else => unreachable,
    } };
}

/// Wrapping arithmetic is two's-complement i64 arithmetic modulo 2^64: it
/// cannot overflow, so it carries no overflow arm. Int-only, like the
/// bitwise words; the checked words keep floats and characters.
fn wrappingBinary(left: Value, right: Value, operation: BinaryOp) ScalarError!Value {
    if (left != .int or right != .int) return error.Type;
    return .{ .int = switch (operation) {
        .wrap_add => left.int +% right.int,
        .wrap_sub => left.int -% right.int,
        .wrap_mul => left.int *% right.int,
        else => unreachable,
    } };
}

/// Shifts move bits rather than scaling a magnitude: `bsl` truncates off the
/// top instead of raising overflow, and `bsr` fills zeros from the top. A
/// count outside 0..63 has no bit-movement meaning and is `'domain`.
fn bitwiseShift(left: Value, right: Value, shift_left: bool) ScalarError!Value {
    if (left != .int or right != .int) return error.Type;
    if (right.int < 0 or right.int > 63) return error.ShiftCount;
    const amount: u6 = @intCast(right.int);
    const pattern: u64 = @bitCast(left.int);
    return .{ .int = @bitCast(if (shift_left)
        pattern << amount
    else
        pattern >> amount) };
}

/// `inline` so a typed reduction's inlined `scalarBinary` folds the character
/// tests below along with the tag dispatch; LLVM keeps these out of line
/// otherwise, and the call stays in the element loop.
inline fn add(left: Value, right: Value) ScalarError!Value {
    return numericBinary(left, right, .add);
}

/// `inline` for the same reason as `add`.
inline fn sub(left: Value, right: Value) ScalarError!Value {
    return numericBinary(left, right, .sub);
}

fn numericBinary(left: Value, right: Value, operation: BinaryOp) ScalarError!Value {
    if (!left.isNumber() or !right.isNumber()) return error.Type;
    if (left == .int and right == .int) {
        return .{ .int = switch (operation) {
            .add => std.math.add(i64, left.int, right.int) catch return error.Overflow,
            .sub => std.math.sub(i64, left.int, right.int) catch return error.Overflow,
            .mul => std.math.mul(i64, left.int, right.int) catch return error.Overflow,
            else => unreachable,
        } };
    }
    const a = asFloat(left);
    const b = asFloat(right);
    const result = switch (operation) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        else => unreachable,
    };
    return checkedFloat(result);
}

/// Float division under IEEE rules: a nonzero numerator over zero is an
/// infinity signed by both operands, and `0 0 /` is NaN, so `'domain`.
fn divide(left: Value, right: Value) ScalarError!Value {
    if (!left.isNumber() or !right.isNumber()) return error.Type;
    return checkedFloat(asFloat(left) / asFloat(right));
}

fn integerDivision(left: Value, right: Value, remainder: bool) ScalarError!Value {
    if (left != .int or right != .int) return error.Type;
    if (right.int == 0) return error.Domain;
    if (left.int == std.math.minInt(i64) and right.int == -1) return error.Overflow;
    return .{ .int = if (remainder)
        @rem(left.int, right.int)
    else
        @divTrunc(left.int, right.int) };
}

fn power(left: Value, right: Value) ScalarError!Value {
    if (!left.isNumber() or !right.isNumber()) return error.Type;
    const a = asFloat(left);
    const b = asFloat(right);
    return checkedFloat(std.math.pow(f64, a, b));
}

fn atan2(left: Value, right: Value) ScalarError!Value {
    if (!left.isNumber() or !right.isNumber()) return error.Type;
    return .{ .float = std.math.atan2(asFloat(left), asFloat(right)) };
}

fn transcendental(operation: UnaryOp, operand: Value) ScalarError!Value {
    if (!operand.isNumber()) return error.Type;
    const number = asFloat(operand);
    const result = switch (operation) {
        .exp => @exp(number),
        .log => @log(number),
        .sin => @sin(number),
        .cos => @cos(number),
        .neg, .abs, .sqrt, .floor, .ceil, .round, .not_word, .bnot => unreachable,
    };
    return checkedFloat(result);
}

fn minMax(left: Value, right: Value, choose_min: bool) ScalarError!Value {
    const ordering = equal.compareScalars(left, right) catch return error.Type;
    const choose_left = if (choose_min) ordering != .gt else ordering != .lt;
    return if (choose_left) left else right;
}

fn comparison(left: Value, right: Value, operation: BinaryOp) ScalarError!Value {
    const ordering = equal.compareScalars(left, right) catch return error.Type;
    const result = switch (operation) {
        .eq => ordering == .eq,
        .ne => ordering != .eq,
        .lt => ordering == .lt,
        .gt => ordering == .gt,
        .le => ordering != .gt,
        .ge => ordering != .lt,
        else => unreachable,
    };
    return .{ .int = @intFromBool(result) };
}

fn booleanBinary(left: Value, right: Value, conjunction: bool) ScalarError!Value {
    const a = try boolean(left);
    const b = try boolean(right);
    return .{ .int = @intFromBool(if (conjunction) a and b else a or b) };
}

fn boolean(operand: Value) ScalarError!bool {
    if (operand != .int or (operand.int != 0 and operand.int != 1)) return error.Type;
    return operand.int == 1;
}

/// Floats follow IEEE 754, so overflow, poles, and division by zero give an
/// infinity; only a NaN result, which ECL has no value for, is `'domain`.
/// No operand is ever NaN, since every boundary that makes floats from outside
/// bits rejects one, so an operation that cannot make NaN from ordinary floats
/// (negation, magnitude, `atan2`, square root of a nonnegative) skips this.
fn checkedFloat(result: f64) ScalarError!Value {
    if (std.math.isNan(result)) return error.Domain;
    return .{ .float = result };
}

fn floatToInt(number: f64) ScalarError!Value {
    const lower: f64 = -9_223_372_036_854_775_808.0;
    const upper: f64 = 9_223_372_036_854_775_808.0;
    if (!std.math.isFinite(number) or number < lower or number >= upper) return error.Overflow;
    return .{ .int = @intFromFloat(number) };
}

fn asFloat(operand: Value) f64 {
    return switch (operand) {
        .int => |integer| @floatFromInt(integer),
        .float => |number| number,
        .char, .symbol, .list, .dict, .task, .port, .address => unreachable,
    };
}

// ===========================================================================
// Typed flat-leaf execution
//
// One route for every numeric pervasion whose operands are flat numeric leaves
// or numeric scalars and whose result width is known before the first element:
// dispatch once, read the unboxed slices, stage a bounded block, store that
// block straight into the typed output buffer. No cell is boxed, no frame is
// pushed per element, and nothing is profiled afterwards to recover a
// representation the dispatch already knew.
//
// Scalar-classified bodies call `scalarBinary`/`scalarUnary` with statically
// known operand tags. The closed explicit-vector set has direct lane formulas,
// but a checked block still replays through those scalar authorities to report
// the first failing index, kind, and message.
// ===========================================================================

/// The element classes a typed loop carries. `byte` and the three char
/// widths are storage classes of one integral class: a loop widens their
/// lanes to ints, and no operation produces them; a 0/1 result is a byte, an
/// arithmetic result an int or a real. Chars enter as their codepoints and
/// leave as ints; `char` is the way back. The declaration order is the
/// plan tables' index order.
const Number = enum {
    byte,
    char1,
    char2,
    char4,
    integer,
    real,

    fn Element(comptime self: Number) type {
        return switch (self) {
            .byte, .char1 => u8,
            .char2 => u16,
            .char4 => u32,
            .integer => i64,
            .real => f64,
        };
    }

    fn kind(comptime self: Number) value.HeapKind {
        return switch (self) {
            .byte => .leaf_u8,
            .char1 => .leaf_char1,
            .char2 => .leaf_char2,
            .char4 => .leaf_char4,
            .integer => .leaf_i64,
            .real => .leaf_f64,
        };
    }

    /// Whether a scalar operand has this class: a stored width has no scalar.
    fn scalar(self: Number) bool {
        return self == .integer or self == .real;
    }

    fn boxed(comptime self: Number, element: self.Element()) Value {
        return switch (self) {
            .byte, .char1, .char2, .char4, .integer => .{ .int = element },
            .real => .{ .float = element },
        };
    }

    /// A result as this class's element, or a scalar operand as its element:
    /// a char scalar is read as its codepoint.
    fn unboxed(comptime self: Number, item: Value) self.Element() {
        return switch (self) {
            .byte => @intCast(item.int),
            .char1, .char2, .char4 => unreachable,
            .integer => switch (item) {
                .int => |number| number,
                .char => |codepoint| codepoint,
                else => unreachable,
            },
            .real => item.float,
        };
    }
};

const number_classes = [_]Number{ .byte, .char1, .char2, .char4, .integer, .real };

fn scalarNumber(item: Value) ?Number {
    return switch (item) {
        .int, .char => .integer,
        .float => .real,
        .symbol, .list, .dict, .task, .port, .address => null,
    };
}

fn leafNumber(item: Value) ?Number {
    if (item != .list) return null;
    return switch (item.list.kind()) {
        .leaf_u8 => .byte,
        .leaf_char1 => .char1,
        .leaf_char2 => .char2,
        .leaf_char4 => .char4,
        .leaf_i64 => .integer,
        .leaf_f64 => .real,
        else => null,
    };
}

/// The result class of one binary operation on two numeric classes, or null when
/// no typed loop exists for the pair.
///
/// `min` and `max` return one of their operands rather than a computed value, so
/// a mixed pair yields ints and floats element by element — genuinely
/// heterogeneous, and the one numeric shape that stays on the profiling route.
///
/// The int-only words fault on every element with a real operand, so such a pair
/// has no result to type. Declining it leaves the fault to the generic route,
/// which reports it identically, and keeps a loop that could never complete out
/// of every binary.
fn binaryResult(comptime operation: BinaryOp, comptime left: Number, comptime right: Number) ?Number {
    const real = left == .real or right == .real;
    return switch (operation) {
        .add, .sub, .mul => if (real) .real else .integer,
        .div, .pow, .atan2 => .real,
        .int_div, .mod, .band, .bor, .bxor, .bsl, .bsr => if (real) null else .integer,
        .wrap_add, .wrap_sub, .wrap_mul => if (real) null else .integer,
        .and_word, .or_word => if (real) null else .byte,
        // A 0/1 result is a byte: a mask over a large list costs one byte per
        // element, and every consumer of a byte leaf reads it as an int.
        .eq, .ne, .lt, .gt, .le, .ge => .byte,
        .min, .max => if (real)
            if (left != right) null else .real
        else if (left == .byte and right == .byte)
            .byte
        else
            .integer,
    };
}

fn unaryResult(comptime operation: UnaryOp, comptime operand: Number) Number {
    return switch (operation) {
        .neg => if (operand == .real) .real else .integer,
        .abs => if (operand == .real or operand == .byte) operand else .integer,
        .sqrt, .exp, .log, .sin, .cos => .real,
        .floor, .ceil, .round => .integer,
        .not_word => .byte,
        .bnot => .integer,
    };
}

/// How the operands are shaped at dispatch. A scalar operand is read with stride
/// zero; no broadcast is ever materialized.
const Shape = enum { leaf_leaf, leaf_scalar, scalar_leaf, leaf_only };
const binary_shapes = [_]Shape{ .leaf_leaf, .leaf_scalar, .scalar_leaf };

/// The closed execution policy selected from the operation and typed element
/// classes. Only checked policies may request scalar replay.
const LoopPolicy = enum {
    vector_infallible,
    vector_checked,
    scalar_infallible,
    scalar_checked,

    fn isVector(self: LoopPolicy) bool {
        return self == .vector_infallible or self == .vector_checked;
    }
};

fn binaryLoopPolicy(
    comptime operation: BinaryOp,
    comptime left: Number,
    comptime right: Number,
) LoopPolicy {
    // Bytes are ints to every loop: a byte lane widens to an int lane before
    // the operation, so byte and mixed pairs take the int loops.
    if (left != .real and right != .real) return switch (operation) {
        .eq, .ne, .lt, .gt, .le, .ge, .min, .max, .band, .bor, .bxor => .vector_infallible,
        .wrap_add, .wrap_sub => .vector_infallible,
        .wrap_mul => if (support.targetHasNativePackedI64Multiply()) .vector_infallible else .scalar_infallible,
        .add, .sub => .vector_checked,
        .mul => if (support.targetHasNativePackedI64Multiply()) .vector_checked else .scalar_checked,
        .and_word, .or_word => .vector_checked,
        .div, .int_div, .mod, .pow, .atan2, .bsl, .bsr => .scalar_checked,
    };
    if (left == .real and right == .real) return switch (operation) {
        // No operand is NaN, so comparison and selection cannot fail.
        .eq, .ne, .lt, .gt, .le, .ge, .min, .max => .vector_infallible,
        .add, .sub, .mul, .div => .vector_checked,
        .pow, .atan2 => .scalar_checked,
        .int_div, .mod, .and_word, .or_word, .band, .bor, .bxor, .bsl, .bsr => .scalar_checked,
        .wrap_add, .wrap_sub, .wrap_mul => .scalar_checked,
    };
    return .scalar_checked;
}

fn unaryLoopPolicy(comptime operation: UnaryOp, comptime operand: Number) LoopPolicy {
    if (operand == .integer and operation == .bnot) return .vector_infallible;
    if (operand != .real and operation == .not_word) return .vector_checked;
    // No operand is NaN, so a float's negation or magnitude cannot fault.
    if (operand == .real and (operation == .neg or operation == .abs)) return .vector_infallible;
    return .scalar_checked;
}

/// Whether a fault carries a logical index.
///
/// Direct pervasion over a list reports the failing element's index, exactly as
/// the boxed route does. A recognized `each`/`zip-with` idiom does not: the
/// generic combinator it stands in for applies the quotation to one element at a
/// time and its fault has no list position, so the fused path must not invent
/// one.
const FaultReport = struct { index: bool = true };

/// What a numeric kernel needs besides its operands: how a fault is reported.
/// Whether an operand's buffer may become the output is the executor's to
/// decide, from which operands the call owns.
const NumericParams = struct {
    report: FaultReport = .{},
};

fn failTypedScalar(
    evaluator: *Fiber,
    report: FaultReport,
    fault: ScalarError,
    index: usize,
) MachineError {
    const diagnostic = scalarDiagnostic(fault);
    if (report.index) return evaluator.failAtIndex(diagnostic.kind, diagnostic.message, index);
    return evaluator.fail(diagnostic.kind, diagnostic.message);
}

/// The next piece of a charged range. A vector loop writes its output's own
/// range and stages nothing, so it takes the rest of the range as one block and
/// pays its fixed per-block work once; a scalar loop's staging is bounded by the
/// staging array. Either way the piece lies inside the range already charged,
/// which also bounds a faulted piece's exact pass and scalar replay.
/// Where a typed range loop writes: the kernel's output, which may be an
/// operand's own buffer, or a scalar program block's scratch run. A loop takes
/// its target at compile time, so each keeps its own inlined body.
fn OutputTarget(comptime class: Number) type {
    return struct {
        output: *support.LeafResult(class.kind()),

        /// The output's own range, which a vector loop writes directly. A
        /// result written over its operands is stored only after its
        /// positions are read; see `flat.Placement`.
        fn vector(self: @This(), piece: flat.Chunk) []class.Element() {
            return self.output.range(piece.start, piece.len());
        }

        fn store(self: @This(), offset: usize, items: []const class.Element()) void {
            self.output.store(offset, items);
        }
    };
}

fn SliceTarget(comptime class: Number) type {
    return struct {
        items: []class.Element(),

        fn vector(self: @This(), piece: flat.Chunk) []class.Element() {
            return self.items[piece.start..piece.end];
        }

        fn store(self: @This(), offset: usize, items: []const class.Element()) void {
            @memcpy(self.items[offset..][0..items.len], items);
        }
    };
}

fn nextPiece(comptime vector: bool, range: flat.Chunk, offset: usize) flat.Chunk {
    if (vector) return .{ .start = range.start + offset, .end = range.end };
    return flat.blockRange(range, offset);
}

/// Narrows a block of lane values to the result element, by bit pattern: a
/// lane that faulted is discarded by its mask, so its value need not fit.
fn narrowLanes(comptime In: type, comptime Out: type, comptime lanes: usize, values: @Vector(lanes, In)) @Vector(lanes, Out) {
    if (In == Out) return values;
    comptime std.debug.assert(@bitSizeOf(Out) < @bitSizeOf(In));
    if (comptime @typeInfo(In).int.signedness == .signed) {
        const pattern: @Vector(lanes, u64) = @bitCast(values);
        return @truncate(pattern);
    }
    return @truncate(values);
}

/// The narrower of two element types.
fn Narrowest(comptime A: type, comptime B: type) type {
    return if (@sizeOf(A) <= @sizeOf(B)) A else B;
}

/// A binary typed operation: one range loop (runPieces) and its replay, run
/// by its result class's `BinaryKernel` at top level or inside pervasion.
fn binaryKernel(
    comptime operation: BinaryOp,
    comptime left_class: Number,
    comptime right_class: Number,
    comptime shape: Shape,
) type {
    return binaryKernelInto(operation, left_class, right_class, shape, comptime binaryResult(operation, left_class, right_class).?);
}

/// The operation that computes `operation(a, b)` as `twin(b, a)`, or null when
/// the order matters. A real `min` or `max` is order-dependent: the selection
/// between `-0.0` and `0.0` keeps whichever operand came first. Every twin
/// reports the same fault for the same element as the operation it stands for.
fn mirroredOperation(comptime operation: BinaryOp, comptime left: Number, comptime right: Number) ?BinaryOp {
    return switch (operation) {
        .add, .mul, .eq, .ne, .band, .bor, .bxor, .wrap_add, .wrap_mul, .and_word, .or_word => operation,
        .lt => .gt,
        .gt => .lt,
        .le => .ge,
        .ge => .le,
        .min, .max => if (left == .real or right == .real) null else operation,
        .sub, .div, .int_div, .mod, .pow, .atan2, .bsl, .bsr, .wrap_sub => null,
    };
}

fn mirroredShape(comptime shape: Shape) Shape {
    return switch (shape) {
        .leaf_leaf => .leaf_leaf,
        .leaf_scalar => .scalar_leaf,
        .scalar_leaf => .leaf_scalar,
        .leaf_only => unreachable,
    };
}

/// Whether a binary plan runs its mirrored twin's loop rather than one of its
/// own: a scalar on the left, or leaves whose classes are out of order. Each
/// unordered pair then compiles one loop, and the twin's loop is the same code
/// with its operands exchanged. A pair with one real operand keeps the real
/// first in either shape: its scalar comparison measured slower with the int
/// first, and both orders of its arithmetic measured alike.
fn mirrorsOnto(comptime operation: BinaryOp, comptime left: Number, comptime right: Number, comptime shape: Shape) bool {
    if (mirroredOperation(operation, left, right) == null) return false;
    if (shape == .leaf_scalar or shape == .leaf_only) return false;
    if ((left == .real) != (right == .real)) return right == .real;
    return shape == .scalar_leaf or @backingInt(left) > @backingInt(right);
}

/// A binary plan's chunk that exchanges its operands and runs its mirrored
/// twin's loop. The call stays out of line so the twin's loop is not copied
/// back into this instantiation.
fn mirroredBinaryKernel(comptime operation: BinaryOp, comptime left_class: Number, comptime right_class: Number, comptime shape: Shape) type {
    const twin = comptime mirroredOperation(operation, left_class, right_class).?;
    const Twin = binaryKernel(twin, right_class, left_class, comptime mirroredShape(shape));
    const out = comptime binaryResult(operation, left_class, right_class).?;
    comptime std.debug.assert(binaryResult(twin, right_class, left_class).? == out);
    return struct {
        fn chunk(params: NumericParams, operands: [2]Value, output: *support.LeafResult(out.kind()), range: flat.Chunk, evaluator: *Fiber) MachineError!void {
            return @call(.never_inline, Twin.chunk, .{ params, [2]Value{ operands[1], operands[0] }, output, range, evaluator });
        }
    };
}

/// `binaryKernel` with the result class chosen by the caller: a scalar program
/// keeps a 0/1 result in its int registers where a standalone operation would
/// publish bytes.
fn binaryKernelInto(
    comptime operation: BinaryOp,
    comptime left_class: Number,
    comptime right_class: Number,
    comptime shape: Shape,
    comptime out: Number,
) type {
    @setEvalBranchQuota(10_000);
    const policy = comptime binaryLoopPolicy(operation, left_class, right_class);
    const ScalarInfallible = flat.InfallibleFamily(left_class.Element(), right_class.Element(), out.Element());
    const ScalarChecked = flat.CheckedFamily(left_class.Element(), right_class.Element(), out.Element());
    // An integral loop runs as many lanes as one vector of its narrowest
    // stream holds, operands or result: that stream then fills whole loads or
    // stores, and the wider streams are the ones split. The count depends on
    // the pair and not on its order, so a mirrored plan runs its twin's loop
    // at its own speed.
    const lanes = if (left_class != .real and right_class != .real)
        std.simd.suggestVectorLength(Narrowest(left_class.Element(), Narrowest(right_class.Element(), out.Element()))) orelse 1
    else
        std.simd.suggestVectorLength(left_class.Element()) orelse 1;
    const Vectors = flat.VectorFamily(left_class.Element(), right_class.Element(), out.Element(), lanes);
    const infallible_body = struct {
        fn run(a: left_class.Element(), b: right_class.Element()) out.Element() {
            return switch (operation) {
                .eq => @intFromBool(a == b),
                .ne => @intFromBool(a != b),
                .lt => @intFromBool(a < b),
                .gt => @intFromBool(a > b),
                .le => @intFromBool(a <= b),
                .ge => @intFromBool(a >= b),
                .min => if (b < a) b else a,
                .max => if (b > a) b else a,
                .band => @intCast(a & b),
                .bor => @intCast(a | b),
                .bxor => @intCast(a ^ b),
                .wrap_add => @as(i64, a) +% @as(i64, b),
                .wrap_sub => @as(i64, a) -% @as(i64, b),
                .wrap_mul => @as(i64, a) *% @as(i64, b),
                .add,
                .sub,
                .mul,
                .div,
                .int_div,
                .mod,
                .pow,
                .atan2,
                .and_word,
                .or_word,
                .bsl,
                .bsr,
                => unreachable,
            };
        }
    }.run;
    const checked_body = struct {
        fn run(a: left_class.Element(), b: right_class.Element()) error{Fault}!out.Element() {
            const result = scalarBinary(operation, left_class.boxed(a), right_class.boxed(b)) catch return error.Fault;
            return out.unboxed(result);
        }
    }.run;
    // Integral lanes as ints: a byte lane widens, an int lane is itself.
    const Wide = @Vector(lanes, i64);
    const integral = left_class != .real and right_class != .real;
    const wide = struct {
        fn left(a: @Vector(lanes, left_class.Element())) Wide {
            return if (left_class == .integer) a else @intCast(a);
        }
        fn right(b: @Vector(lanes, right_class.Element())) Wide {
            return if (right_class == .integer) b else @intCast(b);
        }
    };
    const vector_body = struct {
        fn run(
            a: @Vector(lanes, left_class.Element()),
            b: @Vector(lanes, right_class.Element()),
        ) @Vector(lanes, out.Element()) {
            const Out = out.Element();
            const ones: @Vector(lanes, Out) = @splat(1);
            const zeroes: @Vector(lanes, Out) = @splat(0);
            if (integral) {
                const wa = wide.left(a);
                const wb = wide.right(b);
                return switch (operation) {
                    .eq => @select(Out, wa == wb, ones, zeroes),
                    .ne => @select(Out, wa != wb, ones, zeroes),
                    .lt => @select(Out, wa < wb, ones, zeroes),
                    .gt => @select(Out, wa > wb, ones, zeroes),
                    .le => @select(Out, wa <= wb, ones, zeroes),
                    .ge => @select(Out, wa >= wb, ones, zeroes),
                    // A same-class pair keeps its class; `binaryResult`
                    // widens a mixed pair's selection to ints.
                    .min => if (left_class == right_class) @select(Out, b < a, b, a) else @select(Out, wb < wa, wb, wa),
                    .max => if (left_class == right_class) @select(Out, b > a, b, a) else @select(Out, wb > wa, wb, wa),
                    .band => wa & wb,
                    .bor => wa | wb,
                    .bxor => wa ^ wb,
                    .wrap_add => wa +% wb,
                    .wrap_sub => wa -% wb,
                    .wrap_mul => wa *% wb,
                    .add,
                    .sub,
                    .mul,
                    .div,
                    .int_div,
                    .mod,
                    .pow,
                    .atan2,
                    .and_word,
                    .or_word,
                    .bsl,
                    .bsr,
                    => unreachable,
                };
            }
            return switch (operation) {
                .eq => @select(Out, a == b, ones, zeroes),
                .ne => @select(Out, a != b, ones, zeroes),
                .lt => @select(Out, a < b, ones, zeroes),
                .gt => @select(Out, a > b, ones, zeroes),
                .le => @select(Out, a <= b, ones, zeroes),
                .ge => @select(Out, a >= b, ones, zeroes),
                .min => @select(left_class.Element(), b < a, b, a),
                .max => @select(left_class.Element(), b > a, b, a),
                .band => a & b,
                .bor => a | b,
                .bxor => a ^ b,
                .wrap_add => a +% b,
                .wrap_sub => a -% b,
                .wrap_mul => a *% b,
                .add,
                .sub,
                .mul,
                .div,
                .int_div,
                .mod,
                .pow,
                .atan2,
                .and_word,
                .or_word,
                .bsl,
                .bsr,
                => unreachable,
            };
        }
    }.run;
    const real_lanes = struct {
        fn arithmetic(a: @Vector(lanes, f64), b: @Vector(lanes, f64)) @Vector(lanes, f64) {
            return switch (operation) {
                .add => a + b,
                .sub => a - b,
                .mul => a * b,
                .div => a / b,
                else => unreachable,
            };
        }
    };
    const checked_vector_body = struct {
        fn run(
            a: @Vector(lanes, left_class.Element()),
            b: @Vector(lanes, right_class.Element()),
        ) Vectors.Masked {
            if (integral and (operation == .and_word or operation == .or_word)) {
                // Both operands must be 0 or 1, exactly `boolean`'s test.
                const wa = wide.left(a);
                const wb = wide.right(b);
                const ones: Wide = @splat(1);
                const zeros: Wide = @splat(0);
                // Faulting lanes are discarded, so narrowing may truncate them.
                const values = narrowLanes(i64, out.Element(), lanes, if (operation == .and_word) wa & wb else wa | wb);
                return .{ .values = values, .faults = Vectors.mask((wa | wb) & ~ones != zeros) };
            }
            if (integral) {
                const wa = wide.left(a);
                const wb = wide.right(b);
                const result = switch (operation) {
                    .add => @addWithOverflow(wa, wb),
                    .sub => @subWithOverflow(wa, wb),
                    .mul => @mulWithOverflow(wa, wb),
                    else => unreachable,
                };
                const no_overflow: @Vector(lanes, u1) = @splat(0);
                return .{ .values = result[0], .faults = Vectors.mask(result[1] != no_overflow) };
            }
            if (left_class == .real and right_class == .real and
                (operation == .add or operation == .sub or operation == .mul or operation == .div))
            {
                // The only fault is a NaN result, exactly `checkedFloat`'s.
                // Strict float mode keeps each lane's bits identical to the
                // scalar operation, with no contraction.
                const result = real_lanes.arithmetic(a, b);
                return .{ .values = result, .faults = Vectors.mask(result != result) };
            }
            unreachable;
        }
    }.run;
    const checked: Vectors.Checked = .{
        .vector = checked_vector_body,
        .scalar = checked_body,
    };
    return struct {
        const Left = if (shape == .scalar_leaf) left_class.Element() else []const left_class.Element();
        const Right = if (shape == .leaf_scalar) right_class.Element() else []const right_class.Element();

        /// Computes `range` into `output`. Returns the range a scalar replay
        /// must rescan when a checked piece faulted: it begins at the first
        /// position whose operands are still the input's.
        fn runPieces(left: Left, right: Right, output: *support.LeafResult(out.kind()), placement: flat.Placement, range: flat.Chunk) ?flat.Chunk {
            return runRange(left, right, OutputTarget(out){ .output = output }, placement, range);
        }

        /// Computes positions `0..dest.len` of one scalar-program block into
        /// `dest`. True when a position faulted; `dest` is then not to be read,
        /// and the caller replays.
        fn runBlock(left: Left, right: Right, dest: []out.Element()) bool {
            return runRange(left, right, SliceTarget(out){ .items = dest }, .fresh, .{ .start = 0, .end = dest.len }) != null;
        }

        /// The one range loop: each piece through the loop the policy selects,
        /// written where `target` puts it: the kernel's output, or a program
        /// block's scratch run.
        inline fn runRange(left: Left, right: Right, target: anytype, placement: flat.Placement, range: flat.Chunk) ?flat.Chunk {
            var block = flat.Block(out.Element()).init();
            var offset: usize = 0;
            while (offset != range.len()) {
                const piece = nextPiece(comptime policy.isVector(), range, offset);
                const outcome: flat.CheckedOutcome = switch (comptime policy) {
                    .vector_infallible => blk: {
                        const dest = target.vector(piece);
                        switch (shape) {
                            .leaf_leaf => Vectors.binary(vector_body, infallible_body, left, right, piece, dest),
                            .leaf_scalar => Vectors.binaryScalarRight(vector_body, infallible_body, left, right, piece, dest),
                            .scalar_leaf => Vectors.binaryScalarLeft(vector_body, infallible_body, left, right, piece, dest),
                            .leaf_only => unreachable,
                        }
                        break :blk .clean;
                    },
                    .vector_checked => blk: {
                        const dest = target.vector(piece);
                        break :blk switch (shape) {
                            .leaf_leaf => Vectors.checkedBinary(checked, placement, left, right, piece, dest),
                            .leaf_scalar => Vectors.checkedBinaryScalarRight(checked, placement, left, right, piece, dest),
                            .scalar_leaf => Vectors.checkedBinaryScalarLeft(checked, placement, left, right, piece, dest),
                            .leaf_only => unreachable,
                        };
                    },
                    .scalar_infallible => blk: {
                        switch (shape) {
                            .leaf_leaf => ScalarInfallible.binary(infallible_body, left, right, piece, &block),
                            .leaf_scalar => ScalarInfallible.binaryScalarRight(infallible_body, left, right, piece, &block),
                            .scalar_leaf => ScalarInfallible.binaryScalarLeft(infallible_body, left, right, piece, &block),
                            .leaf_only => unreachable,
                        }
                        target.store(piece.start, block.written());
                        break :blk .clean;
                    },
                    .scalar_checked => blk: {
                        const status = switch (shape) {
                            .leaf_leaf => ScalarChecked.binary(checked_body, left, right, piece, &block),
                            .leaf_scalar => ScalarChecked.binaryScalarRight(checked_body, left, right, piece, &block),
                            .scalar_leaf => ScalarChecked.binaryScalarLeft(checked_body, left, right, piece, &block),
                            .leaf_only => unreachable,
                        };
                        // A staged block stores nothing until it is clean.
                        if (status == .faulted) break :blk .{ .faulted = piece.start };
                        target.store(piece.start, block.written());
                        break :blk .clean;
                    },
                };
                switch (outcome) {
                    .clean => {},
                    // The replay rescans from the first position whose
                    // operands are still the input's; a fresh buffer holds
                    // partial results and is retired unpublished if it fails.
                    .faulted => |from| return .{ .start = from, .end = piece.end },
                }
                offset += piece.len();
            }
            return null;
        }

        /// The operation's range loop over these classes, as
        /// `BinaryKernel` calls it.
        fn chunk(params: NumericParams, operands: [2]Value, output: *support.LeafResult(out.kind()), range: flat.Chunk, evaluator: *Fiber) MachineError!void {
            const left: Left = if (shape == .scalar_leaf)
                left_class.unboxed(operands[0])
            else
                heap.leafElements(left_class.kind(), operands[0].list);
            const right: Right = if (shape == .leaf_scalar)
                right_class.unboxed(operands[1])
            else
                heap.leafElements(right_class.kind(), operands[1].list);
            const placement: flat.Placement = if (output.aliased()) .over_operands else .fresh;
            if (runPieces(left, right, output, placement, range)) |faulted|
                return replayDirect(evaluator, params.report, left, right, faulted);
        }

        noinline fn replayDirect(evaluator: *Fiber, report: FaultReport, left: Left, right: Right, piece: flat.Chunk) MachineError {
            for (piece.start..piece.end) |index| {
                const a = if (shape == .scalar_leaf) left else left[index];
                const b = if (shape == .leaf_scalar) right else right[index];
                _ = scalarBinary(operation, left_class.boxed(a), right_class.boxed(b)) catch |fault|
                    return failTypedScalar(evaluator, report, fault, index);
            }
            unreachable;
        }
    };
}

/// A unary typed operation; see `binaryKernel`.
fn unaryKernel(comptime operation: UnaryOp, comptime operand_class: Number) type {
    return unaryKernelInto(operation, operand_class, comptime unaryResult(operation, operand_class));
}

/// `unaryKernel` with the result class chosen by the caller; see `binaryKernelInto`.
fn unaryKernelInto(comptime operation: UnaryOp, comptime operand_class: Number, comptime out: Number) type {
    @setEvalBranchQuota(10_000);
    const policy = comptime unaryLoopPolicy(operation, operand_class);
    const Checked = flat.CheckedFamily(operand_class.Element(), void, out.Element());
    const lanes = std.simd.suggestVectorLength(operand_class.Element()) orelse 1;
    const Vectors = flat.VectorFamily(operand_class.Element(), void, out.Element(), lanes);
    const infallible_body = struct {
        fn run(a: operand_class.Element()) out.Element() {
            return switch (operation) {
                .bnot => ~a,
                .neg => -a,
                .abs => @abs(a),
                .not_word, .sqrt, .floor, .ceil, .round, .exp, .log, .sin, .cos => unreachable,
            };
        }
    }.run;
    const checked_body = struct {
        fn run(a: operand_class.Element()) error{Fault}!out.Element() {
            const result = scalarUnary(operation, operand_class.boxed(a)) catch return error.Fault;
            return out.unboxed(result);
        }
    }.run;
    const vector_body = struct {
        fn run(a: @Vector(lanes, operand_class.Element())) @Vector(lanes, out.Element()) {
            return switch (operation) {
                .bnot => ~a,
                .neg => -a,
                .abs => @abs(a),
                .not_word, .sqrt, .floor, .ceil, .round, .exp, .log, .sin, .cos => unreachable,
            };
        }
    }.run;
    const checked: Vectors.Checked = .{
        .vector = struct {
            fn run(a: @Vector(lanes, operand_class.Element())) Vectors.Masked {
                switch (operation) {
                    .not_word => {
                        // The operand must be 0 or 1, exactly `boolean`'s test.
                        const ones: @Vector(lanes, operand_class.Element()) = @splat(1);
                        const zeros: @Vector(lanes, operand_class.Element()) = @splat(0);
                        // Faulting lanes are discarded, so narrowing may truncate them.
                        return .{ .values = narrowLanes(operand_class.Element(), out.Element(), lanes, a ^ ones), .faults = Vectors.mask(a & ~ones != zeros) };
                    },
                    else => unreachable,
                }
            }
        }.run,
        .scalar = checked_body,
    };
    return struct {
        /// Computes `range` into `output`. Returns the range a scalar replay
        /// must rescan; see `binaryKernel`'s.
        fn runPieces(operand: []const operand_class.Element(), output: *support.LeafResult(out.kind()), placement: flat.Placement, range: flat.Chunk) ?flat.Chunk {
            return runRange(operand, OutputTarget(out){ .output = output }, placement, range);
        }

        /// One block of a scalar program; see `binaryKernel`'s.
        fn runBlock(operand: []const operand_class.Element(), dest: []out.Element()) bool {
            return runRange(operand, SliceTarget(out){ .items = dest }, .fresh, .{ .start = 0, .end = dest.len }) != null;
        }

        /// The one range loop; see `binaryKernel`'s.
        inline fn runRange(operand: []const operand_class.Element(), target: anytype, placement: flat.Placement, range: flat.Chunk) ?flat.Chunk {
            var block = flat.Block(out.Element()).init();
            var offset: usize = 0;
            while (offset != range.len()) {
                const piece = nextPiece(comptime policy.isVector(), range, offset);
                switch (comptime policy) {
                    .vector_infallible => Vectors.unary(vector_body, infallible_body, operand, piece, target.vector(piece)),
                    .vector_checked => switch (Vectors.checkedUnary(checked, placement, operand, piece, target.vector(piece))) {
                        .clean => {},
                        .faulted => |from| return .{ .start = from, .end = piece.end },
                    },
                    .scalar_checked => {
                        if (Checked.unary(checked_body, operand, piece, &block) == .faulted) return piece;
                        target.store(piece.start, block.written());
                    },
                    .scalar_infallible => unreachable,
                }
                offset += piece.len();
            }
            return null;
        }

        /// The operation's range loop over this class, as `UnaryKernel`
        /// calls it.
        fn chunk(params: NumericParams, operands: [1]Value, output: *support.LeafResult(out.kind()), range: flat.Chunk, evaluator: *Fiber) MachineError!void {
            const elements = heap.leafElements(operand_class.kind(), operands[0].list);
            const placement: flat.Placement = if (output.aliased()) .over_operands else .fresh;
            if (runPieces(elements, output, placement, range)) |faulted|
                return replayDirect(evaluator, params.report, elements, faulted);
        }

        noinline fn replayDirect(evaluator: *Fiber, report: FaultReport, elements: []const operand_class.Element(), piece: flat.Chunk) MachineError {
            for (piece.start..piece.end) |index| {
                _ = scalarUnary(operation, operand_class.boxed(elements[index])) catch |fault|
                    return failTypedScalar(evaluator, report, fault, index);
            }
            unreachable;
        }
    };
}

/// A numeric kernel's result: a typed output, which may be its first
/// operand's buffer taken over in place.
/// A numeric kernel's result: the executor's leaf for the operation's result
/// class, erased to one type so every plan's range loop has one signature.
const KernelOutput = union(enum) {
    bytes: support.LeafResult(.leaf_u8),
    ints: support.LeafResult(.leaf_i64),
    reals: support.LeafResult(.leaf_f64),

    fn wrap(comptime class: Number, result: support.LeafResult(class.kind())) KernelOutput {
        return switch (class) {
            .byte => .{ .bytes = result },
            .integer => .{ .ints = result },
            .real => .{ .reals = result },
            .char1, .char2, .char4 => unreachable,
        };
    }

    fn leaf(self: *KernelOutput, comptime class: Number) *support.LeafResult(class.kind()) {
        return switch (class) {
            .byte => &self.bytes,
            .integer => &self.ints,
            .real => &self.reals,
            .char1, .char2, .char4 => unreachable,
        };
    }

    fn aliased(self: *const KernelOutput) bool {
        return switch (self.*) {
            inline else => |*result| result.aliased(),
        };
    }

    pub fn retire(self: *KernelOutput, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            inline else => |*result| result.retire(releases),
        }
    }

    fn finish(self: *KernelOutput) Value {
        return switch (self.*) {
            inline else => |*result| result.finish(),
        };
    }
};

/// One operation's range loop over one pair of classes; see `BinaryKernel`.
///
/// Stored untyped, since plans of every result class share one table: a plan
/// pairs a result class's executor with that class's loop when it is built,
/// and the executor casts it back to `BinaryLoop(out)`, so the two cannot
/// disagree.
const BinaryChunk = *const anyopaque;

fn BinaryLoop(comptime out: Number) type {
    return *const fn (NumericParams, [2]Value, *support.LeafResult(out.kind()), flat.Chunk, *Fiber) MachineError!void;
}

/// What a binary kernel runs with: the caller's parameters and the plan's
/// range loop.
const BinaryParams = struct {
    numeric: NumericParams,
    chunk: BinaryChunk,
};

/// The `support.Kernel` of every binary operation with this result class. Its
/// inline, nested, and driver paths depend only on the result, which the
/// executor prepares, so they are compiled once per result class, and each
/// operation and class pair contributes only its range loop, which the plan
/// hands over in its parameters.
fn BinaryKernel(comptime out: Number) type {
    return struct {
        const Spec = struct {
            pub const arity = 2;
            pub const Params = BinaryParams;
            pub const Output = support.LeafResult(out.kind());

            /// Either leaf may become the output; a broadcast scalar is no
            /// list and is passed over.
            pub const result: ?support.ResultShape = .{ .kind = out.kind(), .overwritable = &.{ 0, 1 } };

            pub fn chunk(params: BinaryParams, operands: [2]Value, output: *Output, range: flat.Chunk, evaluator: *Fiber) MachineError!void {
                const loop: BinaryLoop(out) = @ptrCast(@alignCast(params.chunk));
                return loop(params.numeric, operands, output, range, evaluator);
            }

            pub const finish = Output.finish;
        };

        const run = support.Kernel(Spec).run;
        const nested = support.Kernel(Spec).nested;
    };
}

/// One operation's range loop over one operand class; see `UnaryKernel`.
/// Untyped for the same reason as `BinaryChunk`.
const UnaryChunk = *const anyopaque;

fn UnaryLoop(comptime out: Number) type {
    return *const fn (NumericParams, [1]Value, *support.LeafResult(out.kind()), flat.Chunk, *Fiber) MachineError!void;
}

const UnaryParams = struct {
    numeric: NumericParams,
    chunk: UnaryChunk,
};

/// The `support.Kernel` of every unary operation with this result class; see
/// `BinaryKernel`.
fn UnaryKernel(comptime out: Number) type {
    return struct {
        const Spec = struct {
            pub const arity = 1;
            pub const Params = UnaryParams;
            pub const Output = support.LeafResult(out.kind());

            pub const result: ?support.ResultShape = .{ .kind = out.kind(), .overwritable = &.{0} };

            pub fn chunk(params: UnaryParams, operands: [1]Value, output: *Output, range: flat.Chunk, evaluator: *Fiber) MachineError!void {
                const loop: UnaryLoop(out) = @ptrCast(@alignCast(params.chunk));
                return loop(params.numeric, operands, output, range, evaluator);
            }

            pub const finish = Output.finish;
        };

        const run = support.Kernel(Spec).run;
        const nested = support.Kernel(Spec).nested;
    };
}

/// Runs a plan's operation through `support.Kernel`, inline or as a driver.
const RunBinary = *const fn (*Fiber, [2]*heap.OwnedValue, BinaryParams, usize) MachineError!void;
/// Runs a plan's operation for a leaf inside pervasion; see `support.Kernel`.
const NestedBinary = *const fn (*Fiber, [2]Value, ?*heap.OwnedValue, BinaryParams, usize) MachineError!support.NestedOutcome;

/// Static selection binds the element classes, output width, and kernel
/// together, so no caller can pair a kernel with another storage contract.
const NumericBinaryPlan = opaque {
    const Data = struct {
        left: Number,
        right: Number,
        shape: Shape,
        out: Number,
        run: RunBinary,
        nested: NestedBinary,
        chunk: BinaryChunk,

        /// Runs the operation inline or as a driver.
        fn start(self: *const Data, evaluator: *Fiber, owners: [2]*heap.OwnedValue, params: NumericParams, length: usize) MachineError!void {
            return self.run(evaluator, owners, .{ .numeric = params, .chunk = self.chunk }, length);
        }

        /// Runs the operation for a leaf inside pervasion.
        fn startNested(self: *const Data, evaluator: *Fiber, operands: [2]Value, root: ?*heap.OwnedValue, params: NumericParams, length: usize) MachineError!support.NestedOutcome {
            return self.nested(evaluator, operands, root, .{ .numeric = params, .chunk = self.chunk }, length);
        }
    };

    fn select(operation: BinaryOp, left: Number, right: Number, shape: Shape) ?*const NumericBinaryPlan {
        return switch (operation) {
            inline else => |selected| selectFor(selected, left, right, shape),
        };
    }

    /// One indexed load per call. The nested comparison chain this replaces
    /// was a fixed cost of every nested row.
    fn selectFor(comptime operation: BinaryOp, left: Number, right: Number, shape: Shape) ?*const NumericBinaryPlan {
        // A stored width has no scalar, so neither broadcast shape pairs one with a leaf.
        std.debug.assert(!(shape == .scalar_leaf and !left.scalar()) and !(shape == .leaf_scalar and !right.scalar()));
        std.debug.assert(shape != .leaf_only);
        const table = comptime plans(operation);
        return table[@backingInt(left)][@backingInt(right)][@backingInt(shape)];
    }

    const PlanTable = [number_classes.len][number_classes.len][binary_shapes.len]?*const NumericBinaryPlan;

    comptime {
        // The table is indexed by enum value, so the class and shape lists
        // must list each enum in value order; `leaf_only` is never binary.
        for (number_classes, 0..) |class, index| std.debug.assert(@backingInt(class) == index);
        for (binary_shapes, 0..) |shape, index| std.debug.assert(@backingInt(shape) == index);
    }

    fn plans(comptime operation: BinaryOp) PlanTable {
        var table: PlanTable = @splat(@splat(@splat(null)));
        for (number_classes) |candidate_left| {
            for (number_classes) |candidate_right| {
                for (binary_shapes) |candidate_shape| {
                    if (candidate_shape == .scalar_leaf and !candidate_left.scalar()) continue;
                    if (candidate_shape == .leaf_scalar and !candidate_right.scalar()) continue;
                    const out = binaryResult(operation, candidate_left, candidate_right) orelse continue;
                    const Shared = BinaryKernel(out);
                    const data = Data{
                        .left = candidate_left,
                        .right = candidate_right,
                        .shape = candidate_shape,
                        .out = out,
                        .run = Shared.run,
                        .nested = Shared.nested,
                        .chunk = if (comptime mirrorsOnto(operation, candidate_left, candidate_right, candidate_shape))
                            @ptrCast(&mirroredBinaryKernel(operation, candidate_left, candidate_right, candidate_shape).chunk)
                        else
                            @ptrCast(&binaryKernel(operation, candidate_left, candidate_right, candidate_shape).chunk),
                    };
                    table[@backingInt(candidate_left)][@backingInt(candidate_right)][@backingInt(candidate_shape)] =
                        @ptrCast(&data);
                }
            }
        }
        return table;
    }
};

fn firstFlatElement(item: Value) ?Value {
    if (item != .list or item.list.length() == 0) return null;
    return switch (item.list.kind()) {
        .leaf_u8 => .{ .int = heap.u8s(item.list)[0] },
        .leaf_i64 => .{ .int = heap.i64s(item.list)[0] },
        .leaf_f64 => .{ .float = heap.f64s(item.list)[0] },
        .leaf_char1 => .{ .char = heap.chars8(item.list)[0] },
        .leaf_char2 => .{ .char = heap.chars16(item.list)[0] },
        .leaf_char4 => .{ .char = @intCast(heap.chars32(item.list)[0]) },
        .generic_spine, .dict, .task, .port, .address, .reserved_mask => null,
    };
}

/// A nonempty flat leaf whose first scalar faults needs no output allocation
/// and no traversal. This closes the typed boundary for character/symbol and
/// nonnumeric combinations without manufacturing a boxed fallback loop.
fn rejectUnsupportedFlatBinary(
    evaluator: *Fiber,
    operation: BinaryOp,
    left: Value,
    right: Value,
    report: FaultReport,
) MachineError!bool {
    if (left == .dict or right == .dict) return false;
    const left_first = firstFlatElement(left);
    const right_first = firstFlatElement(right);
    if (left_first == null and right_first == null) return false;
    if (left == .list and left_first == null) return false;
    if (right == .list and right_first == null) return false;
    if (left == .list and right == .list) {
        const left_count: usize = @intCast(left.list.length());
        const right_count: usize = @intCast(right.list.length());
        if (left_count != right_count) return evaluator.conformError(left_count, right_count);
        if (left_count == 0) return false;
    } else if ((left == .list and left.list.length() == 0) or
        (right == .list and right.list.length() == 0)) return false;
    _ = (switch (operation) {
        inline else => |selected| scalarBinary(selected, left_first orelse left, right_first orelse right),
    }) catch |fault| return scalarFailure(evaluator, fault, if (report.index) 0 else null);
    return false;
}

fn rejectUnsupportedFlatUnary(
    evaluator: *Fiber,
    operation: UnaryOp,
    operand: Value,
    report: FaultReport,
) MachineError!bool {
    const first = firstFlatElement(operand) orelse return false;
    _ = selectUnary(operation)(first) catch |fault|
        return scalarFailure(evaluator, fault, if (report.index) 0 else null);
    return false;
}

fn startNestedNumericBinary(
    evaluator: *Fiber,
    operation: BinaryOp,
    left_item: Value,
    right_item: Value,
    root: ?*heap.OwnedValue,
    report: FaultReport,
) MachineError!?support.NestedOutcome {
    const left_leaf = leafNumber(left_item);
    const right_leaf = leafNumber(right_item);
    const left_scalar = scalarNumber(left_item);
    const right_scalar = scalarNumber(right_item);
    const shape: Shape = if (left_leaf != null and right_leaf != null)
        .leaf_leaf
    else if (left_leaf != null and right_scalar != null)
        .leaf_scalar
    else if (left_scalar != null and right_leaf != null)
        .scalar_leaf
    else
        return null;
    const length = try conformingLength(evaluator, shape, left_item, right_item);
    if (length == 0) return null;
    const left_class = left_leaf orelse left_scalar.?;
    const right_class = right_leaf orelse right_scalar.?;
    const plan = NumericBinaryPlan.select(operation, left_class, right_class, shape) orelse return null;
    const data: *const NumericBinaryPlan.Data = @ptrCast(@alignCast(plan));
    return try data.startNested(evaluator, .{ left_item, right_item }, root, .{ .report = report }, length);
}

/// A typed leaf inside pervasion. `root`, when present, owns `left` and is
/// the operation's own operand, so its buffer may become the output; every
/// other leaf is only borrowed from the structure being descended.
fn startNestedBinary(
    evaluator: *Fiber,
    operation: BinaryOp,
    left: Value,
    right: Value,
    root: ?*heap.OwnedValue,
    report: FaultReport,
) MachineError!?support.NestedOutcome {
    if (try startNestedNumericBinary(evaluator, operation, left, right, root, report)) |typed| return typed;
    _ = try rejectUnsupportedFlatBinary(evaluator, operation, left, right, report);
    return null;
}

const RunUnary = *const fn (*Fiber, [1]*heap.OwnedValue, UnaryParams, usize) MachineError!void;
const NestedUnary = *const fn (*Fiber, [1]Value, ?*heap.OwnedValue, UnaryParams, usize) MachineError!support.NestedOutcome;

/// A closed operation/class pair binds the loop and its output representation.
/// Top-level and nested operations share it.
const NumericUnaryPlan = opaque {
    const Data = struct {
        input: Number,
        out: Number,
        run: RunUnary,
        nested: NestedUnary,
        chunk: UnaryChunk,

        /// Runs the operation inline or as a driver.
        fn start(self: *const Data, evaluator: *Fiber, owners: [1]*heap.OwnedValue, params: NumericParams, length: usize) MachineError!void {
            return self.run(evaluator, owners, .{ .numeric = params, .chunk = self.chunk }, length);
        }

        /// Runs the operation for a leaf inside pervasion.
        fn startNested(self: *const Data, evaluator: *Fiber, operands: [1]Value, root: ?*heap.OwnedValue, params: NumericParams, length: usize) MachineError!support.NestedOutcome {
            return self.nested(evaluator, operands, root, .{ .numeric = params, .chunk = self.chunk }, length);
        }
    };

    fn select(operation: UnaryOp, input: Number) *const NumericUnaryPlan {
        return switch (operation) {
            inline else => |selected| blk: {
                inline for (number_classes) |candidate| {
                    if (candidate == input) {
                        const out = comptime unaryResult(selected, candidate);
                        const data = comptime Data{
                            .input = candidate,
                            .out = out,
                            .run = UnaryKernel(out).run,
                            .nested = UnaryKernel(out).nested,
                            .chunk = @ptrCast(&unaryKernel(selected, candidate).chunk),
                        };
                        break :blk @ptrCast(&data);
                    }
                }
                unreachable;
            },
        };
    }
};

fn startNestedUnary(
    evaluator: *Fiber,
    operation: UnaryOp,
    operand: Value,
    report: FaultReport,
) MachineError!?support.NestedOutcome {
    const class = leafNumber(operand) orelse {
        _ = try rejectUnsupportedFlatUnary(evaluator, operation, operand, report);
        return null;
    };
    const length: usize = @intCast(operand.list.length());
    if (length == 0) return null;
    const data: *const NumericUnaryPlan.Data = @ptrCast(@alignCast(NumericUnaryPlan.select(operation, class)));
    return try data.startNested(evaluator, .{operand}, null, .{ .report = report }, length);
}

/// A numeric operation runs through its plan's kernel, inline or as a
/// driver. It classifies exactly as the numeric builder does, so a pair it
/// declines reaches the builder unchanged.
fn startNumericBinary(
    evaluator: *Fiber,
    operation: BinaryOp,
    left: *heap.OwnedValue,
    right: *heap.OwnedValue,
    report: FaultReport,
) MachineError!bool {
    const left_item = left.borrow();
    const right_item = right.borrow();
    const left_leaf = leafNumber(left_item);
    const right_leaf = leafNumber(right_item);
    const shape: Shape = if (left_leaf != null and right_leaf != null)
        .leaf_leaf
    else if (left_leaf != null and scalarNumber(right_item) != null)
        .leaf_scalar
    else if (right_leaf != null and scalarNumber(left_item) != null)
        .scalar_leaf
    else
        return false;
    const length = try conformingLength(evaluator, shape, left_item, right_item);
    if (length == 0) return false;
    const plan = NumericBinaryPlan.select(
        operation,
        left_leaf orelse scalarNumber(left_item).?,
        right_leaf orelse scalarNumber(right_item).?,
        shape,
    ) orelse return false;
    const data: *const NumericBinaryPlan.Data = @ptrCast(@alignCast(plan));
    try data.start(evaluator, .{ left, right }, .{ .report = report }, length);
    return true;
}

/// Dispatches one binary operation. Returns false when the operand shapes belong
/// to the generic route, having consumed nothing.
fn startTypedBinary(
    evaluator: *Fiber,
    operation: BinaryOp,
    left: *heap.OwnedValue,
    right: *heap.OwnedValue,
    report: FaultReport,
) MachineError!bool {
    if (try startNumericBinary(evaluator, operation, left, right, report)) return true;
    // An empty result's representation is the generic route's to choose, and
    // so is a pair no plan admits.
    _ = try rejectUnsupportedFlatBinary(evaluator, operation, left.borrow(), right.borrow(), report);
    return false;
}

fn startTypedUnary(
    evaluator: *Fiber,
    operation: UnaryOp,
    operand: *heap.OwnedValue,
    report: FaultReport,
) MachineError!bool {
    const item = operand.borrow();
    const class = leafNumber(item) orelse
        return rejectUnsupportedFlatUnary(evaluator, operation, item, report);
    const length: usize = @intCast(item.list.length());
    if (length == 0) return false;
    const data: *const NumericUnaryPlan.Data = @ptrCast(@alignCast(NumericUnaryPlan.select(operation, class)));
    try data.start(evaluator, .{operand}, .{ .report = report }, length);
    return true;
}

/// Recognized-idiom entries.
///
/// A guarded `each`/`zip-with` over numeric leaves *is* pervasion: the elements
/// are atoms, so applying the scalar operation to each of them and pervading
/// over the leaf are the same computation. These entries let the recognizer
/// reach the typed loop instead of keeping a second implementation, and they
/// report faults without a list index because the combinator they stand in for
/// applies its quotation to one element at a time and its fault carries no list
/// position.
pub const IdiomStart = struct {
    pub const Unary = *const fn (*Fiber, *heap.OwnedValue) MachineError!void;
    pub const Binary = *const fn (*Fiber, *heap.OwnedValue, *heap.OwnedValue) MachineError!void;
};

/// A quotation compiled to a straight-line scalar function of one or two
/// inputs: what calling it on atoms computes, without the interpreter. Stack
/// words were resolved when it was compiled, so only operations remain, in
/// the quotation's own order, each reading registers the compiler assigned.
/// Inputs occupy the first registers, then constants and results as the
/// quotation made them.
pub const ScalarProgram = struct {
    pub const max_instructions = 16;
    pub const max_registers = 32;
    pub const Register = u8;

    pub const Instruction = struct {
        operation: union(enum) { unary: UnaryOp, binary: BinaryOp },
        left: Register,
        right: Register = 0,
        destination: Register,
        /// The word and its position in the quotation, which a fault names.
        word: u32,
        index: u32,
    };

    inputs: u8,
    registers: u8,
    // SAFETY: only the first `constant_count` constants are read.
    constants: [max_registers]struct { register: Register, value: Value } = undefined,
    constant_count: u8 = 0,
    // SAFETY: only the first `len` instructions are read.
    instructions: [max_instructions]Instruction = undefined,
    len: u8 = 0,
    result: Register = 0,

    /// Loads the constants into their registers; inputs and results are
    /// written before they are read.
    fn load(self: *const ScalarProgram, registers: *[max_registers]Value) void {
        for (self.constants[0..self.constant_count]) |constant| registers[constant.register] = constant.value;
    }

    /// Runs every instruction over `registers`, reporting the instruction a
    /// fault happened in.
    fn run(self: *const ScalarProgram, registers: *[max_registers]Value, failed: *u8) ScalarError!Value {
        try self.runPrefix(registers, self.len, failed);
        return registers[self.result];
    }

    /// Runs the first `limit` instructions; see `run`.
    fn runPrefix(self: *const ScalarProgram, registers: *[max_registers]Value, limit: u8, failed: *u8) ScalarError!void {
        for (self.instructions[0..limit], 0..) |instruction, position| {
            registers[instruction.destination] = (switch (instruction.operation) {
                .unary => |operation| switch (operation) {
                    inline else => |selected| scalarUnary(selected, registers[instruction.left]),
                },
                .binary => |operation| switch (operation) {
                    inline else => |selected| scalarBinary(selected, registers[instruction.left], registers[instruction.right]),
                },
            }) catch |fault| {
                failed.* = @intCast(position);
                return fault;
            };
        }
    }
};

/// Which order a program's applications are observed in, which decides the
/// first fault and how it is reported. `each` applies the whole program to
/// one element before the next, as a quotation applied per element does, and
/// its fault carries no list position. `pervade` stands for the program's
/// words run one at a time in straight-line code, each pervading the whole
/// list before the next word starts: the first fault is the earliest
/// instruction that faults at any position, reported at that position.
pub const ProgramMode = enum { each, pervade };

/// Whether `operand` can feed a scalar program: a numeric atom, or a nonempty
/// numeric leaf.
fn programOperand(operand: Value) bool {
    return switch (operand) {
        .int, .float => true,
        .list => |header| header.length() != 0 and switch (header.kind()) {
            .leaf_u8, .leaf_i64, .leaf_f64 => true,
            else => false,
        },
        else => false,
    };
}

/// Whether a program over these operands runs as one kernel: every operand a
/// numeric atom or nonempty numeric leaf, at least one a leaf, and the leaves
/// of one length. Anything else takes the generic path.
pub fn programCandidate(operands: []const Value) bool {
    var length: ?usize = null;
    for (operands) |operand| {
        if (!programOperand(operand)) return false;
        if (operand != .list) continue;
        const count: usize = @intCast(operand.list.length());
        if (length) |expected| if (expected != count) return false;
        length = count;
    }
    return length != null;
}

/// Runs a program once per element of its list operands, as calling the
/// quotation per element would: each element passes through every
/// instruction before the next starts, so the first fault is the one that
/// order meets, reported by its own word. An atom operand is the same at every
/// element. The quotation is held as an operand for that report.
pub fn startProgramEach(evaluator: *Fiber, input: *heap.OwnedValue, phrase: *heap.OwnedValue, program: ScalarProgram) MachineError!void {
    const count: usize = @intCast(input.borrow().list.length());
    return startProgram(1, .each, evaluator, .{ input, phrase }, &program, count);
}

/// A program is too large to travel by value in a driver; the kernel's output
/// owns this copy from `prepare` on.
fn ownProgram(evaluator: *Fiber, program: ScalarProgram) error{OutOfMemory}!*ScalarProgram {
    const owned = try evaluator.allocator.create(ScalarProgram);
    owned.* = program;
    return owned;
}

pub fn startProgramZip(
    evaluator: *Fiber,
    left: *heap.OwnedValue,
    right: *heap.OwnedValue,
    phrase: *heap.OwnedValue,
    program: ScalarProgram,
) MachineError!void {
    const count: usize = @intCast(if (left.borrow() == .list) left.borrow().list.length() else right.borrow().list.length());
    return startProgram(2, .each, evaluator, .{ left, right, phrase }, &program, count);
}

/// The most stack values a straight-line chain may read.
pub const max_chain_inputs = 4;

/// Runs a program compiled from straight-line `code` over the top
/// `program.inputs` stack values, which `programCandidate` admitted, as its
/// words would run one at a time.
pub fn startProgramChain(evaluator: *Fiber, code: *value.ListHandle, program: ScalarProgram) MachineError!void {
    return switch (program.inputs) {
        inline 1...max_chain_inputs => |inputs| startChain(inputs, evaluator, code, &program),
        else => unreachable, // The compiler refuses a chain with more inputs.
    };
}

fn startChain(comptime inputs: usize, evaluator: *Fiber, code: *value.ListHandle, program: *const ScalarProgram) MachineError!void {
    // SAFETY: every owner is set below before the kernel reads it.
    var owners: [inputs + 1]heap.OwnedValue = undefined;
    heap.retainValue(.{ .list = code });
    owners[inputs] = .init(evaluator.releases, .{ .list = code });
    var popped: usize = 0;
    defer for (owners[inputs - popped ..]) |*owner| owner.deinit();
    while (popped != inputs) : (popped += 1) owners[inputs - 1 - popped] = try evaluator.popValue();
    // SAFETY: every pointer is set below.
    var pointers: [inputs + 1]*heap.OwnedValue = undefined;
    for (&pointers, &owners) |*pointer, *owner| pointer.* = owner;
    const count: usize = for (owners[0..inputs]) |*owner| {
        if (owner.borrow() == .list) break @intCast(owner.borrow().list.length());
    } else unreachable; // `programCandidate` requires a leaf.
    return startProgram(inputs, .pervade, evaluator, pointers, program, count);
}

/// Runs `program` over its inputs, the last owner being the code it was
/// compiled from. A program whose registers each keep one class writes its
/// result leaf a block at a time; any other computes element by element.
fn startProgram(
    comptime inputs: usize,
    comptime mode: ProgramMode,
    evaluator: *Fiber,
    owners: [inputs + 1]*heap.OwnedValue,
    program: *const ScalarProgram,
    length: usize,
) MachineError!void {
    // SAFETY: every operand is set below.
    var operands: [inputs]Value = undefined;
    for (&operands, owners[0..inputs]) |*operand, owner| operand.* = owner.borrow();
    const classes = programClasses(program, &operands) orelse
        return support.Kernel(ProgramValuesKernel(inputs, mode)).run(evaluator, owners, program, length);
    return switch (classes[program.result]) {
        .integer => support.Kernel(ProgramLeafKernel(inputs, mode, .leaf_i64)).run(evaluator, owners, program, length),
        .real => support.Kernel(ProgramLeafKernel(inputs, mode, .leaf_f64)).run(evaluator, owners, program, length),
        .byte, .char1, .char2, .char4 => unreachable, // Registers are widened.
    };
}

/// Which registers hold the same value at every position: the inputs that
/// are atoms, the constants, and what is computed only from them. The rest
/// hold a run.
fn programScalars(program: *const ScalarProgram, operands: []const Value) [ScalarProgram.max_registers]bool {
    // SAFETY: inputs, constants, and every instruction's destination are set
    // below, which is every register the program reads.
    var scalar: [ScalarProgram.max_registers]bool = undefined;
    for (operands, 0..) |operand, input| scalar[input] = operand != .list;
    for (program.constants[0..program.constant_count]) |constant| scalar[constant.register] = true;
    for (program.instructions[0..program.len]) |instruction| {
        scalar[instruction.destination] = switch (instruction.operation) {
            .unary => scalar[instruction.left],
            .binary => scalar[instruction.left] and scalar[instruction.right],
        };
    }
    return scalar;
}

/// Whether running `program` over `operands` gives a list: its result
/// depends on a list operand. A chain whose result does not is scalar code.
pub fn programResultVaries(program: *const ScalarProgram, operands: []const Value) bool {
    return !programScalars(program, operands)[program.result];
}

/// The one class each register holds for a whole run, from the inputs'
/// representations and each operation's result class, or null when a result
/// class depends on the values (mixed `min` or `max`).
fn programClasses(program: *const ScalarProgram, operands: []const Value) ?[ScalarProgram.max_registers]Number {
    // SAFETY: as in `programScalars`.
    var classes: [ScalarProgram.max_registers]Number = undefined;
    for (operands, 0..) |operand, input| classes[input] = blockNumber(operand);
    for (program.constants[0..program.constant_count]) |constant| classes[constant.register] = blockNumber(constant.value);
    for (program.instructions[0..program.len]) |instruction| {
        classes[instruction.destination] = switch (instruction.operation) {
            .unary => |operation| blockUnaryResult(operation, classes[instruction.left]),
            .binary => |operation| blockBinaryResult(operation, classes[instruction.left], classes[instruction.right]) orelse return null,
        };
    }
    return classes;
}

fn programElement(operand: Value, index: usize) Value {
    if (operand != .list) return operand;
    return switch (operand.list.kind()) {
        .leaf_f64 => .{ .float = heap.leafElements(.leaf_f64, operand.list)[index] },
        .leaf_i64 => .{ .int = heap.leafElements(.leaf_i64, operand.list)[index] },
        .leaf_u8 => .{ .int = heap.leafElements(.leaf_u8, operand.list)[index] },
        else => unreachable, // `programCandidate` admits numeric leaves only.
    };
}

/// One register of a program block: a scalar the whole block shares, or the
/// block's run of elements, by class.
const BlockValue = union(enum) {
    int_scalar: i64,
    real_scalar: f64,
    ints: []const i64,
    reals: []const f64,

    fn of(item: Value) BlockValue {
        return switch (item) {
            .int => |integer| .{ .int_scalar = integer },
            .float => |number| .{ .real_scalar = number },
            else => unreachable, // A planned program holds numeric atoms only.
        };
    }

    fn isScalar(self: BlockValue) bool {
        return self == .int_scalar or self == .real_scalar;
    }

    fn boxed(self: BlockValue) Value {
        return switch (self) {
            .int_scalar => |integer| .{ .int = integer },
            .real_scalar => |number| .{ .float = number },
            .ints, .reals => unreachable,
        };
    }
};

/// A program operand's class in a block: its leaf or scalar class, with bytes
/// widened to ints, which the program's operations read with the same values.
fn blockNumber(item: Value) Number {
    const class = (leafNumber(item) orelse scalarNumber(item)).?;
    return if (class == .byte) .integer else class;
}

/// A program's registers hold ints and reals, so a 0/1 result that would be
/// bytes outside a program is an int inside one; the program narrows its
/// final result to bytes itself when every value fits.
fn widened(class: Number) Number {
    return if (class == .byte) .integer else class;
}

fn blockBinaryResult(operation: BinaryOp, left: Number, right: Number) ?Number {
    @setEvalBranchQuota(100_000);
    return switch (operation) {
        inline else => |selected| switch (left) {
            inline .integer, .real => |left_class| switch (right) {
                inline .integer, .real => |right_class| if (comptime binaryResult(selected, left_class, right_class)) |class| widened(class) else null,
                .byte, .char1, .char2, .char4 => unreachable,
            },
            .byte, .char1, .char2, .char4 => unreachable,
        },
    };
}

fn blockUnaryResult(operation: UnaryOp, operand: Number) Number {
    return switch (operation) {
        inline else => |selected| switch (operand) {
            inline .integer, .real => |operand_class| widened(comptime unaryResult(selected, operand_class)),
            .byte, .char1, .char2, .char4 => unreachable,
        },
    };
}

/// Runs one binary instruction over a block into `ints` or `reals`, whichever
/// its result class writes, with the kernel the operation and operand classes
/// select. True when a position faulted. At least one operand is a run.
fn binaryBlock(operation: BinaryOp, left: BlockValue, right: BlockValue, ints: []i64, reals: []f64) bool {
    @setEvalBranchQuota(100_000);
    switch (operation) {
        inline else => |selected| switch (left) {
            inline else => |left_items, left_tag| switch (right) {
                inline else => |right_items, right_tag| {
                    const left_scalar = comptime left_tag == .int_scalar or left_tag == .real_scalar;
                    const right_scalar = comptime right_tag == .int_scalar or right_tag == .real_scalar;
                    const left_class: Number = comptime if (left_tag == .int_scalar or left_tag == .ints) .integer else .real;
                    const right_class: Number = comptime if (right_tag == .int_scalar or right_tag == .ints) .integer else .real;
                    const result = comptime binaryResult(selected, left_class, right_class);
                    if (comptime (left_scalar and right_scalar) or result == null) unreachable else {
                        const shape: Shape = comptime if (left_scalar) .scalar_leaf else if (right_scalar) .leaf_scalar else .leaf_leaf;
                        const out = comptime widened(result.?);
                        const Kernel = binaryKernelInto(selected, left_class, right_class, shape, out);
                        return switch (out) {
                            .integer => Kernel.runBlock(left_items, right_items, ints),
                            .real => Kernel.runBlock(left_items, right_items, reals),
                            .byte, .char1, .char2, .char4 => unreachable,
                        };
                    }
                },
            },
        },
    }
}

/// Runs one unary instruction over a block; see `binaryBlock`.
fn unaryBlock(operation: UnaryOp, operand: BlockValue, ints: []i64, reals: []f64) bool {
    @setEvalBranchQuota(100_000);
    switch (operation) {
        inline else => |selected| switch (operand) {
            inline .ints, .reals => |items, tag| {
                const operand_class: Number = comptime if (tag == .ints) .integer else .real;
                const out = comptime widened(unaryResult(selected, operand_class));
                const Kernel = unaryKernelInto(selected, operand_class, out);
                return switch (out) {
                    .integer => Kernel.runBlock(items, ints),
                    .real => Kernel.runBlock(items, reals),
                    .byte, .char1, .char2, .char4 => unreachable,
                };
            },
            .int_scalar, .real_scalar => unreachable,
        },
    }
}

/// A program run a block at a time through the typed kernels. Every register
/// has one class for the whole run (`programClasses`), and is a scalar when
/// everything it is computed from is, and a run otherwise.
const BlockPlan = struct {
    allocator: std.mem.Allocator,
    /// Positions per block.
    block: usize,
    classes: [ScalarProgram.max_registers]Number,
    scalar: [ScalarProgram.max_registers]bool,
    /// Storage for each register's run: register `r` uses `[r * block ..]`.
    ints: []i64,
    reals: []f64,

    fn create(allocator: std.mem.Allocator, program: *const ScalarProgram, operands: []const Value, length: usize) error{OutOfMemory}!*BlockPlan {
        const block = @min(length, flat.block_size);
        const registers: usize = program.registers;
        const plan = try allocator.create(BlockPlan);
        errdefer allocator.destroy(plan);
        const ints = try allocator.alloc(i64, registers * block);
        errdefer allocator.free(ints);
        plan.* = .{
            .allocator = allocator,
            .block = block,
            .classes = programClasses(program, operands).?,
            .scalar = programScalars(program, operands),
            .ints = ints,
            .reals = try allocator.alloc(f64, registers * block),
        };
        return plan;
    }

    fn destroy(self: *BlockPlan) void {
        self.allocator.free(self.ints);
        self.allocator.free(self.reals);
        self.allocator.destroy(self);
    }

    fn runInts(self: *const BlockPlan, register: usize, length: usize) []i64 {
        return self.ints[register * self.block ..][0..length];
    }

    fn runReals(self: *const BlockPlan, register: usize, length: usize) []f64 {
        return self.reals[register * self.block ..][0..length];
    }

    /// Computes positions `start..start + length` into `out`, the result's
    /// positions for the block. False when an instruction faulted somewhere in
    /// the block; nothing is written to `out` then, so an operand `out`
    /// shares storage with is intact for a replay.
    fn computeBlock(self: *BlockPlan, program: *const ScalarProgram, operands: []const Value, start: usize, length: usize, comptime Element: type, out: []Element) bool {
        // SAFETY: inputs and constants are set below, and every
        // instruction sets its destination before a later one reads it.
        var views: [ScalarProgram.max_registers]BlockValue = undefined;
        for (operands, 0..) |operand, input| {
            views[input] = if (operand != .list) BlockValue.of(operand) else switch (operand.list.kind()) {
                .leaf_i64 => .{ .ints = heap.leafElements(.leaf_i64, operand.list)[start..][0..length] },
                .leaf_f64 => .{ .reals = heap.leafElements(.leaf_f64, operand.list)[start..][0..length] },
                .leaf_u8 => widened: {
                    const run = self.runInts(input, length);
                    for (run, heap.leafElements(.leaf_u8, operand.list)[start..][0..length]) |*slot, item| slot.* = item;
                    break :widened .{ .ints = run };
                },
                else => unreachable, // `programCandidate` admits numeric leaves only.
            };
        }
        for (program.constants[0..program.constant_count]) |constant| views[constant.register] = BlockValue.of(constant.value);
        for (program.instructions[0..program.len]) |instruction| {
            const destination = instruction.destination;
            if (self.scalar[destination]) {
                const item = (switch (instruction.operation) {
                    .unary => |operation| switch (operation) {
                        inline else => |selected| scalarUnary(selected, views[instruction.left].boxed()),
                    },
                    .binary => |operation| switch (operation) {
                        inline else => |selected| scalarBinary(selected, views[instruction.left].boxed(), views[instruction.right].boxed()),
                    },
                }) catch return false;
                views[destination] = BlockValue.of(item);
                continue;
            }
            const ints = self.runInts(destination, length);
            const reals = self.runReals(destination, length);
            const faulted = switch (instruction.operation) {
                .unary => |operation| unaryBlock(operation, views[instruction.left], ints, reals),
                .binary => |operation| binaryBlock(operation, views[instruction.left], views[instruction.right], ints, reals),
            };
            if (faulted) return false;
            views[destination] = if (self.classes[destination] == .real) .{ .reals = reals } else .{ .ints = ints };
        }
        switch (views[program.result]) {
            .ints => |items| if (Element == i64) @memcpy(out, items) else unreachable,
            .reals => |items| if (Element == f64) @memcpy(out, items) else unreachable,
            .int_scalar => |integer| if (Element == i64) @memset(out, integer) else unreachable,
            .real_scalar => |number| if (Element == f64) @memset(out, number) else unreachable,
        }
        return true;
    }
};

/// A fault `pervade` has met so far, which an earlier instruction may still
/// displace.
const ProgramFault = struct { instruction: u8, index: usize, fault: ScalarError };

/// How a program's first fault is found and reported, shared by both
/// kernels. `each` reports the first element's first fault as it meets it.
/// `pervade` keeps the earliest instruction to fault so far; each later
/// position then runs only the instructions before it, so a fault it meets is
/// an earlier instruction's, at a later position than any before it, and the
/// answer is known once every position has run. An instruction whose result
/// is the same at every position faults with no list position, as a word
/// over atoms does.
fn ProgramFaults(comptime inputs: usize, comptime mode: ProgramMode) type {
    return struct {
        const Self = @This();

        /// The code the program was compiled from, borrowed from the
        /// operands, which the kernel holds.
        phrase: Value,
        scalar: [ScalarProgram.max_registers]bool,
        fault: ?ProgramFault = null,

        fn init(program: *const ScalarProgram, operands: [inputs + 1]Value) Self {
            return .{ .phrase = operands[inputs], .scalar = programScalars(program, operands[0..inputs]) };
        }

        /// Runs position `index` through the whole program. Null when it
        /// faulted and the fault was recorded.
        fn runAt(self: *Self, program: *const ScalarProgram, registers: *[ScalarProgram.max_registers]Value, operands: [inputs + 1]Value, index: usize, evaluator: *Fiber) MachineError!?Value {
            inline for (0..inputs) |input| registers[input] = programElement(operands[input], index);
            var failed: u8 = 0;
            return program.run(registers, &failed) catch |fault| {
                try self.met(program, .{ .instruction = failed, .index = index, .fault = fault }, evaluator);
                return null;
            };
        }

        /// Records a fault, or reports it when nothing can precede it: in
        /// `each` mode always, in `pervade` mode at the first instruction.
        fn met(self: *Self, program: *const ScalarProgram, fault: ProgramFault, evaluator: *Fiber) MachineError!void {
            if (mode == .each or fault.instruction == 0) return self.report(program, fault, evaluator);
            self.fault = fault;
        }

        /// `pervade`'s search over positions `start..end`.
        fn search(self: *Self, program: *const ScalarProgram, operands: [inputs + 1]Value, start: usize, end: usize, evaluator: *Fiber) MachineError!void {
            if (mode == .each) unreachable else { // `met` reported the first fault.
                // SAFETY: `load` fills the constants; inputs are set per position.
                var registers: [ScalarProgram.max_registers]Value = undefined;
                program.load(&registers);
                for (start..end) |index| {
                    inline for (0..inputs) |input| registers[input] = programElement(operands[input], index);
                    var failed: u8 = 0;
                    program.runPrefix(&registers, self.fault.?.instruction, &failed) catch |fault|
                        try self.met(program, .{ .instruction = failed, .index = index, .fault = fault }, evaluator);
                }
            }
        }

        /// Reports the fault the search settled on, once every position ran.
        fn settle(self: *const Self, program: *const ScalarProgram, evaluator: *Fiber) MachineError!void {
            if (self.fault) |fault| return self.report(program, fault, evaluator);
        }

        fn report(self: *const Self, program: *const ScalarProgram, fault: ProgramFault, evaluator: *Fiber) MachineError {
            const instruction = program.instructions[fault.instruction];
            const positioned = mode == .pervade and !self.scalar[instruction.destination];
            return failProgram(evaluator, self.phrase, instruction, fault.fault, if (positioned) fault.index else null);
        }
    };
}

/// The positions `0..inputs`, every input a planned program may write its
/// result over: a block's result is stored only after its operands are read.
fn inputPositions(comptime inputs: usize) [inputs]usize {
    var positions: [inputs]usize = undefined;
    for (&positions, 0..) |*position, index| position.* = index;
    return positions;
}

/// A planned program: each block computed through the typed kernels and
/// stored into the result leaf, which may take over an input's buffer. A
/// block that faults is replayed element by element, which meets the same
/// first fault in `each` mode and starts `pervade`'s search for it. The last
/// operand is the code the program was compiled from, which a fault names a
/// position in.
fn ProgramLeafKernel(comptime inputs: usize, comptime mode: ProgramMode, comptime kind: value.HeapKind) type {
    const Element = heap.LeafElement(kind);
    return struct {
        pub const arity = inputs + 1;
        /// The caller's program, read only by `prepare`, which copies it into
        /// the output.
        pub const Params = *const ScalarProgram;
        const positions = inputPositions(inputs);
        pub const result: support.ResultShape = .{ .kind = kind, .overwritable = &positions };
        const Leaf = support.LeafResult(kind);
        const Faults = ProgramFaults(inputs, mode);
        pub const Output = struct {
            allocator: std.mem.Allocator,
            leaf: Leaf,
            program: *ScalarProgram,
            plan: *BlockPlan,
            faults: Faults,

            pub fn retire(self: *Output, releases: *heap.ReleaseDomain) void {
                self.leaf.retire(releases);
                self.release();
            }

            fn release(self: *Output) void {
                self.plan.destroy();
                self.allocator.destroy(self.program);
            }
        };

        pub fn leafResult(output: *Output) *Leaf {
            return &output.leaf;
        }

        pub fn prepare(evaluator: *Fiber, operands: [arity]Value, borrowed: Params, length: usize, leaf: Leaf) error{OutOfMemory}!Output {
            const allocator = evaluator.allocator;
            const program = try ownProgram(evaluator, borrowed.*);
            errdefer allocator.destroy(program);
            return .{
                .allocator = allocator,
                .leaf = leaf,
                .program = program,
                .plan = try BlockPlan.create(allocator, program, operands[0..inputs], length),
                .faults = .init(program, operands),
            };
        }

        pub fn chunk(_: Params, operands: [arity]Value, output: *Output, range: flat.Chunk, evaluator: *Fiber) MachineError!void {
            const program = output.program;
            if (output.faults.fault != null) return output.faults.search(program, operands, range.start, range.end, evaluator);
            const plan = output.plan;
            var start = range.start;
            while (start != range.end) {
                const length = @min(plan.block, range.end - start);
                const out = output.leaf.range(start, length);
                if (!plan.computeBlock(program, operands[0..inputs], start, length, Element, out)) {
                    // SAFETY: `load` fills the constants; inputs and results
                    // are written before they are read.
                    var registers: [ScalarProgram.max_registers]Value = undefined;
                    program.load(&registers);
                    for (out, start..) |*slot, index| {
                        const item = try output.faults.runAt(program, &registers, operands, index, evaluator) orelse
                            return output.faults.search(program, operands, index + 1, range.end, evaluator);
                        slot.* = if (Element == i64) item.int else item.float;
                    }
                }
                start += length;
            }
        }

        pub fn next(evaluator: *Fiber, output: *Output) MachineError!?usize {
            try output.faults.settle(output.program, evaluator);
            return null;
        }

        pub fn finish(output: *Output) Value {
            const finished = output.leaf.finish();
            output.release();
            return finished;
        }
    };
}

/// A program no plan covers, computed element by element as atoms, then
/// written in the representation its values profile to.
fn ProgramValuesKernel(comptime inputs: usize, comptime mode: ProgramMode) type {
    return struct {
        pub const arity = inputs + 1;
        /// The caller's program, read only by `prepare`, which copies it into
        /// the output.
        pub const Params = *const ScalarProgram;
        const Faults = ProgramFaults(inputs, mode);
        pub const Output = struct {
            allocator: std.mem.Allocator,
            program: *ScalarProgram,
            results: []Value,
            profile: list.ListProfile = .{},
            builder: ?heap.AnyListBuilder = null,
            faults: Faults,

            pub fn retire(self: *Output, releases: *heap.ReleaseDomain) void {
                if (self.builder) |*builder| builder.retirePartial(releases);
                self.release();
            }

            fn release(self: *Output) void {
                self.allocator.free(self.results);
                self.allocator.destroy(self.program);
            }
        };

        pub fn prepare(evaluator: *Fiber, operands: [arity]Value, borrowed: Params, length: usize) error{OutOfMemory}!Output {
            const allocator = evaluator.allocator;
            const program = try ownProgram(evaluator, borrowed.*);
            errdefer allocator.destroy(program);
            return .{
                .allocator = allocator,
                .program = program,
                .results = try allocator.alloc(Value, length),
                .faults = .init(program, operands),
            };
        }

        pub fn chunk(_: Params, operands: [arity]Value, output: *Output, range: flat.Chunk, evaluator: *Fiber) MachineError!void {
            if (output.builder) |*builder| return builder.writeValues(range.start, output.results[range.start..range.end]);
            const program = output.program;
            if (output.faults.fault != null) return output.faults.search(program, operands, range.start, range.end, evaluator);
            // SAFETY: `load` fills the constants; inputs and results are
            // written before they are read.
            var registers: [ScalarProgram.max_registers]Value = undefined;
            program.load(&registers);
            var profile = output.profile;
            defer output.profile = profile;
            for (output.results[range.start..range.end], range.start..) |*slot, index| {
                slot.* = try output.faults.runAt(program, &registers, operands, index, evaluator) orelse
                    return output.faults.search(program, operands, index + 1, range.end, evaluator);
                profile = profile.add(slot.*);
            }
        }

        pub fn next(evaluator: *Fiber, output: *Output) MachineError!?usize {
            try output.faults.settle(output.program, evaluator);
            if (output.builder != null) return null;
            const length = output.results.len;
            output.builder = try heap.AnyListBuilder.init(output.allocator, output.profile.heapKind(), length, length);
            // A generic list counts the values written into it.
            if (output.builder.? == .generic) output.builder.?.generic.setLen(0);
            return length;
        }

        pub fn finish(output: *Output) Value {
            const header = output.builder.?.finish();
            output.release();
            return .{ .list = header };
        }
    };
}

/// Whether a two-input program can reduce `input` from `initial`, or from the
/// list's own first element when `initial` is null: a numeric leaf and a
/// numeric seed.
pub fn programReduceCandidate(input: Value, initial: ?Value) bool {
    if (!programOperand(input) or input != .list) return false;
    const seed = initial orelse return true;
    return seed == .int or seed == .float;
}

/// Runs a two-input program as `fold`, `fold1`, or `scan` runs its
/// quotation: input 0 is the accumulator and input 1 the element, strictly in
/// order, so the first fault is the one the generic route meets. A null
/// `initial` starts from the list's first element.
pub fn startProgramReduce(
    evaluator: *Fiber,
    input: *heap.OwnedValue,
    phrase: *heap.OwnedValue,
    program: ScalarProgram,
    initial: ?Value,
    scan: bool,
) MachineError!void {
    const count: usize = @intCast(input.borrow().list.length());
    const start: usize = if (initial == null) 1 else 0;
    const params: ProgramReduceParams = .{
        .program = try ownProgram(evaluator, program),
        .initial = initial orelse programElement(input.borrow(), 0),
        .start = start,
    };
    if (scan) return support.Kernel(ProgramReduceKernel(true)).run(evaluator, .{ input, phrase }, params, count - start);
    return support.Kernel(ProgramReduceKernel(false)).run(evaluator, .{ input, phrase }, params, count - start);
}

const ProgramReduceParams = struct {
    /// Owned by the output from `prepare` on.
    program: *ScalarProgram,
    initial: Value,
    /// The list index position 0 reads.
    start: usize,
};

fn ProgramReduceKernel(comptime scan: bool) type {
    return struct {
        pub const arity = 2;
        pub const Params = ProgramReduceParams;
        pub const Output = struct {
            allocator: std.mem.Allocator,
            program: *ScalarProgram,
            accumulator: Value,
            /// `scan`'s accumulators, then the list they become.
            results: []Value,
            profile: list.ListProfile = .{},
            builder: ?heap.AnyListBuilder = null,

            pub fn retire(self: *Output, releases: *heap.ReleaseDomain) void {
                if (self.builder) |*builder| builder.retirePartial(releases);
                self.release();
            }

            fn release(self: *Output) void {
                self.allocator.free(self.results);
                self.allocator.destroy(self.program);
            }
        };

        pub fn prepare(evaluator: *Fiber, _: [2]Value, params: Params, length: usize) error{OutOfMemory}!Output {
            const allocator = evaluator.allocator;
            errdefer allocator.destroy(params.program);
            return .{
                .allocator = allocator,
                .program = params.program,
                .accumulator = params.initial,
                .results = try allocator.alloc(Value, if (scan) length else 0),
            };
        }

        pub fn chunk(params: Params, operands: [2]Value, output: *Output, range: flat.Chunk, evaluator: *Fiber) MachineError!void {
            if (output.builder) |*builder| return builder.writeValues(range.start, output.results[range.start..range.end]);
            const program = output.program;
            // SAFETY: `load` fills the constants; inputs and results are
            // written before they are read.
            var registers: [ScalarProgram.max_registers]Value = undefined;
            program.load(&registers);
            var accumulator = output.accumulator;
            var profile = output.profile;
            defer output.accumulator = accumulator;
            for (range.start..range.end) |position| {
                registers[0] = accumulator;
                registers[1] = programElement(operands[0], params.start + position);
                var failed: u8 = 0;
                accumulator = program.run(&registers, &failed) catch |fault|
                    return failProgram(evaluator, operands[1], program.instructions[failed], fault, null);
                if (scan) {
                    output.results[position] = accumulator;
                    profile = profile.add(accumulator);
                }
            }
            output.profile = profile;
        }

        pub fn next(_: *Fiber, output: *Output) MachineError!?usize {
            if (!scan or output.builder != null) return null;
            const length = output.results.len;
            output.builder = try heap.AnyListBuilder.init(output.allocator, output.profile.heapKind(), length, length);
            // A generic list counts the values written into it.
            if (output.builder.? == .generic) output.builder.?.generic.setLen(0);
            return length;
        }

        pub fn finish(output: *Output) Value {
            const result: Value = if (scan) .{ .list = output.builder.?.finish() } else output.accumulator;
            output.release();
            return result;
        }
    };
}

/// Reports a program's fault as the faulting word would: that word active, at
/// its position in the code, with the shared scalar diagnostic, and at the
/// list position a pervading word reports.
fn failProgram(evaluator: *Fiber, phrase: Value, instruction: ScalarProgram.Instruction, fault: ScalarError, index: ?usize) MachineError {
    @setEvalBranchQuota(10_000);
    evaluator.active_word = .plain(instruction.word);
    const failure = scalarFailure(evaluator, fault, index);
    evaluator.setFailureSite(phrase.list, instruction.index);
    return failure;
}

/// The caller guards with the matching candidate predicate, so the start
/// asserts: a guard and a dispatch that could disagree would be a second,
/// silent classification.
pub fn idiomUnaryStart(operation: UnaryOp) IdiomStart.Unary {
    return switch (operation) {
        inline else => |selected| struct {
            fn run(evaluator: *Fiber, operand: *heap.OwnedValue) MachineError!void {
                const started = try startTypedUnary(evaluator, selected, operand, .{ .index = false });
                std.debug.assert(started);
            }
        }.run,
    };
}

pub fn idiomBinaryStart(operation: BinaryOp) IdiomStart.Binary {
    return switch (operation) {
        inline else => |selected| struct {
            fn run(
                evaluator: *Fiber,
                left: *heap.OwnedValue,
                right: *heap.OwnedValue,
            ) MachineError!void {
                const started = try startTypedBinary(evaluator, selected, left, right, .{ .index = false });
                std.debug.assert(started);
            }
        }.run,
    };
}

/// Whether the typed route would take this operand shape. The recognizer asks
/// before consuming its stack values, so a shape that belongs to the generic
/// route reaches the existing driver with the stack untouched.
pub fn typedUnaryCandidate(operand: Value) bool {
    if (operand != .list or operand.list.length() == 0) return false;
    return operand.list.kind() != .generic_spine;
}

/// A constant captured in a recognized phrase pairs with each element, so the
/// typed route applies only when that constant is a numeric atom: a list
/// constant would broadcast per element into a nested result, which is a
/// different computation from an elementwise pass.
pub fn typedConstantCandidate(operation: BinaryOp, input: Value, constant: Value, constant_left: bool) bool {
    if (constant == .list or constant == .dict or constant == .task or constant == .address) return false;
    if (constant_left) return typedBinaryCandidate(operation, constant, input);
    return typedBinaryCandidate(operation, input, constant);
}

pub fn typedBinaryCandidate(operation: BinaryOp, left: Value, right: Value) bool {
    @setEvalBranchQuota(10_000);
    const left_leaf = leafNumber(left);
    const right_leaf = leafNumber(right);
    const left_flat = left == .list and left.list.kind() != .generic_spine;
    const right_flat = right == .list and right.list.kind() != .generic_spine;
    if (!left_flat and !right_flat) return false;
    if ((left == .list and !left_flat) or (right == .list and !right_flat) or
        left == .dict or right == .dict or left == .task or right == .task or
        left == .address or right == .address) return false;
    const length: usize = if (left_flat) @intCast(left.list.length()) else @intCast(right.list.length());
    if (length == 0) return false;
    // The only successful flat result with no single representation is the
    // settled mixed numeric min/max case. Every other nonnumeric combination
    // faults at its first element.
    if (left_leaf != null and right_leaf != null and left_leaf.? != right_leaf.? and
        (operation == .min or operation == .max)) return false;
    const left_class = left_leaf orelse scalarNumber(left);
    const right_class = right_leaf orelse scalarNumber(right);
    if (left_class == null or right_class == null) return true;
    // A conformance mismatch is reported identically by either route, so let the
    // typed route report it.
    var result_known = false;
    inline for (number_classes) |candidate_left| {
        inline for (number_classes) |candidate_right| {
            if (candidate_left == left_class.? and candidate_right == right_class.?) {
                switch (operation) {
                    inline else => |selected| {
                        result_known = comptime binaryResult(selected, candidate_left, candidate_right) != null;
                    },
                }
            }
        }
    }
    return result_known;
}

/// Typed sequential reduction.
///
/// `fold` and `scan` over a numeric leaf are unboxed but strictly sequential:
/// each step consumes the previous accumulator, so the loop may not be
/// reordered, blocked out of order, or reassociated — float sums stay
/// bit-identical to the generic route by construction rather than by policy. The
/// accumulator's class must reach a fixpoint after at most one scalar step.
/// That step retains the original seed's semantics; the kernel then carries
/// only a stable accumulator and needs one monomorphic loop.
const TypedAccumulator = union(enum) {
    integer: i64,
    real: f64,
};

/// What a sequential reduction's kernel needs besides its list: the seed and
/// the list index the reduction starts from.
const ReduceParams = struct {
    initial: Value,
    cursor_start: usize,
};

/// A sequential reduction's result as it builds: the accumulator, and for
/// `scan` the sequence of accumulators. Position 0 of the kernel is list
/// index `base`.
const ReduceOutput = struct {
    accumulator: TypedAccumulator,
    /// Present for `scan`, whose result is the sequence of accumulators.
    scan: ?KernelOutput,
    base: usize,

    pub fn retire(self: *ReduceOutput, releases: *heap.ReleaseDomain) void {
        if (self.scan) |*output| output.retire(releases);
        self.scan = null;
    }
};

const RunReduce = *const fn (*Fiber, [1]*heap.OwnedValue, ReduceKernelParams, usize) MachineError!void;

fn reduceKernel(
    comptime operation: BinaryOp,
    comptime accumulator_class: Number,
    comptime element_class: Number,
    comptime scan: bool,
) type {
    const Staging = flat.Block(accumulator_class.Element());
    return struct {
        fn accumulated(output: *const ReduceOutput) accumulator_class.Element() {
            return switch (accumulator_class) {
                .byte, .char1, .char2, .char4 => unreachable,
                .integer => output.accumulator.integer,
                .real => output.accumulator.real,
            };
        }

        fn store(output: *ReduceOutput, element: accumulator_class.Element()) void {
            output.accumulator = switch (accumulator_class) {
                .byte, .char1, .char2, .char4 => unreachable,
                .integer => .{ .integer = element },
                .real => .{ .real = element },
            };
        }

        /// Float `+`, `-`, and `*` fault only on a NaN result, and NaN is
        /// sticky through them. A block whose unchecked result is not NaN
        /// therefore had no faulting step, so it pays one test instead of one
        /// per element; infinities pass through. A NaN block replays through
        /// the checked scalar to report the fault where it happened.
        const unchecked = accumulator_class == .real and
            (operation == .add or operation == .sub or operation == .mul);

        fn uncheckedBlock(output: *ReduceOutput, elements: []const element_class.Element(), piece: flat.Chunk, block: *Staging) bool {
            var accumulator = accumulated(output);
            for (piece.start..piece.end) |index| {
                const element: f64 = switch (element_class) {
                    .byte, .char1, .char2, .char4, .integer => @floatFromInt(elements[index]),
                    .real => elements[index],
                };
                accumulator = switch (operation) {
                    .add => accumulator + element,
                    .sub => accumulator - element,
                    .mul => accumulator * element,
                    else => unreachable,
                };
                if (scan) block.items[index - piece.start] = accumulator;
            }
            if (std.math.isNan(accumulator)) return false;
            store(output, accumulator);
            if (scan) block.len = piece.len();
            return true;
        }

        /// Folds list indices `range` into the accumulator, in order.
        fn accumulate(output: *ReduceOutput, elements: []const element_class.Element(), range: flat.Chunk, evaluator: *Fiber) MachineError!void {
            var block = Staging.init();
            var offset: usize = 0;
            while (offset != range.len()) {
                const piece = flat.blockRange(range, offset);
                block.reset();
                if (unchecked and uncheckedBlock(output, elements, piece, &block)) {
                    if (scan) output.scan.?.leaf(accumulator_class).store(piece.start, block.written());
                    offset += piece.len();
                    continue;
                }
                // The accumulator stays in a local for the block: `output`
                // is reached through a pointer the loop cannot prove distinct
                // from `elements`, so updating it there would store and reload
                // it on every element.
                var accumulator = accumulated(output);
                for (piece.start..piece.end) |index| {
                    // Both operand tags are comptime-known here, so inlining
                    // the scalar authority lets its type dispatch fold away and
                    // leaves the checked arithmetic itself in the loop. An
                    // out-of-line call boxed and redispatched every element,
                    // and was most of a float reduction's cost.
                    const next = @call(.always_inline, scalarBinary, .{
                        operation,
                        accumulator_class.boxed(accumulator),
                        element_class.boxed(elements[index]),
                    }) catch |fault| {
                        // A sequential fold's first fault is the fault: there is
                        // no later element whose result could precede it, so the
                        // failure is reported where it happened. A recognized
                        // combinator's fault carries no list index, exactly as
                        // the per-element route reported it.
                        const diagnostic = scalarDiagnostic(fault);
                        return evaluator.fail(diagnostic.kind, diagnostic.message);
                    };
                    accumulator = accumulator_class.unboxed(next);
                    if (scan) block.items[index - piece.start] = accumulator;
                }
                store(output, accumulator);
                if (scan) {
                    block.len = piece.len();
                    output.scan.?.leaf(accumulator_class).store(piece.start, block.written());
                }
                offset += piece.len();
            }
        }

        /// The reduction's loop over these classes, as `ReduceKernel` calls
        /// it. Its positions are the list indices after the seed.
        fn chunk(operands: [1]Value, output: *ReduceOutput, range: flat.Chunk, evaluator: *Fiber) MachineError!void {
            return accumulate(
                output,
                heap.leafElements(element_class.kind(), operands[0].list),
                .{ .start = output.base + range.start, .end = output.base + range.end },
                evaluator,
            );
        }
    };
}

/// One reduction's loop over one accumulator and element class; see
/// `ReduceKernel`.
const ReduceChunk = *const fn ([1]Value, *ReduceOutput, flat.Chunk, *Fiber) MachineError!void;

/// What a reduction kernel runs with: the caller's seed and start, the
/// operation's scalar step for a seed that changes class, and the plan's
/// loop.
const ReduceKernelParams = struct {
    reduce: ReduceParams,
    step: ScalarBinary,
    chunk: ReduceChunk,
};

/// The `support.Kernel` of every sequential reduction with this accumulator
/// class and form; see `BinaryKernel`. A seed that changes class takes one
/// scalar step from the first remaining element before the loop.
fn ReduceKernel(comptime accumulator_class: Number, comptime scan: bool, comptime seeded: bool) type {
    return struct {
        const Spec = struct {
            pub const arity = 1;
            pub const Params = ReduceKernelParams;
            pub const Output = ReduceOutput;

            /// A scan's result is the input's length, and each position is
            /// stored only after the element at it is read.
            pub const result: ?support.ResultShape = if (scan) .{ .kind = accumulator_class.kind(), .overwritable = &.{0} } else null;

            pub fn resultLength(_: ReduceKernelParams, operands: [1]Value, _: usize) usize {
                return @intCast(operands[0].list.length());
            }

            pub fn leafResult(output: *Output) *support.LeafResult(accumulator_class.kind()) {
                return output.scan.?.leaf(accumulator_class);
            }

            pub const prepare = if (scan) prepareScan else prepareFold;

            fn prepareScan(evaluator: *Fiber, operands: [1]Value, params: ReduceKernelParams, length: usize, prepared: support.LeafResult(accumulator_class.kind())) MachineError!Output {
                var output = try prepareFold(evaluator, operands, params, length);
                output.scan = .wrap(accumulator_class, prepared);
                if (seeded) output.scan.?.leaf(accumulator_class).store(params.reduce.cursor_start, &.{switch (output.accumulator) {
                    .integer => |number| if (accumulator_class == .integer) number else unreachable,
                    .real => |number| if (accumulator_class == .real) number else unreachable,
                }});
                return output;
            }

            fn prepareFold(evaluator: *Fiber, operands: [1]Value, params: ReduceKernelParams, _: usize) MachineError!Output {
                const input = operands[0];
                const start = params.reduce.cursor_start;
                const seed = if (seeded) first: {
                    // Charge even this single step to the shared budget: many
                    // short reductions must not evade cancellation. Do not
                    // pre-cast initial; mixed numeric comparisons in particular
                    // would lose information.
                    try evaluator.advanceKernel(1);
                    break :first params.step(params.reduce.initial, list.atUnchecked(input, start)) catch |fault| {
                        const diagnostic = scalarDiagnostic(fault);
                        return evaluator.fail(diagnostic.kind, diagnostic.message);
                    };
                } else ordinal(params.reduce.initial);
                const output: Output = .{
                    .accumulator = switch (accumulator_class) {
                        .byte, .char1, .char2, .char4 => unreachable,
                        .integer => .{ .integer = seed.int },
                        .real => .{ .real = seed.float },
                    },
                    .scan = null,
                    .base = start + @intFromBool(seeded),
                };
                return output;
            }

            pub fn chunk(params: ReduceKernelParams, operands: [1]Value, output: *Output, range: flat.Chunk, evaluator: *Fiber) MachineError!void {
                return params.chunk(operands, output, range, evaluator);
            }

            pub fn finish(output: *Output) Value {
                if (scan) return output.scan.?.finish();
                return switch (output.accumulator) {
                    .integer => |number| .{ .int = number },
                    .real => |number| .{ .float = number },
                };
            }
        };

        const run = support.Kernel(Spec).run;
    };
}

/// Whether a recognized `fold`/`scan` over these operands is a typed sequential
/// loop. The accumulator class must stabilize after at most one scalar step.
pub fn typedReduceCandidate(operation: BinaryOp, input: Value, initial: Value) bool {
    const element_class = leafNumber(input) orelse return false;
    const accumulator_class = scalarNumber(initial) orelse return false;
    if (input.list.length() == 0) return false;
    return NumericReducePlan.select(operation, accumulator_class, element_class, false) != null;
}

/// Whether a recognized `fold` or `scan` of `operation` with an int seed is
/// one typed pass over int and byte lanes. The idiom registry requires this
/// of every reduction it recognizes: one that matches but has no plan still
/// runs, one scheduler turn per element, so only the cost would show it.
pub fn reducesIntLanesTyped(comptime operation: BinaryOp) bool {
    inline for ([_]Number{ .integer, .byte }) |element| {
        inline for ([_]bool{ false, true }) |scan| {
            if (NumericReducePlan.select(operation, .integer, element, scan) == null) return false;
        }
    }
    return true;
}

/// The opaque plan binds a possible seed transition to its stable loop and
/// output representation. Guard and entry use the same classification.
const NumericReducePlan = opaque {
    const Data = struct {
        accumulator: Number,
        element: Number,
        scan: bool,
        seeded: bool,
        run: RunReduce,
        step: ScalarBinary,
        chunk: ReduceChunk,
    };

    fn select(operation: BinaryOp, accumulator: Number, element: Number, scan: bool) ?*const NumericReducePlan {
        @setEvalBranchQuota(8000);
        return switch (operation) {
            inline else => |selected| blk: {
                // Scalar accumulators have no byte storage class: a 0/1 result
                // that is a byte in a leaf is an int scalar, as `scalarBinary`
                // returns it, so the accumulator and a scan's output widen.
                inline for ([_]Number{ .integer, .real }) |candidate_accumulator| {
                    inline for (number_classes) |candidate_element| {
                        const raw = comptime binaryResult(selected, candidate_accumulator, candidate_element);
                        if (comptime raw == null) continue;
                        // A widened 0/1 result is planned only where it is
                        // used, an int seed over int or byte lanes; any other
                        // pairing keeps the generic route and its code size.
                        if (comptime raw.? == .byte and (candidate_accumulator != .integer or
                            (candidate_element != .integer and candidate_element != .byte))) continue;
                        const out: ?Number = comptime widened(raw.?);
                        // A known first result is insufficient: every later
                        // result must have that same representation as well.
                        const next = comptime binaryResult(selected, out.?, candidate_element);
                        if (comptime next == null or widened(next.?) != out.?) continue;
                        inline for ([_]bool{ false, true }) |candidate_scan| {
                            if (accumulator == candidate_accumulator and element == candidate_element and scan == candidate_scan) {
                                const seeded = comptime out.? != candidate_accumulator;
                                const data = comptime Data{
                                    .accumulator = out.?,
                                    .element = candidate_element,
                                    .scan = candidate_scan,
                                    .seeded = seeded,
                                    .run = ReduceKernel(out.?, candidate_scan, seeded).run,
                                    .step = selectScalar(selected),
                                    .chunk = reduceKernel(selected, out.?, candidate_element, candidate_scan).chunk,
                                };
                                break :blk @ptrCast(&data);
                            }
                        }
                    }
                }
                break :blk null;
            },
        };
    }

    /// The recognized combinator's `consumed` stack values (the list, then
    /// any seed and quotation) are popped into owners, as an operation pops
    /// its operands, and the list is the kernel's operand; the rest are
    /// released after the result is pushed. `initial` is a scalar or the
    /// list's own element, valid while the list is held. The combinator
    /// handles empty folds/scans and singleton fold1 before entry, so
    /// cursor_start always identifies a remaining input element.
    fn start(self: *const NumericReducePlan, evaluator: *Fiber, input: Value, initial: Value, cursor_start: usize, consumed: usize) MachineError!void {
        const data: *const Data = @ptrCast(@alignCast(self));
        std.debug.assert(consumed >= 1 and consumed <= 3);
        var popped: [3]heap.OwnedValue = undefined;
        var count: usize = 0;
        defer for (popped[0..count]) |*owner| owner.deinit();
        while (count != consumed) : (count += 1) popped[count] = try evaluator.popValue();
        const list_owner = &popped[consumed - 1];
        std.debug.assert(list_owner.borrow().list == input.list);
        const first = cursor_start + @intFromBool(data.seeded);
        const params: ReduceKernelParams = .{
            .reduce = .{ .initial = initial, .cursor_start = cursor_start },
            .step = data.step,
            .chunk = data.chunk,
        };
        try data.run(evaluator, .{list_owner}, params, @as(usize, @intCast(input.list.length())) - first);
    }
};

/// Reached only if a guard and a dispatch disagreed, which the candidate
/// predicate exists to prevent; it is a domain error rather than a silent
/// second classification.
fn unexpectedReduceShape(evaluator: *Fiber) MachineError {
    return evaluator.fail(.domain, "typed reduction reached an unclassified operand shape");
}

/// The result of applying one row of a leading-axis fold.
pub const RowFold = union(enum) {
    /// Not a same-class, same-length typed pair, or the row does not fit the
    /// turn's remaining budget: the caller applies it through its cursor.
    declined,
    /// The solely-owned accumulator was updated in place. The caller's
    /// reference is now this value's reference.
    in_place: Value,
    /// A fresh accumulator. The caller still owns, and releases, the old one.
    fresh: Value,
};

/// One step of a fold over rows: `accumulator operation row`, elementwise,
/// when both are typed leaves of one class whose result keeps that class.
/// It computes what the pervasive binary would, element by element through
/// the same scalar authority, and reports the same first fault at the same
/// element index; it only skips that route's per-row cursor, allocation, and
/// machine turn. The whole row is charged before it runs, and a row larger
/// than the remaining budget is declined rather than split.
pub fn foldLeafRow(
    evaluator: *Fiber,
    operation: BinaryOp,
    accumulator: Value,
    accumulator_owned: bool,
    row: Value,
) MachineError!RowFold {
    @setEvalBranchQuota(100_000);
    const accumulator_class = leafNumber(accumulator) orelse return .declined;
    const row_class = leafNumber(row) orelse return .declined;
    const length: usize = @intCast(row.list.length());
    if (length == 0 or accumulator.list.length() != length) return .declined;
    if (length > evaluator.remainingKernelFuel()) return .declined;
    return switch (operation) {
        inline else => |selected| switch (accumulator_class) {
            inline else => |selected_accumulator| switch (row_class) {
                inline else => |selected_row| if (comptime rowFoldAccepts(selected, selected_accumulator, selected_row))
                    rowFoldStep(selected, selected_accumulator, selected_row).run(evaluator, accumulator, accumulator_owned, row, length)
                else
                    .declined,
            },
        },
    };
}

/// Whether a row step is typed: read from the result lattice, as
/// `columnAccumulator` reads it. The step's result must be of one class and
/// a further step from that class over the same rows must keep it, so the
/// fold's accumulator class settles after at most one step. Byte rows settle
/// on ints, int and real rows on reals; `min` and `max` over mixed classes
/// have no single-class result and stay on the per-row cursor.
///
/// No step produces a stored width other than its own operands' byte, so an
/// accumulator stored narrower than an int differs from its row's class at
/// most once per fold, at its first step over rows of mixed classes; that
/// one step takes the cursor too.
fn rowFoldAccepts(comptime operation: BinaryOp, comptime accumulator: Number, comptime row: Number) bool {
    if (!accumulator.scalar() and accumulator != row) return false;
    const out = binaryResult(operation, accumulator, row) orelse return false;
    return binaryResult(operation, out, row) == out;
}

/// The accumulator class of a fold over rows of `element` leaves: what the
/// first step produces, when every later step keeps it. Bytes accumulate as
/// integers; there is no byte arithmetic result.
fn columnAccumulator(comptime operation: BinaryOp, comptime element: Number) ?Number {
    const first = binaryResult(operation, element, element) orelse return null;
    if (first == .byte) return null;
    if (binaryResult(operation, first, element) != first) return null;
    return first;
}

/// Whether `foldColumns` takes this operation over this operand: a
/// nonempty numeric leaf whose fold over rows keeps one accumulator class.
pub fn columnFoldCandidate(operation: BinaryOp, input: Value) bool {
    const class = leafNumber(input) orelse return false;
    if (input.list.length() == 0) return false;
    return switch (operation) {
        inline else => |selected| switch (class) {
            inline else => |selected_class| comptime columnAccumulator(selected, selected_class) != null,
        },
    };
}

/// The fold over the rows of `input` laid out as `rows` × `columns`,
/// computed from its one buffer through `support.Kernel`: what reshaping it
/// and folding the rows computes, with the same association, the same
/// element arithmetic, the same result representation, and the same first
/// fault at the same column index, but without building the rows. The
/// result is pushed; the caller releases `input` as on any decline. The
/// caller guards with `columnFoldCandidate` and has checked that
/// `rows · columns` is the input's length.
pub fn foldColumns(evaluator: *Fiber, operation: BinaryOp, input: *heap.OwnedValue, rows: usize, columns: usize) MachineError!void {
    @setEvalBranchQuota(10_000);
    const shape: ColumnShape = .{ .rows = rows, .width = columns };
    return switch (operation) {
        inline else => |selected| switch (leafNumber(input.borrow()).?) {
            inline else => |selected_class| if (comptime columnAccumulator(selected, selected_class) == null)
                unreachable
            else if (rows == 1)
                support.Kernel(columnFold(selected, selected_class).CopySpec).run(evaluator, .{input}, shape, columns)
            else
                support.Kernel(columnFold(selected, selected_class).FoldSpec).run(evaluator, .{input}, shape, rows * columns),
        },
    };
}

const ColumnShape = struct { rows: usize, width: usize };

fn columnFold(comptime operation: BinaryOp, comptime element: Number) type {
    const accumulator = columnAccumulator(operation, element).?;
    const Out = accumulator.Element();
    return struct {
        /// A single row is the fold's unchanged first element: a copy of
        /// that row in its own representation.
        const CopySpec = struct {
            pub const arity = 1;
            pub const Params = ColumnShape;
            pub const Output = support.LeafResult(element.kind());
            /// An input that becomes the result already holds its first row
            /// where the result's positions are.
            pub const result: ?support.ResultShape = .{ .kind = element.kind(), .overwritable = &.{0} };

            pub fn resultLength(shape: ColumnShape, _: [1]Value, _: usize) usize {
                return shape.width;
            }

            pub fn chunk(_: ColumnShape, operands: [1]Value, output: *Output, range: flat.Chunk, _: *Fiber) MachineError!void {
                if (output.aliased()) return;
                output.store(range.start, heap.leafElements(element.kind(), operands[0].list)[range.start..range.end]);
            }

            pub const finish = Output.finish;
        };

        /// Positions are the input's, row by row: row 0 seeds each column's
        /// accumulator, and every later row folds into it, so each column
        /// folds in row order however the positions are split into ranges.
        /// Seeding converts row 0 to the accumulator class; a step from it is
        /// the same arithmetic on the same values as one from the row.
        const FoldSpec = struct {
            pub const arity = 1;
            pub const Params = ColumnShape;
            pub const Output = support.LeafResult(accumulator.kind());
            /// The accumulator is the result's `width` positions, over the
            /// input's first row when it takes the input's buffer: seeding
            /// writes row 0 over itself, and every later row is read from
            /// positions the accumulator never covers.
            pub const result: ?support.ResultShape = .{ .kind = accumulator.kind(), .overwritable = &.{0} };

            pub fn resultLength(shape: ColumnShape, _: [1]Value, _: usize) usize {
                return shape.width;
            }

            pub fn chunk(shape: ColumnShape, operands: [1]Value, output: *Output, range: flat.Chunk, evaluator: *Fiber) MachineError!void {
                const width = shape.width;
                const elements = heap.leafElements(element.kind(), operands[0].list);
                const columns = output.range(0, width);
                var position = range.start;
                // Rows 0 and 1 in one step, as `foldLeafRow` folds a first
                // pair, whenever the range holds both whole.
                if (position == 0 and range.end >= 2 * width) {
                    try step(element, evaluator, elements[0..width], elements[width..][0..width], columns, 0);
                    position = 2 * width;
                }
                var row = position / width;
                var column = position % width;
                while (position != range.end) {
                    const count = @min(range.end - position, width - column);
                    const target = columns[column..][0..count];
                    const items = elements[position..][0..count];
                    if (row == 0) {
                        for (target, items) |*slot, item| slot.* = switch (accumulator) {
                            .byte, .char1, .char2, .char4 => unreachable,
                            .integer => if (element == .real) unreachable else @intCast(item),
                            .real => if (element == .real) item else @floatFromInt(item),
                        };
                    } else try step(accumulator, evaluator, target, items, target, column);
                    position += count;
                    row += 1;
                    column = 0;
                }
            }

            pub const finish = Output.finish;
        };

        /// `left op right` into `out`, which may alias `left`: each block is
        /// computed from operands not yet stored over, then stored. Float
        /// `+ - *` run unchecked and replay checked only on a NaN, as
        /// `rowFoldStep` does.
        fn step(
            comptime left_class: Number,
            evaluator: *Fiber,
            left: []const left_class.Element(),
            right: []const element.Element(),
            out: []Out,
            /// The column of `out[0]`, which is where a fault is reported.
            base: usize,
        ) MachineError!void {
            const unchecked = accumulator == .real and left_class == .real and element == .real and
                (operation == .add or operation == .sub or operation == .mul);
            var block: [flat.block_size]Out = undefined;
            var start: usize = 0;
            while (start != out.len) {
                const end = @min(start + flat.block_size, out.len);
                if (unchecked) {
                    var clean = true;
                    for (start..end, 0..) |index, slot| {
                        const next = switch (operation) {
                            .add => left[index] + right[index],
                            .sub => left[index] - right[index],
                            .mul => left[index] * right[index],
                            else => unreachable,
                        };
                        clean = clean and !std.math.isNan(next);
                        block[slot] = next;
                    }
                    if (clean) {
                        @memcpy(out[start..end], block[0 .. end - start]);
                        start = end;
                        continue;
                    }
                }
                for (start..end, 0..) |index, slot| {
                    const next = @call(.always_inline, scalarBinary, .{
                        operation,
                        left_class.boxed(left[index]),
                        element.boxed(right[index]),
                    }) catch |fault| {
                        const diagnostic = scalarDiagnostic(fault);
                        return evaluator.failAtIndex(diagnostic.kind, diagnostic.message, base + index);
                    };
                    block[slot] = accumulator.unboxed(next);
                }
                @memcpy(out[start..end], block[0 .. end - start]);
                start = end;
            }
        }
    };
}

fn rowFoldStep(comptime operation: BinaryOp, comptime accumulator_class: Number, comptime row_class: Number) type {
    const out = comptime binaryResult(operation, accumulator_class, row_class).?;
    const Left = accumulator_class.Element();
    const Right = row_class.Element();
    const Element = out.Element();
    const Staging = flat.Block(Element);
    return struct {
        /// See `reduceKernel`: float `+ - *` fault only on a NaN result, so a
        /// clean unchecked block needs no per-element test.
        const unchecked = accumulator_class == .real and row_class == .real and
            (operation == .add or operation == .sub or operation == .mul);

        fn run(evaluator: *Fiber, accumulator: Value, accumulator_owned: bool, row: Value, length: usize) MachineError!RowFold {
            try evaluator.advanceKernel(length);
            var right = heap.LeafReader(row_class.kind()).acquire(row.list);
            defer right.release(evaluator.releases);
            // The accumulator may become the next one through the one
            // adoption every result producer uses; the step reads each
            // position of it before storing that position.
            if (out == accumulator_class and accumulator_owned) if (support.adopt(out.kind(), accumulator, 1, length)) |adopted| {
                var result = adopted;
                errdefer result.retire(evaluator.releases);
                try apply(evaluator, heap.leafElements(out.kind(), accumulator.list)[0..length], right.slice(), result.range(0, length));
                return .{ .in_place = result.finish() };
            };
            var left = heap.LeafReader(accumulator_class.kind()).acquire(accumulator.list);
            defer left.release(evaluator.releases);
            var writer = try heap.LeafWriter(out.kind()).init(evaluator.allocator, length);
            errdefer writer.retirePartial(evaluator.releases);
            try apply(evaluator, left.slice(), right.slice(), writer.unpublishedRange(0, length));
            return .{ .fresh = writer.finish() };
        }

        /// `out` may alias `left`: each block is computed from operands not
        /// yet stored over, then stored.
        fn apply(evaluator: *Fiber, left: []const Left, right: []const Right, out_items: []Element) MachineError!void {
            var block = Staging.init();
            var start: usize = 0;
            while (start != out_items.len) {
                const end = @min(start + flat.block_size, out_items.len);
                if (unchecked) {
                    var clean = true;
                    for (start..end, 0..) |index, slot| {
                        const next = switch (operation) {
                            .add => left[index] + right[index],
                            .sub => left[index] - right[index],
                            .mul => left[index] * right[index],
                            else => unreachable,
                        };
                        clean = clean and !std.math.isNan(next);
                        block.items[slot] = next;
                    }
                    if (clean) {
                        @memcpy(out_items[start..end], block.items[0 .. end - start]);
                        start = end;
                        continue;
                    }
                }
                for (start..end, 0..) |index, slot| {
                    const next = @call(.always_inline, scalarBinary, .{
                        operation,
                        accumulator_class.boxed(left[index]),
                        row_class.boxed(right[index]),
                    }) catch |fault| {
                        const diagnostic = scalarDiagnostic(fault);
                        return evaluator.failAtIndex(diagnostic.kind, diagnostic.message, index);
                    };
                    block.items[slot] = out.unboxed(next);
                }
                @memcpy(out_items[start..end], block.items[0 .. end - start]);
                start = end;
            }
        }
    };
}

/// `consumed` stack values lie under the result: the list is the deepest,
/// and `start` is 1 when `initial` is its first element.
pub fn startReduction(
    evaluator: *Fiber,
    operation: BinaryOp,
    scan: bool,
    input: Value,
    initial: Value,
    start: usize,
    consumed: usize,
) MachineError!void {
    const from_first = start == 1;
    std.debug.assert(input == .list);
    const count: usize = @intCast(input.list.length());
    if (count == start) {
        if (from_first) {
            try evaluator.pushBorrowed(initial);
            var result = try evaluator.popValue();
            defer result.deinit();
            evaluator.discard(consumed);
            return evaluator.pushOwned(result.take());
        }
        if (scan) {
            const result = try list.fromValuesGeneric(evaluator.allocator, &.{});
            evaluator.discard(3);
            return evaluator.pushOwned(result);
        }
        evaluator.discard(1);
        var accumulator = try evaluator.popValue();
        defer accumulator.deinit();
        evaluator.discard(1);
        try evaluator.pushOwned(accumulator.take());
        return;
    }
    // Over a numeric leaf with an accumulator that stabilizes after at most
    // one scalar step, reduction is one typed sequential pass instead of one
    // cursor and one scheduler turn per element. Association stays left-to-right, so
    // float sums keep the generic route's bits.
    if (typedReduceCandidate(operation, input, initial)) {
        return idiomReduceStart(operation)(evaluator, input, initial, scan, start, consumed);
    }
    const results: ?heap.OwnedValueBuffer = if (scan)
        try .init(evaluator.releases, count)
    else
        null;
    try evaluator.startDriver(ReductionDriver{
        .operation = operation,
        .scan = scan,
        .input = input,
        .initialized = start,
        .consumed = consumed,
        .accumulator = .init(.{ .borrowed = initial }),
        .results = if (results) |owned_results| .init(owned_results) else null,
        .materializer = null,
    });
}

const ReductionDriver = struct {
    /// Like a typed kernel's driver, it lives for one reduction and
    /// releases the slot when it publishes, so it qualifies for the slot on
    /// lifetime; a fold whose rows apply directly would otherwise spend its
    /// largest fixed cost on this driver's allocation.
    pub const inline_driver = true;

    consumed: usize,
    operation: BinaryOp,
    scan: bool,
    input: Value,
    accumulator: heap.Owned(Accumulator),
    results: ?heap.Owned(heap.OwnedValueBuffer),
    initialized: usize = 0,
    materializing: bool = false,
    materializer: ?heap.Owned(list.ValueMaterializer),
    // Not optional: emptying a `?Owned` of this size clears it whole, and
    // the cursor is emptied once per row.
    cursor: heap.Owned(PervadeCursor) = .none,

    pub fn advance(
        evaluator: *Fiber,
        self: *ReductionDriver,
    ) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        // A fold whose accumulator and next row are typed leaves of one class
        // and length applies whole rows here, each charged before it runs,
        // without a cursor or a machine turn per row. Anything else, and any
        // row the remaining budget cannot pay for, takes the cursor below.
        if (!self.scan) while (!self.cursor.isPresent() and self.initialized < self.input.list.length()) {
            const accumulator = self.accumulator.borrowMut();
            const owned = accumulator.* == .owned;
            switch (try foldLeafRow(
                evaluator,
                self.operation,
                accumulator.value(),
                owned,
                list.atUnchecked(self.input, self.initialized),
            )) {
                .declined => break,
                .in_place => |next| accumulator.* = .{ .owned = next },
                .fresh => |next| accumulator.replaceOwned(evaluator.releases, next),
            }
            self.initialized += 1;
            if (evaluator.remainingKernelFuel() == 0) return .stepped;
        };
        if (!self.materializing and self.initialized < self.input.list.length()) {
            if (!self.cursor.isPresent()) {
                const row = list.atUnchecked(self.input, self.initialized);
                // A fold's intermediate accumulator is solely this driver's,
                // so the step may take over its buffer. A seed is borrowed
                // from the caller and a scan accumulator is a retained
                // output; both are only lent.
                self.cursor = .init(if (!self.scan and self.accumulator.borrow() == .owned)
                    try .initBinaryOwningLeft(
                        evaluator.releases,
                        evaluator.allocator,
                        self.operation,
                        .init(evaluator.releases, self.accumulator.borrowMut().takeOwned()),
                        row,
                    )
                else
                    try .initBinary(
                        evaluator.releases,
                        evaluator.allocator,
                        self.operation,
                        self.accumulator.borrow().value(),
                        row,
                    ));
            }
            const next = switch (try self.cursor.borrowMut().advance(evaluator, evaluator.workBudget())) {
                .pending => return .stepped,
                .complete => |result| result,
            };
            self.cursor.deinit(evaluator.releases, evaluator.allocator);
            if (self.scan) {
                self.results.?.borrowMut().appendOwned(next);
                self.accumulator.borrowMut().* = .{ .borrowed = next };
            } else {
                self.accumulator.borrowMut().replaceOwned(evaluator.releases, next);
            }
            self.initialized += 1;
            return .stepped;
        }
        if (!self.scan) {
            evaluator.discard(self.consumed);
            return .{ .output = self.accumulator.borrowMut().takeOwned() };
        }
        if (!self.materializing) {
            self.materializer = .init(.init(
                evaluator.allocator,
                self.results.?.borrow().values(),
            ));
            self.materializing = true;
        }
        return switch (try self.materializer.?.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |result| completed: {
                evaluator.discard(3);
                break :completed .{ .output = result };
            },
        };
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

/// `transferred` is observed both after final publication and mid-fold, while
/// the step's cursor owns the previous accumulator; `replaceOwned` then
/// installs the step's result without releasing anything.
const Accumulator = union(enum) {
    borrowed: Value,
    owned: Value,
    transferred,

    fn value(self: Accumulator) Value {
        return switch (self) {
            .borrowed, .owned => |item| item,
            .transferred => unreachable,
        };
    }

    fn replaceOwned(self: *Accumulator, releases: *heap.ReleaseDomain, next: Value) void {
        switch (self.*) {
            .borrowed, .transferred => {},
            .owned => |item| releases.releaseValue(item),
        }
        self.* = .{ .owned = next };
    }

    fn takeOwned(self: *Accumulator) Value {
        return switch (self.*) {
            .borrowed => unreachable,
            .owned => |item| taken: {
                self.* = .transferred;
                break :taken item;
            },
            .transferred => unreachable,
        };
    }

    pub fn deinit(self: Accumulator, releases: *heap.ReleaseDomain) void {
        switch (self) {
            .borrowed, .transferred => {},
            .owned => |item| releases.releaseValue(item),
        }
    }
};

pub const IdiomReduceStart = *const fn (*Fiber, Value, Value, bool, usize, usize) MachineError!void;

/// Starts the typed reduction. The caller has guarded with
/// `typedReduceCandidate`, so this asserts rather than reporting a second
/// classification.
pub fn idiomReduceStart(operation: BinaryOp) IdiomReduceStart {
    return switch (operation) {
        inline else => |selected| struct {
            fn run(
                evaluator: *Fiber,
                input: Value,
                initial: Value,
                scan: bool,
                start: usize,
                consumed: usize,
            ) MachineError!void {
                const element_class = leafNumber(input).?;
                const accumulator_class = scalarNumber(initial).?;
                const plan = NumericReducePlan.select(selected, accumulator_class, element_class, scan) orelse
                    return unexpectedReduceShape(evaluator);
                return plan.start(evaluator, input, initial, start, consumed);
            }
        }.run,
    };
}
