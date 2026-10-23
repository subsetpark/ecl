//! Closed, identity-guarded phrase recognition with generic fallback.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const equal = @import("equal.zig");
const numeric = @import("kernel_numeric.zig");
const order = @import("kernel_order.zig");
const sequence = @import("kernel_sequence.zig");
const dict_text = @import("kernel_dict_text.zig");
const combinators = @import("combinators.zig");

const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;

pub const Context = enum { direct, each, zip_with, fold, fold1, scan };
pub const DirectOp = enum {
    sort,
    first,
    find,
    rest,
    reverse,
    dip,
    str_format,
    fold1,
    sum,
    product,
    /// `reshape` continued by `sum` or `product`: the fold over the rows a
    /// two-axis reshape would build, without building them.
    reshape_sum,
    reshape_product,

    pub fn spelling(self: DirectOp) []const u8 {
        return switch (self) {
            .str_format => "str.format",
            .reshape_sum, .reshape_product => "reshape",
            else => @tagName(self),
        };
    }
};
pub const Operation = union(enum) {
    unary: numeric.UnaryOp,
    binary: numeric.BinaryOp,
    match,
    length,
    direct: DirectOp,

    pub fn spelling(self: Operation) []const u8 {
        return switch (self) {
            .unary => |operation| operation.spelling(),
            .binary => |operation| operation.spelling(),
            .match => "match?",
            .length => "len",
            .direct => |operation| operation.spelling(),
        };
    }
};
pub const BindingKind = enum { builtin, source };
pub const ExpectedOrigin = enum { trusted, candidate_module };
pub const ExpectedWord = struct {
    spelling: []const u8,
    binding: BindingKind = .builtin,
    origin: ExpectedOrigin = .trusted,
    /// The word a fault inside the entry names, at the top-level position of
    /// the phrase that holds it, as the definition's own execution would.
    active: bool = false,
};
pub const PatternAtom = union(enum) {
    /// A non-word value, which becomes the operation's constant operand.
    /// `literal` leaves every non-word as itself, so this is also what
    /// `partial` prefixes onto its quotation.
    constant,
    literal,
    /// An int literal equal to this value.
    int: i64,
    /// The entry's own operation word, which is also its active word.
    operation,
    word: ExpectedWord,
    /// A quotation literal whose forms match this pattern exactly.
    quotation: []const PatternAtom,
};
pub const RegistryEntry = struct {
    context: Context,
    pattern: []const PatternAtom,
    operation: Operation,
    constant_left: bool = false,
    source_word: ?[]const u8 = null,
    /// Words that must follow the head in the code it runs from, checked
    /// where it runs. The phrase consumes them when it applies.
    following: []const ExpectedWord = &.{},
};

