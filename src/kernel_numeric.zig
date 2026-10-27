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
const Machine = support.Machine;
const MachineError = support.MachineError;
pub const BinaryOp = support.BinaryOp;
pub const UnaryOp = support.UnaryOp;

const ScalarError = error{ Type, Overflow, Domain, ShiftCount };
const ScalarBinary = *const fn (Value, Value) ScalarError!Value;
const ScalarUnary = *const fn (Value) ScalarError!Value;
pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    inline for (comptime std.meta.tags(BinaryOp)) |operation| {
        if (comptime binaryDefinition(operation)) |word| try core.installBuiltin(word);
    }
    inline for (comptime std.meta.tags(UnaryOp)) |operation| {
        if (comptime unaryDefinition(operation)) |word| try core.installBuiltin(word);
    }
}

fn binaryDefinition(comptime operation: BinaryOp) ?env.BuiltinWord {
    return switch (operation) {
        .add => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Add numeric values or conforming numeric arrays pervasively." },
        .sub => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Subtract numeric or character values or conforming arrays pervasively." },
        .mul => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Multiply numeric values or conforming numeric arrays pervasively." },
        .div => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Divide numeric values or conforming numeric arrays pervasively, returning floats." },
        .int_div => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Compute checked integer division pervasively." },
        .atan2 => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "y x -- z", .doc = "Compute the two-argument arctangent of numeric values pervasively." },
        .pow => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Raise numbers to powers pervasively, returning floats." },
        .min => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Return the lesser of two comparable values pervasively." },
        .max => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Return the greater of two comparable values pervasively." },
        .eq => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- bool", .doc = "Compare conforming values for pervasive equality, producing boolean masks." },
        .lt => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- bool", .doc = "Compare conforming values pervasively for ascending order." },
        .gt => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- bool", .doc = "Compare conforming values pervasively for descending order." },
        .band => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Bitwise and over integer bit patterns pervasively." },
        .bor => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Bitwise or over integer bit patterns pervasively." },
        .bxor => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Bitwise exclusive or over integer bit patterns pervasively." },
        .bsl => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x count -- y", .doc = "Shift an integer pattern left, truncating bits off the top." },
        .bsr => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x count -- y", .doc = "Shift an integer pattern right, filling zeros from the top." },
        .wrap_add => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Add integers pervasively, wrapping modulo 2^64 instead of raising overflow." },
        .wrap_sub => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Subtract integers pervasively, wrapping modulo 2^64 instead of raising overflow." },
        .wrap_mul => .{ .name = operation.spelling(), .primitive = bindBinary(operation), .effect = "x y -- z", .doc = "Multiply integers pervasively, wrapping modulo 2^64 instead of raising overflow." },
        .mod, .ne, .le, .ge, .and_word, .or_word => null,
    };
}

fn bindBinary(comptime operation: BinaryOp) env.PrimitiveImpl {
    return support.headed(operation.spelling(), struct {
        fn run(evaluator: *Machine) MachineError!void {
            // Each operation already has its own specialized copy, so
            // inlining it removes only the trampoline.
            return @call(.always_inline, binaryPrimitive, .{ evaluator, operation });
        }
    }.run);
}

pub fn binaryPrimitiveFor(comptime operation: BinaryOp) env.PrimitiveImpl {
    return bindBinary(operation);
}

fn unaryDefinition(comptime operation: UnaryOp) ?env.BuiltinWord {
    return switch (operation) {
        .sqrt => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Return square roots of numeric values pervasively." },
        .floor => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- integer", .doc = "Round numeric values downward pervasively to integers." },
        .ceil => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- integer", .doc = "Round numeric values upward pervasively to integers." },
        .round => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- integer", .doc = "Round numeric values to nearest integers pervasively." },
        .exp => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Return natural exponentials of numeric values pervasively." },
        .log => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Return natural logarithms of numeric values pervasively." },
        .sin => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Return sines of numeric values pervasively." },
        .cos => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Return cosines of numeric values pervasively." },
        .not_word => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "bool -- bool", .doc = "Invert boolean 0 and 1 values pervasively." },
        .bnot => .{ .name = operation.spelling(), .primitive = bindUnary(operation), .effect = "x -- y", .doc = "Invert every bit of an integer pattern pervasively." },
        .neg, .abs => null,
    };
}

