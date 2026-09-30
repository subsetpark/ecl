//! Budget properties every `*WorkBudget` cursor must hold, checked through each
//! cursor's public advance against generated inputs:
//!
//! - it finishes when lent one unit at a time, and at random grains;
//! - it returns `pending` only once the grant is spent, so a pause is never a
//!   phase boundary in disguise and a hand-off never starves a nested cursor;
//! - its result does not depend on the grain it was driven at;
//! - its total charge is bounded by its input.
const std = @import("std");
const minish = @import("minish");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const dict = @import("../dict.zig");
const equal = @import("../equal.zig");
const doc = @import("../doc.zig");
const print = @import("../print.zig");
const poll = @import("../poll.zig");
const storage = @import("../kernel_storage.zig");
const testgen = @import("testgen.zig");

const Value = testgen.Value;
const allocator = std.testing.allocator;

const Grain = enum { one, random };

const Fixture = struct {
    cleanup: heap.testing.Cleanup,

    fn init() Fixture {
        return .{ .cleanup = heap.testing.Cleanup.init(allocator) };
    }
    fn deinit(self: *Fixture) void {
        self.cleanup.deinit();
    }
    fn releases(self: *Fixture) *heap.ReleaseDomain {
        return self.cleanup.domain();
    }
    fn release(self: *Fixture, item: Value) void {
        self.cleanup.releaseValue(item);
    }
};

/// Drives one fresh cursor per grain and checks it against the adapter's
/// unbounded reference. `A` supplies `Cursor`, `Outcome`, `start`, `step`,
/// `finish`, `eql`, and `releaseOutcome`.
fn checkCursor(
    comptime A: type,
    fixture: *Fixture,
    input: A.Input,
    reference: A.Outcome,
    bound: usize,
    seed: u64,
) !void {
    for ([_]Grain{ .one, .random }) |grain| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var cursor = try A.start(fixture, input);
        var spent: usize = 0;
        var calls: usize = 0;
        const outcome = while (true) {
            calls += 1;
            if (calls > bound + 1) {
                A.abandon(fixture, &cursor);
                return error.CursorDidNotFinish;
            }
            const grant: usize = switch (grain) {
                .one => 1,
                .random => 1 + random.uintLessThan(usize, 9),
            };
            var work = poll.testing.budget(grant);
            const done = A.step(&cursor, &work) catch |err| {
                A.abandon(fixture, &cursor);
                return err;
            };
            spent += grant - work.remaining;
            if (done) |result| break result;
            if (work.remaining != 0) {
                A.abandon(fixture, &cursor);
                std.debug.print("{s}: pending with {d} of {d} units unspent\n", .{ @typeName(A), work.remaining, grant });
                return error.PendingBeforeExhaustion;
            }
        };
        A.finish(fixture, &cursor);
        defer A.releaseOutcome(fixture, outcome);
        if (!try A.eql(reference, outcome)) return error.GrainChangedResult;
        if (spent > bound) {
            std.debug.print("{s}: spent {d} over bound {d}\n", .{ @typeName(A), spent, bound });
            return error.ChargeUnbounded;
        }
    }
}

fn seedOf(recipe: testgen.ValueRecipe) u64 {
    return std.hash.Wyhash.hash(0, recipe.bytes);
}

/// A handful of generated values; nesting depth 2 keeps structural cursors
/// busy without making the property slow.
fn valuesFrom(fixture: *Fixture, recipe: testgen.ValueRecipe, dicts: testgen.Dicts, max: usize) ![]Value {
    const count: usize = if (recipe.bytes.len == 0) 0 else recipe.bytes[0] % (max + 1);
    const values = try allocator.alloc(Value, count);
    errdefer allocator.free(values);
    for (values, 0..) |*item, index| item.* = try testgen.valueFromRecipe(
        allocator,
        fixture.releases(),
        recipe,
        2,
        dicts,
        @intCast(index + 1),
    );
    return values;
}

fn releaseValues(fixture: *Fixture, values: []Value) void {
    for (values) |item| fixture.release(item);
    allocator.free(values);
}

