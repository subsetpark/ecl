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
const combinators = @import("combinators.zig");

const Value = value.Value;
const Fiber = machine.Fiber;
const MachineError = machine.MachineError;

pub const Context = enum {
    /// A builtin head continued by the words after it.
    phrase,
    each,
    zip_with,
    fold,
    fold1,
    scan,
    lex_cmp,
};
pub const PhraseOp = enum {
    /// `reshape` continued by `sum` or `product`: the fold over the rows a
    /// two-axis reshape would build, without building them.
    reshape_sum,
    reshape_product,
    /// `where` continued by `at`: the elements a mask selects, without the
    /// index list `where` would build.
    where_at,
    /// `cons` continued by `call`: `x (q) cons call` runs `q` with `x` on
    /// the stack, which is what calling `(x q...)` does, without building it.
    /// `cons` stores its head as data, so this holds for every head: a symbol
    /// enters quoted and the built quotation would push it.
    cons_call,
    /// `cons` continued by `dip`: `x (q) cons dip` protects the value beneath
    /// `x` and runs `q` with `x` on the stack, without building `(x q...)`.
    cons_dip,

    pub fn spelling(self: PhraseOp) []const u8 {
        return switch (self) {
            .reshape_sum, .reshape_product => "reshape",
            .where_at => "where",
            .cons_call, .cons_dip => "cons",
        };
    }
};
pub const Operation = union(enum) {
    unary: numeric.UnaryOp,
    binary: numeric.BinaryOp,
    match,
    length,
    /// `cmp` as a lexicographic comparator.
    cmp,
    phrase: PhraseOp,

    pub fn spelling(self: Operation) []const u8 {
        return switch (self) {
            .unary => |operation| operation.spelling(),
            .binary => |operation| operation.spelling(),
            .match => "match?",
            .length => "len",
            .cmp => "cmp",
            .phrase => |operation| operation.spelling(),
        };
    }
};
pub const ExpectedWord = struct {
    spelling: []const u8,
};
pub const PatternAtom = union(enum) {
    /// A non-word value, which becomes the operation's constant operand.
    constant,
    /// The entry's own operation word, which is also its active word.
    operation,
    word: ExpectedWord,
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
const unary_count = @typeInfo(numeric.UnaryOp).@"enum".field_names.len;
const binary_count = @typeInfo(numeric.BinaryOp).@"enum".field_names.len;
pub const registry = blk: {
    var entries: [unary_count + binary_count * 3 + 4 + 18 + 5]RegistryEntry = undefined;
    var index: usize = 0;
    entries[index] = .{ .context = .each, .pattern = &operation_pattern, .operation = .length };
    entries[index + 1] = .{ .context = .lex_cmp, .pattern = &operation_pattern, .operation = .cmp };
    index += 2;
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
    for ([_]struct { operation: PhraseOp, total: []const u8 }{
        .{ .operation = .reshape_sum, .total = "sum" },
        .{ .operation = .reshape_product, .total = "product" },
    }) |phrase| {
        entries[index] = .{
            .context = .phrase,
            .pattern = &.{},
            .operation = .{ .phrase = phrase.operation },
            .source_word = "reshape",
            .following = &.{.{ .spelling = phrase.total }},
        };
        index += 1;
    }
    entries[index] = .{
        .context = .phrase,
        .pattern = &.{},
        .operation = .{ .phrase = .where_at },
        .source_word = "where",
        .following = &.{.{ .spelling = "at" }},
    };
    index += 1;
    for ([_]struct { operation: PhraseOp, consumer: []const u8 }{
        .{ .operation = .cons_call, .consumer = "call" },
        .{ .operation = .cons_dip, .consumer = "dip" },
    }) |phrase| {
        entries[index] = .{
            .context = .phrase,
            .pattern = &.{},
            .operation = .{ .phrase = phrase.operation },
            .source_word = phrase.operation.spelling(),
            .following = &.{.{ .spelling = phrase.consumer }},
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

/// Whether `word`, where the phrase runs, is the core binding expected: a
/// builtin, and the given primitive when one is named.
fn wordMatches(evaluator: *Fiber, word: value.Symbol, primitive: ?env.PrimitiveImpl) bool {
    if (!plainWord(word.slot)) return false;
    return liveWord(evaluator.peekWord(word), primitive) != null;
}

/// A following word, resolved as its own dispatch would resolve it: through
/// the fiber's resolutions, so a phrase that runs on every iteration pays one
/// probe rather than a full lookup. A word the fiber has not resolved is
/// looked up in full and remembered, since the phrase consumes it instead of
/// dispatching it. Either way it must be the core builtin expected; its trace
/// word is what a fault inside the phrase names.
fn followingWord(evaluator: *Fiber, word: value.Symbol) error{OutOfMemory}!?intern.TraceWord {
    if (!plainWord(word.slot)) return null;
    return liveWord(try evaluator.resolveForRecognition(word), null);
}

/// Resolves `word` where the phrase runs and returns its trace word only when
/// it is the trusted binding expected. A word that resolves to nothing a plain
/// word may run, or whose root has retired, is simply not that binding;
/// generic execution reports any error.
fn liveWord(peeked: ?machine.PeekedWord, primitive: ?env.PrimitiveImpl) ?intern.TraceWord {
    const resolved = peeked orelse return null;
    if (resolved.origin != .core and resolved.origin != .standard_library) return null;
    const code = resolved.definition.code();
    if (code != .builtin or (primitive != null and code.builtin != primitive.?)) return null;
    return resolved.trace_word;
}

/// Matches an offered quotation against one entry's pattern, checking each
/// pattern word's binding where the quotation runs.
fn matchPhrase(evaluator: *Fiber, phrase: Value, entry: RegistryEntry) ?Capture {
    if (phrase != .list or phrase.list.length() != entry.pattern.len) return null;
    var capture: Capture = .{};
    for (entry.pattern, 0..) |atom, atom_index| {
        const actual = list.atUnchecked(phrase, atom_index);
        switch (atom) {
            .constant => {
                if (capture.constant != null or actual == .symbol) return null;
                capture.constant = actual;
            },
            .operation => {
                // A quoted occurrence pushes its symbol; it is never the operation.
                if (actual != .symbol or env.isQuoted(actual.symbol.slot) or
                    !std.mem.eql(u8, intern.get(actual.symbol.name), entry.operation.spelling())) return null;
                if (!wordMatches(evaluator, actual.symbol, operationPrimitive(entry.operation))) return null;
                capture.active_word = actual.symbol.name;
                capture.active_index = @intCast(atom_index);
            },
            .word => |expected| {
                if (actual != .symbol or env.isQuoted(actual.symbol.slot) or
                    !std.mem.eql(u8, intern.get(actual.symbol.name), expected.spelling)) return null;
                if (!wordMatches(evaluator, actual.symbol, null)) return null;
            },
        }
    }
    return capture;
}

pub fn tryApply(
    evaluator: *Fiber,
    request: machine.IdiomRequest,
    fallback: machine.IdiomFallback,
) MachineError!void {
    if (evaluator.inherited.idiom_mode == .generic_only) return fallback(evaluator);
    const candidate = requestCandidate(evaluator, request) orelse return fallback(evaluator);
    const entries = entriesShaped(candidate.context, candidate.phrase.list.length());
    // A quotation of any length may be a scalar program.
    if (entries.len == 0 and candidate.context == .lex_cmp)
        return fallback(evaluator);
    // Inside a finite iteration's call the phrase's words keep their bindings,
    // so the phrase it offered before matches the same way again.
    const planned = try evaluator.planEntry();
    if (planned) |entry| if (entry.offered) |offered| if (offered.request == request and offered.phrase == candidate.phrase.list)
        return applyMatched(evaluator, candidate.phrase, offered.entry, .{
            .constant = offered.constant,
            .active_word = offered.active_word,
            .active_index = offered.active_index,
        }, fallback);
    return matchOffered(evaluator, candidate, entries, fallback, request, planned);
}

/// A quotation offered to a combinator.
const Candidate = struct {
    context: Context,
    phrase: Value,
};

const Capture = struct {
    constant: ?Value = null,
    active_word: ?u32 = null,
    active_index: ?u32 = null,
};

fn requestCandidate(evaluator: *Fiber, request: machine.IdiomRequest) ?Candidate {
    const context: Context, const depth: usize = switch (request) {
        .each => .{ .each, 2 },
        .fold1 => .{ .fold1, 2 },
        .lex_cmp => .{ .lex_cmp, 3 },
        .zip_with => .{ .zip_with, 3 },
        .fold => .{ .fold, 3 },
        .scan => .{ .scan, 3 },
    };
    if (evaluator.available() < depth) return null;
    const phrase = evaluator.stack.items[evaluator.stack.items.len - 1];
    if (phrase != .list) return null;
    return .{ .context = context, .phrase = phrase };
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
        if (entry.context != .phrase) @compileError("a phrase entry must have the phrase context");
        const first = firstPhraseEntry(entry.source_word.?).?;
        for (registry[first..index]) |between| {
            if (between.following.len == 0 or !std.mem.eql(u8, between.source_word.?, entry.source_word.?))
                @compileError("phrase entries of one head must be consecutive: " ++ entry.source_word.?);
        }
    }
}

comptime {
    @setEvalBranchQuota(1_000_000);
    for (registry) |entry| switch (entry.context) {
        .fold, .scan, .fold1 => if (entry.operation == .binary and !numeric.reducesIntLanesTyped(entry.operation.binary))
            @compileError("a recognized reduction has no typed plan over int lanes: " ++ entry.operation.binary.spelling()),
        else => {},
    };
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
/// can head one: a primitive reached any other way declines, as does a fiber
/// that runs generic code only.
pub fn applyHeaded(evaluator: *Fiber, first: u16) MachineError!bool {
    if (evaluator.inherited.idiom_mode == .generic_only) return false;
    if (evaluator.active_word.atom() != try phraseAtom(first, 0)) return false;
    return applyPhrase(evaluator, first);
}

/// A builtin head continued by the words after it. Each entry the head
/// heads is tried in registry order; the first whose following words are
/// the expected core builtins, here, and whose operands admit it, applies
/// and consumes those words. The fused pass reports a fault as the last
/// following word would: it is the only word that can fault, and a builtin
/// has no site inside a body.
fn applyPhrase(evaluator: *Fiber, first: u16) MachineError!bool {
    const name = registry[first].source_word.?;
    var index = first;
    while (index < registry.len) : (index += 1) {
        const entry = registry[index];
        if (entry.following.len == 0 or !std.mem.eql(u8, entry.source_word.?, name)) break;
        const count: u32 = @intCast(entry.following.len);
        const forms = evaluator.followingForms(count) orelse return false;
        var last: ?intern.TraceWord = null;
        const matched = for (0..entry.following.len) |offset| {
            const form = forms.at(@intCast(offset));
            if (form != .symbol or env.isQuoted(form.symbol.slot) or form.symbol.name != try phraseAtom(index, offset + 1)) break false;
            last = try followingWord(evaluator, form.symbol) orelse break false;
        } else true;
        if (!matched) continue;
        switch (entry.operation.phrase) {
            .where_at => {
                if (!compressShape(evaluator)) continue;
                commitPhrase(evaluator, count, last.?);
                var mask = try evaluator.popValue();
                defer mask.deinit();
                var source = try evaluator.popValue();
                defer source.deinit();
                try sequence.compress(evaluator, &source, &mask);
            },
            .reshape_sum, .reshape_product => |operation| {
                const shape = columnFoldShape(evaluator, operation) orelse continue;
                commitPhrase(evaluator, count, last.?);
                var shape_owner = try evaluator.popValue();
                defer shape_owner.deinit();
                var input = try evaluator.popValue();
                defer input.deinit();
                try numeric.foldColumns(evaluator, columnOperation(operation), &input, shape.rows, shape.columns);
            },
            .cons_call => {
                if (!consShape(evaluator, 2)) continue;
                commitPhrase(evaluator, count, last.?);
                var quotation = try evaluator.popValue();
                try evaluator.callOwned(quotation.take().list);
            },
            .cons_dip => {
                if (!consShape(evaluator, 3)) continue;
                commitPhrase(evaluator, count, last.?);
                try combinators.dipBelowHead(evaluator);
            },
        }
        return true;
    }
    return false;
}

/// Whether `x quotation cons` followed by a word that runs the result can
/// skip building it: `depth` operands and a list on top. The built quotation
/// would push the head as data, so the head may stay where it sits; a symbol
/// head is unquoted in place, as the built quotation's push would leave it.
/// Any other shape runs the words as written, which reports `cons`'s own
/// type error.
fn consShape(evaluator: *Fiber, depth: usize) bool {
    if (evaluator.available() < depth) return false;
    const stack = evaluator.stack.items;
    if (stack[stack.len - 1] != .list) return false;
    const head = &stack[stack.len - 2];
    if (head.* == .symbol) head.symbol.slot = env.unquoted(head.symbol.slot);
    return true;
}

/// Consumes a matched phrase's following words, whose last one is now the
/// active word.
fn commitPhrase(evaluator: *Fiber, count: u32, last: intern.TraceWord) void {
    evaluator.idiom_hits += 1;
    evaluator.phrase_hits += 1;
    evaluator.skipFollowingForms(count);
    evaluator.commitPhraseTrace();
    evaluator.active_word = last;
}

fn columnOperation(operation: PhraseOp) numeric.BinaryOp {
    return switch (operation) {
        .reshape_sum => .add,
        .reshape_product => .mul,
        else => unreachable,
    };
}

/// Whether `list mask where at` can run as one pass over the list: see
/// `kernel_sequence.compress`. Anything else runs the words as written.
fn compressShape(evaluator: *Fiber) bool {
    if (evaluator.available() < 2) return false;
    const stack = evaluator.stack.items;
    return sequence.compressCandidate(stack[stack.len - 2], stack[stack.len - 1]);
}

/// The rows and columns of `list [rows columns] reshape` when its fold over
/// rows can run on the list itself: a two-axis shape of positive ints whose
/// volume is the list's length, and a numeric leaf the operation keeps typed.
/// Anything else runs the words as written.
fn columnFoldShape(evaluator: *Fiber, operation: PhraseOp) ?struct { rows: usize, columns: usize } {
    if (evaluator.available() < 2) return null;
    const stack = evaluator.stack.items;
    const shape = stack[stack.len - 1];
    const input = stack[stack.len - 2];
    if (shape != .list or shape.list.length() != 2 or input != .list) return null;
    const rows_value = list.atUnchecked(shape, 0);
    const columns_value = list.atUnchecked(shape, 1);
    if (rows_value != .int or columns_value != .int or rows_value.int < 1 or columns_value.int < 1) return null;
    const rows = std.math.cast(usize, rows_value.int) orelse return null;
    const columns = std.math.cast(usize, columns_value.int) orelse return null;
    const volume = std.math.mul(usize, rows, columns) catch return null;
    if (volume != input.list.length()) return null;
    if (!numeric.columnFoldCandidate(columnOperation(operation), input)) return null;
    return .{ .rows = rows, .columns = columns };
}

/// What a recognized application runs: a registry entry, or a quotation
/// compiled to a scalar program.
const Recognized = union(enum) {
    entry: RegistryEntry,
    program: *const OfferedProgram,
};

/// Every recognized application starts here: it counts the hit and reports
/// a fault or a continuing driver at the phrase's active word.
inline fn applyRecognized(evaluator: *Fiber, phrase: Value, recognized: Recognized, capture: Capture) MachineError!void {
    evaluator.idiom_hits += 1;
    const attribution: Attribution = .{
        .site = if (capture.active_index) |index| .{ .code = phrase.list, .index = index } else null,
    };
    return attribution.started(evaluator, switch (recognized) {
        .entry => |entry| applyEntry(evaluator, entry, capture),
        .program => |program| startProgram(evaluator, program),
    });
}

/// Where a recognized application's fault, or the driver it leaves, is
/// reported: the source position it ran in place of.
const Attribution = struct {
    site: ?struct { code: *value.ListHandle, index: u32 } = null,

    fn started(self: Attribution, evaluator: *Fiber, result: MachineError!void) MachineError!void {
        result catch |err| {
            if (err == error.Ecl) if (self.site) |site| evaluator.setFailureSite(site.code, site.index);
            return err;
        };
        if (self.site) |site| evaluator.setWorkDriverSite(site.code, site.index);
    }
};

/// Matches an offered phrase against the registry entries of its context and
/// length, records the match in the running finite iteration's plan when it
/// has room, then applies the matched entry or declines. The work is bounded
/// by the registry's shape and each pattern word is one slot read, so the
/// whole match runs where the combinator applies.
fn matchOffered(
    evaluator: *Fiber,
    candidate: Candidate,
    entries: []const u16,
    fallback: machine.IdiomFallback,
    request: machine.IdiomRequest,
    planned: ?*machine.PlanEntry,
) MachineError!void {
    var capture: Capture = .{};
    const matched: ?u16 = for (entries) |index| {
        if (matchPhrase(evaluator, candidate.phrase, registry[index])) |found| {
            capture = found;
            break index;
        }
    } else null;
    if (matched == null) if (recognizeProgram(evaluator, candidate)) |program| {
        return applyRecognized(evaluator, candidate.phrase, .{ .program = &program }, .{});
    };
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
    return applyMatched(evaluator, candidate.phrase, matched, capture, fallback);
}

/// The numeric operations a scalar program may contain, by spelling, each with
/// the binding its registry entries expect.
const program_operations = blk: {
    var found: [unary_count + binary_count]struct { spelling: []const u8, operation: Operation } = undefined;
    var index: usize = 0;
    for (std.meta.tags(numeric.UnaryOp)) |operation| {
        found[index] = .{ .spelling = operation.spelling(), .operation = .{ .unary = operation } };
        index += 1;
    }
    for (std.meta.tags(numeric.BinaryOp)) |operation| {
        found[index] = .{ .spelling = operation.spelling(), .operation = .{ .binary = operation } };
        index += 1;
    }
    break :blk found;
};

/// The stack words a scalar program may contain: they only move values, so
/// they compile to register choices.
const ProgramStackWord = enum { dup, swap, pop, over };

/// One form a scalar program can hold.
const ProgramForm = union(enum) {
    constant: Value,
    stack: ProgramStackWord,
    /// A unary or binary numeric operation.
    operation: Operation,

    /// How many program values the form reads, and how many it leaves.
    fn effect(self: ProgramForm) struct { reads: usize, leaves: usize } {
        return switch (self) {
            .constant => .{ .reads = 0, .leaves = 1 },
            .stack => |word| switch (word) {
                .dup => .{ .reads = 1, .leaves = 2 },
                .swap => .{ .reads = 2, .leaves = 2 },
                .pop => .{ .reads = 1, .leaves = 0 },
                .over => .{ .reads = 2, .leaves = 3 },
            },
            .operation => |operation| switch (operation) {
                .unary => .{ .reads = 1, .leaves = 1 },
                .binary => .{ .reads = 2, .leaves = 1 },
                else => unreachable,
            },
        };
    }
};

/// What `form` is to a scalar program where it runs, or null when no program
/// can hold it: a numeric constant, a stack word, or a numeric operation, each
/// word bound as the program expects.
fn programForm(evaluator: *Fiber, form: Value) ?ProgramForm {
    if (form != .symbol) return if (form == .int or form == .float) .{ .constant = form } else null;
    const word = form.symbol;
    // A quoted occurrence pushes a symbol, which no program register holds.
    if (env.isQuoted(word.slot)) return null;
    const spelling = intern.get(word.name);
    if (std.meta.stringToEnum(ProgramStackWord, spelling)) |stack_word| {
        if (!wordMatches(evaluator, word, null)) return null;
        return .{ .stack = stack_word };
    }
    const operation = chainHead(spelling) orelse return null;
    if (!wordMatches(evaluator, word, operationPrimitive(operation))) return null;
    return .{ .operation = operation };
}

/// The numeric operation `spelling` names, which heads a straight-line chain.
pub fn chainHead(spelling: []const u8) ?Operation {
    for (program_operations) |candidate| {
        if (std.mem.eql(u8, candidate.spelling, spelling)) return candidate.operation;
    }
    return null;
}

/// Compiles `length` forms of `code` from `start`, applied to `inputs`
/// values, into a scalar program, or returns null when they are not one: every
/// form must be a `programForm`, and the forms must leave exactly one value
/// from their inputs. Operations keep their order, including one whose result
/// is later popped, so a fault happens where the code's own would.
fn compileProgram(evaluator: *Fiber, code: Value, start: usize, length: usize, inputs: u8) ?numeric.ScalarProgram {
    const Program = numeric.ScalarProgram;
    var program: Program = .{ .inputs = inputs, .registers = inputs };
    // SAFETY: only the first `depth` entries are read.
    var stack: [Program.max_registers]Program.Register = undefined;
    var depth: usize = inputs;
    for (0..inputs) |input| stack[input] = @intCast(input);
    for (start..start + length) |position| {
        const form = list.atUnchecked(code, position);
        switch (programForm(evaluator, form) orelse return null) {
            .constant => |constant| {
                if (program.registers == Program.max_registers or depth == stack.len) return null;
                program.constants[program.constant_count] = .{ .register = program.registers, .value = constant };
                program.constant_count += 1;
                stack[depth] = program.registers;
                depth += 1;
                program.registers += 1;
            },
            .stack => |stack_word| switch (stack_word) {
                .dup => {
                    if (depth < 1 or depth == stack.len) return null;
                    stack[depth] = stack[depth - 1];
                    depth += 1;
                },
                .swap => {
                    if (depth < 2) return null;
                    std.mem.swap(Program.Register, &stack[depth - 1], &stack[depth - 2]);
                },
                .pop => {
                    if (depth < 1) return null;
                    depth -= 1;
                },
                .over => {
                    if (depth < 2 or depth == stack.len) return null;
                    stack[depth] = stack[depth - 2];
                    depth += 1;
                },
            },
            .operation => |operation| {
                if (program.len == Program.max_instructions or program.registers == Program.max_registers) return null;
                program.instructions[program.len] = switch (operation) {
                    .unary => |selected| unary: {
                        if (depth < 1) return null;
                        depth -= 1;
                        break :unary .{
                            .operation = .{ .unary = selected },
                            .left = stack[depth],
                            .destination = program.registers,
                            .word = form.symbol.name,
                            .index = @intCast(position),
                        };
                    },
                    .binary => |selected| binary: {
                        if (depth < 2) return null;
                        depth -= 2;
                        break :binary .{
                            .operation = .{ .binary = selected },
                            .left = stack[depth],
                            .right = stack[depth + 1],
                            .destination = program.registers,
                            .word = form.symbol.name,
                            .index = @intCast(position),
                        };
                    },
                    else => unreachable,
                };
                program.len += 1;
                stack[depth] = program.registers;
                depth += 1;
                program.registers += 1;
            },
        }
    }
    // A quotation that computes nothing is no faster compiled.
    if (depth != 1 or program.len == 0) return null;
    program.result = stack[0];
    return program;
}

/// How far a straight-line chain reaches: its forms, counting the head, and
/// the stack values beneath it that they read.
const ChainExtent = struct { length: usize, inputs: u8 };

/// The longest run of forms from `head` that one scalar program can take: the
/// head is `operation`, every form a `programForm`, at least one operation
/// follows the head, and the run leaves exactly one value from everything it
/// read. Inputs are read from beneath as the forms need them. Null when no
/// such run exists.
fn chainExtent(evaluator: *Fiber, code: Value, head: usize, operation: Operation) ?ChainExtent {
    const Program = numeric.ScalarProgram;
    const count: usize = @intCast(code.list.length());
    var depth: usize = 0;
    var reached: usize = 0;
    var instructions: usize = 0;
    var registers: usize = 0;
    var longest: ?ChainExtent = null;
    for (head..count) |position| {
        const form = programForm(evaluator, list.atUnchecked(code, position)) orelse break;
        if (position == head and !(form == .operation and std.meta.eql(form.operation, operation))) return null;
        const effect = form.effect();
        if (depth < effect.reads) {
            registers += effect.reads - depth;
            reached += effect.reads - depth;
            depth = effect.reads;
        }
        depth = depth - effect.reads + effect.leaves;
        switch (form) {
            .constant => registers += 1,
            .operation => {
                instructions += 1;
                registers += 1;
            },
            .stack => {},
        }
        if (reached > numeric.max_chain_inputs or instructions > Program.max_instructions or
            registers > Program.max_registers or depth > Program.max_registers) break;
        if (depth == 1 and instructions >= 2) longest = .{ .length = position + 1 - head, .inputs = @intCast(reached) };
    }
    return longest;
}

/// A numeric builtin dispatched from straight-line code, continued there by
/// more arithmetic, runs the whole chain as one scalar program over its list
/// operands, the same program `each` runs for a quotation of those words. The
/// program is observed as the words would be, each pervading the whole list
/// before the next, so a fault is the one they would meet first. Any other
/// shape runs the words as written.
pub fn applyChain(evaluator: *Fiber, operation: Operation) MachineError!bool {
    if (evaluator.inherited.idiom_mode == .generic_only) return false;
    const forms = evaluator.followingForms(0) orelse return false;
    const code: Value = .{ .list = forms.code };
    const head = forms.start - 1;
    const extent = chainExtent(evaluator, code, head, operation) orelse return false;
    if (evaluator.available() < extent.inputs) return false;
    const stack = evaluator.stack.items;
    const operands = stack[stack.len - extent.inputs ..];
    if (!numeric.programCandidate(operands)) return false;
    const program = compileProgram(evaluator, code, head, extent.length, extent.inputs) orelse return false;
    // A result no list operand reaches is scalar code, which the words
    // already run as such.
    if (!numeric.programResultVaries(&program, operands)) return false;
    evaluator.idiom_hits += 1;
    evaluator.phrase_hits += 1;
    evaluator.skipFollowingForms(@intCast(extent.length - 1));
    evaluator.commitPhraseTrace();
    try numeric.startProgramChain(evaluator, forms.code, program);
    return true;
}

const OfferedProgram = struct {
    context: Context,
    compiled: numeric.ScalarProgram,
};

/// Offers an unmatched `each`, `zip-with`, `fold`, `fold1`, or `scan`
/// quotation as a scalar program over the operands it will see. It is
/// compiled afresh on every call rather than planned: the plan holds a
/// registry entry, and a program is not one.
fn recognizeProgram(evaluator: *Fiber, candidate: Candidate) ?OfferedProgram {
    const stack = evaluator.stack.items;
    const inputs: u8 = switch (candidate.context) {
        .each => 1,
        .zip_with, .fold, .fold1, .scan => 2,
        else => return null,
    };
    const compiled = compileProgram(evaluator, candidate.phrase, 0, @intCast(candidate.phrase.list.length()), inputs) orelse return null;
    const admitted = switch (candidate.context) {
        .each, .zip_with => numeric.programCandidate(stack[stack.len - 1 - inputs .. stack.len - 1]),
        // The accumulator is input 0 and the element input 1.
        .fold, .scan => numeric.programReduceCandidate(stack[stack.len - 3], stack[stack.len - 2]),
        .fold1 => numeric.programReduceCandidate(stack[stack.len - 2], null),
        else => unreachable,
    };
    if (!admitted) return null;
    return .{ .context = candidate.context, .compiled = compiled };
}

fn startProgram(evaluator: *Fiber, program: *const OfferedProgram) MachineError!void {
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    switch (program.context) {
        .each => {
            var input = try evaluator.popValue();
            defer input.deinit();
            return numeric.startProgramEach(evaluator, &input, &quotation, program.compiled);
        },
        .zip_with => {
            var right = try evaluator.popValue();
            defer right.deinit();
            var left = try evaluator.popValue();
            defer left.deinit();
            return numeric.startProgramZip(evaluator, &left, &right, &quotation, program.compiled);
        },
        .fold, .fold1, .scan => {
            var initial: ?heap.OwnedValue = if (program.context == .fold1) null else try evaluator.popValue();
            defer if (initial) |*owned| owned.deinit();
            var input = try evaluator.popValue();
            defer input.deinit();
            const seed: ?Value = if (initial) |*owned| owned.borrow() else null;
            return numeric.startProgramReduce(evaluator, &input, &quotation, program.compiled, seed, program.context == .scan);
        },
        else => unreachable,
    }
}

/// Applies a matched entry when this application's operands admit it, and
/// declines otherwise.
fn applyMatched(evaluator: *Fiber, phrase: Value, matched: ?u16, capture: Capture, fallback: machine.IdiomFallback) MachineError!void {
    const index = matched orelse return fallback(evaluator);
    const selected = registry[index];
    if (!canApplyEntry(evaluator, selected)) return fallback(evaluator);
    return applyRecognized(evaluator, phrase, .{ .entry = selected }, capture);
}

fn canApplyEntry(evaluator: *Fiber, entry: RegistryEntry) bool {
    const stack = evaluator.stack.items;
    return switch (entry.operation) {
        .unary => entry.context == .each and stack[stack.len - 2] == .list,
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
            .phrase, .lex_cmp => false,
        },
        .length, .match => entry.context == .each and stack[stack.len - 2] == .list,
        .cmp => order.lexCompareCandidate(stack[stack.len - 3], stack[stack.len - 2]),
        .phrase => unreachable, // See `applyPhrase`.
    };
}

fn applyEntry(evaluator: *Fiber, entry: RegistryEntry, capture: Capture) MachineError!void {
    if (capture.active_word) |word| evaluator.active_word = .plain(word);
    try switch (entry.operation) {
        .unary => |operation| applyUnaryEach(evaluator, operation),
        .binary => |operation| switch (entry.context) {
            .each => applyConstantEach(
                evaluator,
                operation,
                capture.constant.?,
                entry.constant_left,
            ),
            .zip_with => applyZipWith(evaluator, operation),
            .fold, .fold1, .scan => applyReduction(evaluator, operation, entry.context),
            .phrase, .lex_cmp => unreachable,
        },
        .match => applyMatchEach(evaluator, capture.constant.?),
        .length => applyLengthEach(evaluator),
        .cmp => applyLexCompare(evaluator),
        .phrase => unreachable, // See `applyPhrase`.
    };
}

/// `(cmp) lex-cmp-with`: the comparator is consumed with the lists.
fn applyLexCompare(evaluator: *Fiber) MachineError!void {
    popRelease(evaluator, 1);
    return order.lexCompare(evaluator);
}

fn applyUnaryEach(evaluator: *Fiber, operation: numeric.UnaryOp) MachineError!void {
    const stack = evaluator.stack.items;
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
    evaluator: *Fiber,
    operation: numeric.BinaryOp,
    constant: Value,
    constant_left: bool,
) MachineError!void {
    const stack = evaluator.stack.items;
    const input = stack[stack.len - 2];
    std.debug.assert(input == .list);
    if (numeric.typedConstantCandidate(operation, input, constant, constant_left)) {
        var quotation = try evaluator.popValue();
        defer quotation.deinit();
        var operand = try evaluator.popValue();
        defer operand.deinit();
        // The captured constant is an atom, so it needs no reference of its own:
        // the typed loop reads it with stride zero.
        var scalar = heap.OwnedValue.init(evaluator.releases, constant);
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

fn applyZipWith(evaluator: *Fiber, operation: numeric.BinaryOp) MachineError!void {
    const stack = evaluator.stack.items;
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
        evaluator: *Fiber,
        mode: Mode,
        left: Value,
        right: ?Value,
        count: usize,
        consumed: usize,
    ) error{OutOfMemory}!void {
        const results = try heap.OwnedValueBuffer.init(evaluator.releases, count);
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
    pub fn advance(evaluator: *Fiber, self: *PervadeEachDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        const count = self.results.borrow().capacity();
        while (self.index != count) {
            if (self.cursor == null) {
                self.cursor = .init(numeric.PervadeCursor.initIdle(evaluator.releases, evaluator.allocator));
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
            cursor.deinit(evaluator.releases, evaluator.allocator);
            self.cursor = null;
        }
        if (self.materializer == null)
            self.materializer = .init(.init(evaluator.allocator, self.results.borrow().values()));
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

fn applyLengthEach(evaluator: *Fiber) MachineError!void {
    const stack = evaluator.stack.items;
    const input = stack[stack.len - 2];
    const count: usize = @intCast(input.list.length());
    if (count == 0) return finishCollected(evaluator, &.{}, 2);
    const writer = try heap.LeafWriter(.leaf_i64).init(evaluator.allocator, count);
    try evaluator.startDriver(LengthEachDriver{ .input = input, .writer = .init(writer) });
}

const LengthEachDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    // The caller's stack owns input and quotation until successful publication.
    input: Value,
    writer: heap.Owned(heap.LeafWriter(.leaf_i64)),
    index: usize = 0,

    pub fn advance(evaluator: *Fiber, self: *LengthEachDriver) MachineError!machine.WorkProgress {
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

fn applyMatchEach(evaluator: *Fiber, constant: Value) MachineError!void {
    const stack = evaluator.stack.items;
    const input = stack[stack.len - 2];
    std.debug.assert(input == .list);
    const count: usize = @intCast(input.list.length());
    if (count == 0) return finishCollected(evaluator, &.{}, 2);
    const writer = try heap.LeafWriter(.leaf_u8).init(evaluator.allocator, count);
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

    pub fn advance(evaluator: *Fiber, self: *MatchEachDriver) MachineError!machine.WorkProgress {
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
                self.cursor = .init(try .init(evaluator.allocator, item, self.constant));
            }
            switch (try self.cursor.?.borrowMut().advance(work)) {
                .pending => return .stepped,
                .complete => |matches| {
                    self.cursor.?.deinit(evaluator.releases, evaluator.allocator);
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

fn applyReduction(
    evaluator: *Fiber,
    operation: numeric.BinaryOp,
    context: Context,
) MachineError!void {
    const scan = context == .scan;
    const from_first = context == .fold1;
    const consumed: usize = if (from_first) 2 else 3;
    const start: usize = if (from_first) 1 else 0;
    const stack = evaluator.stack.items;
    const input = stack[stack.len - consumed];
    const initial = if (from_first) list.atUnchecked(input, 0) else stack[stack.len - 2];
    return numeric.startReduction(evaluator, operation, scan, input, initial, start, consumed);
}

fn finishCollected(evaluator: *Fiber, values: []const Value, consumed: usize) MachineError!void {
    std.debug.assert(values.len == 0);
    const result = try list.fromValuesGeneric(evaluator.allocator, values);
    popRelease(evaluator, consumed);
    try evaluator.pushOwned(result);
}

fn popRelease(evaluator: *Fiber, count: usize) void {
    evaluator.discard(count);
}

fn operationPrimitive(operation: Operation) ?env.PrimitiveImpl {
    return switch (operation) {
        .unary => |selected| unaryPrimitive(selected),
        .binary => |selected| binaryPrimitive(selected),
        .match, .length, .cmp, .phrase => null,
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

/// Whether a word can be a pattern word: anything but a local. A plain word
/// resolves through its own slot wherever it runs, and recognition reads that
/// same slot, so a word written in another root, as a caller's quotation run
/// inside a prelude definition is, matches exactly when dispatch would run the
/// expected binding; a root that shadows the name, or has retired, declines.
fn plainWord(slot_id: u32) bool {
    return env.wordTarget(slot_id) != .local;
}