const operation_pattern = [_]PatternAtom{.operation};
const constant_operation_pattern = [_]PatternAtom{ .constant, .operation };
const constant_swap_operation_pattern = [_]PatternAtom{
    .constant,
    .{ .word = .{ .spelling = "swap" } },
    .operation,
};
const sort_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "dup" } },
    .{ .word = .{ .spelling = "grade", .active = true } },
    .{ .word = .{ .spelling = "at" } },
};
const neg_pattern = [_]PatternAtom{ .literal, .{ .word = .{ .spelling = "*" } } };
const abs_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "dup" } },
    .{ .word = .{ .spelling = "neg", .binding = .source } },
    .literal,
    .{ .word = .{ .spelling = "+" } },
    .{ .word = .{ .spelling = "swap" } },
    .{ .word = .{ .spelling = "max" } },
};
const mod_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "over", .binding = .source } },
    .{ .word = .{ .spelling = "over", .binding = .source } },
    .{ .word = .{ .spelling = "div" } },
    .{ .word = .{ .spelling = "*" } },
    .{ .word = .{ .spelling = "-" } },
};
const ne_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "=" } },
    .{ .word = .{ .spelling = "not" } },
};
const le_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = ">" } },
    .{ .word = .{ .spelling = "not" } },
};
const ge_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "<" } },
    .{ .word = .{ .spelling = "not" } },
};
const and_pattern = [_]PatternAtom{
    .literal,
    .{ .word = .{ .spelling = "dip", .binding = .source } },
    .{ .word = .{ .spelling = "not" } },
    .{ .word = .{ .spelling = "not" } },
    .{ .word = .{ .spelling = "min" } },
};
const or_pattern = [_]PatternAtom{
    .literal,
    .{ .word = .{ .spelling = "dip", .binding = .source } },
    .{ .word = .{ .spelling = "not" } },
    .{ .word = .{ .spelling = "not" } },
    .{ .word = .{ .spelling = "max" } },
};
const first_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "dup" } },
    .{ .word = .{ .spelling = "len" } },
    .{ .word = .{ .spelling = "pop" } },
    .literal,
    .{ .word = .{ .spelling = "at" } },
};
const find_pattern = [_]PatternAtom{
    .{ .quotation = &.{.{ .word = .{ .spelling = "match?" } }} },
    .{ .word = .{ .spelling = "partial", .binding = .source } },
    .{ .word = .{ .spelling = "each" } },
    .{ .word = .{ .spelling = "first-where" } },
};
const rest_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "dup" } },
    .{ .word = .{ .spelling = "first", .binding = .source } },
    .{ .word = .{ .spelling = "pop" } },
    .literal,
    .{ .word = .{ .spelling = "drop" } },
};
const reverse_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "dup" } },
    .{ .word = .{ .spelling = "len" } },
    .{ .word = .{ .spelling = "dup" } },
    .literal,
    .{ .word = .{ .spelling = "=" } },
    .literal,
    .literal,
    .{ .word = .{ .spelling = "if" } },
};
const dip_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "swap" } },
    .{ .word = .{ .spelling = "literal", .binding = .source } },
    .{ .word = .{ .spelling = "compose", .binding = .source } },
    .{ .word = .{ .spelling = "call" } },
};
const str_format_pattern = [_]PatternAtom{
    .{ .word = .{
        .spelling = "format-valid",
        .binding = .source,
        .origin = .candidate_module,
    } },
};
/// `sum` and `product`: `dup empty? (pop seed) ((op) fold1) if`. The
/// reduction's operator is the active word, so a fault names `+` or `*` at
/// that literal, as the definition's own reduction would.
fn totalPattern(comptime seed: i64, comptime operator: []const u8) [5]PatternAtom {
    return .{
        .{ .word = .{ .spelling = "dup" } },
        .{ .word = .{ .spelling = "empty?", .binding = .source } },
        .{ .quotation = &.{ .{ .word = .{ .spelling = "pop" } }, .{ .int = seed } } },
        .{ .quotation = &.{
            .{ .quotation = &.{.{ .word = .{ .spelling = operator, .active = true } }} },
            .{ .word = .{ .spelling = "fold1", .binding = .source } },
        } },
        .{ .word = .{ .spelling = "if" } },
    };
}
const sum_pattern = totalPattern(0, "+");
const product_pattern = totalPattern(1, "*");
const fold1_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "swap" } },
    .{ .word = .{ .spelling = "uncons", .binding = .source } },
    .{ .word = .{ .spelling = "swap" } },
    .{ .word = .{ .spelling = "rolldown", .binding = .source } },
    .{ .word = .{ .spelling = "fold" } },
};
const unary_count = @typeInfo(numeric.UnaryOp).@"enum".field_names.len;
const binary_count = @typeInfo(numeric.BinaryOp).@"enum".field_names.len;
pub const registry = blk: {
    var entries: [unary_count + binary_count * 3 + 3 + 18 + 18 + 2]RegistryEntry = undefined;
    var index: usize = 0;
    entries[index] = .{ .context = .each, .pattern = &operation_pattern, .operation = .length };
    index += 1;
    for (std.meta.tags(numeric.UnaryOp)) |operation| {
        entries[index] = .{
            .context = .each,
            .pattern = &operation_pattern,
            .operation = .{ .unary = operation },
        };
        index += 1;
    }
    for (std.meta.tags(numeric.BinaryOp)) |operation| {
        entries[index] = .{
            .context = .each,
            .pattern = &constant_operation_pattern,
            .operation = .{ .binary = operation },
        };
        entries[index + 1] = .{
            .context = .each,
            .pattern = &constant_swap_operation_pattern,
            .operation = .{ .binary = operation },
            .constant_left = true,
        };
        entries[index + 2] = .{
            .context = .zip_with,
            .pattern = &operation_pattern,
            .operation = .{ .binary = operation },
        };
        index += 3;
    }
    for ([_]struct { pattern: []const PatternAtom, constant_left: bool }{
        .{ .pattern = &constant_operation_pattern, .constant_left = false },
        .{ .pattern = &constant_swap_operation_pattern, .constant_left = true },
    }) |match_each| {
        entries[index] = .{
            .context = .each,
            .pattern = match_each.pattern,
            .operation = .match,
            .constant_left = match_each.constant_left,
        };
        index += 1;
    }
    for ([_]numeric.BinaryOp{ .add, .mul, .min, .max, .and_word, .or_word }) |operation| {
        entries[index] = .{
            .context = .fold,
            .pattern = &operation_pattern,
            .operation = .{ .binary = operation },
        };
        entries[index + 1] = .{
            .context = .scan,
            .pattern = &operation_pattern,
            .operation = .{ .binary = operation },
        };
        entries[index + 2] = .{
            .context = .fold1,
            .pattern = &operation_pattern,
            .operation = .{ .binary = operation },
        };
        index += 3;
    }
    for ([_]struct { operation: Operation, pattern: []const PatternAtom }{
        .{ .operation = .{ .unary = .neg }, .pattern = &neg_pattern },
        .{ .operation = .{ .unary = .abs }, .pattern = &abs_pattern },
        .{ .operation = .{ .binary = .mod }, .pattern = &mod_pattern },
        .{ .operation = .{ .binary = .ne }, .pattern = &ne_pattern },
        .{ .operation = .{ .binary = .le }, .pattern = &le_pattern },
        .{ .operation = .{ .binary = .ge }, .pattern = &ge_pattern },
        .{ .operation = .{ .binary = .and_word }, .pattern = &and_pattern },
        .{ .operation = .{ .binary = .or_word }, .pattern = &or_pattern },
    }) |direct| {
        entries[index] = .{
            .context = .direct,
            .pattern = direct.pattern,
            .operation = direct.operation,
            .source_word = direct.operation.spelling(),
        };
        index += 1;
    }
    for ([_]struct { operation: DirectOp, pattern: []const PatternAtom }{
        .{ .operation = .fold1, .pattern = &fold1_pattern },
        .{ .operation = .sort, .pattern = &sort_pattern },
        .{ .operation = .first, .pattern = &first_pattern },
        .{ .operation = .find, .pattern = &find_pattern },
        .{ .operation = .rest, .pattern = &rest_pattern },
        .{ .operation = .reverse, .pattern = &reverse_pattern },
        .{ .operation = .dip, .pattern = &dip_pattern },
        .{ .operation = .str_format, .pattern = &str_format_pattern },
        .{ .operation = .sum, .pattern = &sum_pattern },
        .{ .operation = .product, .pattern = &product_pattern },
    }) |direct| {
        entries[index] = .{
            .context = .direct,
            .pattern = direct.pattern,
            .operation = .{ .direct = direct.operation },
            .source_word = if (direct.operation == .str_format)
                "format"
            else
                direct.operation.spelling(),
        };
        index += 1;
    }
    for ([_]struct { operation: DirectOp, total: []const u8 }{
        .{ .operation = .reshape_sum, .total = "sum" },
        .{ .operation = .reshape_product, .total = "product" },
    }) |phrase| {
        entries[index] = .{
            .context = .direct,
            .pattern = &.{},
            .operation = .{ .direct = phrase.operation },
            .source_word = "reshape",
            .following = &.{.{ .spelling = phrase.total, .binding = .source }},
        };
        index += 1;
    }
    std.debug.assert(index == entries.len);
    break :blk entries;
};

const max_pattern_len = blk: {
    var longest: usize = 0;
    for (registry) |entry| longest = @max(longest, entry.pattern.len);
    break :blk longest;
};

/// Registry indices grouped by context and pattern length, in registry order,
/// so an offered phrase visits only the entries it could match.
const entries_by_shape = blk: {
    @setEvalBranchQuota(100_000);
    var table: [@typeInfo(Context).@"enum".field_names.len][max_pattern_len + 1][]const u16 = undefined;
    for (std.meta.tags(Context)) |context| {
        for (0..max_pattern_len + 1) |length| {
            var found: [registry.len]u16 = undefined;
            var count: usize = 0;
            for (registry, 0..) |entry, index| {
                if (entry.context != context or entry.pattern.len != length) continue;
                found[count] = index;
                count += 1;
            }
            const shaped = found[0..count].*;
            table[@backingInt(context)][length] = &shaped;
        }
    }
    break :blk table;
};

fn entriesShaped(context: Context, length: usize) []const u16 {
    if (length > max_pattern_len) return &.{};
    return entries_by_shape[@backingInt(context)][length];
}

/// Every trusted definition a direct entry can recognize, by name.
const direct_names = blk: {
    var names: [registry.len][]const u8 = undefined;
    var count: usize = 0;
    for (registry) |entry| {
        // A phrase head asks from its own primitive; nothing freezes for it.
        if (entry.context != .direct or entry.following.len != 0) continue;
        const name = entry.source_word.?;
        const seen = for (names[0..count]) |existing| {
            if (std.mem.eql(u8, existing, name)) break true;
        } else false;
        if (seen) continue;
        names[count] = name;
        count += 1;
    }
    const final = names[0..count].*;
    break :blk final;
};

/// Decides each trusted definition's direct entry when its environment
/// freezes, against bindings that can no longer change.
pub const freeze_recognizer: env.FreezeRecognizer = .{
    .names = &direct_names,
    .recognize = recognizeTrusted,
};

