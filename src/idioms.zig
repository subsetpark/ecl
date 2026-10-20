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

    pub fn spelling(self: DirectOp) []const u8 {
        return switch (self) {
            .str_format => "str.format",
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
};
pub const PatternAtom = union(enum) {
    /// A non-word value, which becomes the operation's constant operand.
    /// `literal` leaves every non-word as itself, so this is also what
    /// `partial` prefixes onto its quotation.
    constant,
    literal,
    quotation_word: ExpectedWord,
    operation,
    word: ExpectedWord,
};
pub const RegistryEntry = struct {
    context: Context,
    pattern: []const PatternAtom,
    operation: Operation,
    constant_left: bool = false,
    source_word: ?[]const u8 = null,
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
    .{ .word = .{ .spelling = "grade" } },
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
    .{ .quotation_word = .{ .spelling = "match?" } },
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
    var entries: [unary_count + binary_count * 3 + 3 + 18 + 16]RegistryEntry = undefined;
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
        if (entry.context != .direct) continue;
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
        if (phrase.list.length() != entry.pattern.len) continue;
        const capture = matchFrozen(lookup, phrase, entry) orelse continue;
        return .{
            .entry = @intCast(index),
            .constant = capture.constant,
            .active_word = capture.active_word,
            .active_index = capture.active_index,
        };
    }
    return null;
}

/// The atom-by-atom match `IdiomDriver` performs, over a frozen environment.
fn matchFrozen(lookup: env.FrozenLookup, phrase: Value, entry: RegistryEntry) ?Capture {
    var capture: Capture = .{};
    for (entry.pattern, 0..) |atom, atom_index| {
        const actual = list.atUnchecked(phrase, atom_index);
        switch (atom) {
            .constant => {
                if (capture.constant != null or actual == .word) return null;
                capture.constant = actual;
            },
            .literal => if (actual == .word) return null,
            .quotation_word => |expected| {
                if (actual != .list or actual.list.length() != 1) return null;
                const quoted = list.atUnchecked(actual, 0);
                if (quoted != .word or !frozenWordMatches(lookup, quoted.word, expected)) return null;
            },
            .operation => {
                if (actual != .word) return null;
                const word = actual.word;
                if (!std.mem.eql(u8, intern.get(word.name), entry.operation.spelling())) return null;
                const binding = operationBinding(entry.operation);
                const primitive = if (binding == .builtin) operationPrimitive(entry.operation) else null;
                if (!frozenBindingMatches(lookup, word, binding, primitive, .trusted)) return null;
                capture.active_word = word.name;
                capture.active_index = @intCast(atom_index);
            },
            .word => |expected| {
                if (actual != .word or !frozenWordMatches(lookup, actual.word, expected)) return null;
                if (std.mem.eql(u8, expected.spelling, "grade")) {
                    capture.active_word = actual.word.name;
                    capture.active_index = @intCast(atom_index);
                }
            },
        }
    }
    return capture;
}

