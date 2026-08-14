const std = @import("std");
const ecl = @import("ecl");

const allocator = std.testing.allocator;

const Variant = enum { atom, empty, spine, float, failure };

test "every idiom entry hits across values empties spines floats and failures" {
    for (ecl.kernels.Registry.entries, 0..) |entry, index| {
        inline for (std.meta.tags(Variant)) |variant| {
            const source = try sourceFor(entry, variant);
            defer allocator.free(source);
            compareExecutions(source) catch |err| {
                std.log.err("idiom {d} variant {s} failed for `{s}`", .{ index, @tagName(variant), source });
                return err;
            };
        }
    }
}

const Execution = struct {
    runtime: ecl.session.Session,
    failure: ?ecl.value.Value,

    fn deinit(self: *Execution) void {
        if (self.failure) |failure| ecl.heap.releaseValue(allocator, failure);
        self.runtime.deinit();
    }
};

fn execute(source: []const u8, mode: ecl.machine.IdiomMode) !Execution {
    var runtime = try ecl.session.Session.init(allocator, &.{});
    errdefer runtime.deinit();
    runtime.idiom_mode = mode;
    const failure = switch (try runtime.runUnit("<idiom-differential>", source)) {
        .ok => null,
        .incomplete => return error.TestUnexpectedResult,
        .err => |item| item,
    };
    return .{ .runtime = runtime, .failure = failure };
}

fn compareExecutions(source: []const u8) !void {
    var automatic = try execute(source, .automatic);
    defer automatic.deinit();
    var generic = try execute(source, .generic_only);
    defer generic.deinit();
    try std.testing.expectEqual(@as(u64, 1), automatic.runtime.last_idiom_hits);
    try std.testing.expectEqual(@as(u64, 0), generic.runtime.last_idiom_hits);
    try std.testing.expectEqual(generic.failure != null, automatic.failure != null);
    if (automatic.failure) |failure| {
        const automatic_display = try ecl.print.toOwnedString(allocator, failure);
        defer allocator.free(automatic_display);
        const generic_display = try ecl.print.toOwnedString(allocator, generic.failure.?);
        defer allocator.free(generic_display);
        try std.testing.expectEqualStrings(generic_display, automatic_display);
        try expectValueIdentical(failure, generic.failure.?);
    } else {
        try expectStacksIdentical(automatic.runtime.stack.items, generic.runtime.stack.items);
        const automatic_display = try automatic.runtime.stackDisplay();
        defer allocator.free(automatic_display);
        const generic_display = try generic.runtime.stackDisplay();
        defer allocator.free(generic_display);
        try std.testing.expectEqualStrings(generic_display, automatic_display);
    }
}

fn sourceFor(entry: ecl.idioms.RegistryEntry, variant: Variant) ![]u8 {
    const phrase = try phraseSource(entry, variant);
    defer allocator.free(phrase);
    return switch (entry.operation) {
        .unary => |operation| std.fmt.allocPrint(
            allocator,
            "{s} ({s}) each",
            .{ unaryInput(operation, variant), phrase },
        ),
        .binary => |operation| switch (entry.context) {
            .each => std.fmt.allocPrint(
                allocator,
                "{s} ({s}) each",
                .{ binaryInput(operation, variant, false), phrase },
            ),
            .each2 => std.fmt.allocPrint(
                allocator,
                "{s} {s} ({s}) each2",
                .{
                    binaryInput(operation, variant, false),
                    binaryInput(operation, variant, true),
                    phrase,
                },
            ),
            .fold, .scan => std.fmt.allocPrint(
                allocator,
                "{s} {s} ({s}) {s}",
                .{
                    reductionInput(variant),
                    reductionInitial(operation),
                    phrase,
                    @tagName(entry.context),
                },
            ),
            .direct => unreachable,
        },
        .direct_sort => std.fmt.allocPrint(
            allocator,
            "{s} {s}",
            .{ sortInput(variant), entry.source_word.? },
        ),
    };
}

fn phraseSource(entry: ecl.idioms.RegistryEntry, variant: Variant) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (entry.pattern, 0..) |atom, index| {
        if (index > 0) try result.append(allocator, ' ');
        try result.appendSlice(allocator, switch (atom) {
            .constant => binaryConstant(entry.operation.binary, variant),
            .operation => entry.operation.spelling(),
            .core_word => |word| word.spelling(),
        });
    }
    return result.toOwnedSlice(allocator);
}

