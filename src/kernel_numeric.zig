//! Checked scalar and flat-leaf arithmetic plus d.13 pervasive descent.
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
const HeapKind = value.HeapKind;
const Machine = support.Machine;
const MachineError = support.MachineError;
pub const BinaryOp = support.BinaryOp;
pub const UnaryOp = support.UnaryOp;

const ScalarError = error{ Type, Overflow, Domain };
const ScalarBinary = *const fn (Value, Value) ScalarError!Value;
const ScalarUnary = *const fn (Value) ScalarError!Value;
const binary_op_count = std.meta.fields(BinaryOp).len;
const heap_kind_count = std.meta.fields(HeapKind).len;
const BinaryMatrix = [binary_op_count][heap_kind_count][heap_kind_count]?ScalarBinary;

const binary_matrix: BinaryMatrix = blk: {
    @setEvalBranchQuota(10_000);
    var matrix = std.mem.zeroes(BinaryMatrix);
    for (std.meta.fields(BinaryOp)) |operation_field| {
        const operation: BinaryOp = @enumFromInt(operation_field.value);
        for (std.meta.fields(HeapKind)) |left_field| {
            const left: HeapKind = @enumFromInt(left_field.value);
            for (std.meta.fields(HeapKind)) |right_field| {
                const right: HeapKind = @enumFromInt(right_field.value);
                const left_sample = leafSample(left);
                const right_sample = leafSample(right);
                if (left_sample != null and right_sample != null and
                    supports(operation, left_sample.?, right_sample.?))
                {
                    matrix[operation_field.value][left_field.value][right_field.value] =
                        selectScalar(operation);
                }
            }
        }
    }
    break :blk matrix;
};

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    inline for (std.meta.fields(BinaryOp)) |field| {
        const operation: BinaryOp = @enumFromInt(field.value);
        try support.installPrimitive(core, operation.spelling(), bindBinary(operation));
    }
    inline for (std.meta.fields(UnaryOp)) |field| {
        const operation: UnaryOp = @enumFromInt(field.value);
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

pub fn scalarForIdiom(operation: BinaryOp, left: Value, right: Value) ?Value {
    if (!isAtom(left) or !isAtom(right)) return null;
    return selectScalar(operation)(left, right) catch null;
}

pub fn scalarUnaryForIdiom(operation: UnaryOp, operand: Value) ?Value {
    if (!isAtom(operand)) return null;
    return selectUnary(operation)(operand) catch null;
}

fn binaryPrimitive(evaluator: *Machine, operation: BinaryOp) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    var right_owned = true;
    defer if (right_owned) heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    var left_owned = true;
    defer if (left_owned) heap.releaseValue(evaluator.allocator(), left);

    const driver = try evaluator.allocator().create(PervadeDriver);
    errdefer evaluator.allocator().destroy(driver);
    driver.* = .{
        .left = left,
        .right = right,
        .cursor = try PervadeCursor.initBinary(evaluator.allocator(), operation, left, right),
    };
    left_owned = false;
    right_owned = false;
    evaluator.installWorkDriver(driver, PervadeDriver.advance, PervadeDriver.destroy);
}

fn unaryPrimitive(evaluator: *Machine, operation: UnaryOp) MachineError!void {
    const operand = try evaluator.popOwned();
    var operand_owned = true;
    defer if (operand_owned) heap.releaseValue(evaluator.allocator(), operand);
    const driver = try evaluator.allocator().create(PervadeDriver);
    errdefer evaluator.allocator().destroy(driver);
    driver.* = .{
        .left = operand,
        .cursor = try PervadeCursor.initUnary(evaluator.allocator(), operation, operand),
    };
    operand_owned = false;
    evaluator.installWorkDriver(driver, PervadeDriver.advance, PervadeDriver.destroy);
}