fn frozenWordMatches(lookup: env.FrozenLookup, word: value.WordRef, expected: ExpectedWord) bool {
    if (!std.mem.eql(u8, intern.get(word.name), expected.spelling)) return false;
    return frozenBindingMatches(lookup, word, expected.binding, null, expected.origin);
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
        .builtin => hit.lease.binding == .builtin and
            (primitive == null or hit.lease.binding.builtin == primitive.?),
        .source => hit.lease.binding == .word,
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
    return matchOffered(evaluator, .{ .candidate = candidate, .entries = entries }, decline);
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
/// length. The work is bounded by the registry's shape, so it runs where the
/// combinator applies; a pattern word whose resolution the call-site cache
/// cannot answer is handed out to be resolved across turns.
const Matcher = struct {
    candidate: Candidate,
    entries: []const u16,
    entry_index: usize = 0,
    atom_index: usize = 0,
    capture: Capture = .{},
    expected: ?env.PrimitiveImpl = null,
    expected_binding: BindingKind = .builtin,

    /// A pattern word to resolve; `cache` is where its answer is recorded.
    const Step = union(enum) { progressed, done: ?RegistryEntry };

    fn phraseSite(self: *const Matcher) machine.ErrorSite {
        return .{ .code = self.candidate.phrase.list, .index = @intCast(self.atom_index) };
    }
    fn rejectEntry(self: *Matcher) void {
        self.entry_index += 1;
        self.atom_index = 0;
        self.capture = .{};
        self.expected = null;
        self.expected_binding = .builtin;
    }
    /// Whether the resolved word is the trusted binding the atom expects.
    fn accept(self: *Matcher, resolved: *const machine.Resolution) void {
        const binding_matches = switch (self.expected_binding) {
            .builtin => resolved.lease.binding == .builtin and
                (self.expected == null or resolved.lease.binding.builtin == self.expected.?),
            .source => resolved.lease.binding == .word,
        };
        const origin_matches = resolved.origin == .core or resolved.origin == .standard_library;
        if (!origin_matches or !binding_matches) return self.rejectEntry();
        self.atom_index += 1;
        self.expected = null;
        self.expected_binding = .builtin;
    }
    /// Resolves a pattern word through its slot. A word that resolves to
    /// nothing a plain word may run, or whose root has retired, is simply not
    /// the expected binding; generic execution reports any error.
    fn resolve(self: *Matcher, evaluator: *Machine, word: value.WordRef) Step {
        var resolved = evaluator.peekSlotWord(word) orelse {
            self.rejectEntry();
            return .progressed;
        };
        defer resolved.deinit(evaluator.allocator());
        self.accept(&resolved);
        return .progressed;
    }
    fn expectWord(
        self: *Matcher,
        evaluator: *Machine,
        word: value.WordRef,
        expected_word: ExpectedWord,
    ) Step {
        std.debug.assert(expected_word.origin == .trusted);
        if (!std.mem.eql(u8, intern.get(word.name), expected_word.spelling) or
            !slotOnRunningRoot(evaluator, word.slot))
        {
            self.rejectEntry();
            return .progressed;
        }
        self.expected_binding = expected_word.binding;
        self.expected = null;
        return self.resolve(evaluator, word);
    }
    fn step(self: *Matcher, evaluator: *Machine) Step {
        if (self.entry_index == self.entries.len) return .{ .done = null };
        const entry = registry[self.entries[self.entry_index]];
        if (self.atom_index == entry.pattern.len)
            return .{ .done = if (canApplyEntry(evaluator, entry)) entry else null };
        const actual = list.atUnchecked(self.candidate.phrase, self.atom_index);
        switch (entry.pattern[self.atom_index]) {
            .constant => {
                if (self.capture.constant != null or actual == .word) {
                    self.rejectEntry();
                    return .progressed;
                }
                self.capture.constant = actual;
                self.atom_index += 1;
            },
            .literal => {
                if (actual == .word) {
                    self.rejectEntry();
                    return .progressed;
                }
                self.atom_index += 1;
            },
            .quotation_word => |expected_word| {
                if (actual != .list or actual.list.length() != 1) {
                    self.rejectEntry();
                    return .progressed;
                }
                const quoted = list.atUnchecked(actual, 0);
                if (quoted != .word) {
                    self.rejectEntry();
                    return .progressed;
                }
                return self.expectWord(evaluator, quoted.word, expected_word);
            },
            .operation => {
                if (actual != .word or
                    !std.mem.eql(u8, intern.get(actual.word.name), entry.operation.spelling()) or
                    !slotOnRunningRoot(evaluator, actual.word.slot))
                {
                    self.rejectEntry();
                    return .progressed;
                }
                self.capture.active_word = actual.word.name;
                self.capture.active_index = @intCast(self.atom_index);
                self.expected_binding = operationBinding(entry.operation);
                self.expected = if (self.expected_binding == .builtin)
                    operationPrimitive(entry.operation)
                else
                    null;
                return self.resolve(evaluator, actual.word);
            },
            .word => |expected_word| {
                if (actual != .word) {
                    self.rejectEntry();
                    return .progressed;
                }
                // Recorded before resolving: a cached answer advances the
                // atom at once.
                if (std.mem.eql(u8, expected_word.spelling, "grade")) {
                    self.capture.active_word = actual.word.name;
                    self.capture.active_index = @intCast(self.atom_index);
                }
                return self.expectWord(evaluator, actual.word, expected_word);
            },
        }
        return .progressed;
    }
};

/// Matches as far as the call-site cache allows, settling at once when it
/// answers every pattern word; otherwise a driver resolves the missing word
/// and carries the match on from there.
fn matchOffered(evaluator: *Machine, matcher: Matcher, decline: Decline) MachineError!void {
    var matching = matcher;
    while (true) switch (matching.step(evaluator)) {
        .progressed => {},
        .done => |entry| {
            const selected = entry orelse return decline.run(evaluator);
            decline.discard(evaluator);
            return applySelected(evaluator, matching.candidate.phrase, selected, matching.capture);
        },
    };
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
    };
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

    pub fn advance(evaluator: *Machine, self: *PervadeEachDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.index != self.results.borrow().capacity()) {
            if (self.cursor == null) self.cursor = .init(try self.startCursor(
                evaluator.releaseDomain(),
                evaluator.allocator(),
            ));
            switch (try self.cursor.?.borrowMut().advance(evaluator, evaluator.workBudget())) {
                .pending => return .stepped,
                .complete => |result| {
                    self.cursor.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.cursor = null;
                    self.results.borrowMut().appendOwned(result);
                    self.index += 1;
                    return .stepped;
                },
            }
        }
        if (self.materializer == null)
            self.materializer = .init(.init(evaluator.allocator(), self.results.borrow().values()));
        return switch (try self.materializer.?.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |result| completed: {
                popRelease(evaluator, self.consumed);
                break :completed .{ .output = result };
            },
        };
    }

    fn startCursor(
        self: *PervadeEachDriver,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!numeric.PervadeCursor {
        return switch (self.mode) {
            .unary => |operation| .initUnary(
                releases,
                allocator,
                operation,
                list.atUnchecked(self.left, self.index),
            ),
            .constant => |constant| blk: {
                const item = list.atUnchecked(self.left, self.index);
                break :blk .initBinary(
                    releases,
                    allocator,
                    constant.operation,
                    if (constant.left) constant.value else item,
                    if (constant.left) item else constant.value,
                );
            },
            .zip_with => |zip_with| .initBinary(
                releases,
                allocator,
                zip_with.operation,
                if (zip_with.left_list) list.atUnchecked(self.left, self.index) else self.left,
                if (zip_with.right_list) list.atUnchecked(self.right.?, self.index) else self.right.?,
            ),
        };
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