fn recognizeTrusted(lookup: env.FrozenLookup, name: []const u8, body: *env.Quotation) ?env.DirectIdiom {
    const phrase: Value = .{ .list = env.quotationHeader(body) };
    for (registry, 0..) |entry, index| {
        if (entry.context != .direct or !std.mem.eql(u8, entry.source_word.?, name)) continue;
        if (entry.following.len != 0) continue;
        const capture = matchPhrase(.{ .frozen = lookup }, phrase, entry) orelse continue;
        return .{
            .entry = @intCast(index),
            .constant = capture.constant,
            .active_word = capture.active_word,
            .active_index = capture.active_index,
        };
    }
    return null;
}

/// How a pattern word's binding is checked: against a frozen environment,
/// once, when a trusted definition is recognized; or where the phrase runs,
/// when a quotation is offered.
const WordGuard = union(enum) {
    frozen: env.FrozenLookup,
    live: *Machine,

    fn matches(
        self: WordGuard,
        word: value.WordRef,
        binding: BindingKind,
        primitive: ?env.PrimitiveImpl,
        origin: ExpectedOrigin,
    ) bool {
        switch (self) {
            .frozen => |lookup| return frozenBindingMatches(lookup, word, binding, primitive, origin),
            .live => |evaluator| {
                std.debug.assert(origin == .trusted);
                return liveWord(evaluator, word, binding, primitive) != null;
            },
        }
    }
};

/// What a trusted word resolved to where a phrase runs.
const LiveWord = struct {
    trace_word: intern.TraceWord,
    /// The word's own frozen recognition and body, for a source word.
    idiom: ?env.DirectIdiom,
    body: ?*value.ListHandle,
};

/// A following word, resolved as its own dispatch would resolve it: through
/// the unit's dispatch cache, so a phrase that runs on every iteration pays
/// one cache probe rather than a slot resolution. A word the cache does not
/// hold is resolved in full. Either way it must be the trusted binding
/// expected, from a slot on core or the running root.
fn followingWord(evaluator: *Machine, word: value.WordRef, binding: BindingKind) error{OutOfMemory}!?LiveWord {
    if (!slotOnRunningRoot(evaluator, word.slot)) return null;
    const cached = try evaluator.cachedResolution(word) orelse return liveWord(evaluator, word, binding, null);
    if (cached.origin != .core and cached.origin != .standard_library) return null;
    const spec = cached.spec;
    switch (binding) {
        .builtin => if (spec.binding != .builtin) return null,
        .source => if (spec.binding != .word) return null,
    }
    return .{
        .trace_word = cached.trace_word,
        .idiom = spec.direct_idiom,
        .body = if (spec.binding == .word) env.quotationHeader(spec.binding.word) else null,
    };
}

/// Resolves `word` where the phrase runs and returns it only when it is the
/// trusted binding expected. A word that resolves to nothing a plain word may
/// run, or whose root has retired, is simply not that binding; generic
/// execution reports any error. A frozen binding outlives the call that
/// matched it, so what it returns stays valid for the call.
fn liveWord(evaluator: *Machine, word: value.WordRef, binding: BindingKind, primitive: ?env.PrimitiveImpl) ?LiveWord {
    if (!slotOnRunningRoot(evaluator, word.slot)) return null;
    // SAFETY: read only after `peekSlotWord` returns true, which initializes it.
    var resolved: machine.Resolution = undefined;
    if (!evaluator.peekSlotWord(word, &resolved)) return null;
    defer resolved.deinit(evaluator.allocator());
    if (resolved.origin != .core and resolved.origin != .standard_library) return null;
    const spec = resolved.lease.spec();
    switch (binding) {
        .builtin => if (spec.binding != .builtin or (primitive != null and spec.binding.builtin != primitive.?)) return null,
        .source => if (spec.binding != .word) return null,
    }
    return .{
        .trace_word = resolved.trace_word,
        .idiom = spec.direct_idiom,
        .body = if (spec.binding == .word) env.quotationHeader(spec.binding.word) else null,
    };
}

/// The one atom matcher, shared by every site; only the guard differs. The
/// phrase matches when every atom does, at every nesting level.
fn matchPhrase(guard: WordGuard, phrase: Value, entry: RegistryEntry) ?Capture {
    var capture: Capture = .{};
    if (!matchAtoms(guard, phrase, entry.pattern, entry.operation, &capture, null)) return null;
    return capture;
}

/// `top` is the top-level position of the quotation holding a nested
/// pattern: a capture records where in the phrase a fault is reported.
fn matchAtoms(
    guard: WordGuard,
    phrase: Value,
    pattern: []const PatternAtom,
    operation: Operation,
    capture: *Capture,
    top: ?u32,
) bool {
    if (phrase != .list or phrase.list.length() != pattern.len) return false;
    for (pattern, 0..) |atom, atom_index| {
        const actual = list.atUnchecked(phrase, atom_index);
        const site: u32 = top orelse @intCast(atom_index);
        switch (atom) {
            .constant => {
                if (capture.constant != null or actual == .word) return false;
                capture.constant = actual;
            },
            .literal => if (actual == .word) return false,
            .int => |expected| if (actual != .int or actual.int != expected) return false,
            .quotation => |inner| if (!matchAtoms(guard, actual, inner, operation, capture, site)) return false,
            .operation => {
                if (actual != .word or !std.mem.eql(u8, intern.get(actual.word.name), operation.spelling())) return false;
                const binding = operationBinding(operation);
                const primitive = if (binding == .builtin) operationPrimitive(operation) else null;
                if (!guard.matches(actual.word, binding, primitive, .trusted)) return false;
                capture.active_word = actual.word.name;
                capture.active_index = site;
            },
            .word => |expected| {
                if (actual != .word or !std.mem.eql(u8, intern.get(actual.word.name), expected.spelling)) return false;
                if (!guard.matches(actual.word, expected.binding, null, expected.origin)) return false;
                if (expected.active) {
                    capture.active_word = actual.word.name;
                    capture.active_index = site;
                }
            },
        }
    }
    return true;
}

/// The binding guard, decided once. A trusted word may resolve in the frozen
/// environment or core; a candidate-module word only in the frozen image.
fn frozenBindingMatches(
    lookup: env.FrozenLookup,
    word: value.WordRef,
    binding: BindingKind,
    primitive: ?env.PrimitiveImpl,
    origin: ExpectedOrigin,
) bool {
    if (!lookup.admits(word.slot)) return false;
    var hit = lookup.resolve(word.slot, word.name) orelse return false;
    defer hit.lease.deinit();
    const binding_matches = switch (binding) {
        .builtin => hit.lease.spec().binding == .builtin and
            (primitive == null or hit.lease.spec().binding.builtin == primitive.?),
        .source => hit.lease.spec().binding == .word,
    };
    const origin_matches = switch (origin) {
        .trusted => true,
        .candidate_module => !hit.in_core,
    };
    return binding_matches and origin_matches;
}

