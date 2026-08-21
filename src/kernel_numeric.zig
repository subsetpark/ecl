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
const storage = @import("kernel_storage.zig");
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
    inline for (std.meta.fields(BinaryOp)) |field| {
        const operation: BinaryOp = @enumFromInt(field.value);
        if (operation == .mod or operation == .ne or operation == .le or operation == .ge or
            operation == .and_word or operation == .or_word) continue;
        try support.installPrimitive(core, operation.spelling(), bindBinary(operation));
    }
    inline for (std.meta.fields(UnaryOp)) |field| {
        const operation: UnaryOp = @enumFromInt(field.value);
        if (operation == .neg or operation == .abs) continue;
        try support.installPrimitive(core, operation.spelling(), bindUnary(operation));
    }
}

fn bindBinary(comptime operation: BinaryOp) env.PrimitiveImpl {
    return struct {
        fn run(evaluator: *Machine) MachineError!void {
            return binaryPrimitive(evaluator, operation);
        }
    }.run;
}

pub fn binaryPrimitiveFor(comptime operation: BinaryOp) env.PrimitiveImpl {
    return bindBinary(operation);
}

fn bindUnary(comptime operation: UnaryOp) env.PrimitiveImpl {
    return struct {
        fn run(evaluator: *Machine) MachineError!void {
            return unaryPrimitive(evaluator, operation);
        }
    }.run;
}

pub fn unaryPrimitiveFor(comptime operation: UnaryOp) env.PrimitiveImpl {
    return bindUnary(operation);
}

fn binaryPrimitive(evaluator: *Machine, comptime operation: BinaryOp) MachineError!void {
    try evaluator.require(2);
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
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
        return switch (try self.cursor.borrowMut().advance(evaluator, machine.kernel_poll_quantum)) {
            .pending => .yielded,
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
        materializer: ?storage.ValueMaterializer = null,
        result: ?Value = null,

        fn deinit(self: *ListFrame, releases: *heap.ReleaseDomain) void {
            if (self.materializer) |*materializer| materializer.retire(releases);
            self.values.deinit();
            if (self.result) |result| releases.releaseValue(result);
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
        phase: enum { left, right, materialize, release } = .left,
        index: usize = 0,
        candidate: usize = 0,
        pair_count: usize = 0,
        waiting: bool = false,
        match_cursor: ?equal.MatchCursor = null,
        materializer: ?storage.DictMaterializer = null,
        result: ?Value = null,

        fn deinit(self: *DictFrame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
            if (self.match_cursor) |*cursor| cursor.deinit();
            if (self.materializer) |*materializer| materializer.retire(releases);
            self.values.deinit();
            allocator.free(self.pairs);
            if (self.result) |result| releases.releaseValue(result);
        }
    };
    const Frame = union(enum) {
        binary: BinaryNode,
        unary: UnaryNode,
        list: ListFrame,
        dictionary: DictFrame,
        typed: NestedTyped,

        fn deinit(self: *Frame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .binary, .unary => {},
                .list => |*frame| frame.deinit(releases),
                .dictionary => |*frame| frame.deinit(releases, allocator),
                .typed => |*typed| typed.retire(releases),
            }
        }
    };

    pub fn initBinary(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        operation: BinaryOp,
        left: Value,
        right: Value,
    ) error{OutOfMemory}!PervadeCursor {
        var frames = poll.ChunkStack(Frame).init(allocator);
        errdefer frames.deinit();
        try frames.push(.{ .binary = .{
            .operation = operation,
            .left = left,
            .right = right,
            .depth = 0,
            .logical_index = null,
        } });
        return .{ .releases = releases, .allocator = allocator, .frames = frames };
    }

    pub fn initUnary(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        operation: UnaryOp,
        operand: Value,
    ) error{OutOfMemory}!PervadeCursor {
        var frames = poll.ChunkStack(Frame).init(allocator);
        errdefer frames.deinit();
        try frames.push(.{ .unary = .{
            .operation = operation,
            .operand = operand,
            .depth = 0,
            .logical_index = null,
        } });
        return .{ .releases = releases, .allocator = allocator, .frames = frames };
    }

    pub fn deinit(self: *PervadeCursor) void {
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
        budget: usize,
    ) MachineError!PervadeProgress {
        std.debug.assert(budget != 0);
        var remaining = budget;
        while (remaining != 0) : (remaining -= 1) {
            var frame = self.frames.pop() orelse {
                const result = self.last.?;
                self.last = null;
                return .{ .complete = result };
            };
            switch (frame) {
                .binary => |node| try self.startBinary(evaluator, node),
                .unary => |node| try self.startUnary(evaluator, node),
                .list => |*list_frame| {
                    if (!try self.advanceList(evaluator, list_frame, remaining)) return .pending;
                },
                .dictionary => |*dict_frame| {
                    if (!try self.advanceDict(evaluator, dict_frame, remaining)) return .pending;
                },
                .typed => |*typed| {
                    errdefer typed.retire(self.releases);
                    if (try typed.advance(evaluator)) |result| {
                        self.last = result;
                    } else {
                        try self.frames.reserve(1);
                        self.frames.pushReserved(.{ .typed = typed.* });
                        return .pending;
                    }
                },
            }
        }
        return .pending;
    }

    fn startBinary(self: *PervadeCursor, evaluator: *Machine, node: BinaryNode) MachineError!void {
        if (node.depth >= support.max_depth and
            (node.left == .list or node.left == .dict or node.right == .list or node.right == .dict))
            return evaluator.fail(.domain, "pervasion nesting exceeds 256 levels");
        if (node.left == .dict or node.right == .dict) {
            try self.pushDictBinary(node);
            return;
        }
        if (node.left == .list or node.right == .list) {
            if (try buildNestedTypedBinary(
                evaluator,
                node.operation,
                node.left,
                node.right,
                .{},
            )) |typed_value| {
                var typed = typed_value;
                errdefer typed.retire(self.releases);
                try self.frames.reserve(1);
                self.frames.pushReserved(.{ .typed = typed });
                return;
            }
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
            return;
        }
        self.last = selectScalar(node.operation)(node.left, node.right) catch |fault|
            return scalarFailure(evaluator, fault, node.logical_index);
    }

    fn startUnary(self: *PervadeCursor, evaluator: *Machine, node: UnaryNode) MachineError!void {
        if (node.depth >= support.max_depth and (node.operand == .list or node.operand == .dict))
            return evaluator.fail(.domain, "pervasion nesting exceeds 256 levels");
        if (node.operand == .dict) {
            const count: usize = @intCast(node.operand.dict.length());
            const pairs = try self.allocator.alloc(dict.Pair, count);
            errdefer self.allocator.free(pairs);
            var values = try heap.OwnedValueBuffer.init(self.releases, count);
            errdefer values.deinit();
            try self.frames.reserve(1);
            self.frames.pushReserved(.{ .dictionary = .{
                .mode = .{ .unary = node.operation },
                .left = node.operand,
                .right = null,
                .depth = node.depth,
                .pairs = pairs,
                .values = values.take(),
            } });
            return;
        }
        if (node.operand == .list) {
            if (try buildNestedTypedUnary(evaluator, node.operation, node.operand, .{})) |typed_value| {
                var typed = typed_value;
                errdefer typed.retire(self.releases);
                try self.frames.reserve(1);
                self.frames.pushReserved(.{ .typed = typed });
                return;
            }
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
            return;
        }
        self.last = selectUnary(node.operation)(node.operand) catch |fault|
            return scalarFailure(evaluator, fault, node.logical_index);
    }

    fn advanceList(
        self: *PervadeCursor,
        _: *Machine,
        frame: *ListFrame,
        budget: usize,
    ) MachineError!bool {
        errdefer frame.deinit(self.releases);
        if (frame.result) |result| {
            frame.values.deinit();
            frame.result = null;
            self.last = result;
            return true;
        }
        if (frame.waiting) {
            frame.values.appendOwned(self.last.?);
            self.last = null;
            frame.index += 1;
            frame.waiting = false;
        }
        if (frame.index != frame.values.capacity()) {
            const index = frame.index;
            frame.waiting = true;
            try self.frames.reserve(2);
            self.frames.pushReserved(.{ .list = frame.* });
            switch (frame.operation) {
                .binary => |operation| self.frames.pushReserved(.{ .binary = .{
                    .operation = operation,
                    .left = if (frame.left_scalar) frame.left else list.atUnchecked(frame.left, index),
                    .right = if (frame.right_scalar) frame.right.? else list.atUnchecked(frame.right.?, index),
                    .depth = frame.depth + 1,
                    .logical_index = index,
                } }),
                .unary => |operation| self.frames.pushReserved(.{ .unary = .{
                    .operation = operation,
                    .operand = list.atUnchecked(frame.left, index),
                    .depth = frame.depth + 1,
                    .logical_index = index,
                } }),
            }
            return true;
        }
        if (frame.materializer == null)
            frame.materializer = .init(self.allocator, frame.values.values());
        try self.frames.reserve(1);
        switch (try frame.materializer.?.advance(budget)) {
            .pending => {
                self.frames.pushReserved(.{ .list = frame.* });
                return false;
            },
            .complete => |result| {
                frame.result = result;
                self.frames.pushReserved(.{ .list = frame.* });
                return false;
            },
        }
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
        try self.frames.reserve(1);
        self.frames.pushReserved(.{ .dictionary = .{
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
        } });
    }

    fn advanceDict(
        self: *PervadeCursor,
        _: *Machine,
        frame: *DictFrame,
        budget: usize,
    ) MachineError!bool {
        errdefer frame.deinit(self.releases, self.allocator);
        if (frame.phase == .release) {
            frame.values.deinit();
            self.allocator.free(frame.pairs);
            const result = frame.result.?;
            frame.result = null;
            self.last = result;
            return true;
        }
        if (frame.waiting) {
            frame.values.appendOwned(self.last.?);
            frame.pairs[frame.pair_count][1] = self.last.?;
            self.last = null;
            frame.pair_count += 1;
            frame.index += 1;
            frame.candidate = 0;
            frame.waiting = false;
        }
        if (frame.phase == .materialize) {
            if (frame.materializer == null) frame.materializer = try .init(
                self.allocator,
                frame.pairs[0..frame.pair_count],
                false,
            );
            try self.frames.reserve(1);
            switch (try frame.materializer.?.advance(budget)) {
                .pending => {
                    self.frames.pushReserved(.{ .dictionary = frame.* });
                    return false;
                },
                .duplicate_key => unreachable,
                .complete => |result| {
                    frame.materializer.?.deinit();
                    frame.materializer = null;
                    frame.result = result;
                    frame.phase = .release;
                    self.frames.pushReserved(.{ .dictionary = frame.* });
                    return false;
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
                    try self.frames.reserve(1);
                    self.frames.pushReserved(.{ .dictionary = frame.* });
                    return true;
                }
                const index = frame.index;
                frame.pairs[frame.pair_count][0] = dict.keyAt(dictionary.dict, index);
                frame.waiting = true;
                try self.frames.reserve(2);
                self.frames.pushReserved(.{ .dictionary = frame.* });
                switch (frame.mode) {
                    .unary => |operation| self.frames.pushReserved(.{ .unary = .{
                        .operation = operation,
                        .operand = dict.valueAt(dictionary.dict, index),
                        .depth = frame.depth + 1,
                        .logical_index = index,
                    } }),
                    .left => |operation| self.frames.pushReserved(.{ .binary = .{
                        .operation = operation,
                        .left = dict.valueAt(dictionary.dict, index),
                        .right = frame.right.?,
                        .depth = frame.depth + 1,
                        .logical_index = index,
                    } }),
                    .right => |operation| self.frames.pushReserved(.{ .binary = .{
                        .operation = operation,
                        .left = frame.left,
                        .right = dict.valueAt(dictionary.dict, index),
                        .depth = frame.depth + 1,
                        .logical_index = index,
                    } }),
                    .both => unreachable,
                }
                return true;
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
                    try self.frames.reserve(1);
                    self.frames.pushReserved(.{ .dictionary = frame.* });
                    return true;
                }
                if (frame.candidate == other_count) {
                    const key = dict.keyAt(source.dict, frame.index);
                    const item = dict.valueAt(source.dict, frame.index);
                    frame.values.appendBorrowed(item);
                    frame.pairs[frame.pair_count] = .{ key, item };
                    frame.pair_count += 1;
                    frame.index += 1;
                    frame.candidate = 0;
                    try self.frames.reserve(1);
                    self.frames.pushReserved(.{ .dictionary = frame.* });
                    return true;
                }
                if (frame.match_cursor == null) frame.match_cursor = try .init(
                    self.allocator,
                    dict.keyAt(source.dict, frame.index),
                    dict.keyAt(other.dict, frame.candidate),
                );
                try self.frames.reserve(2);
                switch (try frame.match_cursor.?.advance(budget)) {
                    .pending => {
                        self.frames.pushReserved(.{ .dictionary = frame.* });
                        return false;
                    },
                    .complete => |matches| {
                        frame.match_cursor.?.deinit();
                        frame.match_cursor = null;
                        if (!matches) {
                            frame.candidate += 1;
                            self.frames.pushReserved(.{ .dictionary = frame.* });
                            return false;
                        }
                        if (frame.phase == .right) {
                            frame.index += 1;
                            frame.candidate = 0;
                            self.frames.pushReserved(.{ .dictionary = frame.* });
                            return false;
                        }
                        const index = frame.index;
                        const candidate = frame.candidate;
                        frame.pairs[frame.pair_count][0] = dict.keyAt(frame.left.dict, index);
                        frame.waiting = true;
                        self.frames.pushReserved(.{ .dictionary = frame.* });
                        self.frames.pushReserved(.{ .binary = .{
                            .operation = operation,
                            .left = dict.valueAt(frame.left.dict, index),
                            .right = dict.valueAt(frame.right.?.dict, candidate),
                            .depth = frame.depth + 1,
                            .logical_index = index,
                        } });
                        return false;
                    },
                }
            },
        }
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
    };
}