const PervadeDriver = struct {
    left: Value,
    right: ?Value = null,
    cursor: PervadeCursor,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *PervadeDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        return switch (try self.cursor.advance(evaluator, machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |result| completed: {
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *PervadeDriver = @ptrCast(@alignCast(raw));
        self.cursor.deinit();
        heap.releaseValue(allocator, self.left);
        if (self.right) |right| heap.releaseValue(allocator, right);
        allocator.destroy(self);
    }
};

pub const PervadeProgress = union(enum) { pending, complete: Value };

pub const PervadeCursor = struct {
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
        values: []Value,
        index: usize = 0,
        waiting: bool = false,
        materializer: ?storage.ValueMaterializer = null,
        result: ?Value = null,
        release_index: usize = 0,

        fn deinit(self: *ListFrame, allocator: std.mem.Allocator) void {
            if (self.materializer) |*materializer| materializer.deinit();
            for (self.values[self.release_index..self.index]) |item| heap.releaseValue(allocator, item);
            allocator.free(self.values);
            if (self.result) |result| heap.releaseValue(allocator, result);
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
        phase: enum { left, right, materialize, release } = .left,
        index: usize = 0,
        candidate: usize = 0,
        pair_count: usize = 0,
        waiting: bool = false,
        match_cursor: ?equal.MatchCursor = null,
        materializer: ?storage.DictMaterializer = null,
        result: ?Value = null,
        release_index: usize = 0,

        fn deinit(self: *DictFrame, allocator: std.mem.Allocator) void {
            if (self.match_cursor) |*cursor| cursor.deinit();
            if (self.materializer) |*materializer| materializer.deinit();
            for (self.pairs[self.release_index..self.pair_count]) |pair|
                heap.releaseValue(allocator, pair[1]);
            allocator.free(self.pairs);
            if (self.result) |result| heap.releaseValue(allocator, result);
        }
    };
    const Frame = union(enum) {
        binary: BinaryNode,
        unary: UnaryNode,
        list: ListFrame,
        dictionary: DictFrame,

        fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .binary, .unary => {},
                .list => |*frame| frame.deinit(allocator),
                .dictionary => |*frame| frame.deinit(allocator),
            }
        }
    };

    pub fn initBinary(
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
        return .{ .allocator = allocator, .frames = frames };
    }

    pub fn initUnary(
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
        return .{ .allocator = allocator, .frames = frames };
    }

    pub fn deinit(self: *PervadeCursor) void {
        if (self.last) |last| heap.releaseValue(self.allocator, last);
        while (self.frames.pop()) |frame_value| {
            var frame = frame_value;
            frame.deinit(self.allocator);
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
            const values = try self.allocator.alloc(Value, count);
            errdefer self.allocator.free(values);
            try self.frames.push(.{ .list = .{
                .operation = .{ .binary = node.operation },
                .left = node.left,
                .right = node.right,
                .left_scalar = node.left != .list,
                .right_scalar = node.right != .list,
                .depth = node.depth,
                .values = values,
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
            try self.frames.push(.{ .dictionary = .{
                .mode = .{ .unary = node.operation },
                .left = node.operand,
                .right = null,
                .depth = node.depth,
                .pairs = pairs,
            } });
            return;
        }
        if (node.operand == .list) {
            const count: usize = @intCast(node.operand.list.length());
            const values = try self.allocator.alloc(Value, count);
            errdefer self.allocator.free(values);
            try self.frames.push(.{ .list = .{
                .operation = .{ .unary = node.operation },
                .left = node.operand,
                .right = null,
                .left_scalar = false,
                .right_scalar = false,
                .depth = node.depth,
                .values = values,
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
        errdefer frame.deinit(self.allocator);
        if (frame.result) |result| {
            if (frame.release_index != frame.index) {
                heap.releaseValue(self.allocator, frame.values[frame.release_index]);
                frame.release_index += 1;
                try self.frames.reserve(1);
                try self.frames.push(.{ .list = frame.* });
                return true;
            }
            self.allocator.free(frame.values);
            frame.result = null;
            self.last = result;
            return true;
        }
        if (frame.waiting) {
            frame.values[frame.index] = self.last.?;
            self.last = null;
            frame.index += 1;
            frame.waiting = false;
        }
        if (frame.index != frame.values.len) {
            const index = frame.index;
            frame.waiting = true;
            try self.frames.reserve(2);
            try self.frames.push(.{ .list = frame.* });
            switch (frame.operation) {
                .binary => |operation| try self.frames.push(.{ .binary = .{
                    .operation = operation,
                    .left = if (frame.left_scalar) frame.left else list.atUnchecked(frame.left, index),
                    .right = if (frame.right_scalar) frame.right.? else list.atUnchecked(frame.right.?, index),
                    .depth = frame.depth + 1,
                    .logical_index = index,
                } }),
                .unary => |operation| try self.frames.push(.{ .unary = .{
                    .operation = operation,
                    .operand = list.atUnchecked(frame.left, index),
                    .depth = frame.depth + 1,
                    .logical_index = index,
                } }),
            }
            return true;
        }
        if (frame.materializer == null)
            frame.materializer = .init(self.allocator, frame.values);
        try self.frames.reserve(1);
        switch (try frame.materializer.?.advance(budget)) {
            .pending => {
                try self.frames.push(.{ .list = frame.* });
                return false;
            },
            .complete => |result| {
                frame.result = result;
                try self.frames.push(.{ .list = frame.* });
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
        try self.frames.push(.{ .dictionary = .{
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
        } });
    }

    fn advanceDict(
        self: *PervadeCursor,
        _: *Machine,
        frame: *DictFrame,
        budget: usize,
    ) MachineError!bool {
        errdefer frame.deinit(self.allocator);
        if (frame.phase == .release) {
            if (frame.release_index != frame.pair_count) {
                heap.releaseValue(self.allocator, frame.pairs[frame.release_index][1]);
                frame.release_index += 1;
                try self.frames.reserve(1);
                try self.frames.push(.{ .dictionary = frame.* });
                return true;
            }
            self.allocator.free(frame.pairs);
            const result = frame.result.?;
            frame.result = null;
            self.last = result;
            return true;
        }
        if (frame.waiting) {
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
                    try self.frames.push(.{ .dictionary = frame.* });
                    return false;
                },
                .duplicate_key => unreachable,
                .complete => |result| {
                    frame.materializer.?.deinit();
                    frame.materializer = null;
                    frame.result = result;
                    frame.phase = .release;
                    try self.frames.push(.{ .dictionary = frame.* });
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
                    try self.frames.push(.{ .dictionary = frame.* });
                    return true;
                }
                const index = frame.index;
                frame.pairs[frame.pair_count][0] = dict.keyAt(dictionary.dict, index);
                frame.waiting = true;
                try self.frames.reserve(2);
                try self.frames.push(.{ .dictionary = frame.* });
                switch (frame.mode) {
                    .unary => |operation| try self.frames.push(.{ .unary = .{
                        .operation = operation,
                        .operand = dict.valueAt(dictionary.dict, index),
                        .depth = frame.depth + 1,
                        .logical_index = index,
                    } }),
                    .left => |operation| try self.frames.push(.{ .binary = .{
                        .operation = operation,
                        .left = dict.valueAt(dictionary.dict, index),
                        .right = frame.right.?,
                        .depth = frame.depth + 1,
                        .logical_index = index,
                    } }),
                    .right => |operation| try self.frames.push(.{ .binary = .{
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
                    try self.frames.push(.{ .dictionary = frame.* });
                    return true;
                }
                if (frame.candidate == other_count) {
                    const key = dict.keyAt(source.dict, frame.index);
                    const item = dict.valueAt(source.dict, frame.index);
                    heap.retainValue(item);
                    frame.pairs[frame.pair_count] = .{ key, item };
                    frame.pair_count += 1;
                    frame.index += 1;
                    frame.candidate = 0;
                    try self.frames.reserve(1);
                    try self.frames.push(.{ .dictionary = frame.* });
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
                        try self.frames.push(.{ .dictionary = frame.* });
                        return false;
                    },
                    .complete => |matches| {
                        frame.match_cursor.?.deinit();
                        frame.match_cursor = null;
                        if (!matches) {
                            frame.candidate += 1;
                            try self.frames.push(.{ .dictionary = frame.* });
                            return false;
                        }
                        if (frame.phase == .right) {
                            frame.index += 1;
                            frame.candidate = 0;
                            try self.frames.push(.{ .dictionary = frame.* });
                            return false;
                        }
                        const index = frame.index;
                        const candidate = frame.candidate;
                        frame.pairs[frame.pair_count][0] = dict.keyAt(frame.left.dict, index);
                        frame.waiting = true;
                        try self.frames.push(.{ .dictionary = frame.* });
                        try self.frames.push(.{ .binary = .{
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

fn selectLeafBinary(operation: BinaryOp, left: HeapKind, right: HeapKind) ?ScalarBinary {
    return binary_matrix[@intFromEnum(operation)][@intFromEnum(left)][@intFromEnum(right)];
}

pub fn matrixEntryForTest(operation: BinaryOp, left: HeapKind, right: HeapKind) bool {
    return selectLeafBinary(operation, left, right) != null;
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
    if (adjusted < 0 or adjusted > 0x10ffff) return error.Domain;
    const result: u32 = @intCast(adjusted);
    if (result >= 0xd800 and result <= 0xdfff) return error.Domain;
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

fn supports(operation: BinaryOp, left: Value, right: Value) bool {
    return switch (operation) {
        .add => (left.isNumber() and right.isNumber()) or
            (left == .char and right == .int) or (left == .int and right == .char),
        .sub => (left.isNumber() and right.isNumber()) or
            (left == .char and (right == .char or right == .int)),
        .mul, .div, .pow, .atan2 => left.isNumber() and right.isNumber(),
        .int_div, .mod, .and_word, .or_word => left == .int and right == .int,
        .min, .max, .eq, .ne, .lt, .gt, .le, .ge => (left.isNumber() and right.isNumber()) or (left == .char and right == .char),
    };
}

fn leafSample(kind: HeapKind) ?Value {
    return switch (kind) {
        .leaf_i64 => .{ .int = 0 },
        .leaf_f64 => .{ .float = 0.0 },
        .leaf_char1, .leaf_char2, .leaf_char4 => .{ .char = 0 },
        .leaf_symbol => .{ .symbol = 0 },
        .generic_spine, .dict, .task, .reserved_mask => null,
    };
}

fn isAtom(item: Value) bool {
    return switch (item) {
        .int, .float, .char, .symbol, .word => true,
        .list, .dict, .task => false,
    };
}

test "numeric dispatch matrix rejects symbols explicitly" {
    try std.testing.expect(selectLeafBinary(.add, .leaf_i64, .leaf_f64) != null);
    try std.testing.expect(selectLeafBinary(.add, .leaf_symbol, .leaf_i64) == null);
    try std.testing.expect(selectLeafBinary(.sub, .leaf_char1, .leaf_char4) != null);
}

test "numeric scalar semantics include exact mixed comparison and chars" {
    const large: i64 = (1 << 53) + 1;
    try std.testing.expectEqual(
        @as(i64, 0),
        (try scalarBinary(.eq, .{ .int = large }, .{ .float = @floatFromInt(large - 1) })).int,
    );
    try std.testing.expectEqual(
        @as(u32, 'b'),
        (try scalarBinary(.add, .{ .char = 'a' }, .{ .int = 1 })).char,
    );
    try std.testing.expectError(error.Domain, scalarBinary(.div, .{ .int = 1 }, .{ .int = 0 }));
}