pub fn tryApply(
    evaluator: *Machine,
    request: machine.IdiomRequest,
    source: machine.FallbackSource,
) MachineError!void {
    const decline: Decline = .{ .deferred = source };
    if (evaluator.unit.inherited.idiom_mode == .generic_only) return decline.run(evaluator);
    const candidate = requestCandidate(evaluator, request) orelse return decline.run(evaluator);
    const entries = entriesShaped(candidate.context, candidate.phrase.list.length());
    if (entries.len == 0) return decline.run(evaluator);
    // Inside a finite iteration's call the phrase's words keep their bindings,
    // so the phrase it offered before matches the same way again.
    const planned = try evaluator.planEntry();
    if (planned) |entry| if (entry.offered) |offered| if (offered.request == request and offered.phrase == candidate.phrase.list)
        return applyMatched(evaluator, candidate.phrase, offered.entry, .{
            .constant = offered.constant,
            .active_word = offered.active_word,
            .active_index = offered.active_index,
        }, decline);
    return matchOffered(evaluator, candidate, entries, decline, request, planned);
}

/// What an offered match runs if it declines: still the caller's source while
/// the match is synchronous, and a made fallback once a match that must wait
/// carries it into a driver.
const Decline = union(enum) {
    deferred: machine.FallbackSource,
    made: machine.IdiomFallback,

    fn take(self: Decline, evaluator: *Machine) machine.IdiomFallback {
        return switch (self) {
            .deferred => |source| source.make(evaluator),
            .made => |fallback| fallback,
        };
    }

    fn run(self: Decline, evaluator: *Machine) MachineError!void {
        var owned = self.take(evaluator);
        defer owned.deinit(evaluator.releaseDomain(), evaluator.allocator());
        return owned.run(evaluator);
    }

    fn discard(self: Decline, evaluator: *Machine) void {
        switch (self) {
            .deferred => {},
            .made => |fallback| {
                var owned = fallback;
                owned.deinit(evaluator.releaseDomain(), evaluator.allocator());
            },
        }
    }
};

/// A user quotation offered to a combinator. Trusted definitions never reach
/// the driver: their recognition was decided when their environment froze.
const Candidate = struct {
    context: Context,
    phrase: Value,
};

const Capture = struct {
    constant: ?Value = null,
    active_word: ?u32 = null,
    active_index: ?u32 = null,
};

fn requestCandidate(evaluator: *Machine, request: machine.IdiomRequest) ?Candidate {
    const context: Context, const depth: usize = switch (request) {
        .each => .{ .each, 2 },
        .fold1 => .{ .fold1, 2 },
        .zip_with => .{ .zip_with, 3 },
        .fold => .{ .fold, 3 },
        .scan => .{ .scan, 3 },
    };
    if (evaluator.available() < depth) return null;
    const phrase = evaluator.unit.stack.items[evaluator.unit.stack.items.len - 1];
    if (phrase != .list) return null;
    return .{ .context = context, .phrase = phrase };
}

/// Applies a trusted word's recognized entry when this call's operands admit
/// it. A declined call runs the word's body, so nothing is prepared for it.
/// `fold1` is the combinator itself: it offers the caller's quotation, and the
/// body is the fallback should that be declined.
pub fn applyTrusted(evaluator: *Machine, call: machine.TrustedCall) MachineError!machine.TrustedOutcome {
    if (evaluator.unit.inherited.idiom_mode == .generic_only) return .declined;
    const entry = registry[call.idiom.entry];
    if (entry.operation == .direct and entry.operation.direct == .fold1) return .{ .offered = .fold1 };
    if (!canApplyEntry(evaluator, entry)) return .declined;
    try applySelected(evaluator, .{ .list = call.body }, entry, .{
        .constant = call.idiom.constant,
        .active_word = call.idiom.active_word,
        .active_index = call.idiom.active_index,
    });
    return .applied;
}

/// The first registry entry headed by the kernel word `spelling`, or null
/// when it heads none. A head's entries are consecutive (checked below).
pub fn firstPhraseEntry(comptime spelling: []const u8) ?u16 {
    @setEvalBranchQuota(100_000);
    for (registry, 0..) |entry, index| {
        if (entry.following.len != 0 and std.mem.eql(u8, entry.source_word.?, spelling)) return index;
    }
    return null;
}

comptime {
    for (registry, 0..) |entry, index| {
        if (entry.following.len == 0) continue;
        if (entry.context != .direct) @compileError("a phrase entry must be direct");
        const first = firstPhraseEntry(entry.source_word.?).?;
        for (registry[first..index]) |between| {
            if (between.following.len == 0 or !std.mem.eql(u8, between.source_word.?, entry.source_word.?))
                @compileError("phrase entries of one head must be consecutive: " ++ entry.source_word.?);
        }
    }
}

/// Phrase words' interned names, interned on first use: each entry's head,
/// then its following words. The intern table is one per process and never
/// reset, so an id once learned stays valid.
const max_following = blk: {
    var longest: usize = 0;
    for (registry) |entry| longest = @max(longest, entry.following.len);
    break :blk longest;
};
var phrase_atoms: [registry.len][1 + max_following]std.atomic.Value(u32) = @splat(@splat(.init(unknown_atom)));
const unknown_atom = std.math.maxInt(u32);

/// Position 0 is the head; position n is following word n - 1.
fn phraseAtom(entry: u16, position: usize) error{OutOfMemory}!u32 {
    const cell = &phrase_atoms[entry][position];
    const cached = cell.load(.monotonic);
    if (cached != unknown_atom) return cached;
    const spelling = if (position == 0)
        registry[entry].source_word.?
    else
        registry[entry].following[position - 1].spelling;
    const id = try intern.intern(spelling);
    cell.store(id, .monotonic);
    return id;
}

/// A kernel word's primitive asks whether the words after it continue one of
/// its phrases (see `kernel_support.headed`). Only the word being dispatched
/// can head one: a primitive reached any other way declines, as does a unit
/// that runs generic code only.
pub fn applyHeaded(evaluator: *Machine, first: u16) MachineError!bool {
    if (evaluator.unit.inherited.idiom_mode == .generic_only) return false;
    if (evaluator.unit.active_word.atom() != try phraseAtom(first, 0)) return false;
    return try applyPhrase(evaluator, first) == .applied;
}

