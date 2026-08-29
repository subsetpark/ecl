const std = @import("std");
const ecl = @import("ecl");

const allocator = std.testing.allocator;

/// Session bootstrap dominates this harness: every case builds two full
/// sessions, and each evaluates the embedded prelude. `std.testing.allocator`
/// captures a stack trace per allocation, which makes one bootstrap cost
/// ~270ms against ~14ms without them. Dropping the traces keeps both leak
/// detection and the safety checks; a leak still fails the run, just without
/// an allocation site — which the failing case's logged source already gives.
/// Source strings stay on `std.testing.allocator`, where the volume is small
/// and the attribution is worth having.
const SessionHeap = std.heap.DebugAllocator(.{ .stack_trace_frames = 0 });

fn retireHeap(heap: *SessionHeap) void {
    if (heap.deinit() == .leak) std.debug.panic("idiom differential leaked session memory", .{});
}

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
        if (self.failure) |failure| self.runtime.release(failure);
        self.runtime.deinit();
    }
};

fn execute(
    source: []const u8,
    mode: ecl.machine.IdiomMode,
    session_allocator: std.mem.Allocator,
) !Execution {
    var runtime = try ecl.session.Session.init(session_allocator, &.{});
    errdefer runtime.deinit();
    runtime.setIdiomMode(mode);
    const warmup: ?[]const u8 = if (std.mem.indexOf(u8, source, "str.format") != null)
        "\"\" str.upper pop"
    else if (std.mem.indexOf(u8, source, "distinct") != null)
        "{} dict.keys pop"
    else
        null;
    if (warmup) |stdlib_source| switch (try runtime.runUnit("<idiom-warmup>", stdlib_source)) {
        .ok => {},
        .incomplete => return error.TestUnexpectedResult,
        .err => |failure| {
            runtime.release(failure);
            return error.TestUnexpectedResult;
        },
    };
    const failure = switch (try runtime.runUnit("<idiom-differential>", source)) {
        .ok => null,
        .incomplete => return error.TestUnexpectedResult,
        .err => |item| item,
    };
    return .{ .runtime = runtime, .failure = failure };
}

fn compareExecutions(source: []const u8) !void {
    var automatic_heap: SessionHeap = .init;
    defer retireHeap(&automatic_heap);
    var generic_heap: SessionHeap = .init;
    defer retireHeap(&generic_heap);
    var automatic = try execute(source, .automatic, automatic_heap.allocator());
    defer automatic.deinit();
    var generic = try execute(source, .generic_only, generic_heap.allocator());
    defer generic.deinit();
    try std.testing.expectEqual(@as(u64, 1), automatic.runtime.lastIdiomHits());
    try std.testing.expectEqual(@as(u64, 0), generic.runtime.lastIdiomHits());
    try std.testing.expectEqual(generic.failure != null, automatic.failure != null);
    if (automatic.failure == null) {
        try expectStacksEquivalent(automatic.runtime.stackItems(), generic.runtime.stackItems());
        var automatic_display = try automatic.runtime.stackDisplay();
        defer automatic_display.deinit();
        var generic_display = try generic.runtime.stackDisplay();
        defer generic_display.deinit();
        try std.testing.expectEqualStrings(generic_display.bytes(), automatic_display.bytes());
    }
}

fn sourceFor(entry: ecl.idioms.RegistryEntry, variant: Variant) ![]u8 {
    if (entry.context == .direct) return directSource(entry, variant);
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
            .zip_with => std.fmt.allocPrint(
                allocator,
                "{s} {s} ({s}) zip-with",
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
        .match => std.fmt.allocPrint(
            allocator,
            "{s} ({s}) each",
            .{ matchInput(variant), phrase },
        ),
        .direct => unreachable,
    };
}

fn directSource(entry: ecl.idioms.RegistryEntry, variant: Variant) ![]u8 {
    return switch (entry.operation) {
        .unary => |operation| std.fmt.allocPrint(
            allocator,
            "{s} {s}",
            .{ unaryDirectInput(operation, variant), entry.source_word.? },
        ),
        .binary => |operation| std.fmt.allocPrint(
            allocator,
            "{s} {s} {s}",
            .{
                binaryInput(operation, variant, false),
                binaryInput(operation, variant, true),
                entry.source_word.?,
            },
        ),
        .match => unreachable,
        .direct => |operation| std.fmt.allocPrint(
            allocator,
            "{s} {s}",
            .{
                directInput(operation, variant),
                if (operation == .str_format) operation.spelling() else entry.source_word.?,
            },
        ),
    };
}