fn unaryInput(operation: ecl.kernels.numeric.UnaryOp, variant: Variant) []const u8 {
    return switch (variant) {
        .atom => switch (operation) {
            .sqrt => "[4 9]",
            .log => "[1.0 2.0]",
            .not_word => "[0 1]",
            .abs => "[-2 3]",
            .floor, .ceil, .round, .exp, .sin, .cos => "[1.25 2.5]",
            .neg => "[1 2]",
        },
        .empty => "[]",
        .spine => "[[1.25] [2.5]]",
        .float => "[0.1 0.2]",
        .failure => "[{}]",
    };
}

fn binaryInput(
    operation: ecl.kernels.numeric.BinaryOp,
    variant: Variant,
    right: bool,
) []const u8 {
    const boolean = operation == .and_word or operation == .or_word;
    return if (right) switch (variant) {
        .atom => if (boolean) "[1 0]" else "[4 5]",
        .empty => "[]",
        .spine => "[[4] [5]]",
        .float => "[0.3 0.4]",
        .failure => "[1]",
    } else switch (variant) {
        .atom => if (boolean) "[0 1]" else "[2 3]",
        .empty => "[]",
        .spine => "[[2] [3]]",
        .float => "[0.1 0.2]",
        .failure => "[{}]",
    };
}

fn binaryConstant(operation: ecl.kernels.numeric.BinaryOp, variant: Variant) []const u8 {
    const boolean = operation == .and_word or operation == .or_word;
    return switch (variant) {
        .failure => "{}",
        .float => "0.5",
        else => if (boolean) "1" else "4",
    };
}

fn reductionInitial(operation: ecl.kernels.numeric.BinaryOp) []const u8 {
    return switch (operation) {
        .add => "0",
        .mul => "1",
        .min => "10",
        .max => "0",
        else => unreachable,
    };
}

fn reductionInput(variant: Variant) []const u8 {
    return switch (variant) {
        .atom => "[1 2 3]",
        .empty => "[]",
        .spine => "[[1] [2] [3]]",
        .float => "[0.1 0.2 0.3]",
        .failure => "[{}]",
    };
}

fn sortInput(variant: Variant) []const u8 {
    return switch (variant) {
        .atom => "[3 1 2]",
        .empty => "[]",
        .spine => "[\"b\" \"a\"]",
        .float => "[0.1 -0.0 0.2]",
        .failure => "[1 \"x\"]",
    };
}

fn expectStacksIdentical(left: []const ecl.value.Value, right: []const ecl.value.Value) !void {
    try std.testing.expectEqual(left.len, right.len);
    for (left, right) |a, b| try expectValueIdentical(a, b);
}

fn expectValueIdentical(left: ecl.value.Value, right: ecl.value.Value) !void {
    try std.testing.expectEqual(left.tag(), right.tag());
    switch (left) {
        .int => |item| try std.testing.expectEqual(item, right.int),
        .float => |item| try std.testing.expectEqual(@as(u64, @bitCast(item)), @as(u64, @bitCast(right.float))),
        .char => |item| try std.testing.expectEqual(item, right.char),
        .symbol => |item| try std.testing.expectEqual(item, right.symbol),
        .word => |item| try std.testing.expectEqual(item, right.word),
        .task => |header| try std.testing.expectEqual(header, right.task),
        .list => |header| {
            try std.testing.expectEqual(header.kind(), right.list.kind());
            try std.testing.expectEqual(header.length(), right.list.length());
            for (0..@as(usize, @intCast(header.length()))) |index| {
                try expectValueIdentical(ecl.list.atUnchecked(left, index), ecl.list.atUnchecked(right, index));
            }
        },
        .dict => |header| {
            try std.testing.expectEqual(header.length(), right.dict.length());
            for (0..@as(usize, @intCast(header.length()))) |index| {
                try expectValueIdentical(ecl.dict.keyAt(header, index), ecl.dict.keyAt(right.dict, index));
                try expectValueIdentical(ecl.dict.valueAt(header, index), ecl.dict.valueAt(right.dict, index));
            }
        },
    }
}