/// A builtin head continued by the words after it. Each entry the head
/// heads is tried in registry order; the first whose following words are
/// the expected trusted bindings, here, and whose operands admit it, applies
/// and consumes those words. A fault is reported as the last following word
/// would report it when it runs alone: its own recognition names the active
/// word and the site in its body, and the word is the trace parent.
fn applyPhrase(evaluator: *Machine, first: u16) MachineError!machine.TrustedOutcome {
    const name = registry[first].source_word.?;
    var index = first;
    while (index < registry.len) : (index += 1) {
        const entry = registry[index];
        if (entry.following.len == 0 or !std.mem.eql(u8, entry.source_word.?, name)) break;
        const count: u32 = @intCast(entry.following.len);
        const forms = evaluator.followingForms(count) orelse return .declined;
        var last: ?LiveWord = null;
        const matched = for (entry.following, 0..) |expected, offset| {
            const form = forms.at(@intCast(offset));
            if (form != .word or form.word.name != try phraseAtom(index, offset + 1)) break false;
            last = try followingWord(evaluator, form.word, expected.binding) orelse break false;
        } else true;
        if (!matched) continue;
        const shape = columnFoldShape(evaluator, entry.operation.direct) orelse continue;
        const owner = last.?;
        const idiom = owner.idiom orelse continue;
        evaluator.unit.idiom_hits += 1;
        evaluator.unit.phrase_hits += 1;
        evaluator.skipFollowingForms(count);
        _ = evaluator.commitDirectIdiomTrace();
        if (idiom.active_word) |word| evaluator.setActiveWord(.plain(word));
        const stack = evaluator.unit.stack.items;
        const result = numeric.foldLeafColumns(
            evaluator,
            columnOperation(entry.operation.direct),
            stack[stack.len - 2],
            shape.rows,
            shape.columns,
        ) catch |err| {
            if (err == error.Ecl) {
                if (idiom.active_index) |site| evaluator.setFailureSite(owner.body.?, site);
                evaluator.setFailureTraceParent(owner.trace_word);
            }
            return err;
        };
        popRelease(evaluator, 2);
        try evaluator.pushOwned(result);
        return .applied;
    }
    return .declined;
}

fn columnOperation(operation: DirectOp) numeric.BinaryOp {
    return switch (operation) {
        .reshape_sum => .add,
        .reshape_product => .mul,
        else => unreachable,
    };
}

/// The rows and columns of `list [rows columns] reshape` when its fold over
/// rows can run on the list itself: a two-axis shape of positive ints whose
/// volume is the list's length, a numeric leaf the operation keeps typed, and
/// work the remaining budget covers. Anything else runs the words as written.
fn columnFoldShape(evaluator: *Machine, operation: DirectOp) ?struct { rows: usize, columns: usize } {
    if (evaluator.available() < 2) return null;
    const stack = evaluator.unit.stack.items;
    const shape = stack[stack.len - 1];
    const input = stack[stack.len - 2];
    if (shape != .list or shape.list.length() != 2 or input != .list) return null;
    const rows_value = list.atUnchecked(shape, 0);
    const columns_value = list.atUnchecked(shape, 1);
    if (rows_value != .int or columns_value != .int or rows_value.int < 1 or columns_value.int < 1) return null;
    const rows = std.math.cast(usize, rows_value.int) orelse return null;
    const columns = std.math.cast(usize, columns_value.int) orelse return null;
    const volume = std.math.mul(usize, rows, columns) catch return null;
    if (volume != input.list.length() or volume > evaluator.remainingKernelFuel()) return null;
    if (!numeric.columnFoldCandidate(columnOperation(operation), input)) return null;
    return .{ .rows = rows, .columns = columns };
}

fn applySelected(evaluator: *Machine, phrase: Value, selected: RegistryEntry, capture: Capture) MachineError!void {
    const direct_parent = if (selected.context == .direct or selected.context == .fold1)
        evaluator.commitDirectIdiomTrace()
    else
        null;
    evaluator.unit.idiom_hits += 1;
    applyEntry(evaluator, selected, capture) catch |err| {
        if (err == error.Ecl) {
            if (capture.active_index) |index| evaluator.setFailureSite(phrase.list, index);
            if (direct_parent) |word| evaluator.setFailureTraceParent(word);
        }
        return err;
    };
    if (capture.active_index) |index| {
        evaluator.setWorkDriverSite(phrase.list, index);
    }
    if (direct_parent) |word| evaluator.setWorkDriverTraceParent(word);
}

/// Matches an offered phrase against the registry entries of its context and
/// length, records the match in the running finite iteration's plan when it
/// has room, then applies the matched entry or declines. The work is bounded
/// by the registry's shape and each pattern word is one slot read, so the
/// whole match runs where the combinator applies.
fn matchOffered(
    evaluator: *Machine,
    candidate: Candidate,
    entries: []const u16,
    decline: Decline,
    request: machine.IdiomRequest,
    planned: ?*machine.PlanEntry,
) MachineError!void {
    var capture: Capture = .{};
    const matched: ?u16 = for (entries) |index| {
        if (matchPhrase(.{ .live = evaluator }, candidate.phrase, registry[index])) |found| {
            capture = found;
            break index;
        }
    } else null;
    if (planned) |entry| if (entry.offered == null) {
        heap.retainValue(candidate.phrase);
        entry.offered = .{
            .request = request,
            .phrase = candidate.phrase.list,
            .entry = matched,
            .constant = capture.constant,
            .active_word = capture.active_word,
            .active_index = capture.active_index,
        };
    };
    return applyMatched(evaluator, candidate.phrase, matched, capture, decline);
}

/// Applies a matched entry when this application's operands admit it, and
/// declines otherwise.
fn applyMatched(evaluator: *Machine, phrase: Value, matched: ?u16, capture: Capture, decline: Decline) MachineError!void {
    const index = matched orelse return decline.run(evaluator);
    const selected = registry[index];
    if (!canApplyEntry(evaluator, selected)) return decline.run(evaluator);
    decline.discard(evaluator);
    return applySelected(evaluator, phrase, selected, capture);
}

fn canApplyEntry(evaluator: *Machine, entry: RegistryEntry) bool {
    const stack = evaluator.unit.stack.items;
    return switch (entry.operation) {
        .unary => switch (entry.context) {
            .direct => evaluator.available() >= 1,
            .each => stack[stack.len - 2] == .list,
            else => false,
        },
        .binary => switch (entry.context) {
            .each => stack[stack.len - 2] == .list,
            .zip_with => blk: {
                const right = stack[stack.len - 2];
                const left = stack[stack.len - 3];
                if (left != .list and right != .list) break :blk false;
                break :blk left != .list or right != .list or left.list.length() == right.list.length();
            },
            .fold, .scan => stack[stack.len - 3] == .list,
            .fold1 => stack[stack.len - 2] == .list and stack[stack.len - 2].list.length() != 0,
            .direct => evaluator.available() >= 2,
        },
        .length, .match => entry.context == .each and stack[stack.len - 2] == .list,
        // `dip` is the one direct entry that needs a second input, and a
        // non-list top must reach the generic composition so the type error
        // still names the word that observed it.
        .direct => |operation| switch (operation) {
            .fold1 => unreachable, // Offers its quotation instead; see `applyTrusted`.
            .dip => evaluator.available() >= 2 and stack[stack.len - 1] == .list,
            .find => evaluator.available() >= 2 and stack[stack.len - 2] == .list,
            .str_format => evaluator.available() >= 2,
            // Any other operand reaches the definition, so its error is the
            // definition's.
            .sum, .product => evaluator.available() >= 1 and stack[stack.len - 1] == .list,
            .reshape_sum, .reshape_product => unreachable, // See `applyPhrase`.
            else => evaluator.available() >= 1,
        },
    };
}