fn phraseSource(entry: ecl.idioms.RegistryEntry, variant: Variant) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (entry.pattern, 0..) |atom, index| {
        if (index > 0) try result.append(allocator, ' ');
        switch (atom) {
            // The capture wrapper is spelled as the one-element list that
            // `literal` builds at runtime — the same value either way.
            .capture => {
                try result.append(allocator, '(');
                try result.appendSlice(allocator, constantFor(entry.operation, variant));
                try result.append(allocator, ')');
            },
            else => try result.appendSlice(allocator, switch (atom) {
                .constant => constantFor(entry.operation, variant),
                .literal => "0",
                .operation => entry.operation.spelling(),
                .word => |word| word.spelling,
                .capture => unreachable,
            }),
        }
    }
    return result.toOwnedSlice(allocator);
}

fn constantFor(operation: ecl.idioms.Operation, variant: Variant) []const u8 {
    return switch (operation) {
        .binary => |binary| binaryConstant(binary, variant),
        .match => matchConstant(variant),
        else => unreachable,
    };
}

fn matchInput(variant: Variant) []const u8 {
    return switch (variant) {
        .atom => "[1 2 1]",
        .empty => "[]",
        .spine => "[[1] [2] [1]]",
        .float => "[1.0 2.0]",
        .failure => "[{} {'a 1}]",
    };
}

fn matchConstant(variant: Variant) []const u8 {
    return switch (variant) {
        .atom, .empty, .float => "1",
        .spine => "[1]",
        .failure => "{'a 1}",
    };
}

fn unaryDirectInput(operation: ecl.kernels.numeric.UnaryOp, variant: Variant) []const u8 {
    if (operation == .bnot) return switch (variant) {
        .atom, .float => "-2",
        .empty => "[]",
        .spine => "[[-2] [3]]",
        .failure => "{}",
    };
    return switch (variant) {
        .atom => switch (operation) {
            .sqrt => "4",
            .log => "1.0",
            .not_word => "0",
            .bnot => "-2",
            .abs, .neg => "-2",
            .floor, .ceil, .round, .exp, .sin, .cos => "1.25",
        },
        .empty => "[]",
        .spine => "[[-2] [3]]",
        .float => "-0.0",
        .failure => "{}",
    };
}

