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

const Value = value.Value;
const Machine = support.Machine;
const MachineError = support.MachineError;
pub const BinaryOp = support.BinaryOp;
pub const UnaryOp = support.UnaryOp;

const ScalarError = error{ Type, Overflow, Domain };
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

fn binaryPrimitive(evaluator: *Machine, operation: BinaryOp) MachineError!void {
    try evaluator.require(2);
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();

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

fn unaryPrimitive(evaluator: *Machine, operation: UnaryOp) MachineError!void {
    var operand = try evaluator.popValue();
    defer operand.deinit();
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

        fn deinit(self: *Frame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .binary, .unary => {},
                .list => |*frame| frame.deinit(releases),
                .dictionary => |*frame| frame.deinit(releases, allocator),
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

fn scalarFailure(evaluator: *Machine, fault: ScalarError, index: ?usize) MachineError {
    const kind: @import("machine.zig").ErrorKind = switch (fault) {
        error.Type => .type,
        error.Overflow => .overflow,
        error.Domain => .domain,
    };
    const message = switch (fault) {
        error.Type => "kernel received incompatible scalar operands",
        error.Overflow => "kernel arithmetic overflow",
        error.Domain => "kernel arithmetic is outside its domain",
    };
    if (index) |logical_index| return evaluator.failAtIndex(kind, message, logical_index);
    return evaluator.fail(kind, message);
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
    };
}

fn scalarUnary(comptime operation: UnaryOp, operand: Value) ScalarError!Value {
    return switch (operation) {
        .not_word => .{ .int = @intFromBool(!(try boolean(operand))) },
        .neg => switch (operand) {
            .int => |integer| .{ .int = std.math.sub(i64, 0, integer) catch return error.Overflow },
            .float => |number| try checkedFloat(-number, !std.math.isFinite(number)),
            .char, .symbol, .word, .list, .dict, .task => error.Type,
        },
        .abs => switch (operand) {
            .int => |integer| if (integer == std.math.minInt(i64))
                error.Overflow
            else
                .{ .int = if (integer < 0) -integer else integer },
            .float => |number| try checkedFloat(@abs(number), !std.math.isFinite(number)),
            .char, .symbol, .word, .list, .dict, .task => error.Type,
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
            .char, .symbol, .word, .list, .dict, .task => error.Type,
        },
        .floor, .ceil, .round => switch (operand) {
            .int => operand,
            .float => |number| floatToInt(switch (operation) {
                .floor => @floor(number),
                .ceil => @ceil(number),
                .round => @round(number),
                else => unreachable,
            }),
            .char, .symbol, .word, .list, .dict, .task => error.Type,
        },
        .exp, .log, .sin, .cos => transcendental(operation, operand),
    };
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
        .neg, .abs, .sqrt, .floor, .ceil, .round, .not_word => unreachable,
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
        .char, .symbol, .word, .list, .dict, .task => unreachable,
    };
}