fn applyEntry(evaluator: *Machine, entry: RegistryEntry, capture: Capture) MachineError!void {
    if (capture.active_word) |word| evaluator.setActiveWord(.plain(word));
    try switch (entry.operation) {
        .unary => |operation| switch (entry.context) {
            .direct => unaryPrimitive(operation)(evaluator),
            .each => applyUnaryEach(evaluator, operation),
            else => unreachable,
        },
        .binary => |operation| switch (entry.context) {
            .each => applyConstantEach(
                evaluator,
                operation,
                capture.constant.?,
                entry.constant_left,
            ),
            .zip_with => applyZipWith(evaluator, operation),
            .fold, .fold1, .scan => applyReduction(evaluator, operation, entry.context),
            .direct => binaryPrimitive(operation)(evaluator),
        },
        .match => applyMatchEach(evaluator, capture.constant.?),
        .length => applyLengthEach(evaluator),
        .direct => |operation| applyDirect(evaluator, operation),
    };
}

fn applyDirect(evaluator: *Machine, operation: DirectOp) MachineError!void {
    try switch (operation) {
        .fold1 => unreachable, // Offers its quotation instead; see `applyTrusted`.
        .sort => order.sortForIdiom(evaluator),
        .first => sequence.firstForIdiom(evaluator),
        .find => applyMatchFind(evaluator),
        .rest => sequence.restForIdiom(evaluator),
        .reverse => sequence.reverseForIdiom(evaluator),
        .dip => combinators.dipForIdiom(evaluator),
        .str_format => dict_text.formatForIdiom(evaluator),
        .sum => applyTotal(evaluator, .add, 0),
        .product => applyTotal(evaluator, .mul, 1),
        .reshape_sum, .reshape_product => unreachable, // See `applyPhrase`.
    };
}

/// `sum`/`product` over a list: the empty seed, or `(op) fold1` without the
/// definition's dispatch. The list is the reduction's only consumed value.
fn applyTotal(evaluator: *Machine, operation: numeric.BinaryOp, empty: i64) MachineError!void {
    const stack = evaluator.unit.stack.items;
    const input = stack[stack.len - 1];
    if (input.list.length() == 0) {
        popRelease(evaluator, 1);
        return evaluator.pushOwned(.{ .int = empty });
    }
    return startReduction(evaluator, operation, false, input, list.atUnchecked(input, 0), 1, 1);
}

fn applyUnaryEach(evaluator: *Machine, operation: numeric.UnaryOp) MachineError!void {
    const stack = evaluator.unit.stack.items;
    const input = stack[stack.len - 2];
    std.debug.assert(input == .list);
    // Over a numeric leaf, applying the operation to each element and pervading
    // over the leaf are the same computation, so the recognizer enters the typed
    // loop rather than driving one cursor and one scheduler turn per element.
    if (numeric.typedUnaryCandidate(input)) {
        var quotation = try evaluator.popValue();
        defer quotation.deinit();
        var operand = try evaluator.popValue();
        defer operand.deinit();
        return numeric.idiomUnaryStart(operation)(evaluator, &operand);
    }
    const count: usize = @intCast(input.list.length());
    try PervadeEachDriver.install(evaluator, .{ .unary = operation }, input, null, count, 2);
}

fn applyConstantEach(
    evaluator: *Machine,
    operation: numeric.BinaryOp,
    constant: Value,
    constant_left: bool,
) MachineError!void {
    const stack = evaluator.unit.stack.items;
    const input = stack[stack.len - 2];
    std.debug.assert(input == .list);
    if (numeric.typedConstantCandidate(operation, input, constant, constant_left)) {
        var quotation = try evaluator.popValue();
        defer quotation.deinit();
        var operand = try evaluator.popValue();
        defer operand.deinit();
        // The captured constant is an atom, so it needs no reference of its own:
        // the typed loop reads it with stride zero.
        var scalar = heap.OwnedValue.init(evaluator.releaseDomain(), constant);
        heap.retainValue(constant);
        defer scalar.deinit();
        return if (constant_left)
            numeric.idiomBinaryStart(operation)(evaluator, &scalar, &operand)
        else
            numeric.idiomBinaryStart(operation)(evaluator, &operand, &scalar);
    }
    const count: usize = @intCast(input.list.length());
    try PervadeEachDriver.install(
        evaluator,
        .{ .constant = .{ .operation = operation, .value = constant, .left = constant_left } },
        input,
        null,
        count,
        2,
    );
}

fn applyZipWith(evaluator: *Machine, operation: numeric.BinaryOp) MachineError!void {
    const stack = evaluator.unit.stack.items;
    const right = stack[stack.len - 2];
    const left = stack[stack.len - 3];
    const left_list = left == .list;
    const right_list = right == .list;
    std.debug.assert(left_list or right_list);
    std.debug.assert(!left_list or !right_list or left.list.length() == right.list.length());
    if (numeric.typedBinaryCandidate(operation, left, right)) {
        var quotation = try evaluator.popValue();
        defer quotation.deinit();
        var right_operand = try evaluator.popValue();
        defer right_operand.deinit();
        var left_operand = try evaluator.popValue();
        defer left_operand.deinit();
        return numeric.idiomBinaryStart(operation)(evaluator, &left_operand, &right_operand);
    }
    const count: usize = if (left_list) @intCast(left.list.length()) else @intCast(right.list.length());
    try PervadeEachDriver.install(
        evaluator,
        .{ .zip_with = .{ .operation = operation, .left_list = left_list, .right_list = right_list } },
        left,
        right,
        count,
        3,
    );
}