fn unaryInput(operation: ecl.kernels.numeric.UnaryOp, variant: Variant) []const u8 {
    if (operation == .bnot) return switch (variant) {
        .atom, .float => "[-2 3]",
        .empty => "[]",
        .spine => "[[-2] [3]]",
        .failure => "[{}]",
    };
    return switch (variant) {
        .atom => switch (operation) {
            .sqrt => "[4 9]",
            .log => "[1.0 2.0]",
            .not_word => "[0 1]",
            .bnot => "[-2 3]",
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

fn isBitwise(operation: ecl.kernels.numeric.BinaryOp) bool {
    return switch (operation) {
        .band, .bor, .bxor, .bsl, .bsr => true,
        else => false,
    };
}

fn binaryInput(
    operation: ecl.kernels.numeric.BinaryOp,
    variant: Variant,
    right: bool,
) []const u8 {
    const boolean = operation == .and_word or operation == .or_word;
    // Bitwise words are int-only, so a float variant would compare two
    // identical 'type errors instead of two values. Feed them ints, and keep
    // the right operand inside the 0..63 shift domain.
    if (isBitwise(operation)) return if (right) switch (variant) {
        .atom, .float => "[1 2]",
        .empty => "[]",
        .spine => "[[1] [2]]",
        .failure => "[1]",
    } else switch (variant) {
        .atom, .float => "[6 12]",
        .empty => "[]",
        .spine => "[[6] [12]]",
        .failure => "[{}]",
    };
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
    if (isBitwise(operation)) return switch (variant) {
        .failure => "{}",
        else => "3",
    };
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

fn directInput(operation: ecl.idioms.DirectOp, variant: Variant) []const u8 {
    return switch (operation) {
        .sort => sortInput(variant),
        .first, .rest, .reverse => switch (variant) {
            .atom => "[1 2 3]",
            .empty => "[]",
            .spine => "[[1] [2]]",
            .float => "[0.1 -0.0 0.2]",
            .failure => "1",
        },
        .distinct => switch (variant) {
            .atom => "[1 2 1]",
            .empty => "[]",
            .spine => "[[1] [2] [1]]",
            .float => "[0.1 -0.0 0.1]",
            .failure => "1",
        },
        // `dip` needs a value below the protected one for its quotation to
        // work on, and quotations built only from builtins so the pass counts
        // one recognition rather than a nested one. The failure variant fails
        // inside the quotation: a non-list top would fall through to the
        // generic composition instead, which is a fallback rather than a
        // fused-versus-generic comparison.
        .dip => switch (variant) {
            .atom => "5 9 (1 +)",
            .empty => "[] 9 (len)",
            .spine => "[[1] [2]] 9 (len)",
            .float => "0.5 9 (1 +)",
            .failure => "'sym 9 (1 +)",
        },
        .str_format => switch (variant) {
            .atom => "[\"Ada\" 2] \"name={} n={}\"",
            .empty => "[] \"\"",
            .spine => "[[1] {'a 2}] \"{} {}\"",
            .float => "[0.1] \"{}\"",
            .failure => "[] \"{\"",
        },
    };
}

fn expectStacksEquivalent(left: []const ecl.value.Value, right: []const ecl.value.Value) !void {
    try std.testing.expectEqual(left.len, right.len);
    for (left, right) |a, b| try expectValueEquivalent(a, b);
}

/// Compare language-visible values without treating an invisible packed leaf
/// choice as behavior. Numeric leaves may differ when one execution can infer
/// byte range earlier than the other; indexing must nevertheless expose the
/// same integers, while floats remain bit-identical.
fn expectValueEquivalent(left: ecl.value.Value, right: ecl.value.Value) !void {
    try std.testing.expectEqual(left.tag(), right.tag());
    switch (left) {
        .int => |item| try std.testing.expectEqual(item, right.int),
        .float => |item| try std.testing.expectEqual(@as(u64, @bitCast(item)), @as(u64, @bitCast(right.float))),
        .char => |item| try std.testing.expectEqual(item, right.char),
        .symbol => |item| try std.testing.expectEqual(item, right.symbol),
        .word => |item| try std.testing.expectEqual(item, right.word),
        .task => |header| try std.testing.expectEqual(header, right.task),
        .module => |header| try std.testing.expectEqual(header, right.module),
        .unit_plan => |header| try std.testing.expectEqual(header, right.unit_plan),
        .list => |header| {
            try std.testing.expectEqual(header.length(), right.list.length());
            for (0..@as(usize, @intCast(header.length()))) |index| {
                try expectValueEquivalent(ecl.list.atUnchecked(left, index), ecl.list.atUnchecked(right, index));
            }
        },
        .dict => |header| {
            try std.testing.expectEqual(header.length(), right.dict.length());
            for (0..@as(usize, @intCast(header.length()))) |index| {
                try expectValueEquivalent(ecl.dict.keyAt(header, index), ecl.dict.keyAt(right.dict, index));
                try expectValueEquivalent(ecl.dict.valueAt(header, index), ecl.dict.valueAt(right.dict, index));
            }
        },
    }
}

/// Full observational comparison of the two execution modes: success or
/// failure alike, stack values (bit-identical floats via
/// expectValueEquivalent), rendered representation, and — unlike the
/// exhaustive harness above — the complete error dict on failure.
fn compareModesExactly(source: []const u8) !void {
    var automatic_heap: SessionHeap = .init;
    defer retireHeap(&automatic_heap);
    var generic_heap: SessionHeap = .init;
    defer retireHeap(&generic_heap);
    var automatic = try execute(source, .automatic, automatic_heap.allocator());
    defer automatic.deinit();
    var generic = try execute(source, .generic_only, generic_heap.allocator());
    defer generic.deinit();

    try std.testing.expectEqual(generic.failure != null, automatic.failure != null);
    if (automatic.failure) |automatic_failure| {
        var automatic_rendered = try automatic.runtime.renderValue(automatic_failure);
        defer automatic_rendered.deinit();
        var generic_rendered = try generic.runtime.renderValue(generic.failure.?);
        defer generic_rendered.deinit();
        try std.testing.expectEqualStrings(generic_rendered.bytes(), automatic_rendered.bytes());
        return;
    }
    try expectStacksEquivalent(automatic.runtime.stackItems(), generic.runtime.stackItems());
    var automatic_display = try automatic.runtime.stackDisplay();
    defer automatic_display.deinit();
    var generic_display = try generic.runtime.stackDisplay();
    defer generic_display.deinit();
    try std.testing.expectEqualStrings(generic_display.bytes(), automatic_display.bytes());
}

test "idioms: capture shapes preserve generic behavior" {
    // The literal-capture shape `((v) first)` is what `literal` builds and
    // what `partial` prefixes onto a quotation. These sources build the
    // shape the way programs do, rather than spelling the list literally as
    // the exhaustive harness above does, so recognition is proven against
    // the runtime-constructed value.
    const sources = [_][]const u8{
        // Constant on the right, then the swapped (constant-left) form.
        "[1 2 3] 3 (+) partial each",
        "[1 2 3] 3 (swap -) partial each",
        "[1 2 3] 3 (-) partial each",
        // Nested spines, empties, and dict pervasion.
        "[[1 2] [3]] 10 (*) partial each",
        "[] 4 (+) partial each",
        // Floats must stay bit-identical, including signed zero.
        "[0.1 0.2 0.3] 0.3 (+) partial each",
        "[0.0 -0.0] -0.0 (+) partial each",
        "[1 2] 0.5 (swap /) partial each",
        // Failures: type, overflow, and domain must carry identical dicts.
        "[1 2] {} (+) partial each",
        "[9223372036854775807 1] 1 (+) partial each",
        "[1 0] 0 (swap div) partial each",
        // Shapes that must NOT be recognized still agree with the generic
        // path: a multi-element wrapper, a longer phrase, and a capture whose
        // captured element is itself a word.
        "[1 2 3] ((3 4) first +) each",
        "[1 2 3] ((1) first pop 7 +) each",
        "[1 2 3] ((dup) first +) each",
        // The `first` guard is load-bearing, not decorative: the pattern
        // demands the core source binding, so a session definition of `first`
        // must send an otherwise perfectly capture-shaped phrase down the
        // generic path — where the shadow actually runs. Recognizing through
        // the shadow would silently compute the unshadowed answer.
        "(pop 99) 'first def [1 2 3] 3 (+) partial each",
        "(pop 99) 'first def [1 2 3] 3 (swap -) partial each",
    };
    for (sources) |source| {
        compareModesExactly(source) catch |err| {
            std.log.err("capture-shape differential failed for `{s}`", .{source});
            return err;
        };
    }

    // A recognized capture fuses the whole `each` into one kernel run: one
    // hit for the three elements, and `first` never executes. A rejected
    // wrapper falls through to the generic frame machine, which then runs
    // `first` once per element — three hits from `first`'s own direct
    // recognition. The contrast is the proof that selection is shape-driven.
    try expectHits("[1 2 3] 3 (+) partial each", 1);
    try expectHits("[1 2 3] 3 (swap -) partial each", 1);
    try expectHits("[1 2 3] ((3 4) first +) each", 3);
    // Shadowing `first` takes the *capture* entry out of play -- which is why
    // this is three direct hits and not one fused hit -- but the three hits are
    // core `first`, not the shadow. `partial` is `(swap literal swap compose)`
    // and `literal` is `(wrap (first) cons)`, so the `(first)` token lives in
    // prelude source and seals to core; `each` runs that captured quotation once
    // per element, and each execution earns its own direct recognition.
    //
    // This expectation was 0 before scope-on-the-word, and the 0 was measuring
    // the leak the sealing rule exists to remove: a session `def` reaching into
    // prelude internals. What proves the shadow no longer runs there is the
    // value, not the count -- `(pop 99)` in that position would destroy the
    // capture, yet the result is byte-identical to the unshadowed baseline:
    //
    //   (pop 99) 'first def [1 2 3] 3 (+) partial each   =>  [4 5 6]
    //   [1 2 3] 3 (+) partial each                       =>  [4 5 6]
    //   (pop 99) 'first def [1 2 3] first                =>  99
    //
    // The third line is the control: the shadow is live, just sealed out of
    // prelude internals, exactly as `table.where` does not become the `where`
    // that `filter` is written against.
    try expectHits("(pop 99) 'first def [1 2 3] 3 (+) partial each", 3);
}

test "idioms: an ordinary replacement cannot inherit stdlib recognition" {
    const source =
        "((pop pop \"ordinary\") 'format-valid defp " ++
        "(format-valid) 'format def) 'str @defm " ++
        "[] \"\" str.format";
    var heap: SessionHeap = .init;
    defer retireHeap(&heap);
    var run = try execute(source, .automatic, heap.allocator());
    defer run.deinit();
    try std.testing.expect(run.failure == null);
    try std.testing.expectEqual(@as(u64, 0), run.runtime.lastIdiomHits());
    var display = try run.runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("\"ordinary\"", display.bytes());
}

fn expectHits(source: []const u8, expected: u64) !void {
    var heap: SessionHeap = .init;
    defer retireHeap(&heap);
    var run = try execute(source, .automatic, heap.allocator());
    defer run.deinit();
    try std.testing.expectEqual(expected, run.runtime.lastIdiomHits());
}