/// Every nested value contributes to the structural charge bound.
fn weight(item: Value) usize {
    return switch (item) {
        .list => |header| blk: {
            var total: usize = 1;
            const count: usize = @intCast(header.length());
            for (0..count) |index| total += weight(list.atUnchecked(item, index));
            break :blk total;
        },
        .dict => |header| blk: {
            var total: usize = 1;
            const count: usize = @intCast(header.length());
            for (0..count) |index| total += weight(dict.keyAt(header, index)) + weight(dict.valueAt(header, index));
            break :blk total;
        },
        else => 1,
    };
}

fn weightOf(values: []const Value) usize {
    var total: usize = 0;
    for (values) |item| total += weight(item);
    return total;
}

const ValueListAdapter = struct {
    const Input = []const Value;
    const Cursor = list.ValueMaterializer;
    const Outcome = Value;
    fn start(_: *Fixture, input: Input) !Cursor {
        return .init(allocator, input);
    }
    fn step(cursor: *Cursor, work: *poll.WorkBudget) !?Outcome {
        return switch (try cursor.advance(work)) {
            .pending => null,
            .complete => |result| result,
        };
    }
    fn finish(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn abandon(fixture: *Fixture, cursor: *Cursor) void {
        cursor.retire(fixture.releases());
    }
    fn eql(a: Outcome, b: Outcome) !bool {
        return equal.matchWithAllocator(allocator, a, b);
    }
    fn releaseOutcome(fixture: *Fixture, outcome: Outcome) void {
        fixture.release(outcome);
    }
};

const GenericListAdapter = struct {
    const Input = []const Value;
    const Cursor = list.GenericValueMaterializer;
    const Outcome = Value;
    fn start(_: *Fixture, input: Input) !Cursor {
        return .init(allocator, input);
    }
    fn step(cursor: *Cursor, work: *poll.WorkBudget) !?Outcome {
        return switch (try cursor.advance(work)) {
            .pending => null,
            .complete => |result| result,
        };
    }
    fn finish(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn abandon(fixture: *Fixture, cursor: *Cursor) void {
        cursor.retire(fixture.releases());
    }
    const eql = ValueListAdapter.eql;
    const releaseOutcome = ValueListAdapter.releaseOutcome;
};

const CodepointAdapter = struct {
    const Input = []const u32;
    const Cursor = list.CodepointMaterializer;
    const Outcome = Value;
    fn start(_: *Fixture, input: Input) !Cursor {
        return .init(allocator, input);
    }
    fn step(cursor: *Cursor, work: *poll.WorkBudget) !?Outcome {
        return switch (try cursor.advance(work)) {
            .pending => null,
            .complete => |result| result,
        };
    }
    fn finish(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn abandon(fixture: *Fixture, cursor: *Cursor) void {
        cursor.retire(fixture.releases());
    }
    const eql = ValueListAdapter.eql;
    const releaseOutcome = ValueListAdapter.releaseOutcome;
};

const DictBuild = union(enum) { duplicate, built: Value };

const DictAdapter = struct {
    const Input = []const dict.Pair;
    const Cursor = dict.Materializer;
    const Outcome = DictBuild;
    fn start(_: *Fixture, input: Input) !Cursor {
        return dict.Materializer.init(allocator, input, true);
    }
    fn step(cursor: *Cursor, work: *poll.WorkBudget) !?Outcome {
        return switch (try cursor.advance(work)) {
            .pending => null,
            .duplicate_key => .duplicate,
            .complete => |result| .{ .built = result },
        };
    }
    fn finish(fixture: *Fixture, cursor: *Cursor) void {
        // A duplicate leaves the materializer mid-build; its owner retires it.
        if (cursor.state == .complete) cursor.deinit() else cursor.retire(fixture.releases());
    }
    fn abandon(fixture: *Fixture, cursor: *Cursor) void {
        cursor.retire(fixture.releases());
    }
    fn eql(a: Outcome, b: Outcome) !bool {
        return switch (a) {
            .duplicate => b == .duplicate,
            .built => |left| b == .built and try equal.matchWithAllocator(allocator, left, b.built),
        };
    }
    fn releaseOutcome(fixture: *Fixture, outcome: Outcome) void {
        switch (outcome) {
            .duplicate => {},
            .built => |item| fixture.release(item),
        }
    }
};

/// The same build from borrowed pairs, which starts by copying them.
const BorrowedDictAdapter = struct {
    const Input = []const dict.Pair;
    const Cursor = dict.Materializer;
    const Outcome = DictBuild;
    fn start(_: *Fixture, input: Input) !Cursor {
        return dict.Materializer.initBorrowedPairs(allocator, input, true);
    }
    const step = DictAdapter.step;
    const finish = DictAdapter.finish;
    const abandon = DictAdapter.abandon;
    const eql = DictAdapter.eql;
    const releaseOutcome = DictAdapter.releaseOutcome;
};

const FindInput = struct { dictionary: Value, key: Value };

const FindAdapter = struct {
    const Input = FindInput;
    const Cursor = dict.FindCursor;
    const Outcome = ?Value;
    fn start(_: *Fixture, input: Input) !Cursor {
        return dict.FindCursor.init(allocator, input.dictionary, input.key);
    }
    fn step(cursor: *Cursor, work: *poll.WorkBudget) !?Outcome {
        return switch (try cursor.advance(work)) {
            .pending => null,
            .complete => |found| found,
        };
    }
    fn finish(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn abandon(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn eql(a: Outcome, b: Outcome) !bool {
        if (a == null or b == null) return a == null and b == null;
        return equal.matchWithAllocator(allocator, a.?, b.?);
    }
    fn releaseOutcome(_: *Fixture, _: Outcome) void {}
};

const PairInput = struct { a: Value, b: Value };

const MatchAdapter = struct {
    const Input = PairInput;
    const Cursor = equal.MatchCursor;
    const Outcome = bool;
    fn start(_: *Fixture, input: Input) !Cursor {
        return equal.MatchCursor.init(allocator, input.a, input.b);
    }
    fn step(cursor: *Cursor, work: *poll.WorkBudget) !?Outcome {
        return switch (try cursor.advance(work)) {
            .pending => null,
            .complete => |matches| matches,
        };
    }
    fn finish(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn abandon(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn eql(a: Outcome, b: Outcome) !bool {
        return a == b;
    }
    fn releaseOutcome(_: *Fixture, _: Outcome) void {}
};

const HashAdapter = struct {
    const Input = Value;
    const Cursor = equal.HashCursor;
    const Outcome = u64;
    fn start(_: *Fixture, input: Input) !Cursor {
        return equal.HashCursor.init(allocator, input);
    }
    fn step(cursor: *Cursor, work: *poll.WorkBudget) !?Outcome {
        return switch (try cursor.advance(work)) {
            .pending => null,
            .complete => |hashed| hashed,
        };
    }
    fn finish(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn abandon(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn eql(a: Outcome, b: Outcome) !bool {
        return a == b;
    }
    fn releaseOutcome(_: *Fixture, _: Outcome) void {}
};

const TextAdapter = struct {
    const Input = []const u8;
    const Cursor = storage.TextMaterializer;
    const Outcome = Value;
    fn start(_: *Fixture, input: Input) !Cursor {
        return .init(allocator, input);
    }
    fn step(cursor: *Cursor, work: *poll.WorkBudget) !?Outcome {
        return switch (try cursor.advance(work)) {
            .pending => null,
            .complete => |result| result,
        };
    }
    fn finish(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn abandon(fixture: *Fixture, cursor: *Cursor) void {
        cursor.retire(fixture.releases());
    }
    const eql = ValueListAdapter.eql;
    const releaseOutcome = ValueListAdapter.releaseOutcome;
};

const EncodeAdapter = struct {
    const Input = Value;
    const Cursor = storage.StringEncoder;
    const Outcome = []u8;
    fn start(_: *Fixture, input: Input) !Cursor {
        return .init(allocator, input);
    }
    fn step(cursor: *Cursor, work: *poll.WorkBudget) !?Outcome {
        return switch (try cursor.advance(work)) {
            .pending => null,
            .complete => |bytes| bytes,
        };
    }
    fn finish(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn abandon(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn eql(a: Outcome, b: Outcome) !bool {
        return std.mem.eql(u8, a, b);
    }
    fn releaseOutcome(_: *Fixture, outcome: Outcome) void {
        allocator.free(outcome);
    }
};

const NormalizeAdapter = struct {
    const Input = Value;
    const Cursor = doc.NormalizeCursor;
    const Outcome = Value;
    fn start(_: *Fixture, input: Input) !Cursor {
        return doc.NormalizeCursor.init(allocator, input);
    }
    fn step(cursor: *Cursor, work: *poll.WorkBudget) !?Outcome {
        return switch (try cursor.advance(work)) {
            .pending => null,
            .complete => |result| result,
        };
    }
    fn finish(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn abandon(fixture: *Fixture, cursor: *Cursor) void {
        cursor.retire(fixture.releases());
    }
    const eql = ValueListAdapter.eql;
    const releaseOutcome = ValueListAdapter.releaseOutcome;
};

const RenderAdapter = struct {
    const Input = Value;
    const Cursor = print.OwnedStringCursor;
    const Outcome = []u8;
    fn start(_: *Fixture, input: Input) !Cursor {
        return print.OwnedStringCursor.init(allocator, input);
    }
    fn step(cursor: *Cursor, work: *poll.WorkBudget) !?Outcome {
        return switch (try cursor.advance(work)) {
            .pending => null,
            .complete => |bytes| bytes,
        };
    }
    fn finish(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    fn abandon(_: *Fixture, cursor: *Cursor) void {
        cursor.deinit();
    }
    const eql = EncodeAdapter.eql;
    const releaseOutcome = EncodeAdapter.releaseOutcome;
};

/// A comparator that spends one unit per byte, so the sort's hand-off to it
/// is exercised at every grain.
const ByteComparator = struct {
    pub const Context = void;
    pub const Cursor = struct { left: u32, right: u32, shift: u5 = 24 };
    pub fn init(_: Context, left: u32, right: u32) Cursor {
        return .{ .left = left, .right = right };
    }
    pub fn advance(cursor: *Cursor, work: *poll.WorkBudget) poll.Progress(std.math.Order) {
        while (true) {
            if (!work.spend()) return .pending;
            const left: u8 = @truncate(cursor.left >> cursor.shift);
            const right: u8 = @truncate(cursor.right >> cursor.shift);
            if (left != right or cursor.shift == 0) return .{ .complete = std.math.order(left, right) };
            cursor.shift -= 8;
        }
    }
};

const SortInput = []const u32;

const SortAdapter = struct {
    const Sorter = poll.MergeSortCursor(u32, ByteComparator);
    const Input = SortInput;
    const Cursor = struct { items: []u32, sorter: Sorter };
    const Outcome = []u32;
    fn start(_: *Fixture, input: Input) !Cursor {
        const items = try allocator.dupe(u32, input);
        errdefer allocator.free(items);
        return .{ .items = items, .sorter = try .init(allocator, items, {}) };
    }
    fn step(cursor: *Cursor, work: *poll.WorkBudget) !?Outcome {
        return switch (cursor.sorter.advance(work)) {
            .pending => null,
            .complete => cursor.items,
        };
    }
    fn finish(_: *Fixture, cursor: *Cursor) void {
        cursor.sorter.deinit();
    }
    fn abandon(_: *Fixture, cursor: *Cursor) void {
        cursor.sorter.deinit();
        allocator.free(cursor.items);
    }
    fn eql(a: Outcome, b: Outcome) !bool {
        return std.mem.eql(u32, a, b);
    }
    fn releaseOutcome(_: *Fixture, outcome: Outcome) void {
        allocator.free(outcome);
    }
};

fn codepointsFrom(recipe: testgen.ValueRecipe) ![]u32 {
    const codepoints = try allocator.alloc(u32, recipe.bytes.len);
    for (recipe.bytes, codepoints) |byte, *out| out.* = testgen.codepoint(byte);
    return codepoints;
}

fn stringFrom(recipe: testgen.ValueRecipe) !Value {
    const codepoints = try codepointsFrom(recipe);
    defer allocator.free(codepoints);
    return list.fromCodepoints(allocator, codepoints);
}

fn listProperties(recipe: testgen.ValueRecipe) anyerror!void {
    var fixture = Fixture.init();
    defer fixture.deinit();
    const values = try valuesFrom(&fixture, recipe, .allowed, 24);
    defer releaseValues(&fixture, values);
    const bound = 4 * values.len + 8;
    {
        const reference = try list.fromValues(allocator, values);
        defer fixture.release(reference);
        try checkCursor(ValueListAdapter, &fixture, values, reference, bound, seedOf(recipe));
    }
    {
        const reference = try list.fromValuesGeneric(allocator, values);
        defer fixture.release(reference);
        try checkCursor(GenericListAdapter, &fixture, values, reference, bound, seedOf(recipe));
    }
    const codepoints = try codepointsFrom(recipe);
    defer allocator.free(codepoints);
    const reference = try list.fromCodepoints(allocator, codepoints);
    defer fixture.release(reference);
    try checkCursor(CodepointAdapter, &fixture, codepoints, reference, 4 * codepoints.len + 8, seedOf(recipe));
}

fn dictProperties(recipe: testgen.ValueRecipe) anyerror!void {
    var fixture = Fixture.init();
    defer fixture.deinit();
    // Past the index threshold (16) a dict builds and probes a hash table;
    // below it, it scans. Both regimes are generated.
    const keys = try valuesFrom(&fixture, recipe, .allowed, 40);
    defer releaseValues(&fixture, keys);
    const pairs = try allocator.alloc(dict.Pair, keys.len);
    defer allocator.free(pairs);
    for (keys, pairs, 0..) |key, *pair, index| pair.* = .{ key, .{ .int = @intCast(index) } };
    // Duplicate detection compares keys structurally, pairwise when small.
    const bound = 8 * weightOf(keys) * (keys.len + 1) + 64;
    const reference: DictBuild = if (dict.fromPairs(allocator, fixture.releases(), pairs)) |built|
        .{ .built = built }
    else |err| switch (err) {
        error.DuplicateKey => .duplicate,
        error.OutOfMemory => return err,
    };
    defer DictAdapter.releaseOutcome(&fixture, reference);
    try checkCursor(DictAdapter, &fixture, pairs, reference, bound, seedOf(recipe));
    try checkCursor(BorrowedDictAdapter, &fixture, pairs, reference, bound, seedOf(recipe));

    const dictionary = switch (reference) {
        .built => |built| built,
        .duplicate => return,
    };
    const probe = if (keys.len == 0) Value{ .int = 0 } else keys[recipe.bytes[recipe.bytes.len - 1] % keys.len];
    const found = try dict.getWithAllocator(allocator, dictionary, probe);
    try checkCursor(
        FindAdapter,
        &fixture,
        .{ .dictionary = dictionary, .key = probe },
        found,
        8 * weightOf(keys) + 8 * weight(probe) + 16,
        seedOf(recipe),
    );
}

fn equalityProperties(recipe: testgen.ValueRecipe) anyerror!void {
    var fixture = Fixture.init();
    defer fixture.deinit();
    const a = try testgen.valueFromRecipe(allocator, fixture.releases(), recipe, 3, .allowed, 1);
    defer fixture.release(a);
    // A second value from the same recipe is structurally equal, and one
    // from a different salt is usually not: both outcomes are exercised.
    const salt: u8 = if (recipe.bytes.len % 2 == 0) 1 else 2;
    const b = try testgen.valueFromRecipe(allocator, fixture.releases(), recipe, 3, .allowed, salt);
    defer fixture.release(b);
    const bound = 8 * (weight(a) + weight(b)) + 16;
    try checkCursor(MatchAdapter, &fixture, .{ .a = a, .b = b }, try equal.matchWithAllocator(allocator, a, b), bound, seedOf(recipe));
    try checkCursor(HashAdapter, &fixture, a, try equal.hashWithAllocator(allocator, a), 8 * weight(a) + 16, seedOf(recipe));
}

fn textProperties(recipe: testgen.ValueRecipe) anyerror!void {
    var fixture = Fixture.init();
    defer fixture.deinit();
    const bound = 4 * recipe.bytes.len + 8;
    {
        // Raw recipe bytes are frequently invalid UTF-8, which exercises the
        // fallback to byte characters inside one allowance.
        var reference_cursor = storage.TextMaterializer.init(allocator, recipe.bytes);
        var unbounded = poll.unbounded();
        const reference = switch (try reference_cursor.advance(&unbounded)) {
            .pending => unreachable,
            .complete => |result| result,
        };
        reference_cursor.deinit();
        defer fixture.release(reference);
        try checkCursor(TextAdapter, &fixture, recipe.bytes, reference, bound, seedOf(recipe));
    }
    const string = try stringFrom(recipe);
    defer fixture.release(string);
    var reference_encoder = storage.StringEncoder.init(allocator, string);
    var unbounded = poll.unbounded();
    const encoded = switch (try reference_encoder.advance(&unbounded)) {
        .pending => unreachable,
        .complete => |bytes| bytes,
    };
    reference_encoder.deinit();
    defer allocator.free(encoded);
    try checkCursor(EncodeAdapter, &fixture, string, encoded, 2 * recipe.bytes.len + 8, seedOf(recipe));

    const normalized = try doc.normalize(allocator, string);
    defer fixture.release(normalized);
    try checkCursor(NormalizeAdapter, &fixture, string, normalized, 8 * recipe.bytes.len + 16, seedOf(recipe));
}

fn renderProperties(recipe: testgen.ValueRecipe) anyerror!void {
    var fixture = Fixture.init();
    defer fixture.deinit();
    const item = try testgen.valueFromRecipe(allocator, fixture.releases(), recipe, 3, .allowed, 1);
    defer fixture.release(item);
    const rendered = try print.toOwnedString(allocator, item);
    defer allocator.free(rendered);
    try checkCursor(RenderAdapter, &fixture, item, rendered, 16 * weight(item) + 16, seedOf(recipe));
}

fn sortProperties(recipe: testgen.ValueRecipe) anyerror!void {
    var fixture = Fixture.init();
    defer fixture.deinit();
    const count = recipe.bytes.len / 2;
    const items = try allocator.alloc(u32, count);
    defer allocator.free(items);
    for (items, 0..) |*item, index| {
        // Shared high bytes force multi-unit comparisons.
        item.* = (@as(u32, recipe.bytes[2 * index] % 3) << 24) | recipe.bytes[2 * index + 1];
    }
    const expected = try allocator.dupe(u32, items);
    defer allocator.free(expected);
    std.mem.sort(u32, expected, {}, std.sort.asc(u32));
    const log2 = std.math.log2_int_ceil(usize, count + 1) + 1;
    try checkCursor(SortAdapter, &fixture, items, expected, 16 * (count + 1) * log2 + 16, seedOf(recipe));
}

const options: minish.Options = .{ .num_runs = 64, .seed = 0x6275_6467_6574 };

test "cursor budget: list materializers pause only when their grant is spent" {
    try minish.check(allocator, testgen.value_recipe_generator, listProperties, options);
}

test "cursor budget: dict build and lookup pause only when their grant is spent" {
    try minish.check(allocator, testgen.value_recipe_generator, dictProperties, options);
}

test "cursor budget: structural match and hash pause only when their grant is spent" {
    try minish.check(allocator, testgen.value_recipe_generator, equalityProperties, options);
}

test "cursor budget: text, encoding, and documentation pause only when their grant is spent" {
    try minish.check(allocator, testgen.value_recipe_generator, textProperties, options);
}

test "cursor budget: rendering pauses only when its grant is spent" {
    try minish.check(allocator, testgen.value_recipe_generator, renderProperties, options);
}

test "cursor budget: sorting pauses only when its grant is spent" {
    try minish.check(allocator, testgen.value_recipe_generator, sortProperties, options);
}