fn scalarUnary(comptime operation: UnaryOp, operand: Value) ScalarError!Value {
    return switch (operation) {
        .not_word => .{ .int = @intFromBool(!(try boolean(operand))) },
        .neg => switch (operand) {
            .int => |integer| .{ .int = std.math.sub(i64, 0, integer) catch return error.Overflow },
            .float => |number| try checkedFloat(-number, !std.math.isFinite(number)),
            .char, .symbol, .word, .list, .dict, .task, .module => error.Type,
        },
        .abs => switch (operand) {
            .int => |integer| if (integer == std.math.minInt(i64))
                error.Overflow
            else
                .{ .int = if (integer < 0) -integer else integer },
            .float => |number| try checkedFloat(@abs(number), !std.math.isFinite(number)),
            .char, .symbol, .word, .list, .dict, .task, .module => error.Type,
        },
        .sqrt => switch (operand) {
            .int => |integer| if (integer < 0)
                error.Domain
            else
                try checkedFloat(@sqrt(@as(f64, @floatFromInt(integer))), false),
            .float => |number| if (number < 0.0)
                error.Domain
            else
                try checkedFloat(@sqrt(number), !std.math.isFinite(number)),
            .char, .symbol, .word, .list, .dict, .task, .module => error.Type,
        },
        .floor, .ceil, .round => switch (operand) {
            .int => operand,
            .float => |number| floatToInt(switch (operation) {
                .floor => @floor(number),
                .ceil => @ceil(number),
                .round => @round(number),
                else => unreachable,
            }),
            .char, .symbol, .word, .list, .dict, .task, .module => error.Type,
        },
        .exp, .log, .sin, .cos => transcendental(operation, operand),
        .bnot => switch (operand) {
            .int => |integer| .{ .int = ~integer },
            .char, .float, .symbol, .word, .list, .dict, .task, .module => error.Type,
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

fn add(left: Value, right: Value) ScalarError!Value {
    if (left == .char and right == .int) return offsetChar(left.char, right.int);
    if (left == .int and right == .char) return offsetChar(right.char, left.int);
    if (left == .char or right == .char) return error.Type;
    return numericBinary(left, right, .add);
}

fn sub(left: Value, right: Value) ScalarError!Value {
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
    return checkedFloat(result, !std.math.isFinite(a) or !std.math.isFinite(b));
}

fn divide(left: Value, right: Value) ScalarError!Value {
    if (!left.isNumber() or !right.isNumber()) return error.Type;
    const a = asFloat(left);
    const b = asFloat(right);
    if (b == 0.0) return error.Domain;
    return checkedFloat(a / b, !std.math.isFinite(a) or !std.math.isFinite(b));
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
    return checkedFloat(std.math.pow(f64, a, b), !std.math.isFinite(a) or !std.math.isFinite(b));
}

fn atan2(left: Value, right: Value) ScalarError!Value {
    if (!left.isNumber() or !right.isNumber()) return error.Type;
    const y = asFloat(left);
    const x = asFloat(right);
    return checkedFloat(
        std.math.atan2(y, x),
        !std.math.isFinite(y) or !std.math.isFinite(x),
    );
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
    return checkedFloat(result, !std.math.isFinite(number));
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

fn checkedFloat(result: f64, propagating: bool) ScalarError!Value {
    if (std.math.isNan(result)) return error.Domain;
    if (std.math.isInf(result) and !propagating) return error.Overflow;
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
        .char, .symbol, .word, .list, .dict, .task, .module => unreachable,
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
// The semantics are not reimplemented here. Every block body calls the same
// `scalarBinary`/`scalarUnary` the generic route calls, with statically known
// operand tags, so an optimized build folds those tag switches away while the
// meaning stays in exactly one place. A block that faults is replayed through
// that same function to report the first failing index, kind, and message.
// ===========================================================================

/// The two numeric element classes a typed loop carries. Chars and symbols are
/// deliberately absent: a char result chooses its width from the codepoints it
/// produces, which is a profiling decision, and symbols are not arithmetic.
const Number = enum {
    integer,
    real,

    fn Element(comptime self: Number) type {
        return switch (self) {
            .integer => i64,
            .real => f64,
        };
    }

    fn kind(comptime self: Number) value.HeapKind {
        return switch (self) {
            .integer => .leaf_i64,
            .real => .leaf_f64,
        };
    }

    fn boxed(comptime self: Number, element: self.Element()) Value {
        return switch (self) {
            .integer => .{ .int = element },
            .real => .{ .float = element },
        };
    }

    fn unboxed(comptime self: Number, item: Value) self.Element() {
        return switch (self) {
            .integer => item.int,
            .real => item.float,
        };
    }
};

const number_classes = [_]Number{ .integer, .real };

fn scalarNumber(item: Value) ?Number {
    return switch (item) {
        .int => .integer,
        .float => .real,
        .char, .symbol, .word, .list, .dict, .task, .module => null,
    };
}

fn leafNumber(item: Value) ?Number {
    if (item != .list) return null;
    return switch (item.list.kind()) {
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
    integer,
    char1,
    char2,
    char4,

    fn Element(comptime self: FlatScalarClass) type {
        return switch (self) {
            .integer => i64,
            .char1 => u8,
            .char2 => u16,
            .char4 => u32,
        };
    }

    fn boxed(comptime self: FlatScalarClass, element: self.Element()) Value {
        return switch (self) {
            .integer => .{ .int = element },
            .char1, .char2, .char4 => .{ .char = @intCast(element) },
        };
    }

    fn isCharacter(self: FlatScalarClass) bool {
        return self != .integer;
    }
};

fn characterFlatClass(character: Character) FlatScalarClass {
    return switch (character) {
        .char1 => .char1,
        .char2 => .char2,
        .char4 => .char4,
    };
}

const FlatScalarOperand = union(enum) {
    absent,
    scalar: Value,
    ints: heap.LeafReader(.leaf_i64),
    char1: heap.LeafReader(.leaf_char1),
    char2: heap.LeafReader(.leaf_char2),
    char4: heap.LeafReader(.leaf_char4),

    fn release(self: *FlatScalarOperand, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .absent, .scalar => {},
            inline else => |*reader| reader.release(releases),
        }
        self.* = .absent;
    }

    fn slice(self: *const FlatScalarOperand, comptime class: FlatScalarClass) []const class.Element() {
        return switch (class) {
            .integer => self.ints.slice(),
            .char1 => self.char1.slice(),
            .char2 => self.char2.slice(),
            .char4 => self.char4.slice(),
        };
    }
};

fn acquireFlatScalarOperand(comptime class: FlatScalarClass, item: Value) FlatScalarOperand {
    return switch (class) {
        .integer => .{ .ints = .acquire(item.list) },
        .char1 => .{ .char1 = .acquire(item.list) },
        .char2 => .{ .char2 = .acquire(item.list) },
        .char4 => .{ .char4 = .acquire(item.list) },
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
        .eq, .ne, .lt, .gt, .le, .ge => .integer,
        .min, .max => if (left != right) null else left,
    };
}

fn unaryResult(comptime operation: UnaryOp, comptime operand: Number) Number {
    return switch (operation) {
        .neg, .abs => operand,
        .sqrt, .exp, .log, .sin, .cos => .real,
        .floor, .ceil, .round => .integer,
        .not_word, .bnot => .integer,
    };
}

/// How the operands are shaped at dispatch. A scalar operand is read with stride
/// zero; no broadcast is ever materialized.
const Shape = enum { leaf_leaf, leaf_scalar, scalar_leaf, leaf_only };
const binary_shapes = [_]Shape{ .leaf_leaf, .leaf_scalar, .scalar_leaf };

/// A typed input operand. A leaf is reached through a reader that retains its
/// root for the driver's whole lifetime; `aliased` marks the operand whose
/// buffer the result is taking over, whose reads come from the output capability
/// because the two are the same memory.
const TypedOperand = union(enum) {
    absent,
    scalar: Value,
    ints: heap.LeafReader(.leaf_i64),
    reals: heap.LeafReader(.leaf_f64),
    aliased,

    fn release(self: *TypedOperand, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .absent, .scalar, .aliased => {},
            .ints => |*reader| reader.release(releases),
            .reals => |*reader| reader.release(releases),
        }
        self.* = .absent;
    }

    fn slice(self: *const TypedOperand, comptime class: Number) []const class.Element() {
        return switch (class) {
            .integer => self.ints.slice(),
            .real => self.reals.slice(),
        };
    }
};

/// The typed result buffer: freshly allocated, or a solely-owned input buffer
/// taken over in place under the mask-before-store protocol.
const TypedOutput = union(enum) {
    fresh_ints: heap.LeafWriter(.leaf_i64),
    fresh_reals: heap.LeafWriter(.leaf_f64),
    reuse_ints: heap.UniqueLeafAdoption(.leaf_i64),
    reuse_reals: heap.UniqueLeafAdoption(.leaf_f64),

    fn store(self: *TypedOutput, comptime class: Number, offset: usize, block: []const class.Element()) void {
        switch (class) {
            .integer => switch (self.*) {
                .fresh_ints => |*writer| writer.writeRange(offset, block),
                .reuse_ints => |*adoption| adoption.writeRange(offset, block),
                .fresh_reals, .reuse_reals => unreachable,
            },
            .real => switch (self.*) {
                .fresh_reals => |*writer| writer.writeRange(offset, block),
                .reuse_reals => |*adoption| adoption.writeRange(offset, block),
                .fresh_ints, .reuse_ints => unreachable,
            },
        }
    }

    /// The reused buffer read as the operand representation it still holds.
    fn aliasedSlice(self: *const TypedOutput, comptime class: Number) []const class.Element() {
        return switch (self.*) {
            .reuse_ints => |*adoption| adoption.sourceSlice(class.kind()),
            .reuse_reals => |*adoption| adoption.sourceSlice(class.kind()),
            .fresh_ints, .fresh_reals => unreachable,
        };
    }

    fn finish(self: *TypedOutput) Value {
        return switch (self.*) {
            inline else => |*capability| capability.finish(),
        };
    }

    fn reusing(self: *const TypedOutput) bool {
        return switch (self.*) {
            .reuse_ints, .reuse_reals => true,
            .fresh_ints, .fresh_reals => false,
        };
    }

    fn retire(self: *TypedOutput, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .fresh_ints => |*writer| writer.retirePartial(releases),
            .fresh_reals => |*writer| writer.retirePartial(releases),
            // An abandoned reuse leaves the input exactly as it was; the
            // caller's reference to it is the one `root` holds.
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

const FixedCharState = struct {
    left: FlatScalarOperand,
    right: FlatScalarOperand,
    output: heap.LeafWriter(.leaf_i64),
    cursor: flat.FlatCursor,
    report: FaultReport,

    pub fn retire(self: *FixedCharState, releases: *heap.ReleaseDomain) void {
        self.left.release(releases);
        self.right.release(releases);
        self.output.retirePartial(releases);
    }
};

const FixedCharStep = *const fn (*FixedCharState, support.Context) MachineError!void;

const FixedCharDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    state: heap.Owned(FixedCharState),
    step: FixedCharStep,

    pub fn advance(evaluator: *Machine, self: *FixedCharDriver) MachineError!machine.WorkProgress {
        return advanceFixedCharState(evaluator, self.state.borrowMut(), self.step);
    }
};

fn advanceFixedCharState(
    evaluator: *Machine,
    state: *FixedCharState,
    step: FixedCharStep,
) MachineError!machine.WorkProgress {
    const context = support.Context{ .evaluator = evaluator };
    try step(state, context);
    if (!state.cursor.complete()) return .yielded;
    state.left.release(evaluator.releaseDomain());
    state.right.release(evaluator.releaseDomain());
    return .{ .output = state.output.finish() };
}

fn fixedCharStep(
    comptime operation: BinaryOp,
    comptime left_class: FlatScalarClass,
    comptime right_class: FlatScalarClass,
    comptime shape: Shape,
) FixedCharStep {
    const Loops = flat.Family(left_class.Element(), right_class.Element(), i64);
    const body = struct {
        fn run(a: left_class.Element(), b: right_class.Element()) ?i64 {
            const result = scalarBinary(operation, left_class.boxed(a), right_class.boxed(b)) catch return null;
            return result.int;
        }
    }.run;
    return struct {
        fn leftValue(state: *const FixedCharState, index: usize) left_class.Element() {
            return if (shape == .scalar_leaf)
                switch (left_class) {
                    .integer => state.left.scalar.int,
                    .char1, .char2, .char4 => @intCast(state.left.scalar.char),
                }
            else
                state.left.slice(left_class)[index];
        }

        fn rightValue(state: *const FixedCharState, index: usize) right_class.Element() {
            return if (shape == .leaf_scalar)
                switch (right_class) {
                    .integer => state.right.scalar.int,
                    .char1, .char2, .char4 => @intCast(state.right.scalar.char),
                }
            else
                state.right.slice(right_class)[index];
        }

        fn replay(state: *FixedCharState, context: support.Context, piece: flat.Chunk) MachineError {
            for (piece.start..piece.end) |index| {
                _ = scalarBinary(
                    operation,
                    left_class.boxed(leftValue(state, index)),
                    right_class.boxed(rightValue(state, index)),
                ) catch |fault| return failTypedScalar(context, state.report, fault, index);
            }
            unreachable;
        }

        fn step(state: *FixedCharState, context: support.Context) MachineError!void {
            const range = try state.cursor.nextRange(context) orelse return;
            var block = Loops.Staging.init();
            var offset: usize = 0;
            while (offset != range.len()) {
                const piece = flat.blockRange(range, offset);
                switch (shape) {
                    .leaf_leaf => Loops.binary(
                        body,
                        state.left.slice(left_class),
                        state.right.slice(right_class),
                        piece,
                        &block,
                    ),
                    .leaf_scalar => Loops.binaryScalarRight(
                        body,
                        state.left.slice(left_class),
                        rightValue(state, piece.start),
                        piece,
                        &block,
                    ),
                    .scalar_leaf => Loops.binaryScalarLeft(
                        body,
                        leftValue(state, piece.start),
                        state.right.slice(right_class),
                        piece,
                        &block,
                    ),
                    .leaf_only => unreachable,
                }
                if (block.faulted) return replay(state, context, piece);
                state.output.writeRange(piece.start, block.written());
                offset += piece.len();
            }
        }
    }.step;
}

const DynamicCharState = struct {
    left: FlatScalarOperand,
    right: FlatScalarOperand,
    writer: ?heap.Owned(flat.CodepointWriter) = null,
    cursor: flat.FlatCursor,
    max_codepoint: u32 = 0,
    phase: enum { profile, fill } = .profile,
    report: FaultReport,

    pub fn retire(self: *DynamicCharState, releases: *heap.ReleaseDomain) void {
        self.left.release(releases);
        self.right.release(releases);
        if (self.writer) |*writer| {
            var owned = writer.take();
            owned.retire(releases);
        }
        self.writer = null;
    }
};

const DynamicCharStep = *const fn (*DynamicCharState, support.Context) MachineError!void;

const DynamicCharDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    state: heap.Owned(DynamicCharState),
    step: DynamicCharStep,

    pub fn advance(evaluator: *Machine, self: *DynamicCharDriver) MachineError!machine.WorkProgress {
        return advanceDynamicCharState(evaluator, self.state.borrowMut(), self.step);
    }
};

fn advanceDynamicCharState(
    evaluator: *Machine,
    state: *DynamicCharState,
    step: DynamicCharStep,
) MachineError!machine.WorkProgress {
    const context = support.Context{ .evaluator = evaluator };
    try step(state, context);
    if (!state.cursor.complete()) return .yielded;
    if (state.phase == .profile) {
        state.writer = .init(try flat.CodepointWriter.init(
            evaluator.allocator(),
            state.cursor.length,
            state.max_codepoint,
        ));
        state.cursor = .init(state.cursor.length);
        state.phase = .fill;
        return .yielded;
    }
    state.left.release(evaluator.releaseDomain());
    state.right.release(evaluator.releaseDomain());
    return .{ .output = state.writer.?.borrowMut().finish() };
}

fn dynamicCharStep(
    comptime operation: BinaryOp,
    comptime left_class: FlatScalarClass,
    comptime right_class: FlatScalarClass,
    comptime shape: Shape,
) DynamicCharStep {
    const Loops = flat.Family(left_class.Element(), right_class.Element(), u32);
    const body = struct {
        fn run(a: left_class.Element(), b: right_class.Element()) ?u32 {
            const result = scalarBinary(operation, left_class.boxed(a), right_class.boxed(b)) catch return null;
            return result.char;
        }
    }.run;
    return struct {
        fn leftValue(state: *const DynamicCharState, index: usize) left_class.Element() {
            return if (shape == .scalar_leaf)
                switch (left_class) {
                    .integer => state.left.scalar.int,
                    .char1, .char2, .char4 => @intCast(state.left.scalar.char),
                }
            else
                state.left.slice(left_class)[index];
        }

        fn rightValue(state: *const DynamicCharState, index: usize) right_class.Element() {
            return if (shape == .leaf_scalar)
                switch (right_class) {
                    .integer => state.right.scalar.int,
                    .char1, .char2, .char4 => @intCast(state.right.scalar.char),
                }
            else
                state.right.slice(right_class)[index];
        }

        fn replay(state: *DynamicCharState, context: support.Context, piece: flat.Chunk) MachineError {
            for (piece.start..piece.end) |index| {
                _ = scalarBinary(
                    operation,
                    left_class.boxed(leftValue(state, index)),
                    right_class.boxed(rightValue(state, index)),
                ) catch |fault| return failTypedScalar(context, state.report, fault, index);
            }
            unreachable;
        }

        fn step(state: *DynamicCharState, context: support.Context) MachineError!void {
            const range = try state.cursor.nextRange(context) orelse return;
            var block = Loops.Staging.init();
            var offset: usize = 0;
            while (offset != range.len()) {
                const piece = flat.blockRange(range, offset);
                switch (shape) {
                    .leaf_leaf => Loops.binary(
                        body,
                        state.left.slice(left_class),
                        state.right.slice(right_class),
                        piece,
                        &block,
                    ),
                    .leaf_scalar => Loops.binaryScalarRight(
                        body,
                        state.left.slice(left_class),
                        rightValue(state, piece.start),
                        piece,
                        &block,
                    ),
                    .scalar_leaf => Loops.binaryScalarLeft(
                        body,
                        leftValue(state, piece.start),
                        state.right.slice(right_class),
                        piece,
                        &block,
                    ),
                    .leaf_only => unreachable,
                }
                if (block.faulted) return replay(state, context, piece);
                if (state.phase == .profile) {
                    for (block.written()) |codepoint| state.max_codepoint = @max(state.max_codepoint, codepoint);
                } else state.writer.?.borrowMut().writeCodepoints(piece.start, block.written());
                offset += piece.len();
            }
        }
    }.step;
}

const TypedState = struct {
    left: TypedOperand,
    right: TypedOperand,
    output: TypedOutput,
    cursor: flat.FlatCursor,
    report: FaultReport,
    /// The aliased input's reference, held until the result is published — the
    /// adoption republishes that same list, so the reference becomes the
    /// result's rather than being released.
    root: ?Value,

    pub fn retire(self: *TypedState, releases: *heap.ReleaseDomain) void {
        self.left.release(releases);
        self.right.release(releases);
        self.output.retire(releases);
        if (self.root) |item| releases.releaseValue(item);
        self.root = null;
    }

    fn faultAt(self: *const TypedState, context: support.Context, fault: ScalarError, index: usize) MachineError {
        return failTypedScalar(context, self.report, fault, index);
    }
};

const TypedStep = *const fn (*TypedState, support.Context) MachineError!void;

const TypedDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    state: heap.Owned(TypedState),
    step: TypedStep,

    pub fn advance(evaluator: *Machine, self: *TypedDriver) MachineError!machine.WorkProgress {
        return advanceTypedState(evaluator, self.state.borrowMut(), self.step);
    }
};

fn advanceTypedState(
    evaluator: *Machine,
    state: *TypedState,
    step: TypedStep,
) MachineError!machine.WorkProgress {
    const context = support.Context{ .evaluator = evaluator };
    try step(state, context);
    if (!state.cursor.complete()) return .yielded;
    state.left.release(evaluator.releaseDomain());
    state.right.release(evaluator.releaseDomain());
    const reused = state.output.reusing();
    const result = state.output.finish();
    if (reused) {
        // The adoption republished this very list, so its reference is the
        // result's. Releasing it here would retire the value being returned.
        state.root = null;
    } else if (state.root) |item| {
        evaluator.releaseDomain().releaseValue(item);
        state.root = null;
    }
    return .{ .output = result };
}

/// A typed leaf computation embedded in generic spine/dictionary descent.
/// The frame owns exactly the same state and step function as a top-level
/// driver; only the completion destination differs. This is the re-entry seam:
/// structural descent stops at a leaf and never regains per-cell boxing.
const NestedTyped = union(enum) {
    numeric: struct { state: TypedState, step: TypedStep },
    fixed_char: struct { state: FixedCharState, step: FixedCharStep },
    dynamic_char: struct { state: DynamicCharState, step: DynamicCharStep },

    fn retire(self: *NestedTyped, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .numeric => |*typed| typed.state.retire(releases),
            .fixed_char => |*typed| typed.state.retire(releases),
            .dynamic_char => |*typed| typed.state.retire(releases),
        }
    }

    fn advance(self: *NestedTyped, evaluator: *Machine) MachineError!?Value {
        const progress = switch (self.*) {
            .numeric => |*typed| try advanceTypedState(evaluator, &typed.state, typed.step),
            .fixed_char => |*typed| try advanceFixedCharState(evaluator, &typed.state, typed.step),
            .dynamic_char => |*typed| try advanceDynamicCharState(evaluator, &typed.state, typed.step),
        };
        return switch (progress) {
            .yielded => null,
            .output => |result| result,
            .completed, .detached, .failed => unreachable,
        };
    }
};

/// One charged chunk of a binary typed operation.
fn binaryStep(
    comptime operation: BinaryOp,
    comptime left_class: Number,
    comptime right_class: Number,
    comptime shape: Shape,
) TypedStep {
    const out = comptime binaryResult(operation, left_class, right_class).?;
    const Loops = flat.Family(left_class.Element(), right_class.Element(), out.Element());
    const body = struct {
        fn run(a: left_class.Element(), b: right_class.Element()) ?out.Element() {
            const result = scalarBinary(operation, left_class.boxed(a), right_class.boxed(b)) catch
                return null;
            return out.unboxed(result);
        }
    }.run;
    return struct {
        fn leftSlice(state: *const TypedState) []const left_class.Element() {
            return if (state.left == .aliased)
                state.output.aliasedSlice(left_class)
            else
                state.left.slice(left_class);
        }

        fn rightSlice(state: *const TypedState) []const right_class.Element() {
            return if (state.right == .aliased)
                state.output.aliasedSlice(right_class)
            else
                state.right.slice(right_class);
        }

        /// Replays one faulted block through the shared scalar semantics to find
        /// the first failing logical index. The mask proved something in this
        /// block faults, so the walk always finds it.
        fn replay(state: *TypedState, context: support.Context, piece: flat.Chunk) MachineError {
            for (piece.start..piece.end) |index| {
                const a = switch (shape) {
                    .leaf_leaf, .leaf_scalar => leftSlice(state)[index],
                    .scalar_leaf => left_class.unboxed(state.left.scalar),
                    .leaf_only => unreachable,
                };
                const b = switch (shape) {
                    .leaf_leaf, .scalar_leaf => rightSlice(state)[index],
                    .leaf_scalar => right_class.unboxed(state.right.scalar),
                    .leaf_only => unreachable,
                };
                _ = scalarBinary(operation, left_class.boxed(a), right_class.boxed(b)) catch |fault|
                    return state.faultAt(context, fault, index);
            }
            unreachable;
        }

        fn step(state: *TypedState, context: support.Context) MachineError!void {
            const range = try state.cursor.nextRange(context) orelse return;
            var block = Loops.Staging.init();
            var offset: usize = 0;
            while (offset != range.len()) {
                const piece = flat.blockRange(range, offset);
                switch (shape) {
                    .leaf_leaf => Loops.binary(body, leftSlice(state), rightSlice(state), piece, &block),
                    .leaf_scalar => Loops.binaryScalarRight(
                        body,
                        leftSlice(state),
                        right_class.unboxed(state.right.scalar),
                        piece,
                        &block,
                    ),
                    .scalar_leaf => Loops.binaryScalarLeft(
                        body,
                        left_class.unboxed(state.left.scalar),
                        rightSlice(state),
                        piece,
                        &block,
                    ),
                    .leaf_only => unreachable,
                }
                // Nothing is stored until the whole block is known clean: a
                // reused input buffer still holds the operands the replay reads.
                if (block.faulted) return replay(state, context, piece);
                state.output.store(out, piece.start, block.written());
                offset += piece.len();
            }
        }
    }.step;
}

/// One charged chunk of a unary typed operation.
fn unaryStep(comptime operation: UnaryOp, comptime operand_class: Number) TypedStep {
    const out = comptime unaryResult(operation, operand_class);
    const Loops = flat.Family(operand_class.Element(), void, out.Element());
    const body = struct {
        fn run(a: operand_class.Element()) ?out.Element() {
            const result = scalarUnary(operation, operand_class.boxed(a)) catch return null;
            return out.unboxed(result);
        }
    }.run;
    return struct {
        fn operandSlice(state: *const TypedState) []const operand_class.Element() {
            return if (state.left == .aliased)
                state.output.aliasedSlice(operand_class)
            else
                state.left.slice(operand_class);
        }

        fn replay(state: *TypedState, context: support.Context, piece: flat.Chunk) MachineError {
            for (piece.start..piece.end) |index| {
                const a = operandSlice(state)[index];
                _ = scalarUnary(operation, operand_class.boxed(a)) catch |fault|
                    return state.faultAt(context, fault, index);
            }
            unreachable;
        }

        fn step(state: *TypedState, context: support.Context) MachineError!void {
            const range = try state.cursor.nextRange(context) orelse return;
            var block = Loops.Staging.init();
            var offset: usize = 0;
            while (offset != range.len()) {
                const piece = flat.blockRange(range, offset);
                Loops.unary(body, operandSlice(state), piece, &block);
                if (block.faulted) return replay(state, context, piece);
                state.output.store(out, piece.start, block.written());
                offset += piece.len();
            }
        }
    }.step;
}

/// Acquires the typed result buffer: the operand's own buffer when it is solely
/// owned and its elements are the result's width, a fresh exact-size buffer
/// otherwise. Reuse consumes the caller's reference to that operand.
fn acquireOutput(
    evaluator: *Machine,
    comptime out: Number,
    reuse_candidate: ?*heap.OwnedValue,
    length: usize,
) error{OutOfMemory}!struct { output: TypedOutput, aliased: bool, root: ?Value } {
    if (reuse_candidate) |candidate| {
        const item = candidate.borrow();
        if (heap.UniqueLeafAdoption(out.kind()).claim(item.list, length)) |adoption| {
            return .{
                .output = switch (out) {
                    .integer => .{ .reuse_ints = adoption },
                    .real => .{ .reuse_reals = adoption },
                },
                .aliased = true,
                .root = candidate.take(),
            };
        }
    }
    const writer = try heap.LeafWriter(out.kind()).init(evaluator.allocator(), length);
    return .{
        .output = switch (out) {
            .integer => .{ .fresh_ints = writer },
            .real => .{ .fresh_reals = writer },
        },
        .aliased = false,
        .root = null,
    };
}

fn acquireOperand(comptime class: Number, item: Value) TypedOperand {
    return switch (class) {
        .integer => .{ .ints = heap.LeafReader(.leaf_i64).acquire(item.list) },
        .real => .{ .reals = heap.LeafReader(.leaf_f64).acquire(item.list) },
    };
}

fn startTypedDriver(
    evaluator: *Machine,
    state: TypedState,
    step: TypedStep,
) error{OutOfMemory}!bool {
    try evaluator.startDriver(TypedDriver{ .state = .init(state), .step = step });
    return true;
}

fn leafFlatScalarClass(item: Value) ?FlatScalarClass {
    if (leafNumber(item)) |number| return switch (number) {
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

fn buildNestedTypedCharBinaryFor(
    evaluator: *Machine,
    comptime operation: BinaryOp,
    left_item: Value,
    right_item: Value,
    report: FaultReport,
) MachineError!?NestedTyped {
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
    const fixed_result = left_class.isCharacter() and right_class.isCharacter() and
        (operation == .sub or switch (operation) {
            .eq, .ne, .lt, .gt, .le, .ge => true,
            else => false,
        });
    const dynamic_result = switch (operation) {
        .add => left_class.isCharacter() != right_class.isCharacter(),
        .sub => left_class.isCharacter() and right_class == .integer,
        .min, .max => left_class.isCharacter() and right_class.isCharacter(),
        else => false,
    };
    if (!fixed_result and !dynamic_result) return null;

    const flat_classes = [_]FlatScalarClass{ .integer, .char1, .char2, .char4 };
    inline for (flat_classes) |candidate_left| {
        inline for (flat_classes) |candidate_right| {
            inline for (binary_shapes) |candidate_shape| {
                if (candidate_left == left_class and candidate_right == right_class and candidate_shape == shape) {
                    if (fixed_result) {
                        var state = FixedCharState{
                            .left = .absent,
                            .right = .absent,
                            .output = try .init(evaluator.allocator(), length),
                            .cursor = .init(length),
                            .report = report,
                        };
                        var held_locally = true;
                        errdefer if (held_locally) state.retire(evaluator.releaseDomain());
                        state.left = if (candidate_shape == .scalar_leaf)
                            .{ .scalar = left_item }
                        else
                            acquireFlatScalarOperand(candidate_left, left_item);
                        state.right = if (candidate_shape == .leaf_scalar)
                            .{ .scalar = right_item }
                        else
                            acquireFlatScalarOperand(candidate_right, right_item);
                        const step = comptime fixedCharStep(
                            operation,
                            candidate_left,
                            candidate_right,
                            candidate_shape,
                        );
                        held_locally = false;
                        return .{ .fixed_char = .{ .state = state, .step = step } };
                    }
                    var state = DynamicCharState{
                        .left = .absent,
                        .right = .absent,
                        .cursor = .init(length),
                        .report = report,
                    };
                    var held_locally = true;
                    errdefer if (held_locally) state.retire(evaluator.releaseDomain());
                    state.left = if (candidate_shape == .scalar_leaf)
                        .{ .scalar = left_item }
                    else
                        acquireFlatScalarOperand(candidate_left, left_item);
                    state.right = if (candidate_shape == .leaf_scalar)
                        .{ .scalar = right_item }
                    else
                        acquireFlatScalarOperand(candidate_right, right_item);
                    const step = comptime dynamicCharStep(
                        operation,
                        candidate_left,
                        candidate_right,
                        candidate_shape,
                    );
                    held_locally = false;
                    return .{ .dynamic_char = .{ .state = state, .step = step } };
                }
            }
        }
    }
    unreachable;
}

fn buildNestedTypedCharBinary(
    evaluator: *Machine,
    operation: BinaryOp,
    left: Value,
    right: Value,
    report: FaultReport,
) MachineError!?NestedTyped {
    return switch (operation) {
        inline else => |selected| buildNestedTypedCharBinaryFor(evaluator, selected, left, right, report),
    };
}

fn startTypedCharBinary(
    evaluator: *Machine,
    comptime operation: BinaryOp,
    left: *heap.OwnedValue,
    right: *heap.OwnedValue,
    report: FaultReport,
) MachineError!bool {
    var typed = (try buildNestedTypedCharBinaryFor(
        evaluator,
        operation,
        left.borrow(),
        right.borrow(),
        report,
    )) orelse return false;
    switch (typed) {
        .fixed_char => |payload| try evaluator.startDriver(FixedCharDriver{
            .state = .init(payload.state),
            .step = payload.step,
        }),
        .dynamic_char => |payload| try evaluator.startDriver(DynamicCharDriver{
            .state = .init(payload.state),
            .step = payload.step,
        }),
        .numeric => unreachable,
    }
    // SAFETY: startDriver consumed the selected payload's owned state; poison
    // the tagged source so no later edit can accidentally reuse that owner.
    typed = undefined;
    return true;
}

fn firstFlatElement(item: Value) ?Value {
    if (item != .list or item.list.length() == 0) return null;
    return switch (item.list.kind()) {
        .leaf_i64 => .{ .int = heap.i64s(item.list)[0] },
        .leaf_f64 => .{ .float = heap.f64s(item.list)[0] },
        .leaf_char1 => .{ .char = heap.chars8(item.list)[0] },
        .leaf_char2 => .{ .char = heap.chars16(item.list)[0] },
        .leaf_char4 => .{ .char = @intCast(heap.chars32(item.list)[0]) },
        .leaf_symbol => .{ .symbol = heap.symbols(item.list)[0] },
        .generic_spine, .dict, .task, .module, .reserved_mask => null,
    };
}

/// A nonempty flat leaf whose first scalar faults needs no output allocation
/// and no traversal. This closes the typed boundary for character/symbol and
/// nonnumeric combinations without manufacturing a boxed fallback loop.
fn rejectUnsupportedFlatBinary(
    evaluator: *Machine,
    comptime operation: BinaryOp,
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
    _ = scalarBinary(
        operation,
        left_first orelse left,
        right_first orelse right,
    ) catch |fault| return scalarFailure(evaluator, fault, if (report.index) 0 else null);
    return false;
}

fn rejectUnsupportedFlatUnary(
    evaluator: *Machine,
    comptime operation: UnaryOp,
    operand: Value,
    report: FaultReport,
) MachineError!bool {
    const first = firstFlatElement(operand) orelse return false;
    _ = scalarUnary(operation, first) catch |fault|
        return scalarFailure(evaluator, fault, if (report.index) 0 else null);
    return false;
}

fn buildNestedTypedNumericBinaryFor(
    evaluator: *Machine,
    comptime operation: BinaryOp,
    left_item: Value,
    right_item: Value,
    report: FaultReport,
) MachineError!?NestedTyped {
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
    inline for (number_classes) |candidate_left| {
        inline for (number_classes) |candidate_right| {
            inline for (binary_shapes) |candidate_shape| {
                if (candidate_left == left_class and candidate_right == right_class and candidate_shape == shape) {
                    const maybe_out = comptime binaryResult(operation, candidate_left, candidate_right);
                    if (maybe_out == null) return null;
                    const out = comptime maybe_out.?;
                    const acquired = try acquireOutput(evaluator, out, null, length);
                    var state = TypedState{
                        .left = .absent,
                        .right = .absent,
                        .output = acquired.output,
                        .cursor = .init(length),
                        .report = report,
                        .root = null,
                    };
                    var held_locally = true;
                    errdefer if (held_locally) state.retire(evaluator.releaseDomain());
                    state.left = switch (candidate_shape) {
                        .leaf_leaf, .leaf_scalar => acquireOperand(candidate_left, left_item),
                        .scalar_leaf => .{ .scalar = left_item },
                        .leaf_only => unreachable,
                    };
                    state.right = switch (candidate_shape) {
                        .leaf_leaf, .scalar_leaf => acquireOperand(candidate_right, right_item),
                        .leaf_scalar => .{ .scalar = right_item },
                        .leaf_only => unreachable,
                    };
                    const step = comptime binaryStep(operation, candidate_left, candidate_right, candidate_shape);
                    held_locally = false;
                    return .{ .numeric = .{ .state = state, .step = step } };
                }
            }
        }
    }
    unreachable;
}

fn buildNestedTypedBinary(
    evaluator: *Machine,
    operation: BinaryOp,
    left: Value,
    right: Value,
    report: FaultReport,
) MachineError!?NestedTyped {
    if (try buildNestedTypedCharBinary(evaluator, operation, left, right, report)) |typed| return typed;
    const numeric = switch (operation) {
        inline else => |selected| try buildNestedTypedNumericBinaryFor(evaluator, selected, left, right, report),
    };
    if (numeric) |typed| return typed;
    _ = switch (operation) {
        inline else => |selected| try rejectUnsupportedFlatBinary(evaluator, selected, left, right, report),
    };
    return null;
}

fn buildNestedTypedUnaryFor(
    evaluator: *Machine,
    comptime operation: UnaryOp,
    operand: Value,
    report: FaultReport,
) MachineError!?NestedTyped {
    const class = leafNumber(operand) orelse {
        _ = try rejectUnsupportedFlatUnary(evaluator, operation, operand, report);
        return null;
    };
    const length: usize = @intCast(operand.list.length());
    if (length == 0) return null;
    inline for (number_classes) |candidate| {
        if (candidate == class) {
            const out = comptime unaryResult(operation, candidate);
            const acquired = try acquireOutput(evaluator, out, null, length);
            var state = TypedState{
                .left = .absent,
                .right = .absent,
                .output = acquired.output,
                .cursor = .init(length),
                .report = report,
                .root = null,
            };
            var held_locally = true;
            errdefer if (held_locally) state.retire(evaluator.releaseDomain());
            state.left = acquireOperand(candidate, operand);
            const step = comptime unaryStep(operation, candidate);
            held_locally = false;
            return .{ .numeric = .{ .state = state, .step = step } };
        }
    }
    unreachable;
}

fn buildNestedTypedUnary(
    evaluator: *Machine,
    operation: UnaryOp,
    operand: Value,
    report: FaultReport,
) MachineError!?NestedTyped {
    return switch (operation) {
        inline else => |selected| buildNestedTypedUnaryFor(evaluator, selected, operand, report),
    };
}

/// Dispatches one binary operation. Returns false when the operand shapes belong
/// to the generic route, having consumed nothing.
fn startTypedBinary(
    evaluator: *Machine,
    comptime operation: BinaryOp,
    left: *heap.OwnedValue,
    right: *heap.OwnedValue,
    report: FaultReport,
) MachineError!bool {
    if (try startTypedCharBinary(evaluator, operation, left, right, report)) return true;
    const left_item = left.borrow();
    const right_item = right.borrow();
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
        return rejectUnsupportedFlatBinary(evaluator, operation, left_item, right_item, report);

    const length = try conformingLength(evaluator, shape, left_item, right_item);
    // An empty result's representation is the generic route's to choose; there
    // is no typed work to do and no reason to fork that decision.
    if (length == 0) return false;

    const left_class = left_leaf orelse left_scalar.?;
    const right_class = right_leaf orelse right_scalar.?;

    inline for (number_classes) |candidate_left| {
        inline for (number_classes) |candidate_right| {
            inline for (binary_shapes) |candidate_shape| {
                if (candidate_left == left_class and
                    candidate_right == right_class and
                    candidate_shape == shape)
                {
                    // `min`/`max` on a mixed pair has no single result width; that
                    // combination is classified generic and never reaches here.
                    const maybe_out = comptime binaryResult(operation, candidate_left, candidate_right);
                    if (maybe_out == null) return false;
                    const out = comptime maybe_out.?;
                    // Reuse only the left leaf, and only when it is not also the
                    // right operand: a shared list refuses the claim, which is
                    // what makes self-aliasing safe without a special case.
                    const reuse: ?*heap.OwnedValue = if (candidate_shape == .leaf_scalar) left else null;
                    const acquired = try acquireOutput(evaluator, out, reuse, length);
                    var state = TypedState{
                        .left = .absent,
                        .right = .absent,
                        .output = acquired.output,
                        .cursor = flat.FlatCursor.init(length),
                        .report = report,
                        .root = acquired.root,
                    };
                    // Local ownership ends the moment the driver takes the
                    // state: a failing `startDriver` retires the copy it was
                    // handed, so retiring this one too would release the same
                    // capabilities twice.
                    var held_locally = true;
                    errdefer if (held_locally) state.retire(evaluator.releaseDomain());
                    state.left = if (acquired.aliased)
                        .aliased
                    else switch (candidate_shape) {
                        .leaf_leaf, .leaf_scalar => acquireOperand(candidate_left, left_item),
                        .scalar_leaf => TypedOperand{ .scalar = left_item },
                        .leaf_only => unreachable,
                    };
                    state.right = switch (candidate_shape) {
                        .leaf_leaf, .scalar_leaf => acquireOperand(candidate_right, right_item),
                        .leaf_scalar => TypedOperand{ .scalar = right_item },
                        .leaf_only => unreachable,
                    };
                    const step = comptime binaryStep(
                        operation,
                        candidate_left,
                        candidate_right,
                        candidate_shape,
                    );
                    held_locally = false;
                    return startTypedDriver(evaluator, state, step);
                }
            }
        }
    }
    return rejectUnsupportedFlatBinary(evaluator, operation, left_item, right_item, report);
}

fn startTypedUnary(
    evaluator: *Machine,
    comptime operation: UnaryOp,
    operand: *heap.OwnedValue,
    report: FaultReport,
) MachineError!bool {
    const item = operand.borrow();
    const class = leafNumber(item) orelse
        return rejectUnsupportedFlatUnary(evaluator, operation, item, report);
    const length: usize = @intCast(item.list.length());
    if (length == 0) return false;
    inline for (number_classes) |candidate| {
        if (candidate == class) {
            const out = comptime unaryResult(operation, candidate);
            const acquired = try acquireOutput(evaluator, out, operand, length);
            var state = TypedState{
                .left = .absent,
                .right = .absent,
                .output = acquired.output,
                .cursor = flat.FlatCursor.init(length),
                .report = report,
                .root = acquired.root,
            };
            // See the binary entry: local ownership ends at the hand-off.
            var held_locally = true;
            errdefer if (held_locally) state.retire(evaluator.releaseDomain());
            state.left = if (acquired.aliased) .aliased else acquireOperand(candidate, item);
            const step = comptime unaryStep(operation, candidate);
            held_locally = false;
            return startTypedDriver(evaluator, state, step);
        }
    }
    return false;
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
    if (constant == .list or constant == .dict or constant == .task) return false;
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
        left == .dict or right == .dict or left == .task or right == .task) return false;
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
/// accumulator's class must be a fixpoint of the operation, which is what makes
/// one monomorphic loop enough; a class that would change part way through
/// (an int accumulator meeting float elements) belongs to the generic route.
const TypedAccumulator = union(enum) {
    integer: i64,
    real: f64,
};

const TypedReduceState = struct {
    input: TypedOperand,
    /// Present for `scan`, whose result is the sequence of accumulators.
    output: ?TypedOutput,
    accumulator: TypedAccumulator,
    cursor: flat.FlatCursor,

    pub fn retire(self: *TypedReduceState, releases: *heap.ReleaseDomain) void {
        self.input.release(releases);
        if (self.output) |*output| output.retire(releases);
        self.output = null;
    }
};

const TypedReduceStep = *const fn (*TypedReduceState, support.Context) MachineError!void;

const TypedReduceDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    state: heap.Owned(TypedReduceState),
    step: TypedReduceStep,
    /// The recognized combinator's three stack values — list, initial
    /// accumulator, quotation — are released when the result is published, the
    /// same accounting the boxed reduction driver used.
    consumed: usize,

    pub fn advance(evaluator: *Machine, self: *TypedReduceDriver) MachineError!machine.WorkProgress {
        const context = support.Context{ .evaluator = evaluator };
        const state = self.state.borrowMut();
        try self.step(state, context);
        if (!state.cursor.complete()) return .yielded;
        state.input.release(evaluator.releaseDomain());
        const result: Value = if (state.output) |*output|
            output.finish()
        else switch (state.accumulator) {
            .integer => |number| .{ .int = number },
            .real => |number| .{ .float = number },
        };
        state.output = null;
        // The recognized combinator's own stack values go through the machine's
        // discard, which is the only sanctioned bulk release outside it.
        evaluator.discard(self.consumed);
        return .{ .output = result };
    }
};

fn reduceStep(
    comptime operation: BinaryOp,
    comptime accumulator_class: Number,
    comptime element_class: Number,
    comptime scan: bool,
) TypedReduceStep {
    const Staging = flat.Block(accumulator_class.Element());
    return struct {
        fn accumulated(state: *const TypedReduceState) accumulator_class.Element() {
            return switch (accumulator_class) {
                .integer => state.accumulator.integer,
                .real => state.accumulator.real,
            };
        }

        fn store(state: *TypedReduceState, element: accumulator_class.Element()) void {
            state.accumulator = switch (accumulator_class) {
                .integer => .{ .integer = element },
                .real => .{ .real = element },
            };
        }

        fn step(state: *TypedReduceState, context: support.Context) MachineError!void {
            const range = try state.cursor.nextRange(context) orelse return;
            const elements = state.input.slice(element_class);
            var block = Staging.init();
            var offset: usize = 0;
            while (offset != range.len()) {
                const piece = flat.blockRange(range, offset);
                block.reset();
                for (piece.start..piece.end) |index| {
                    const next = scalarBinary(
                        operation,
                        accumulator_class.boxed(accumulated(state)),
                        element_class.boxed(elements[index]),
                    ) catch |fault| {
                        // A sequential fold's first fault is the fault: there is
                        // no later element whose result could precede it, so the
                        // failure is reported where it happened. A recognized
                        // combinator's fault carries no list index, exactly as
                        // the per-element route reported it.
                        const diagnostic = scalarDiagnostic(fault);
                        return context.fail(diagnostic.kind, diagnostic.message);
                    };
                    store(state, accumulator_class.unboxed(next));
                    if (scan) {
                        block.items[index - piece.start] = accumulated(state);
                        block.len = index - piece.start + 1;
                    }
                }
                if (scan) state.output.?.store(accumulator_class, piece.start, block.written());
                offset += piece.len();
            }
        }
    }.step;
}

/// Whether a recognized `fold`/`scan` over these operands is a typed sequential
/// loop. The accumulator class must be a fixpoint of the operation so one
/// monomorphic loop covers every step.
pub fn typedReduceCandidate(operation: BinaryOp, input: Value, initial: Value) bool {
    const element_class = leafNumber(input) orelse return false;
    const accumulator_class = scalarNumber(initial) orelse return false;
    if (input.list.length() == 0) return false;
    var stable = false;
    inline for (number_classes) |candidate_accumulator| {
        inline for (number_classes) |candidate_element| {
            if (candidate_accumulator == accumulator_class and candidate_element == element_class) {
                switch (operation) {
                    inline else => |selected| {
                        const result = comptime binaryResult(selected, candidate_accumulator, candidate_element);
                        stable = result != null and result.? == candidate_accumulator;
                    },
                }
            }
        }
    }
    return stable;
}

/// Reached only if a guard and a dispatch disagreed, which the candidate
/// predicate exists to prevent; it is a domain error rather than a silent
/// second classification.
fn unexpectedReduceShape(evaluator: *Machine) MachineError {
    return evaluator.fail(.domain, "typed reduction reached an unclassified operand shape");
}

pub const IdiomReduceStart = *const fn (*Machine, Value, Value, bool) MachineError!void;

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
            ) MachineError!void {
                const element_class = leafNumber(input).?;
                const accumulator_class = scalarNumber(initial).?;
                const length: usize = @intCast(input.list.length());
                inline for (number_classes) |candidate_accumulator| {
                    inline for (number_classes) |candidate_element| {
                        if (candidate_accumulator == accumulator_class and
                            candidate_element == element_class)
                        {
                            // Only the fixpoint combinations exist; the guard
                            // above is what guarantees one of them is reached.
                            const maybe_out = comptime binaryResult(
                                selected,
                                candidate_accumulator,
                                candidate_element,
                            );
                            if (comptime maybe_out == null) return unexpectedReduceShape(evaluator);
                            const out = comptime maybe_out.?;
                            if (comptime out != candidate_accumulator) return unexpectedReduceShape(evaluator);
                            var state = TypedReduceState{
                                .input = acquireOperand(candidate_element, input),
                                .output = null,
                                .accumulator = switch (candidate_accumulator) {
                                    .integer => .{ .integer = initial.int },
                                    .real => .{ .real = initial.float },
                                },
                                .cursor = flat.FlatCursor.init(length),
                            };
                            var held_locally = true;
                            errdefer if (held_locally) state.retire(evaluator.releaseDomain());
                            inline for ([_]bool{ false, true }) |candidate_scan| {
                                if (candidate_scan == scan) {
                                    if (candidate_scan) {
                                        const writer = try heap.LeafWriter(out.kind()).init(
                                            evaluator.allocator(),
                                            length,
                                        );
                                        state.output = switch (out) {
                                            .integer => .{ .fresh_ints = writer },
                                            .real => .{ .fresh_reals = writer },
                                        };
                                    }
                                    const step = comptime reduceStep(
                                        selected,
                                        candidate_accumulator,
                                        candidate_element,
                                        candidate_scan,
                                    );
                                    held_locally = false;
                                    return evaluator.startDriver(TypedReduceDriver{
                                        .state = .init(state),
                                        .step = step,
                                        .consumed = 3,
                                    });
                                }
                            }
                        }
                    }
                }
                unreachable;
            }
        }.run,
    };
}