fn bindUnary(comptime operation: UnaryOp) env.PrimitiveImpl {
    return support.headed(operation.spelling(), struct {
        fn run(evaluator: *Machine) MachineError!void {
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

fn binaryPrimitive(evaluator: *Machine, comptime operation: BinaryOp) MachineError!void {
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
        evaluator.releaseDomain(),
        evaluator.allocator(),
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

fn unaryPrimitive(evaluator: *Machine, comptime operation: UnaryOp) MachineError!void {
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
        evaluator.releaseDomain(),
        evaluator.allocator(),
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

    pub fn advance(evaluator: *Machine, self: *PervadeDriver) MachineError!machine.WorkProgress {
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

    /// Typed frames charge the unit through `Context`. A list frame spends one
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
        evaluator: *Machine,
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

    fn start(self: *PervadeCursor, evaluator: *Machine, child: Child) MachineError!Started {
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

    fn startBinary(self: *PervadeCursor, evaluator: *Machine, node: BinaryNode) MachineError!Started {
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

    fn startUnary(self: *PervadeCursor, evaluator: *Machine, node: UnaryNode) MachineError!Started {
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
        evaluator: *Machine,
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
    fn startNumericRow(self: *PervadeCursor, evaluator: *Machine, node: BinaryNode) MachineError!?Started {
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
        return try self.runTyped(try data.nested(evaluator, .{ node.left, node.right }, null, .{ .reuse = false }, length));
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
        evaluator: *Machine,
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
    fn startDictChild(self: *PervadeCursor, evaluator: *Machine, frame: *DictFrame, child: Child, work: *poll.WorkBudget) MachineError!FrameStep {
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
    evaluator: *Machine,
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

fn scalarFailure(evaluator: *Machine, fault: ScalarError, index: ?usize) MachineError {
    const diagnostic = scalarDiagnostic(fault);
    if (index) |logical_index|
        return evaluator.failAtIndex(diagnostic.kind, diagnostic.message, logical_index);
    return evaluator.fail(diagnostic.kind, diagnostic.message);
}

fn scalarBinary(comptime operation: BinaryOp, left: Value, right: Value) ScalarError!Value {
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

fn scalarUnary(comptime operation: UnaryOp, operand: Value) ScalarError!Value {
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
    if (left == .char and right == .int) return offsetChar(left.char, right.int);
    if (left == .int and right == .char) return offsetChar(right.char, left.int);
    if (left == .char or right == .char) return error.Type;
    return numericBinary(left, right, .add);
}

/// `inline` for the same reason as `add`.
inline fn sub(left: Value, right: Value) ScalarError!Value {
    if (left == .char and right == .char) {
        return .{ .int = @as(i64, left.char) - @as(i64, right.char) };
    }
    if (left == .char and right == .int) {
        const offset = std.math.sub(i64, 0, right.int) catch return error.Overflow;
        return offsetChar(left.char, offset);
    }
    if (left == .char or right == .char) return error.Type;
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

fn offsetChar(codepoint: u32, offset: i64) ScalarError!Value {
    const adjusted = std.math.add(i64, @intCast(codepoint), offset) catch return error.Domain;
    if (adjusted < 0) return error.Domain;
    const result = value.unicodeScalar(@intCast(adjusted)) orelse return error.Domain;
    return .{ .char = result };
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

/// The numeric element classes a typed loop carries. `byte` is an invisible
/// storage class for ordinary integers; operations widen whenever their result
/// is not provably within the byte range. Chars and symbols are deliberately
/// absent: a char result chooses its width from the codepoints it produces,
/// which is a profiling decision, and symbols are not arithmetic.
const Number = enum {
    byte,
    integer,
    real,

    fn Element(comptime self: Number) type {
        return switch (self) {
            .byte => u8,
            .integer => i64,
            .real => f64,
        };
    }

    fn kind(comptime self: Number) value.HeapKind {
        return switch (self) {
            .byte => .leaf_u8,
            .integer => .leaf_i64,
            .real => .leaf_f64,
        };
    }

    fn boxed(comptime self: Number, element: self.Element()) Value {
        return switch (self) {
            .byte, .integer => .{ .int = element },
            .real => .{ .float = element },
        };
    }

    fn unboxed(comptime self: Number, item: Value) self.Element() {
        return switch (self) {
            .byte => @intCast(item.int),
            .integer => item.int,
            .real => item.float,
        };
    }
};

const number_classes = [_]Number{ .byte, .integer, .real };

fn scalarNumber(item: Value) ?Number {
    return switch (item) {
        .int => .integer,
        .float => .real,
        .char, .symbol, .list, .dict, .task, .port, .address => null,
    };
}

fn leafNumber(item: Value) ?Number {
    if (item != .list) return null;
    return switch (item.list.kind()) {
        .leaf_u8 => .byte,
        .leaf_i64 => .integer,
        .leaf_f64 => .real,
        else => null,
    };
}

/// Character leaves keep their storage width in the dispatch class. The
/// scalar meaning remains one Unicode codepoint; the width exists solely so a
/// loop can select one pinned monomorphic slice before it starts.
const Character = enum {
    char1,
    char2,
    char4,

    fn Element(comptime self: Character) type {
        return switch (self) {
            .char1 => u8,
            .char2 => u16,
            .char4 => u32,
        };
    }

    fn kind(comptime self: Character) value.HeapKind {
        return switch (self) {
            .char1 => .leaf_char1,
            .char2 => .leaf_char2,
            .char4 => .leaf_char4,
        };
    }

    fn boxed(comptime self: Character, element: self.Element()) Value {
        return .{ .char = @intCast(element) };
    }
};

fn leafCharacter(item: Value) ?Character {
    if (item != .list) return null;
    return switch (item.list.kind()) {
        .leaf_char1 => .char1,
        .leaf_char2 => .char2,
        .leaf_char4 => .char4,
        else => null,
    };
}

const FlatScalarClass = enum {
    byte,
    integer,
    char1,
    char2,
    char4,

    fn Element(comptime self: FlatScalarClass) type {
        return switch (self) {
            .byte => u8,
            .integer => i64,
            .char1 => u8,
            .char2 => u16,
            .char4 => u32,
        };
    }

    fn boxed(comptime self: FlatScalarClass, element: self.Element()) Value {
        return switch (self) {
            .byte, .integer => .{ .int = element },
            .char1, .char2, .char4 => .{ .char = @intCast(element) },
        };
    }

    fn isCharacter(self: FlatScalarClass) bool {
        return self != .byte and self != .integer;
    }

    fn kind(comptime self: FlatScalarClass) value.HeapKind {
        return switch (self) {
            .byte => .leaf_u8,
            .integer => .leaf_i64,
            .char1 => .leaf_char1,
            .char2 => .leaf_char2,
            .char4 => .leaf_char4,
        };
    }

    /// A scalar operand as this class's element: an int for the numeric
    /// classes, a codepoint for the character ones.
    fn unboxed(comptime self: FlatScalarClass, item: Value) self.Element() {
        return switch (self) {
            .byte => @intCast(item.int),
            .integer => item.int,
            .char1, .char2, .char4 => @intCast(item.char),
        };
    }
};

fn characterFlatClass(character: Character) FlatScalarClass {
    return switch (character) {
        .char1 => .char1,
        .char2 => .char2,
        .char4 => .char4,
    };
}

/// The result class of one binary operation on two numeric classes, or null when
/// the result is not of one width.
///
/// `min` and `max` return one of their operands rather than a computed value, so
/// a mixed pair yields ints and floats element by element — genuinely
/// heterogeneous, and the one numeric shape that stays on the profiling route.
fn binaryResult(comptime operation: BinaryOp, comptime left: Number, comptime right: Number) ?Number {
    const real = left == .real or right == .real;
    return switch (operation) {
        .add, .sub, .mul => if (real) .real else .integer,
        .div, .pow, .atan2 => .real,
        .int_div, .mod, .band, .bor, .bxor, .bsl, .bsr, .and_word, .or_word => .integer,
        .wrap_add, .wrap_sub, .wrap_mul => .integer,
        .eq, .ne, .lt, .gt, .le, .ge => .integer,
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
        .neg => if (operand == .byte) .integer else operand,
        .abs => operand,
        .sqrt, .exp, .log, .sin, .cos => .real,
        .floor, .ceil, .round => .integer,
        .not_word, .bnot => .integer,
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
    if (left == .integer and right == .integer) return switch (operation) {
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
    if (left == .byte and right == .byte) return switch (operation) {
        .eq, .ne, .lt, .gt, .le, .ge, .min, .max, .band, .bor, .bxor => .scalar_infallible,
        .wrap_add, .wrap_sub, .wrap_mul => .scalar_infallible,
        .add, .sub, .mul, .div, .int_div, .mod, .pow, .atan2, .and_word, .or_word, .bsl, .bsr => .scalar_checked,
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

/// The typed result buffer: freshly allocated, or a solely-owned input buffer
/// taken over in place under the mask-before-store protocol.
const TypedOutput = union(enum) {
    fresh_bytes: heap.LeafWriter(.leaf_u8),
    fresh_ints: heap.LeafWriter(.leaf_i64),
    fresh_reals: heap.LeafWriter(.leaf_f64),
    reuse_bytes: heap.UniqueLeafAdoption(.leaf_u8),
    reuse_ints: heap.UniqueLeafAdoption(.leaf_i64),
    reuse_reals: heap.UniqueLeafAdoption(.leaf_f64),

    fn store(self: *TypedOutput, comptime class: Number, offset: usize, block: []const class.Element()) void {
        switch (class) {
            .byte => switch (self.*) {
                .fresh_bytes => |*writer| writer.writeRange(offset, block),
                .reuse_bytes => |*adoption| adoption.writeRange(offset, block),
                .fresh_ints, .fresh_reals, .reuse_ints, .reuse_reals => unreachable,
            },
            .integer => switch (self.*) {
                .fresh_ints => |*writer| writer.writeRange(offset, block),
                .reuse_ints => |*adoption| adoption.writeRange(offset, block),
                .fresh_bytes, .fresh_reals, .reuse_bytes, .reuse_reals => unreachable,
            },
            .real => switch (self.*) {
                .fresh_reals => |*writer| writer.writeRange(offset, block),
                .reuse_reals => |*adoption| adoption.writeRange(offset, block),
                .fresh_bytes, .fresh_ints, .reuse_bytes, .reuse_ints => unreachable,
            },
        }
    }

    /// The output's own range, which a vector loop writes directly. Nothing
    /// reads a fresh buffer before it is published, so a block may land there
    /// before its faults are known. A reused input's positions are its
    /// operands until stored, so its loop stores a vector only after reading
    /// it and, when checked, knowing it clean.
    fn vectorRange(self: *TypedOutput, comptime class: Number, piece: flat.Chunk) []class.Element() {
        return switch (class) {
            .byte => switch (self.*) {
                .fresh_bytes => |*writer| writer.unpublishedRange(piece.start, piece.len()),
                .reuse_bytes => |*adoption| adoption.inPlaceRange(piece.start, piece.len()),
                .fresh_ints, .fresh_reals, .reuse_ints, .reuse_reals => unreachable,
            },
            .integer => switch (self.*) {
                .fresh_ints => |*writer| writer.unpublishedRange(piece.start, piece.len()),
                .reuse_ints => |*adoption| adoption.inPlaceRange(piece.start, piece.len()),
                .fresh_bytes, .fresh_reals, .reuse_bytes, .reuse_reals => unreachable,
            },
            .real => switch (self.*) {
                .fresh_reals => |*writer| writer.unpublishedRange(piece.start, piece.len()),
                .reuse_reals => |*adoption| adoption.inPlaceRange(piece.start, piece.len()),
                .fresh_bytes, .fresh_ints, .reuse_bytes, .reuse_ints => unreachable,
            },
        };
    }

    fn finish(self: *TypedOutput) Value {
        return switch (self.*) {
            inline else => |*capability| capability.finish(),
        };
    }

    fn retire(self: *TypedOutput, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .fresh_bytes => |*writer| writer.retirePartial(releases),
            .fresh_ints => |*writer| writer.retirePartial(releases),
            .fresh_reals => |*writer| writer.retirePartial(releases),
            // An abandoned reuse may hold stored results; the caller's
            // reference to it is the one `root` holds, and only releases it.
            .reuse_bytes => |*adoption| adoption.abandon(),
            .reuse_ints => |*adoption| adoption.abandon(),
            .reuse_reals => |*adoption| adoption.abandon(),
        }
    }
};

/// Whether a fault carries a logical index.
///
/// Direct pervasion over a list reports the failing element's index, exactly as
/// the boxed route does. A recognized `each`/`zip-with` idiom does not: the
/// generic combinator it stands in for applies the quotation to one element at a
/// time and its fault has no list position, so the fused path must not invent
/// one.
const FaultReport = struct { index: bool = true };

/// What a numeric or character kernel needs besides its operands: how a
/// fault is reported, and whether its first operand is the operation's own
/// and so may be taken over as the output. An element of a structure being
/// descended is held by that structure, however few references it has.
const NumericParams = struct {
    report: FaultReport = .{},
    reuse: bool = true,
};

fn failTypedScalar(
    context: support.Context,
    report: FaultReport,
    fault: ScalarError,
    index: usize,
) MachineError {
    const diagnostic = scalarDiagnostic(fault);
    if (report.index) return context.failAt(diagnostic.kind, diagnostic.message, index);
    return context.fail(diagnostic.kind, diagnostic.message);
}

/// A character binary operation as a `support.Kernel` spec. A fixed result is
/// one int per position; a dynamic one is a codepoint whose storage width a
/// profiling pass decides before the fill.
fn charKernel(
    comptime operation: BinaryOp,
    comptime left_class: FlatScalarClass,
    comptime right_class: FlatScalarClass,
    comptime shape: Shape,
    comptime dynamic: bool,
) type {
    const Out = if (dynamic) u32 else i64;
    const Loops = flat.CheckedFamily(left_class.Element(), right_class.Element(), Out);
    const body = struct {
        fn run(a: left_class.Element(), b: right_class.Element()) error{Fault}!Out {
            const result = scalarBinary(operation, left_class.boxed(a), right_class.boxed(b)) catch return error.Fault;
            return if (dynamic) result.char else result.int;
        }
    }.run;
    return struct {
        const Left = if (shape == .scalar_leaf) left_class.Element() else []const left_class.Element();
        const Right = if (shape == .leaf_scalar) right_class.Element() else []const right_class.Element();

        /// One staged piece; nothing is stored when it faults.
        fn runPiece(left: Left, right: Right, piece: flat.Chunk, block: *Loops.Staging) flat.CheckedStatus {
            return switch (shape) {
                .leaf_leaf => Loops.binary(body, left, right, piece, block),
                .leaf_scalar => Loops.binaryScalarRight(body, left, right, piece, block),
                .scalar_leaf => Loops.binaryScalarLeft(body, left, right, piece, block),
                .leaf_only => unreachable,
            };
        }

        fn valueLeft(item: Value) Left {
            return if (shape == .scalar_leaf) left_class.unboxed(item) else heap.leafElements(left_class.kind(), item.list);
        }

        fn valueRight(item: Value) Right {
            return if (shape == .leaf_scalar) right_class.unboxed(item) else heap.leafElements(right_class.kind(), item.list);
        }

        noinline fn replay(context: support.Context, report: FaultReport, left: Left, right: Right, piece: flat.Chunk) MachineError {
            for (piece.start..piece.end) |index| {
                const a = if (shape == .scalar_leaf) left else left[index];
                const b = if (shape == .leaf_scalar) right else right[index];
                _ = scalarBinary(operation, left_class.boxed(a), right_class.boxed(b)) catch |fault|
                    return failTypedScalar(context, report, fault, index);
            }
            unreachable;
        }

        /// The fixed operation as a `support.Kernel`.
        const FixedSpec = struct {
            pub const arity = 2;
            pub const Params = NumericParams;
            pub const Output = heap.LeafWriter(.leaf_i64);

            pub fn prepare(evaluator: *Machine, _: [2]Value, _: NumericParams, length: usize) error{OutOfMemory}!Output {
                return .init(evaluator.allocator(), length);
            }

            pub fn chunk(params: NumericParams, operands: [2]Value, output: *Output, range: flat.Chunk, context: support.Context) MachineError!void {
                const left = valueLeft(operands[0]);
                const right = valueRight(operands[1]);
                var block = Loops.Staging.init();
                var offset: usize = 0;
                while (offset != range.len()) {
                    const piece = flat.blockRange(range, offset);
                    if (runPiece(left, right, piece, &block) == .faulted) return replay(context, params.report, left, right, piece);
                    output.writeRange(piece.start, block.written());
                    offset += piece.len();
                }
            }

            pub fn finish(output: *Output) Value {
                return output.finish();
            }
        };

        /// The dynamic operation as a `support.Kernel` of twice the length:
        /// positions below `length / 2` profile the widest codepoint, and the
        /// rest fill a writer of that width, made when the fill begins. The
        /// profile charges and faults exactly as the fill would.
        const DynamicSpec = struct {
            pub const arity = 2;
            pub const Params = NumericParams;
            pub const Output = struct {
                count: usize,
                max_codepoint: u32 = 0,
                writer: ?flat.CodepointWriter = null,

                pub fn retire(self: *Output, releases: *heap.ReleaseDomain) void {
                    if (self.writer) |*writer| writer.retire(releases);
                    self.writer = null;
                }
            };

            pub fn prepare(_: *Machine, _: [2]Value, _: NumericParams, length: usize) error{OutOfMemory}!Output {
                return .{ .count = length / 2 };
            }

            pub fn chunk(params: NumericParams, operands: [2]Value, output: *Output, range: flat.Chunk, context: support.Context) MachineError!void {
                const left = valueLeft(operands[0]);
                const right = valueRight(operands[1]);
                if (range.start < output.count)
                    try pass(params.report, left, right, output, .{ .start = range.start, .end = @min(range.end, output.count) }, context, true);
                if (range.end > output.count) {
                    if (output.writer == null)
                        output.writer = try flat.CodepointWriter.init(context.allocator(), output.count, output.max_codepoint);
                    const start = @max(range.start, output.count) - output.count;
                    try pass(params.report, left, right, output, .{ .start = start, .end = range.end - output.count }, context, false);
                }
            }

            fn pass(report: FaultReport, left: Left, right: Right, output: *Output, range: flat.Chunk, context: support.Context, profile: bool) MachineError!void {
                var block = Loops.Staging.init();
                var offset: usize = 0;
                while (offset != range.len()) {
                    const piece = flat.blockRange(range, offset);
                    if (runPiece(left, right, piece, &block) == .faulted) return replay(context, report, left, right, piece);
                    if (profile) {
                        for (block.written()) |codepoint| output.max_codepoint = @max(output.max_codepoint, codepoint);
                    } else output.writer.?.writeCodepoints(piece.start, block.written());
                    offset += piece.len();
                }
            }

            pub fn finish(output: *Output) Value {
                return output.writer.?.finish();
            }
        };

        const Spec = if (dynamic) DynamicSpec else FixedSpec;
        const run = support.Kernel(Spec).run;
        const nested = support.Kernel(Spec).nested;
    };
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
        output: *TypedOutput,

        fn vector(self: @This(), piece: flat.Chunk) []class.Element() {
            return self.output.vectorRange(class, piece);
        }

        fn store(self: @This(), offset: usize, items: []const class.Element()) void {
            self.output.store(class, offset, items);
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

/// A binary typed operation: one range loop (runPieces) and its replay, as
/// a `support.Kernel` spec run at top level (run) or inside pervasion
/// (nested).
fn binaryKernel(
    comptime operation: BinaryOp,
    comptime left_class: Number,
    comptime right_class: Number,
    comptime shape: Shape,
) type {
    const out = comptime binaryResult(operation, left_class, right_class).?;
    const policy = comptime binaryLoopPolicy(operation, left_class, right_class);
    const ScalarInfallible = flat.InfallibleFamily(left_class.Element(), right_class.Element(), out.Element());
    const ScalarChecked = flat.CheckedFamily(left_class.Element(), right_class.Element(), out.Element());
    const lanes = std.simd.suggestVectorLength(left_class.Element()) orelse 1;
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
    const vector_body = struct {
        fn run(
            a: @Vector(lanes, left_class.Element()),
            b: @Vector(lanes, right_class.Element()),
        ) @Vector(lanes, out.Element()) {
            const ones: @Vector(lanes, i64) = @splat(1);
            const zeroes: @Vector(lanes, i64) = @splat(0);
            return switch (operation) {
                .eq => @select(i64, a == b, ones, zeroes),
                .ne => @select(i64, a != b, ones, zeroes),
                .lt => @select(i64, a < b, ones, zeroes),
                .gt => @select(i64, a > b, ones, zeroes),
                .le => @select(i64, a <= b, ones, zeroes),
                .ge => @select(i64, a >= b, ones, zeroes),
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
            if (left_class == .integer and right_class == .integer and
                (operation == .and_word or operation == .or_word))
            {
                // Both operands must be 0 or 1, exactly `boolean`'s test.
                const ones: @Vector(lanes, i64) = @splat(1);
                const zeros: @Vector(lanes, i64) = @splat(0);
                const values = if (operation == .and_word) a & b else a | b;
                return .{ .values = values, .faults = Vectors.mask((a | b) & ~ones != zeros) };
            }
            if (left_class == .integer and right_class == .integer) {
                const result = switch (operation) {
                    .add => @addWithOverflow(a, b),
                    .sub => @subWithOverflow(a, b),
                    .mul => @mulWithOverflow(a, b),
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
        fn runPieces(left: Left, right: Right, output: *TypedOutput, placement: flat.Placement, range: flat.Chunk) ?flat.Chunk {
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

        /// The operation as a `support.Kernel`: its output is the left
        /// operand's buffer when that is solely owned, or a fresh one.
        const Spec = struct {
            pub const arity = 2;
            pub const Params = NumericParams;
            pub const Output = KernelOutput;

            pub fn prepare(evaluator: *Machine, operands: [2]Value, params: NumericParams, length: usize) error{OutOfMemory}!Output {
                if (shape != .scalar_leaf and params.reuse) {
                    if (heap.UniqueLeafAdoption(out.kind()).claim(operands[0].list, length)) |claimed| return .{
                        .typed = switch (out) {
                            .byte => .{ .reuse_bytes = claimed },
                            .integer => .{ .reuse_ints = claimed },
                            .real => .{ .reuse_reals = claimed },
                        },
                        .adopted = true,
                    };
                }
                return .{ .typed = try freshOutput(out, evaluator, length), .adopted = false };
            }

            pub fn chunk(params: NumericParams, operands: [2]Value, output: *Output, range: flat.Chunk, context: support.Context) MachineError!void {
                const left: Left = if (shape == .scalar_leaf)
                    left_class.unboxed(operands[0])
                else
                    heap.leafElements(left_class.kind(), operands[0].list);
                const right: Right = if (shape == .leaf_scalar)
                    right_class.unboxed(operands[1])
                else
                    heap.leafElements(right_class.kind(), operands[1].list);
                const placement: flat.Placement = if (output.adopted) .over_operands else .fresh;
                if (runPieces(left, right, &output.typed, placement, range)) |faulted|
                    return replayDirect(context, params.report, left, right, faulted);
            }

            pub const finish = KernelOutput.finish;
            pub const adopted = KernelOutput.adoptedOperand;
        };

        const run = support.Kernel(Spec).run;
        const nested = support.Kernel(Spec).nested;

        noinline fn replayDirect(context: support.Context, report: FaultReport, left: Left, right: Right, piece: flat.Chunk) MachineError {
            for (piece.start..piece.end) |index| {
                const a = if (shape == .scalar_leaf) left else left[index];
                const b = if (shape == .leaf_scalar) right else right[index];
                _ = scalarBinary(operation, left_class.boxed(a), right_class.boxed(b)) catch |fault|
                    return failTypedScalar(context, report, fault, index);
            }
            unreachable;
        }
    };
}

/// A unary typed operation; see `binaryKernel`.
fn unaryKernel(comptime operation: UnaryOp, comptime operand_class: Number) type {
    const out = comptime unaryResult(operation, operand_class);
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
                        return .{ .values = @intCast(a ^ ones), .faults = Vectors.mask(a & ~ones != zeros) };
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
        fn runPieces(operand: []const operand_class.Element(), output: *TypedOutput, placement: flat.Placement, range: flat.Chunk) ?flat.Chunk {
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

        /// The operation as a `support.Kernel`; see `binaryKernel`.
        const Spec = struct {
            pub const arity = 1;
            pub const Params = NumericParams;
            pub const Output = KernelOutput;

            pub fn prepare(evaluator: *Machine, operands: [1]Value, params: NumericParams, length: usize) error{OutOfMemory}!Output {
                if (params.reuse) if (heap.UniqueLeafAdoption(out.kind()).claim(operands[0].list, length)) |claimed| return .{
                    .typed = switch (out) {
                        .byte => .{ .reuse_bytes = claimed },
                        .integer => .{ .reuse_ints = claimed },
                        .real => .{ .reuse_reals = claimed },
                    },
                    .adopted = true,
                };
                return .{ .typed = try freshOutput(out, evaluator, length), .adopted = false };
            }

            pub fn chunk(params: NumericParams, operands: [1]Value, output: *Output, range: flat.Chunk, context: support.Context) MachineError!void {
                const elements = heap.leafElements(operand_class.kind(), operands[0].list);
                const placement: flat.Placement = if (output.adopted) .over_operands else .fresh;
                if (runPieces(elements, &output.typed, placement, range)) |faulted|
                    return replayDirect(context, params.report, elements, faulted);
            }

            pub const finish = KernelOutput.finish;
            pub const adopted = KernelOutput.adoptedOperand;
        };

        const run = support.Kernel(Spec).run;
        const nested = support.Kernel(Spec).nested;

        noinline fn replayDirect(context: support.Context, report: FaultReport, elements: []const operand_class.Element(), piece: flat.Chunk) MachineError {
            for (piece.start..piece.end) |index| {
                _ = scalarUnary(operation, operand_class.boxed(elements[index])) catch |fault|
                    return failTypedScalar(context, report, fault, index);
            }
            unreachable;
        }
    };
}

/// A numeric kernel's result: a typed output, which may be its first
/// operand's buffer taken over in place.
const KernelOutput = struct {
    typed: TypedOutput,
    adopted: bool,

    pub fn retire(self: *KernelOutput, releases: *heap.ReleaseDomain) void {
        self.typed.retire(releases);
    }

    fn finish(self: *KernelOutput) Value {
        return self.typed.finish();
    }

    fn adoptedOperand(self: *const KernelOutput) ?usize {
        return if (self.adopted) 0 else null;
    }
};

fn freshOutput(comptime out: Number, evaluator: *Machine, length: usize) error{OutOfMemory}!TypedOutput {
    return switch (out) {
        .byte => .{ .fresh_bytes = try .init(evaluator.allocator(), length) },
        .integer => .{ .fresh_ints = try .init(evaluator.allocator(), length) },
        .real => .{ .fresh_reals = try .init(evaluator.allocator(), length) },
    };
}

/// Runs a plan's operation through `support.Kernel`, inline or as a driver.
const RunBinary = *const fn (*Machine, [2]*heap.OwnedValue, NumericParams, usize) MachineError!void;
/// Runs a plan's operation for a leaf inside pervasion; see `support.Kernel`.
const NestedBinary = *const fn (*Machine, [2]Value, ?*heap.OwnedValue, NumericParams, usize) MachineError!support.NestedOutcome;

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
    };

    fn select(operation: BinaryOp, left: Number, right: Number, shape: Shape) ?*const NumericBinaryPlan {
        return switch (operation) {
            inline else => |selected| selectFor(selected, left, right, shape),
        };
    }

    /// One indexed load per call. The nested comparison chain this replaces
    /// was a fixed cost of every nested row.
    fn selectFor(comptime operation: BinaryOp, left: Number, right: Number, shape: Shape) ?*const NumericBinaryPlan {
        // There is no byte scalar, so neither broadcast shape pairs one with a leaf.
        std.debug.assert(!(shape == .scalar_leaf and left == .byte) and !(shape == .leaf_scalar and right == .byte));
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
                    if (candidate_shape == .scalar_leaf and candidate_left == .byte) continue;
                    if (candidate_shape == .leaf_scalar and candidate_right == .byte) continue;
                    const out = binaryResult(operation, candidate_left, candidate_right) orelse continue;
                    const Kernel = binaryKernel(operation, candidate_left, candidate_right, candidate_shape);
                    const data = Data{
                        .left = candidate_left,
                        .right = candidate_right,
                        .shape = candidate_shape,
                        .out = out,
                        .run = Kernel.run,
                        .nested = Kernel.nested,
                    };
                    table[@backingInt(candidate_left)][@backingInt(candidate_right)][@backingInt(candidate_shape)] =
                        @ptrCast(&data);
                }
            }
        }
        return table;
    }
};

fn leafFlatScalarClass(item: Value) ?FlatScalarClass {
    if (leafNumber(item)) |number| return switch (number) {
        .byte => .byte,
        .integer => .integer,
        .real => null,
    };
    if (leafCharacter(item)) |character| return characterFlatClass(character);
    return null;
}

fn scalarFlatScalarClass(item: Value) ?FlatScalarClass {
    return switch (item) {
        .int => .integer,
        // A scalar has no storage width. u32 is the honest loop class because
        // it can carry every scalar without a narrowing precondition.
        .char => .char4,
        else => null,
    };
}

/// The result variant is selected before generating a loop. In particular, a
/// numeric pair must never instantiate a character loop merely because the
/// runtime dispatcher would reject that pair later.
const CharacterBinaryPlan = opaque {
    const Data = struct {
        left: FlatScalarClass,
        right: FlatScalarClass,
        shape: Shape,
        /// A dynamic kernel profiles before it fills, so its work is twice
        /// its length.
        dynamic: bool,
        run: RunBinary,
        nested: NestedBinary,
    };

    fn select(operation: BinaryOp, left: FlatScalarClass, right: FlatScalarClass, shape: Shape) ?*const CharacterBinaryPlan {
        return switch (operation) {
            inline else => |selected| selectFor(selected, left, right, shape),
        };
    }

    fn selectFor(comptime operation: BinaryOp, left: FlatScalarClass, right: FlatScalarClass, shape: Shape) ?*const CharacterBinaryPlan {
        const classes = [_]FlatScalarClass{ .byte, .integer, .char1, .char2, .char4 };
        inline for (classes) |candidate_left| {
            inline for (classes) |candidate_right| {
                const both_char = comptime candidate_left.isCharacter() and candidate_right.isCharacter();
                const fixed = comptime both_char and switch (operation) {
                    .sub, .eq, .ne, .lt, .gt, .le, .ge => true,
                    else => false,
                };
                const dynamic = comptime switch (operation) {
                    .add => candidate_left.isCharacter() != candidate_right.isCharacter(),
                    .sub => candidate_left.isCharacter() and candidate_right == .integer,
                    .min, .max => both_char,
                    else => false,
                };
                if (comptime !fixed and !dynamic) continue;
                inline for (binary_shapes) |candidate_shape| {
                    // Scalars have no narrow storage class.
                    if (comptime candidate_shape == .scalar_leaf and candidate_left != .integer and candidate_left != .char4) continue;
                    if (comptime candidate_shape == .leaf_scalar and candidate_right != .integer and candidate_right != .char4) continue;
                    if (candidate_left == left and candidate_right == right and candidate_shape == shape) {
                        const Kernel = comptime charKernel(operation, candidate_left, candidate_right, candidate_shape, !fixed);
                        const data = comptime Data{
                            .left = candidate_left,
                            .right = candidate_right,
                            .shape = candidate_shape,
                            .dynamic = !fixed,
                            .run = Kernel.run,
                            .nested = Kernel.nested,
                        };
                        return @ptrCast(&data);
                    }
                }
            }
        }
        return null;
    }
};

fn startNestedCharBinary(
    evaluator: *Machine,
    operation: BinaryOp,
    left_item: Value,
    right_item: Value,
    report: FaultReport,
) MachineError!?support.NestedOutcome {
    const left_leaf = leafFlatScalarClass(left_item);
    const right_leaf = leafFlatScalarClass(right_item);
    const left_scalar = scalarFlatScalarClass(left_item);
    const right_scalar = scalarFlatScalarClass(right_item);
    const shape: Shape = if (left_leaf != null and right_leaf != null)
        .leaf_leaf
    else if (left_leaf != null and right_scalar != null)
        .leaf_scalar
    else if (left_scalar != null and right_leaf != null)
        .scalar_leaf
    else
        return null;
    const left_class = left_leaf orelse left_scalar.?;
    const right_class = right_leaf orelse right_scalar.?;
    if (!left_class.isCharacter() and !right_class.isCharacter()) return null;
    const length = try conformingLength(evaluator, shape, left_item, right_item);
    if (length == 0) return null;
    const plan = CharacterBinaryPlan.select(operation, left_class, right_class, shape) orelse return null;
    const data: *const CharacterBinaryPlan.Data = @ptrCast(@alignCast(plan));
    return try data.nested(evaluator, .{ left_item, right_item }, null, .{ .report = report, .reuse = false }, if (data.dynamic) 2 * length else length);
}

fn firstFlatElement(item: Value) ?Value {
    if (item != .list or item.list.length() == 0) return null;
    return switch (item.list.kind()) {
        .leaf_u8 => .{ .int = heap.u8s(item.list)[0] },
        .leaf_i64 => .{ .int = heap.i64s(item.list)[0] },
        .leaf_f64 => .{ .float = heap.f64s(item.list)[0] },
        .leaf_char1 => .{ .char = heap.chars8(item.list)[0] },
        .leaf_char2 => .{ .char = heap.chars16(item.list)[0] },
        .leaf_char4 => .{ .char = @intCast(heap.chars32(item.list)[0]) },
        .leaf_symbol => .{ .symbol = .{ .name = heap.symbols(item.list)[0] } },
        .generic_spine, .dict, .task, .port, .address, .reserved_mask => null,
    };
}

/// A nonempty flat leaf whose first scalar faults needs no output allocation
/// and no traversal. This closes the typed boundary for character/symbol and
/// nonnumeric combinations without manufacturing a boxed fallback loop.
fn rejectUnsupportedFlatBinary(
    evaluator: *Machine,
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
    evaluator: *Machine,
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
    evaluator: *Machine,
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
    return try data.nested(evaluator, .{ left_item, right_item }, root, .{ .report = report, .reuse = root != null }, length);
}

/// A typed leaf inside pervasion. `root`, when present, owns `left` and is
/// the operation's own operand, so its buffer may become the output; every
/// other leaf is only borrowed from the structure being descended.
fn startNestedBinary(
    evaluator: *Machine,
    operation: BinaryOp,
    left: Value,
    right: Value,
    root: ?*heap.OwnedValue,
    report: FaultReport,
) MachineError!?support.NestedOutcome {
    // The builders are disjoint: numeric needs both operands numeric, and
    // character needs one character operand. The common numeric row is tried
    // first so it does not pay the character classification.
    if (try startNestedNumericBinary(evaluator, operation, left, right, root, report)) |typed| return typed;
    if (try startNestedCharBinary(evaluator, operation, left, right, report)) |typed| return typed;
    _ = try rejectUnsupportedFlatBinary(evaluator, operation, left, right, report);
    return null;
}

const RunUnary = *const fn (*Machine, [1]*heap.OwnedValue, NumericParams, usize) MachineError!void;
const NestedUnary = *const fn (*Machine, [1]Value, ?*heap.OwnedValue, NumericParams, usize) MachineError!support.NestedOutcome;

/// A closed operation/class pair binds the loop and its output representation.
/// Top-level and nested operations share it.
const NumericUnaryPlan = opaque {
    const Data = struct { input: Number, out: Number, run: RunUnary, nested: NestedUnary };

    fn select(operation: UnaryOp, input: Number) *const NumericUnaryPlan {
        return switch (operation) {
            inline else => |selected| blk: {
                inline for (number_classes) |candidate| {
                    if (candidate == input) {
                        const Kernel = comptime unaryKernel(selected, candidate);
                        const data = comptime Data{
                            .input = candidate,
                            .out = unaryResult(selected, candidate),
                            .run = Kernel.run,
                            .nested = Kernel.nested,
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
    evaluator: *Machine,
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
    return try data.nested(evaluator, .{operand}, null, .{ .report = report, .reuse = false }, length);
}

/// A numeric operation runs through its plan's kernel, inline or as a
/// driver. It classifies exactly as the numeric builder does, so a pair it
/// declines reaches the builder unchanged.
fn startNumericBinary(
    evaluator: *Machine,
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
    try data.run(evaluator, .{ left, right }, .{ .report = report }, length);
    return true;
}

/// Dispatches one binary operation. Returns false when the operand shapes belong
/// to the generic route, having consumed nothing.
fn startTypedBinary(
    evaluator: *Machine,
    operation: BinaryOp,
    left: *heap.OwnedValue,
    right: *heap.OwnedValue,
    report: FaultReport,
) MachineError!bool {
    if (try startNumericBinary(evaluator, operation, left, right, report)) return true;
    // The numeric kernel classified exactly as the numeric builder does, so
    // what remains is the character kernels', classified as the character
    // builder does. An empty result's representation is the generic route's
    // to choose, and so is a pair no plan admits.
    if (try startCharacterBinary(evaluator, operation, left, right, report)) return true;
    _ = try rejectUnsupportedFlatBinary(evaluator, operation, left.borrow(), right.borrow(), report);
    return false;
}

fn startCharacterBinary(
    evaluator: *Machine,
    operation: BinaryOp,
    left: *heap.OwnedValue,
    right: *heap.OwnedValue,
    report: FaultReport,
) MachineError!bool {
    const left_item = left.borrow();
    const right_item = right.borrow();
    const left_leaf = leafFlatScalarClass(left_item);
    const right_leaf = leafFlatScalarClass(right_item);
    const shape: Shape = if (left_leaf != null and right_leaf != null)
        .leaf_leaf
    else if (left_leaf != null and scalarFlatScalarClass(right_item) != null)
        .leaf_scalar
    else if (right_leaf != null and scalarFlatScalarClass(left_item) != null)
        .scalar_leaf
    else
        return false;
    const left_class = left_leaf orelse scalarFlatScalarClass(left_item).?;
    const right_class = right_leaf orelse scalarFlatScalarClass(right_item).?;
    if (!left_class.isCharacter() and !right_class.isCharacter()) return false;
    const length = try conformingLength(evaluator, shape, left_item, right_item);
    if (length == 0) return false;
    const plan = CharacterBinaryPlan.select(operation, left_class, right_class, shape) orelse return false;
    const data: *const CharacterBinaryPlan.Data = @ptrCast(@alignCast(plan));
    try data.run(evaluator, .{ left, right }, .{ .report = report }, if (data.dynamic) 2 * length else length);
    return true;
}

fn startTypedUnary(
    evaluator: *Machine,
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
    try data.run(evaluator, .{operand}, .{ .report = report }, length);
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
    pub const Unary = *const fn (*Machine, *heap.OwnedValue) MachineError!void;
    pub const Binary = *const fn (*Machine, *heap.OwnedValue, *heap.OwnedValue) MachineError!void;
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
        /// The word is a prelude definition, so a fault traces through it as
        /// well as through the operation its body runs.
        defined: bool,
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
        for (self.instructions[0..self.len], 0..) |instruction, position| {
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
        return registers[self.result];
    }
};

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
pub fn startProgramEach(evaluator: *Machine, input: *heap.OwnedValue, phrase: *heap.OwnedValue, program: ScalarProgram) MachineError!void {
    const count: usize = @intCast(input.borrow().list.length());
    return support.Kernel(ProgramKernel(1)).run(evaluator, .{ input, phrase }, try ownProgram(evaluator, program), count);
}

/// A program is too large to travel by value in a driver; the kernel's output
/// owns this copy from `prepare` on.
fn ownProgram(evaluator: *Machine, program: ScalarProgram) error{OutOfMemory}!*ScalarProgram {
    const owned = try evaluator.allocator().create(ScalarProgram);
    owned.* = program;
    return owned;
}

pub fn startProgramZip(
    evaluator: *Machine,
    left: *heap.OwnedValue,
    right: *heap.OwnedValue,
    phrase: *heap.OwnedValue,
    program: ScalarProgram,
) MachineError!void {
    const count: usize = @intCast(if (left.borrow() == .list) left.borrow().list.length() else right.borrow().list.length());
    return support.Kernel(ProgramKernel(2)).run(evaluator, .{ left, right, phrase }, try ownProgram(evaluator, program), count);
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

fn blockBinaryResult(operation: BinaryOp, left: Number, right: Number) ?Number {
    @setEvalBranchQuota(100_000);
    return switch (operation) {
        inline else => |selected| switch (left) {
            inline .integer, .real => |left_class| switch (right) {
                inline .integer, .real => |right_class| comptime binaryResult(selected, left_class, right_class),
                .byte => unreachable,
            },
            .byte => unreachable,
        },
    };
}

fn blockUnaryResult(operation: UnaryOp, operand: Number) Number {
    return switch (operation) {
        inline else => |selected| switch (operand) {
            inline .integer, .real => |operand_class| comptime unaryResult(selected, operand_class),
            .byte => unreachable,
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
                        const Kernel = binaryKernel(selected, left_class, right_class, shape);
                        return switch (comptime result.?) {
                            .integer => Kernel.runBlock(left_items, right_items, ints),
                            .real => Kernel.runBlock(left_items, right_items, reals),
                            .byte => unreachable,
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
                const Kernel = unaryKernel(selected, operand_class);
                return switch (comptime unaryResult(selected, operand_class)) {
                    .integer => Kernel.runBlock(items, ints),
                    .real => Kernel.runBlock(items, reals),
                    .byte => unreachable,
                };
            },
            .int_scalar, .real_scalar => unreachable,
        },
    }
}

/// A program run a block at a time through the typed kernels. Every register
/// has one class for the whole run, decided from the inputs' representations
/// and each operation's result class; a program whose result class depends on
/// its values (mixed `min` or `max`) is not planned. A register is a scalar
/// when everything it is computed from is, and a run otherwise.
const BlockPlan = struct {
    allocator: std.mem.Allocator,
    /// Positions per block.
    block: usize,
    classes: [ScalarProgram.max_registers]Number,
    scalar: [ScalarProgram.max_registers]bool,
    /// Storage for each register's run: register `r` uses `[r * block ..]`.
    ints: []i64,
    reals: []f64,
    result: union(enum) { ints: []i64, reals: []f64 },
    /// Every int result so far lies from 0 to 255, so `each` would give bytes.
    bytes: bool = true,

    fn create(allocator: std.mem.Allocator, program: *const ScalarProgram, operands: []const Value, length: usize) error{OutOfMemory}!?*BlockPlan {
        // SAFETY: inputs, constants, and every instruction's destination
        // are set below, which is every register the program reads.
        var classes: [ScalarProgram.max_registers]Number = undefined;
        // SAFETY: as for `classes`.
        var scalar: [ScalarProgram.max_registers]bool = undefined;
        for (operands, 0..) |operand, input| {
            scalar[input] = operand != .list;
            classes[input] = blockNumber(operand);
        }
        for (program.constants[0..program.constant_count]) |constant| {
            scalar[constant.register] = true;
            classes[constant.register] = blockNumber(constant.value);
        }
        for (program.instructions[0..program.len]) |instruction| {
            const destination = instruction.destination;
            switch (instruction.operation) {
                .unary => |operation| {
                    scalar[destination] = scalar[instruction.left];
                    classes[destination] = blockUnaryResult(operation, classes[instruction.left]);
                },
                .binary => |operation| {
                    scalar[destination] = scalar[instruction.left] and scalar[instruction.right];
                    classes[destination] = blockBinaryResult(operation, classes[instruction.left], classes[instruction.right]) orelse return null;
                },
            }
        }
        const block = @min(length, flat.block_size);
        const registers: usize = program.registers;
        const plan = try allocator.create(BlockPlan);
        errdefer allocator.destroy(plan);
        const ints = try allocator.alloc(i64, registers * block);
        errdefer allocator.free(ints);
        const reals = try allocator.alloc(f64, registers * block);
        errdefer allocator.free(reals);
        plan.* = .{
            .allocator = allocator,
            .block = block,
            .classes = classes,
            .scalar = scalar,
            .ints = ints,
            .reals = reals,
            .result = switch (classes[program.result]) {
                .integer => .{ .ints = try allocator.alloc(i64, length) },
                .real => .{ .reals = try allocator.alloc(f64, length) },
                .byte => unreachable,
            },
        };
        return plan;
    }

    fn destroy(self: *BlockPlan) void {
        self.allocator.free(self.ints);
        self.allocator.free(self.reals);
        switch (self.result) {
            inline else => |items| self.allocator.free(items),
        }
        self.allocator.destroy(self);
    }

    fn runInts(self: *const BlockPlan, register: usize, length: usize) []i64 {
        return self.ints[register * self.block ..][0..length];
    }

    fn runReals(self: *const BlockPlan, register: usize, length: usize) []f64 {
        return self.reals[register * self.block ..][0..length];
    }

    /// Computes positions `start..start + length` into the result. False
    /// when an instruction faulted somewhere in the block; nothing is
    /// written to the result then.
    fn computeBlock(self: *BlockPlan, program: *const ScalarProgram, operands: []const Value, start: usize, length: usize) bool {
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
        switch (self.result) {
            .ints => |results| {
                const out = results[start..][0..length];
                switch (views[program.result]) {
                    .ints => |items| @memcpy(out, items),
                    .int_scalar => |integer| @memset(out, integer),
                    .reals, .real_scalar => unreachable,
                }
                if (self.bytes) for (out) |item| {
                    if (item < 0 or item > std.math.maxInt(u8)) {
                        self.bytes = false;
                        break;
                    }
                };
            },
            .reals => |results| {
                const out = results[start..][0..length];
                switch (views[program.result]) {
                    .reals => |items| @memcpy(out, items),
                    .real_scalar => |number| @memset(out, number),
                    .ints, .int_scalar => unreachable,
                }
            },
        }
        return true;
    }

    /// Stores one element's result, as computed element by element.
    fn store(self: *BlockPlan, index: usize, item: Value) void {
        switch (self.result) {
            .ints => |results| {
                results[index] = item.int;
                if (item.int < 0 or item.int > std.math.maxInt(u8)) self.bytes = false;
            },
            .reals => |results| results[index] = item.float,
        }
    }

    fn kind(self: *const BlockPlan) value.HeapKind {
        return switch (self.result) {
            .ints => if (self.bytes) .leaf_u8 else .leaf_i64,
            .reals => .leaf_f64,
        };
    }

    fn fill(self: *const BlockPlan, builder: *heap.AnyListBuilder, range: flat.Chunk) void {
        switch (builder.*) {
            .u8 => |*target| for (target.items()[range.start..range.end], self.result.ints[range.start..range.end]) |*slot, item| {
                slot.* = @intCast(item);
            },
            .i64 => |*target| @memcpy(target.items()[range.start..range.end], self.result.ints[range.start..range.end]),
            .f64 => |*target| @memcpy(target.items()[range.start..range.end], self.result.reals[range.start..range.end]),
            else => unreachable, // `kind` names one of these three.
        }
    }
};

/// Two phases: compute every element's result, then write the results in the
/// representation `each` would give them. A planned program computes a block
/// at a time through the typed kernels; a block that faults is replayed
/// element by element, which meets the same first fault. A program that cannot
/// be planned computes element by element throughout, as atoms. The last
/// operand is the quotation.
fn ProgramKernel(comptime inputs: usize) type {
    return struct {
        pub const arity = inputs + 1;
        /// Owned by the output from `prepare` on.
        pub const Params = *ScalarProgram;
        pub const Output = struct {
            allocator: std.mem.Allocator,
            program: *ScalarProgram,
            plan: ?*BlockPlan,
            /// The element-by-element results, when there is no plan.
            results: []Value,
            profile: list.ListProfile = .{},
            builder: ?heap.AnyListBuilder = null,

            pub fn retire(self: *Output, releases: *heap.ReleaseDomain) void {
                if (self.builder) |*builder| builder.retirePartial(releases);
                self.release();
            }

            fn release(self: *Output) void {
                if (self.plan) |plan| plan.destroy();
                self.allocator.free(self.results);
                self.allocator.destroy(self.program);
            }
        };

        pub fn prepare(evaluator: *Machine, operands: [arity]Value, program: *ScalarProgram, length: usize) error{OutOfMemory}!Output {
            const allocator = evaluator.allocator();
            errdefer allocator.destroy(program);
            const plan = try BlockPlan.create(allocator, program, operands[0..inputs], length);
            errdefer if (plan) |planned| planned.destroy();
            return .{
                .allocator = allocator,
                .program = program,
                .plan = plan,
                .results = try allocator.alloc(Value, if (plan == null) length else 0),
            };
        }

        pub fn chunk(program: *ScalarProgram, operands: [arity]Value, output: *Output, range: flat.Chunk, context: support.Context) MachineError!void {
            if (output.builder) |*builder| {
                if (output.plan) |plan| return plan.fill(builder, range);
                return builder.writeValues(range.start, output.results[range.start..range.end]);
            }
            if (output.plan) |plan| return runBlocks(plan, program, operands, range, context);
            // SAFETY: `load` fills the constants; inputs and results are
            // written before they are read.
            var registers: [ScalarProgram.max_registers]Value = undefined;
            program.load(&registers);
            var profile = output.profile;
            for (output.results[range.start..range.end], range.start..) |*slot, index| {
                inline for (0..inputs) |input| registers[input] = programElement(operands[input], index);
                var failed: u8 = 0;
                slot.* = program.run(&registers, &failed) catch |fault|
                    return failProgram(context.evaluator, operands[inputs], program.instructions[failed], fault);
                profile = profile.add(slot.*);
            }
            output.profile = profile;
        }

        fn runBlocks(plan: *BlockPlan, program: *ScalarProgram, operands: [arity]Value, range: flat.Chunk, context: support.Context) MachineError!void {
            var start = range.start;
            while (start != range.end) {
                const length = @min(plan.block, range.end - start);
                if (!plan.computeBlock(program, operands[0..inputs], start, length)) {
                    // SAFETY: as in the element-by-element loop.
                    var registers: [ScalarProgram.max_registers]Value = undefined;
                    program.load(&registers);
                    for (start..start + length) |index| {
                        inline for (0..inputs) |input| registers[input] = programElement(operands[input], index);
                        var failed: u8 = 0;
                        const item = program.run(&registers, &failed) catch |fault|
                            return failProgram(context.evaluator, operands[inputs], program.instructions[failed], fault);
                        plan.store(index, item);
                    }
                }
                start += length;
            }
        }

        pub fn next(_: support.Context, output: *Output) MachineError!?usize {
            if (output.builder != null) return null;
            const length = if (output.plan) |plan| switch (plan.result) {
                inline else => |items| items.len,
            } else output.results.len;
            const kind = if (output.plan) |plan| plan.kind() else output.profile.heapKind();
            output.builder = try heap.AnyListBuilder.init(output.allocator, kind, length, length);
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
    evaluator: *Machine,
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

        pub fn prepare(evaluator: *Machine, _: [2]Value, params: Params, length: usize) error{OutOfMemory}!Output {
            const allocator = evaluator.allocator();
            errdefer allocator.destroy(params.program);
            return .{
                .allocator = allocator,
                .program = params.program,
                .accumulator = params.initial,
                .results = try allocator.alloc(Value, if (scan) length else 0),
            };
        }

        pub fn chunk(params: Params, operands: [2]Value, output: *Output, range: flat.Chunk, context: support.Context) MachineError!void {
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
                    return failProgram(context.evaluator, operands[1], program.instructions[failed], fault);
                if (scan) {
                    output.results[position] = accumulator;
                    profile = profile.add(accumulator);
                }
            }
            output.profile = profile;
        }

        pub fn next(_: support.Context, output: *Output) MachineError!?usize {
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
/// its position in the quotation, with the shared scalar diagnostic.
fn failProgram(evaluator: *Machine, phrase: Value, instruction: ScalarProgram.Instruction, fault: ScalarError) MachineError {
    evaluator.setActiveWord(.plain(instruction.word));
    const failure = scalarFailure(evaluator, fault, null);
    evaluator.setFailureSite(phrase.list, instruction.index);
    if (instruction.defined) evaluator.setFailureTraceParent(.plain(instruction.word));
    return failure;
}

/// The caller guards with the matching candidate predicate, so the start
/// asserts: a guard and a dispatch that could disagree would be a second,
/// silent classification.
pub fn idiomUnaryStart(operation: UnaryOp) IdiomStart.Unary {
    return switch (operation) {
        inline else => |selected| struct {
            fn run(evaluator: *Machine, operand: *heap.OwnedValue) MachineError!void {
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
                evaluator: *Machine,
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
    // either has a typed character result or faults at its first element.
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
    scan: ?TypedOutput,
    base: usize,

    pub fn retire(self: *ReduceOutput, releases: *heap.ReleaseDomain) void {
        if (self.scan) |*output| output.retire(releases);
        self.scan = null;
    }
};

const RunReduce = *const fn (*Machine, [1]*heap.OwnedValue, ReduceParams, usize) MachineError!void;

fn reduceKernel(
    comptime operation: BinaryOp,
    comptime accumulator_class: Number,
    comptime element_class: Number,
    comptime scan: bool,
    /// The seed changes class, so the first remaining element takes one
    /// scalar step before the loop.
    comptime seeded: bool,
) type {
    const Staging = flat.Block(accumulator_class.Element());
    return struct {
        fn accumulated(output: *const ReduceOutput) accumulator_class.Element() {
            return switch (accumulator_class) {
                .byte => unreachable,
                .integer => output.accumulator.integer,
                .real => output.accumulator.real,
            };
        }

        fn store(output: *ReduceOutput, element: accumulator_class.Element()) void {
            output.accumulator = switch (accumulator_class) {
                .byte => unreachable,
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
                    .byte, .integer => @floatFromInt(elements[index]),
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
        fn accumulate(output: *ReduceOutput, elements: []const element_class.Element(), range: flat.Chunk, context: support.Context) MachineError!void {
            var block = Staging.init();
            var offset: usize = 0;
            while (offset != range.len()) {
                const piece = flat.blockRange(range, offset);
                block.reset();
                if (unchecked and uncheckedBlock(output, elements, piece, &block)) {
                    if (scan) output.scan.?.store(accumulator_class, piece.start, block.written());
                    offset += piece.len();
                    continue;
                }
                for (piece.start..piece.end) |index| {
                    // Both operand tags are comptime-known here, so inlining
                    // the scalar authority lets its type dispatch fold away and
                    // leaves the checked arithmetic itself in the loop. An
                    // out-of-line call boxed and redispatched every element,
                    // and was most of a float reduction's cost.
                    const next = @call(.always_inline, scalarBinary, .{
                        operation,
                        accumulator_class.boxed(accumulated(output)),
                        element_class.boxed(elements[index]),
                    }) catch |fault| {
                        // A sequential fold's first fault is the fault: there is
                        // no later element whose result could precede it, so the
                        // failure is reported where it happened. A recognized
                        // combinator's fault carries no list index, exactly as
                        // the per-element route reported it.
                        const diagnostic = scalarDiagnostic(fault);
                        return context.fail(diagnostic.kind, diagnostic.message);
                    };
                    store(output, accumulator_class.unboxed(next));
                    if (scan) {
                        block.items[index - piece.start] = accumulated(output);
                        block.len = index - piece.start + 1;
                    }
                }
                if (scan) output.scan.?.store(accumulator_class, piece.start, block.written());
                offset += piece.len();
            }
        }

        /// The reduction as a `support.Kernel`. Its positions are the list
        /// indices after the seed: a seed that changes class takes one scalar
        /// step from the first remaining element before the loop.
        const Spec = struct {
            pub const arity = 1;
            pub const Params = ReduceParams;
            pub const Output = ReduceOutput;

            pub fn prepare(evaluator: *Machine, operands: [1]Value, params: ReduceParams, _: usize) MachineError!Output {
                const input = operands[0];
                const seed = if (seeded) first: {
                    // Charge even this single step to the shared budget: many
                    // short reductions must not evade cancellation. Do not
                    // pre-cast initial; mixed numeric comparisons in particular
                    // would lose information.
                    try evaluator.advanceKernel(1);
                    break :first scalarBinary(operation, params.initial, list.atUnchecked(input, params.cursor_start)) catch |fault| {
                        const diagnostic = scalarDiagnostic(fault);
                        return evaluator.fail(diagnostic.kind, diagnostic.message);
                    };
                } else params.initial;
                var output: Output = .{
                    .accumulator = switch (accumulator_class) {
                        .byte => unreachable,
                        .integer => .{ .integer = seed.int },
                        .real => .{ .real = seed.float },
                    },
                    .scan = null,
                    .base = params.cursor_start + @intFromBool(seeded),
                };
                if (scan) {
                    output.scan = try freshOutput(accumulator_class, evaluator, @intCast(input.list.length()));
                    if (seeded) output.scan.?.store(accumulator_class, params.cursor_start, &.{accumulator_class.unboxed(seed)});
                }
                return output;
            }

            pub fn chunk(_: ReduceParams, operands: [1]Value, output: *Output, range: flat.Chunk, context: support.Context) MachineError!void {
                return accumulate(
                    output,
                    heap.leafElements(element_class.kind(), operands[0].list),
                    .{ .start = output.base + range.start, .end = output.base + range.end },
                    context,
                );
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

/// The opaque plan binds a possible seed transition to its stable loop and
/// output representation. Guard and entry use the same classification.
const NumericReducePlan = opaque {
    const Data = struct {
        accumulator: Number,
        element: Number,
        scan: bool,
        seeded: bool,
        run: RunReduce,
    };

    fn select(operation: BinaryOp, accumulator: Number, element: Number, scan: bool) ?*const NumericReducePlan {
        @setEvalBranchQuota(4000);
        return switch (operation) {
            inline else => |selected| blk: {
                // Scalar accumulators have no byte storage class.
                inline for ([_]Number{ .integer, .real }) |candidate_accumulator| {
                    inline for (number_classes) |candidate_element| {
                        const out = comptime binaryResult(selected, candidate_accumulator, candidate_element);
                        if (comptime out == null or out.? == .byte) continue;
                        // A known first result is insufficient: every later
                        // result must have that same representation as well.
                        if (comptime binaryResult(selected, out.?, candidate_element) != out) continue;
                        inline for ([_]bool{ false, true }) |candidate_scan| {
                            if (accumulator == candidate_accumulator and element == candidate_element and scan == candidate_scan) {
                                const seeded = comptime out.? != candidate_accumulator;
                                const data = comptime Data{
                                    .accumulator = out.?,
                                    .element = candidate_element,
                                    .scan = candidate_scan,
                                    .seeded = seeded,
                                    .run = reduceKernel(selected, out.?, candidate_element, candidate_scan, seeded).run,
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
    fn start(self: *const NumericReducePlan, evaluator: *Machine, input: Value, initial: Value, cursor_start: usize, consumed: usize) MachineError!void {
        const data: *const Data = @ptrCast(@alignCast(self));
        std.debug.assert(consumed >= 1 and consumed <= 3);
        var popped: [3]heap.OwnedValue = undefined;
        var count: usize = 0;
        defer for (popped[0..count]) |*owner| owner.deinit();
        while (count != consumed) : (count += 1) popped[count] = try evaluator.popValue();
        const list_owner = &popped[consumed - 1];
        std.debug.assert(list_owner.borrow().list == input.list);
        const first = cursor_start + @intFromBool(data.seeded);
        try data.run(evaluator, .{list_owner}, .{ .initial = initial, .cursor_start = cursor_start }, @as(usize, @intCast(input.list.length())) - first);
    }
};

/// Reached only if a guard and a dispatch disagreed, which the candidate
/// predicate exists to prevent; it is a domain error rather than a silent
/// second classification.
fn unexpectedReduceShape(evaluator: *Machine) MachineError {
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
    evaluator: *Machine,
    operation: BinaryOp,
    accumulator: Value,
    accumulator_owned: bool,
    row: Value,
) MachineError!RowFold {
    const class = leafNumber(accumulator) orelse return .declined;
    if (leafNumber(row) != class) return .declined;
    const length: usize = @intCast(row.list.length());
    if (length == 0 or accumulator.list.length() != length) return .declined;
    if (length > evaluator.remainingKernelFuel()) return .declined;
    return switch (operation) {
        inline else => |selected| switch (class) {
            .byte => .declined,
            inline .integer, .real => |selected_class| if (comptime binaryResult(selected, selected_class, selected_class) != selected_class)
                .declined
            else
                rowFoldStep(selected, selected_class).run(evaluator, accumulator, accumulator_owned, row, length),
        },
    };
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
pub fn foldColumns(evaluator: *Machine, operation: BinaryOp, input: *heap.OwnedValue, rows: usize, columns: usize) MachineError!void {
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
            pub const Output = heap.LeafWriter(element.kind());

            pub fn prepare(evaluator: *Machine, _: [1]Value, shape: ColumnShape, _: usize) error{OutOfMemory}!Output {
                return .init(evaluator.allocator(), shape.width);
            }

            pub fn chunk(_: ColumnShape, operands: [1]Value, output: *Output, range: flat.Chunk, _: support.Context) MachineError!void {
                output.writeRange(range.start, heap.leafElements(element.kind(), operands[0].list)[range.start..range.end]);
            }

            pub fn finish(output: *Output) Value {
                return output.finish();
            }
        };

        /// Positions are the input's, row by row: row 0 seeds each column's
        /// accumulator, and every later row folds into it, so each column
        /// folds in row order however the positions are split into ranges.
        /// Seeding converts row 0 to the accumulator class; a step from it is
        /// the same arithmetic on the same values as one from the row.
        const FoldSpec = struct {
            pub const arity = 1;
            pub const Params = ColumnShape;
            pub const Output = heap.LeafWriter(accumulator.kind());

            pub fn prepare(evaluator: *Machine, _: [1]Value, shape: ColumnShape, _: usize) error{OutOfMemory}!Output {
                return .init(evaluator.allocator(), shape.width);
            }

            pub fn chunk(shape: ColumnShape, operands: [1]Value, output: *Output, range: flat.Chunk, context: support.Context) MachineError!void {
                const width = shape.width;
                const elements = heap.leafElements(element.kind(), operands[0].list);
                const columns = output.unpublishedRange(0, width);
                var position = range.start;
                // Rows 0 and 1 in one step, as `foldLeafRow` folds a first
                // pair, whenever the range holds both whole.
                if (position == 0 and range.end >= 2 * width) {
                    try step(element, context.evaluator, elements[0..width], elements[width..][0..width], columns, 0);
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
                            .byte => unreachable,
                            .integer => if (element == .real) unreachable else @intCast(item),
                            .real => if (element == .real) item else @floatFromInt(item),
                        };
                    } else try step(accumulator, context.evaluator, target, items, target, column);
                    position += count;
                    row += 1;
                    column = 0;
                }
            }

            pub fn finish(output: *Output) Value {
                return output.finish();
            }
        };

        /// `left op right` into `out`, which may alias `left`: each block is
        /// computed from operands not yet stored over, then stored. Float
        /// `+ - *` run unchecked and replay checked only on a NaN, as
        /// `rowFoldStep` does.
        fn step(
            comptime left_class: Number,
            evaluator: *Machine,
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

fn rowFoldStep(comptime operation: BinaryOp, comptime class: Number) type {
    const Element = class.Element();
    const Staging = flat.Block(Element);
    return struct {
        /// See `reduceKernel`: float `+ - *` fault only on a NaN result, so a
        /// clean unchecked block needs no per-element test.
        const unchecked = class == .real and
            (operation == .add or operation == .sub or operation == .mul);

        fn run(evaluator: *Machine, accumulator: Value, accumulator_owned: bool, row: Value, length: usize) MachineError!RowFold {
            try evaluator.advanceKernel(length);
            var right = heap.LeafReader(class.kind()).acquire(row.list);
            defer right.release(evaluator.releaseDomain());
            if (accumulator_owned) if (heap.UniqueLeafAdoption(class.kind()).claim(accumulator.list, length)) |claimed| {
                var adoption = claimed;
                errdefer adoption.abandon();
                try apply(evaluator, adoption.sourceSlice(class.kind()), right.slice(), adoption.inPlaceRange(0, length));
                return .{ .in_place = adoption.finish() };
            };
            var left = heap.LeafReader(class.kind()).acquire(accumulator.list);
            defer left.release(evaluator.releaseDomain());
            var writer = try heap.LeafWriter(class.kind()).init(evaluator.allocator(), length);
            errdefer writer.retirePartial(evaluator.releaseDomain());
            try apply(evaluator, left.slice(), right.slice(), writer.unpublishedRange(0, length));
            return .{ .fresh = writer.finish() };
        }

        /// `out` may alias `left`: each block is computed from operands not
        /// yet stored over, then stored.
        fn apply(evaluator: *Machine, left: []const Element, right: []const Element, out: []Element) MachineError!void {
            var block = Staging.init();
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
                        block.items[slot] = next;
                    }
                    if (clean) {
                        @memcpy(out[start..end], block.items[0 .. end - start]);
                        start = end;
                        continue;
                    }
                }
                for (start..end, 0..) |index, slot| {
                    const next = @call(.always_inline, scalarBinary, .{
                        operation,
                        class.boxed(left[index]),
                        class.boxed(right[index]),
                    }) catch |fault| {
                        const diagnostic = scalarDiagnostic(fault);
                        return evaluator.failAtIndex(diagnostic.kind, diagnostic.message, index);
                    };
                    block.items[slot] = class.unboxed(next);
                }
                @memcpy(out[start..end], block.items[0 .. end - start]);
                start = end;
            }
        }
    };
}

pub const IdiomReduceStart = *const fn (*Machine, Value, Value, bool, usize, usize) MachineError!void;

/// Starts the typed reduction. The caller has guarded with
/// `typedReduceCandidate`, so this asserts rather than reporting a second
/// classification.
pub fn idiomReduceStart(operation: BinaryOp) IdiomReduceStart {
    return switch (operation) {
        inline else => |selected| struct {
            fn run(
                evaluator: *Machine,
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

/// Reducer symbols select fixed semantics independently of language bindings.
pub fn reduceGroups(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
    var reducer = try evaluator.popValue();
    defer reducer.deinit();
    if (reducer.borrow() != .symbol) return evaluator.typeError("a reducer symbol");
    const operation = std.meta.stringToEnum(GroupReducer, @import("intern.zig").get(reducer.borrow().symbol.name)) orelse
        return evaluator.fail(.domain, "unknown group reducer");
    var groups = try evaluator.popList();
    defer groups.deinit();
    var values = try evaluator.popList();
    defer values.deinit();
    try evaluator.startDriver(GroupReduceDriver{
        .values = .init(values.take()),
        .groups = .init(groups.take()),
        .operation = operation,
    });
}

const GroupReducer = enum { sum, count, min, max };
/// Reduces each group in order. A typed numeric value leaf selected by a typed
/// index leaf is reduced in granted runs: the run's indices are checked at
/// once, and the elements before the first bad one are still reduced, so a
/// fault earlier in a group is reported before a bad index after it. Any
/// other group takes the per-element boxed loop. The results are profiled
/// into a typed list like every other collected result.
const GroupReduceDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    values: heap.Owned(Value),
    groups: heap.Owned(Value),
    operation: GroupReducer,
    output: ?heap.Owned(heap.OwnedValueBuffer) = null,
    materializer: ?heap.Owned(list.ValueMaterializer) = null,
    group: usize = 0,
    index: usize = 0,
    accumulator: Value = .{ .int = 0 },
    comparison: ?heap.Owned(@import("kernel_order.zig").CompareCursor) = null,

    fn reduceRun(
        self: *GroupReduceDriver,
        comptime value_kind: value.HeapKind,
        comptime index_kind: value.HeapKind,
        evaluator: *Machine,
        work: *poll.WorkBudget,
        indices: *heap.ListHandle,
    ) MachineError!void {
        const Element = heap.LeafElement(value_kind);
        var values = heap.LeafReader(value_kind).acquire(self.values.borrow().list);
        defer values.release(evaluator.releaseDomain());
        var selectors = heap.LeafReader(index_kind).acquire(indices);
        defer selectors.release(evaluator.releaseDomain());
        const items = values.slice();
        const run = selectors.slice()[self.index..][0..work.take(selectors.len() - self.index)];
        const fault = flat.firstIndexFault(heap.LeafElement(index_kind), run, items.len);
        for (run[0..if (fault) |found| found.position else run.len]) |selector| {
            const position: usize = @intCast(selector);
            const item: Element = items[position];
            const boxed: Value = if (Element == f64) .{ .float = item } else .{ .int = item };
            switch (self.operation) {
                .count => self.accumulator.int += 1,
                .sum => self.accumulator = add(self.accumulator, boxed) catch |err|
                    return scalarFailure(evaluator, err, position),
                .min, .max => {
                    // The first element seeds the accumulator, which until
                    // then holds the sum's integer zero.
                    const replace = self.index == 0 or replace: {
                        const current: Element = if (Element == f64) self.accumulator.float else @intCast(self.accumulator.int);
                        break :replace if (self.operation == .min) item < current else item > current;
                    };
                    if (replace) self.accumulator = boxed;
                },
            }
            self.index += 1;
        }
        if (fault != null) return evaluator.fail(.domain, "group index is out of bounds");
    }

    /// Reduces part of the current group through the typed run when both the
    /// values and its selectors are typed numeric leaves; false otherwise.
    fn typedRun(self: *GroupReduceDriver, evaluator: *Machine, work: *poll.WorkBudget, indices: Value) MachineError!bool {
        const values = self.values.borrow().list;
        switch (values.kind()) {
            inline .leaf_u8, .leaf_i64, .leaf_f64 => |value_kind| switch (indices.list.kind()) {
                inline .leaf_u8, .leaf_i64 => |index_kind| {
                    try self.reduceRun(value_kind, index_kind, evaluator, work, indices.list);
                    return true;
                },
                else => return false,
            },
            else => return false,
        }
    }

    pub fn advance(evaluator: *Machine, self: *GroupReduceDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const count: usize = @intCast(self.groups.borrow().list.length());
        if (self.output == null and self.materializer == null) self.output = .init(try .init(evaluator.releaseDomain(), count));
        const work = evaluator.workBudget();
        while (self.group != count and !work.exhausted()) {
            const indices = list.atUnchecked(self.groups.borrow(), self.group);
            if (indices != .list) return evaluator.typeError("group index lists");
            if (self.index == indices.list.length()) {
                if (self.index == 0 and (self.operation == .min or self.operation == .max))
                    return evaluator.fail(.domain, "first requires a non-empty list");
                self.output.?.borrowMut().appendBorrowed(self.accumulator);
                self.accumulator = .{ .int = 0 };
                self.group += 1;
                self.index = 0;
                _ = work.spend();
                continue;
            }
            if (try self.typedRun(evaluator, work, indices)) continue;
            _ = work.spend();
            const selector = list.atUnchecked(indices, self.index);
            if (selector != .int) return evaluator.typeError("integer group indices");
            if (selector.int < 0 or @as(u64, @intCast(selector.int)) >= self.values.borrow().list.length())
                return evaluator.fail(.domain, "group index is out of bounds");
            const item = list.atUnchecked(self.values.borrow(), @intCast(selector.int));
            switch (self.operation) {
                .count => self.accumulator.int += 1,
                .sum => {
                    if (!item.isNumber()) return evaluator.typeError("numeric group values");
                    self.accumulator = add(self.accumulator, item) catch |err| return scalarFailure(evaluator, err, @intCast(selector.int));
                },
                .min, .max => {
                    if (self.index == 0) self.accumulator = item;
                    if (self.comparison == null) self.comparison = .init(.init(evaluator.allocator(), self.accumulator, item));
                    switch (try self.comparison.?.borrowMut().advance(work)) {
                        .pending => continue,
                        .not_comparable => return evaluator.typeError("comparable group values"),
                        .complete => |order| {
                            if ((self.operation == .min and order == .gt) or (self.operation == .max and order == .lt)) self.accumulator = item;
                            self.comparison.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                            self.comparison = null;
                        },
                    }
                },
            }
            self.index += 1;
        }
        if (self.group != count) return .stepped;
        if (self.materializer == null) {
            const results = self.output.?.take();
            self.output = null;
            self.materializer = .init(list.ValueMaterializer.initOwned(evaluator.allocator(), results));
        }
        if (work.exhausted()) return .stepped;
        return switch (try self.materializer.?.borrowMut().advance(work)) {
            .pending => .stepped,
            .complete => |result| completed: {
                self.materializer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.materializer = null;
                break :completed .{ .output = result };
            },
        };
    }
};