const PervadeEachDriver = struct {
    const Mode = union(enum) {
        unary: numeric.UnaryOp,
        constant: struct { operation: numeric.BinaryOp, value: Value, left: bool },
        zip_with: struct { operation: numeric.BinaryOp, left_list: bool, right_list: bool },
    };

    mode: Mode,
    left: Value,
    right: ?Value,
    results: heap.Owned(heap.OwnedValueBuffer),
    consumed: usize,
    index: usize = 0,
    cursor: ?heap.Owned(numeric.PervadeCursor) = null,
    materializer: ?heap.Owned(list.ValueMaterializer) = null,

    fn install(
        evaluator: *Machine,
        mode: Mode,
        left: Value,
        right: ?Value,
        count: usize,
        consumed: usize,
    ) error{OutOfMemory}!void {
        const results = try heap.OwnedValueBuffer.init(evaluator.releaseDomain(), count);
        try evaluator.startDriver(PervadeEachDriver{
            .mode = mode,
            .left = left,
            .right = right,
            .results = .init(results),
            .consumed = consumed,
        });
    }

    /// Elements run one after another within a step until the budget is spent,
    /// through one cursor armed in place for each.
    pub fn advance(evaluator: *Machine, self: *PervadeEachDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        const count = self.results.borrow().capacity();
        while (self.index != count) {
            if (self.cursor == null) {
                self.cursor = .init(numeric.PervadeCursor.initIdle(evaluator.releaseDomain(), evaluator.allocator()));
                self.arm(self.cursor.?.borrowMut());
            }
            switch (try self.cursor.?.borrowMut().advance(evaluator, work)) {
                .pending => return .stepped,
                .complete => |result| {
                    self.results.borrowMut().appendOwned(result);
                    self.index += 1;
                    if (self.index != count) self.arm(self.cursor.?.borrowMut());
                },
            }
        }
        if (self.cursor) |*cursor| {
            cursor.deinit(evaluator.releaseDomain(), evaluator.allocator());
            self.cursor = null;
        }
        if (self.materializer == null)
            self.materializer = .init(.init(evaluator.allocator(), self.results.borrow().values()));
        if (work.exhausted()) return .stepped;
        return switch (try self.materializer.?.borrowMut().advance(work)) {
            .pending => .stepped,
            .complete => |result| completed: {
                popRelease(evaluator, self.consumed);
                break :completed .{ .output = result };
            },
        };
    }

    /// Arms `cursor` with the operation on the element at `index`.
    fn arm(self: *const PervadeEachDriver, cursor: *numeric.PervadeCursor) void {
        switch (self.mode) {
            .unary => |operation| cursor.rearmUnary(operation, list.atUnchecked(self.left, self.index)),
            .constant => |constant| {
                const item = list.atUnchecked(self.left, self.index);
                cursor.rearmBinary(
                    constant.operation,
                    if (constant.left) constant.value else item,
                    if (constant.left) item else constant.value,
                );
            },
            .zip_with => |zip_with| cursor.rearmBinary(
                zip_with.operation,
                if (zip_with.left_list) list.atUnchecked(self.left, self.index) else self.left,
                if (zip_with.right_list) list.atUnchecked(self.right.?, self.index) else self.right.?,
            ),
        }
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn applyLengthEach(evaluator: *Machine) MachineError!void {
    const stack = evaluator.unit.stack.items;
    const input = stack[stack.len - 2];
    const count: usize = @intCast(input.list.length());
    if (count == 0) return finishCollected(evaluator, &.{}, 2);
    const writer = try heap.LeafWriter(.leaf_i64).init(evaluator.allocator(), count);
    try evaluator.startDriver(LengthEachDriver{ .input = input, .writer = .init(writer) });
}

const LengthEachDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    // The caller's stack owns input and quotation until successful publication.
    input: Value,
    writer: heap.Owned(heap.LeafWriter(.leaf_i64)),
    index: usize = 0,

    pub fn advance(evaluator: *Machine, self: *LengthEachDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const count: usize = @intCast(self.input.list.length());
        const end = self.index + evaluator.workBudget().take(count - self.index);
        while (self.index < end) : (self.index += 1) {
            const item = list.atUnchecked(self.input, self.index);
            if (item != .list) return evaluator.typeError("a list");
            self.writer.borrowMut().fillRange(self.index, 1, @intCast(item.list.length()));
        }
        if (self.index != count) return .stepped;
        popRelease(evaluator, 2);
        return .{ .output = self.writer.borrowMut().finish() };
    }
};

fn applyMatchEach(evaluator: *Machine, constant: Value) MachineError!void {
    const stack = evaluator.unit.stack.items;
    const input = stack[stack.len - 2];
    std.debug.assert(input == .list);
    const count: usize = @intCast(input.list.length());
    if (count == 0) return finishCollected(evaluator, &.{}, 2);
    const writer = try heap.LeafWriter(.leaf_u8).init(evaluator.allocator(), count);
    try evaluator.startDriver(MatchEachDriver{
        .input = input,
        .constant = constant,
        .writer = .init(writer),
    });
}

/// The recognized `(constant match?) each` family writes its known boolean
/// result representation directly. Atomic pairs stay in one bounded loop;
/// structured pairs retain `match?`'s iterative, allocation-fallible cursor.
const MatchEachDriver = struct {
    input: Value,
    constant: Value,
    writer: heap.Owned(heap.LeafWriter(.leaf_u8)),
    index: usize = 0,
    cursor: ?heap.Owned(equal.MatchCursor) = null,

    pub fn advance(evaluator: *Machine, self: *MatchEachDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const count: usize = @intCast(self.input.list.length());
        const work = evaluator.workBudget();
        while (self.index != count and work.spend()) {
            const item = list.atUnchecked(self.input, self.index);
            if (self.cursor == null) {
                if (equal.matchWithoutStructure(item, self.constant)) |matches| {
                    self.writer.borrowMut().fillRange(self.index, 1, @intFromBool(matches));
                    self.index += 1;
                    continue;
                }
                self.cursor = .init(try .init(evaluator.allocator(), item, self.constant));
            }
            switch (try self.cursor.?.borrowMut().advance(work)) {
                .pending => return .stepped,
                .complete => |matches| {
                    self.cursor.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.cursor = null;
                    self.writer.borrowMut().fillRange(self.index, 1, @intFromBool(matches));
                    self.index += 1;
                    // The comparison drew on the same budget, so the next
                    // element continues within the turn while it lasts.
                    continue;
                },
            }
        }
        if (self.index != count) return .stepped;
        popRelease(evaluator, 2);
        return .{ .output = self.writer.borrowMut().finish() };
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn applyMatchFind(evaluator: *Machine) MachineError!void {
    const stack = evaluator.unit.stack.items;
    const input = stack[stack.len - 2];
    std.debug.assert(input == .list);
    try evaluator.startDriver(MatchFindDriver{
        .input = input,
        .needle = stack[stack.len - 1],
    });
}

/// The recognized `find` source word compares until its first hit and returns
/// the miss sentinel directly. Atomic pairs share `match?`'s scalar authority;
/// structured pairs retain the same allocation-fallible bounded cursor.
const MatchFindDriver = struct {
    pub const inline_driver = true;

    input: Value,
    needle: Value,
    index: usize = 0,
    cursor: ?heap.Owned(equal.MatchCursor) = null,

    fn finish(self: *MatchFindDriver, evaluator: *Machine, index: usize) machine.WorkProgress {
        if (self.cursor) |*cursor| cursor.deinit(evaluator.releaseDomain(), evaluator.allocator());
        self.cursor = null;
        popRelease(evaluator, 2);
        return .{ .output = .{ .int = @intCast(index) } };
    }

    pub fn advance(evaluator: *Machine, self: *MatchFindDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const count: usize = @intCast(self.input.list.length());
        const work = evaluator.workBudget();
        while (self.index != count and work.spend()) {
            const item = list.atUnchecked(self.input, self.index);
            if (self.cursor == null) {
                if (equal.matchWithoutStructure(item, self.needle)) |matches| {
                    if (matches) return self.finish(evaluator, self.index);
                    self.index += 1;
                    continue;
                }
                self.cursor = .init(try .init(evaluator.allocator(), item, self.needle));
            }
            switch (try self.cursor.?.borrowMut().advance(work)) {
                .pending => return .stepped,
                .complete => |matches| {
                    self.cursor.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.cursor = null;
                    if (matches) return self.finish(evaluator, self.index);
                    self.index += 1;
                    // The comparison drew on the same budget, so the next
                    // element continues within the turn while it lasts.
                    continue;
                },
            }
        }
        if (self.index != count) return .stepped;
        return self.finish(evaluator, count);
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn applyReduction(
    evaluator: *Machine,
    operation: numeric.BinaryOp,
    context: Context,
) MachineError!void {
    const scan = context == .scan;
    const from_first = context == .fold1;
    const consumed: usize = if (from_first) 2 else 3;
    const start: usize = if (from_first) 1 else 0;
    const stack = evaluator.unit.stack.items;
    const input = stack[stack.len - consumed];
    const initial = if (from_first) list.atUnchecked(input, 0) else stack[stack.len - 2];
    return startReduction(evaluator, operation, scan, input, initial, start, consumed);
}

/// `consumed` stack values lie under the result: the list is the deepest,
/// and `start` is 1 when `initial` is its first element.
fn startReduction(
    evaluator: *Machine,
    operation: numeric.BinaryOp,
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
            popRelease(evaluator, consumed);
            return evaluator.pushOwned(result.take());
        }
        if (scan) return finishCollected(evaluator, &.{}, 3);
        popRelease(evaluator, 1);
        var accumulator = try evaluator.popValue();
        defer accumulator.deinit();
        popRelease(evaluator, 1);
        try evaluator.pushOwned(accumulator.take());
        return;
    }
    // Over a numeric leaf with an accumulator that stabilizes after at most
    // one scalar step, reduction is one typed sequential pass instead of one
    // cursor and one scheduler turn per element. Association stays left-to-right, so
    // float sums keep the generic route's bits.
    if (numeric.typedReduceCandidate(operation, input, initial)) {
        return numeric.idiomReduceStart(operation)(evaluator, input, initial, scan, start, consumed);
    }
    const results: ?heap.OwnedValueBuffer = if (scan)
        try .init(evaluator.releaseDomain(), count)
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
    /// Like `numeric.TypedReduceDriver`, it lives for one reduction and
    /// releases the slot when it publishes, so it qualifies for the slot on
    /// lifetime; a fold whose rows apply directly would otherwise spend its
    /// largest fixed cost on this driver's allocation.
    pub const inline_driver = true;

    consumed: usize,
    operation: numeric.BinaryOp,
    scan: bool,
    input: Value,
    accumulator: heap.Owned(Accumulator),
    results: ?heap.Owned(heap.OwnedValueBuffer),
    initialized: usize = 0,
    materializing: bool = false,
    materializer: ?heap.Owned(list.ValueMaterializer),
    // Not optional: emptying a `?Owned` of this size clears it whole, and
    // the cursor is emptied once per row.
    cursor: heap.Owned(numeric.PervadeCursor) = .none,

    pub fn advance(
        evaluator: *Machine,
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
            switch (try numeric.foldLeafRow(
                evaluator,
                self.operation,
                accumulator.value(),
                owned,
                list.atUnchecked(self.input, self.initialized),
            )) {
                .declined => break,
                .in_place => |next| accumulator.* = .{ .owned = next },
                .fresh => |next| accumulator.replaceOwned(evaluator.releaseDomain(), next),
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
                        evaluator.releaseDomain(),
                        evaluator.allocator(),
                        self.operation,
                        .init(evaluator.releaseDomain(), self.accumulator.borrowMut().takeOwned()),
                        row,
                    )
                else
                    try .initBinary(
                        evaluator.releaseDomain(),
                        evaluator.allocator(),
                        self.operation,
                        self.accumulator.borrow().value(),
                        row,
                    ));
            }
            const next = switch (try self.cursor.borrowMut().advance(evaluator, evaluator.workBudget())) {
                .pending => return .stepped,
                .complete => |result| result,
            };
            self.cursor.deinit(evaluator.releaseDomain(), evaluator.allocator());
            if (self.scan) {
                self.results.?.borrowMut().appendOwned(next);
                self.accumulator.borrowMut().* = .{ .borrowed = next };
            } else {
                self.accumulator.borrowMut().replaceOwned(evaluator.releaseDomain(), next);
            }
            self.initialized += 1;
            return .stepped;
        }
        if (!self.scan) {
            popRelease(evaluator, self.consumed);
            return .{ .output = self.accumulator.borrowMut().takeOwned() };
        }
        if (!self.materializing) {
            self.materializer = .init(.init(
                evaluator.allocator(),
                self.results.?.borrow().values(),
            ));
            self.materializing = true;
        }
        return switch (try self.materializer.?.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |result| completed: {
                popRelease(evaluator, 3);
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

fn finishCollected(evaluator: *Machine, values: []const Value, consumed: usize) MachineError!void {
    std.debug.assert(values.len == 0);
    const result = try list.fromValuesGeneric(evaluator.allocator(), values);
    popRelease(evaluator, consumed);
    try evaluator.pushOwned(result);
}

fn popRelease(evaluator: *Machine, count: usize) void {
    evaluator.discard(count);
}

fn operationPrimitive(operation: Operation) ?env.PrimitiveImpl {
    return switch (operation) {
        .unary => |selected| unaryPrimitive(selected),
        .binary => |selected| binaryPrimitive(selected),
        .match, .length => null,
        .direct => null,
    };
}

fn operationBinding(operation: Operation) BindingKind {
    return switch (operation) {
        .unary => |selected| switch (selected) {
            .neg, .abs => .source,
            else => .builtin,
        },
        .binary => |selected| switch (selected) {
            .mod, .ne, .le, .ge, .and_word, .or_word => .source,
            else => .builtin,
        },
        .match, .length => .builtin,
        .direct => .source,
    };
}

fn unaryPrimitive(operation: numeric.UnaryOp) env.PrimitiveImpl {
    return switch (operation) {
        inline else => |selected| numeric.unaryPrimitiveFor(selected),
    };
}

fn binaryPrimitive(operation: numeric.BinaryOp) env.PrimitiveImpl {
    return switch (operation) {
        inline else => |selected| numeric.binaryPrimitiveFor(selected),
    };
}

/// Whether a word linked to `slot_id` resolves where the phrase runs: its
/// slot belongs to core or to the running activation's root. An unlinked word
/// links where it runs, so it matches by definition. Recognition then reads
/// the slot, so a root that has shadowed the name still declines.
fn slotOnRunningRoot(evaluator: *machine.Machine, slot_id: u32) bool {
    const root_id: u32 = switch (env.wordTarget(slot_id)) {
        .unlinked => return true,
        .local => return false,
        .image => |scope| @backingInt(scope),
        .slot => |id| root: {
            const slot = evaluator.unit.environment.slot(id) orelse return false;
            const root = slot.rootCell();
            if (root.core) return true;
            break :root @backingInt(root.id);
        },
    };
    const running = evaluator.unit.current.?.resolutionScope() orelse return false;
    return @backingInt(running.cellId()) == root_id;
}
