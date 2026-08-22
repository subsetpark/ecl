//! Closed installer and closed classification registry for the kernel surface.
//!
//! Two artifacts live here. `install` publishes every kernel family's words.
//! `registry` classifies every sized kernel operation against every operand
//! shape it can meet at dispatch, exactly once, and `comptime` validation makes
//! a missing or duplicated classification a compile error rather than a silent
//! fall-through to a boxed path.
//!
//! The operand vocabulary is deliberately borrowed, not invented: aggregates are
//! named by `value.HeapKind` and atoms by the `Value` tag. There is no second
//! leaf-tag enum and no name list for an auditor to drift from — an operation
//! that is not in one of the family enums cannot be installed, and one that is
//! cannot escape classification.
const std = @import("std");
const env = @import("env.zig");
const value = @import("value.zig");
pub const support = @import("kernel_support.zig");
pub const storage = @import("kernel_storage.zig");
pub const numeric = @import("kernel_numeric.zig");
const sequence = @import("kernel_sequence.zig");
const order = @import("kernel_order.zig");
const dict_text = @import("kernel_dict_text.zig");
pub const random = @import("kernel_random.zig");
pub const flat = @import("kernel_flat.zig");

pub const HeapKind = value.HeapKind;

/// The `Value` tag of an operand that is not an aggregate. Reusing the value
/// tag keeps atoms and aggregates in one vocabulary; `.list` and `.dict` never
/// appear here because those operands are classified by representation.
pub const AtomTag = std.meta.Tag(value.Value);

pub const Registry = struct {
    pub const entries = @import("idioms.zig").registry;
};

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    try numeric.install(core);
    try sequence.install(core);
    try order.install(core);
    try dict_text.install(core);
    try random.install(core);
}

/// How an operation executes for one operand shape.
///
/// - `typed_loop`: a monomorphic loop over unboxed slices, chunked against the
///   caller's budget, writing the typed output buffer directly.
/// - `bulk_copy`: data movement with no per-element semantics — a memcpy, a
///   memset, a fill, or one direct typed element read.
/// - `sequential_typed`: unboxed, but element order is load-bearing (a running
///   accumulator, a stable comparison sort), so the loop may not be reordered
///   or reassociated even when the elements are typed.
/// - `generic_fallback`: the operand shape is a generic spine or a dict, or the
///   shape is rejected before any loop runs. Bounded descent continues and
///   re-enters this registry when it reaches a flat leaf.
pub const KernelClass = enum {
    typed_loop,
    bulk_copy,
    sequential_typed,
    generic_fallback,
};

/// One operand's runtime shape at dispatch.
pub const Operand = union(enum) {
    atom: AtomTag,
    aggregate: HeapKind,
};

/// How many operands take part in representation dispatch. Operations whose
/// extra arguments are scalars — `put`'s key and value, `rand-ints`' count and
/// bound, `take`'s count — dispatch on one shape; the count is documented per
/// operation rather than derived from the word's stack effect.
pub const Arity = enum { one, two };

pub const Operation = union(enum) {
    binary: support.BinaryOp,
    unary: support.UnaryOp,
    sequence: support.SequenceOp,
    order: support.OrderOp,
    text: support.TextOp,
    random: support.RandomOp,

    pub fn spelling(self: Operation) []const u8 {
        return switch (self) {
            inline else => |operation| operation.spelling(),
        };
    }

    pub fn arity(self: Operation) Arity {
        return switch (self) {
            .binary => .two,
            .unary => .one,
            .sequence => |operation| switch (operation) {
                // `at` gathers with a list index; `cat`, `take`, `drop`, `in?`,
                // and `reshape` each read two operands whose representations
                // both matter.
                .at, .cat, .take, .drop, .in_word, .reshape => .two,
                .where, .raze, .reverse, .first, .rest, .range, .shape, .len, .flip => .one,
            },
            .order => |operation| switch (operation) {
                .cmp => .two,
                .grade, .group => .one,
            },
            .text => |operation| switch (operation) {
                // `split`, `join`, `format`, and `merge` read two sized
                // operands; the rest dispatch on their collection alone.
                .split, .join, .format, .merge => .two,
                .keys, .put, .to_dict, .del, .has, .str => .one,
            },
            .random => .one,
        };
    }
};

/// A compact operand predicate. Rows name sets so the table stays readable;
/// validation still expands every point of the domain.
pub const OperandSet = struct {
    atoms: []const AtomTag = &.{},
    aggregates: []const HeapKind = &.{},

    fn matches(self: OperandSet, operand: Operand) bool {
        switch (operand) {
            .atom => |tag| for (self.atoms) |candidate| {
                if (candidate == tag) return true;
            },
            .aggregate => |kind| for (self.aggregates) |candidate| {
                if (candidate == kind) return true;
            },
        }
        return false;
    }
};

pub const Row = struct {
    operations: []const Operation,
    left: OperandSet,
    /// Null exactly when every named operation has arity `one`.
    right: ?OperandSet = null,
    class: KernelClass,
};

const numbers = OperandSet{ .atoms = &.{ .int, .float } };
const non_numeric_atoms = OperandSet{ .atoms = &.{ .char, .symbol, .word, .task, .module } };
const char_atom = OperandSet{ .atoms = &.{.char} };
const rejected_numeric_atoms = without(non_numeric_atoms, char_atom);
const any_atom = OperandSet{ .atoms = &.{ .int, .float, .char, .symbol, .word, .task, .module } };
const integers = OperandSet{ .atoms = &.{.int} };
const numeric_leaves = OperandSet{ .aggregates = &.{ .leaf_i64, .leaf_f64 } };
const byte_leaf = OperandSet{ .aggregates = &.{.leaf_u8} };
const char_leaves = OperandSet{ .aggregates = &.{ .leaf_char1, .leaf_char2, .leaf_char4 } };
const all_leaves = OperandSet{ .aggregates = &.{
    .leaf_u8,
    .leaf_i64,
    .leaf_f64,
    .leaf_char1,
    .leaf_char2,
    .leaf_char4,
    .leaf_symbol,
} };
const spine = OperandSet{ .aggregates = &.{.generic_spine} };
const dictionary = OperandSet{ .aggregates = &.{.dict} };
const any_list = union2(all_leaves, spine);
const any_aggregate = union2(any_list, dictionary);
const any_operand = union2(any_atom, any_aggregate);

fn union2(comptime left: OperandSet, comptime right: OperandSet) OperandSet {
    return .{
        .atoms = left.atoms ++ right.atoms,
        .aggregates = left.aggregates ++ right.aggregates,
    };
}

fn without(comptime set: OperandSet, comptime removed: OperandSet) OperandSet {
    comptime var atoms: []const AtomTag = &.{};
    comptime var aggregates: []const HeapKind = &.{};
    inline for (set.atoms) |tag| {
        if (!removed.matches(.{ .atom = tag })) atoms = atoms ++ [_]AtomTag{tag};
    }
    inline for (set.aggregates) |kind| {
        if (!removed.matches(.{ .aggregate = kind })) aggregates = aggregates ++ [_]HeapKind{kind};
    }
    return .{ .atoms = atoms, .aggregates = aggregates };
}

fn operations(comptime Enum: type, comptime tag: []const u8) []const Operation {
    comptime var result: []const Operation = &.{};
    inline for (std.meta.fields(Enum)) |field| {
        const operation: Enum = @enumFromInt(field.value);
        result = result ++ [_]Operation{@unionInit(Operation, tag, operation)};
    }
    return result;
}

fn only(comptime items: anytype) []const Operation {
    comptime var result: []const Operation = &.{};
    inline for (items) |item| result = result ++ [_]Operation{item};
    return result;
}

const all_binary = operations(support.BinaryOp, "binary");
const all_unary = operations(support.UnaryOp, "unary");

/// `min` and `max` return one of their operands rather than a computed value, so
/// their result representation follows the operands element by element. Every
/// other binary operation computes a result whose width the pair decides once.
const selecting_binary = only(.{
    Operation{ .binary = .min },
    Operation{ .binary = .max },
});
const computing_binary = withoutOperations(all_binary, selecting_binary);

fn withoutOperations(comptime set: []const Operation, comptime removed: []const Operation) []const Operation {
    comptime var result: []const Operation = &.{};
    inline for (set) |candidate| {
        comptime var dropped = false;
        inline for (removed) |excluded| {
            if (sameOperation(candidate, excluded)) dropped = true;
        }
        if (!dropped) result = result ++ [_]Operation{candidate};
    }
    return result;
}

pub const registry = binary_rows ++ unary_rows ++ sequence_rows ++ order_rows ++ text_rows ++ random_rows;

/// Numeric, comparison, boolean, bitwise, and shift pervasion share one shape:
/// the loop is chosen by the pair of representations, and the operation only
/// selects which monomorphic body that loop runs. Mixed `i64`/`f64` pairs and
/// character-width pairs are inside the typed rows rather than beside them,
/// because comparison and subtraction are meaningful on chars while arithmetic
/// is not — and the difference is a fault the block mask reports, not a
/// different dispatch.
const binary_rows = [_]Row{
    .{
        .operations = all_binary,
        .left = byte_leaf,
        .right = without(any_operand, union2(spine, dictionary)),
        .class = .generic_fallback,
        // packed bytes have ordinary integer semantics; the profiling route widens results when
        // an operation leaves 0..255 and may select packed storage again when it does not
    },
    .{
        .operations = all_binary,
        .left = without(any_operand, union2(byte_leaf, union2(spine, dictionary))),
        .right = byte_leaf,
        .class = .generic_fallback,
        // mirrored packed-byte pervasion uses the same representation-independent scalar path
    },
    .{
        .operations = computing_binary,
        .left = numeric_leaves,
        .right = union2(numeric_leaves, numbers),
        .class = .typed_loop,
        // typed pervasion: one monomorphic block loop per element-class pair, mixed numeric widths
        // included, faults masked per block and replayed scalar-wise
    },
    .{
        .operations = computing_binary,
        .left = numbers,
        .right = numeric_leaves,
        .class = .typed_loop,
        // typed pervasion with a stride-zero left operand; no broadcast is materialized
    },
    .{
        .operations = selecting_binary,
        .left = OperandSet{ .aggregates = &.{.leaf_i64} },
        .right = union2(OperandSet{ .aggregates = &.{.leaf_i64} }, integers),
        .class = .typed_loop,
        // same-class selection keeps one width, so the choice is a typed loop
    },
    .{
        .operations = selecting_binary,
        .left = OperandSet{ .aggregates = &.{.leaf_f64} },
        .right = union2(OperandSet{ .aggregates = &.{.leaf_f64} }, OperandSet{ .atoms = &.{.float} }),
        .class = .typed_loop,
        // same-class selection keeps one width, so the choice is a typed loop
    },
    .{
        .operations = selecting_binary,
        .left = integers,
        .right = OperandSet{ .aggregates = &.{.leaf_i64} },
        .class = .typed_loop,
        // same-class selection with a stride-zero left operand
    },
    .{
        .operations = selecting_binary,
        .left = OperandSet{ .atoms = &.{.float} },
        .right = OperandSet{ .aggregates = &.{.leaf_f64} },
        .class = .typed_loop,
        // same-class selection with a stride-zero left operand
    },
    .{
        .operations = selecting_binary,
        .left = OperandSet{ .aggregates = &.{.leaf_i64} },
        .right = union2(OperandSet{ .aggregates = &.{.leaf_f64} }, OperandSet{ .atoms = &.{.float} }),
        .class = .generic_fallback,
        // a mixed numeric pair selects ints and floats element by element, so the result is
        // genuinely heterogeneous and keeps the profiling route
    },
    .{
        .operations = selecting_binary,
        .left = OperandSet{ .aggregates = &.{.leaf_f64} },
        .right = union2(OperandSet{ .aggregates = &.{.leaf_i64} }, integers),
        .class = .generic_fallback,
        // a mixed numeric pair is heterogeneous, as above
    },
    .{
        .operations = selecting_binary,
        .left = integers,
        .right = OperandSet{ .aggregates = &.{.leaf_f64} },
        .class = .generic_fallback,
        // a mixed numeric pair is heterogeneous, as above
    },
    .{
        .operations = selecting_binary,
        .left = OperandSet{ .atoms = &.{.float} },
        .right = OperandSet{ .aggregates = &.{.leaf_i64} },
        .class = .generic_fallback,
        // a mixed numeric pair is heterogeneous, as above
    },
    .{
        .operations = all_binary,
        .left = union2(char_leaves, OperandSet{ .aggregates = &.{.leaf_symbol} }),
        .right = without(any_operand, union2(union2(spine, dictionary), byte_leaf)),
        .class = .typed_loop,
        // character results profile faults and maximum codepoint, then fill one exact-width writer;
        // fixed i64 results use one pass, and symbol elements reject before a loop
    },
    .{
        .operations = all_binary,
        .left = without(
            any_operand,
            union2(
                union2(spine, dictionary),
                union2(byte_leaf, union2(char_leaves, OperandSet{ .aggregates = &.{.leaf_symbol} })),
            ),
        ),
        .right = union2(char_leaves, OperandSet{ .aggregates = &.{.leaf_symbol} }),
        .class = .typed_loop,
        // the mirrored character/symbol leaf path uses the same typed result protocol
    },
    .{
        .operations = all_binary,
        .left = numeric_leaves,
        .right = char_atom,
        .class = .typed_loop,
        // a character scalar is stride zero; valid offsets profile an exact-width result and all
        // other pairs reject before a loop
    },
    .{
        .operations = all_binary,
        .left = char_atom,
        .right = numeric_leaves,
        .class = .typed_loop,
        // the mirrored stride-zero character offset/rejection path
    },
    .{
        .operations = all_binary,
        .left = union2(numeric_leaves, numbers),
        .right = rejected_numeric_atoms,
        .class = .generic_fallback,
        // a non-numeric scalar operand is rejected before any loop, except for the char offset
        // rules, which are classified by the typed character rows above
    },
    .{
        .operations = all_binary,
        .left = rejected_numeric_atoms,
        .right = numeric_leaves,
        .class = .generic_fallback,
        // a non-numeric scalar left operand, as above
    },
    .{
        .operations = all_binary,
        .left = spine,
        .right = any_operand,
        .class = .generic_fallback,
        // bounded spine descent; each leaf it reaches re-enters this registry
    },
    .{
        .operations = all_binary,
        .left = without(any_operand, spine),
        .right = spine,
        .class = .generic_fallback,
        // bounded spine descent on the right operand
    },
    .{
        .operations = all_binary,
        .left = dictionary,
        .right = without(any_operand, spine),
        .class = .generic_fallback,
        // dict pervasion aligns by key, then re-enters this registry at the values
    },
    .{
        .operations = all_binary,
        .left = without(any_operand, union2(spine, dictionary)),
        .right = dictionary,
        .class = .generic_fallback,
        // dict pervasion on the right operand
    },
};

const unary_rows = [_]Row{
    .{
        .operations = all_unary,
        .left = byte_leaf,
        .class = .generic_fallback,
        // packed bytes are boxed as ordinary integers and widened only when the result requires it
    },
    .{
        .operations = all_unary,
        .left = numeric_leaves,
        .class = .typed_loop,
        // typed pervasion: one monomorphic body per leaf representation, with in-place reuse when
        // the operand is solely owned and the widths agree
    },
    .{
        .operations = all_unary,
        .left = union2(char_leaves, OperandSet{ .aggregates = &.{.leaf_symbol} }),
        .class = .typed_loop,
        // no unary word accepts characters or symbols, so a nonempty typed leaf rejects at logical
        // index zero without entering the boxed cursor
    },
    .{
        .operations = all_unary,
        .left = spine,
        .class = .generic_fallback,
        // bounded spine descent; each leaf it reaches re-enters this registry
    },
    .{
        .operations = all_unary,
        .left = dictionary,
        .class = .generic_fallback,
        // dict pervasion maps values, then re-enters this registry
    },
};

const sequence_rows = [_]Row{
    // at
    .{
        .operations = only(.{Operation{ .sequence = .at }}),
        .left = any_list,
        .right = integers,
        .class = .bulk_copy,
        // one direct typed element read; no loop
    },
    .{
        .operations = only(.{Operation{ .sequence = .at }}),
        .left = any_list,
        .right = OperandSet{ .aggregates = &.{.leaf_i64} },
        .class = .typed_loop,
        // typed gather: a leaf_i64 index vector into a pinned typed source, with the scalar path's
        // bounds and sign checks
    },
    .{
        .operations = only(.{Operation{ .sequence = .at }}),
        .left = any_list,
        .right = without(any_operand, union2(integers, OperandSet{ .aggregates = &.{.leaf_i64} })),
        .class = .generic_fallback,
        // a non-integer index is rejected, or a boxed index path descends generically
    },
    .{
        .operations = only(.{Operation{ .sequence = .at }}),
        .left = union2(any_atom, dictionary),
        .right = any_operand,
        .class = .generic_fallback,
        // dict lookup by key identity, or an atom source that cannot be indexed
    },
    // cat, take, drop: exact-size data movement over one representation
    .{
        .operations = only(.{
            Operation{ .sequence = .cat },
            Operation{ .sequence = .take },
            Operation{ .sequence = .drop },
        }),
        .left = all_leaves,
        .right = union2(all_leaves, any_atom),
        .class = .bulk_copy,
        // exact-size typed range copy between pinned slices; a mixed-representation pair keeps the
        // profiling route because its result kind is that pass's decision
    },
    .{
        .operations = only(.{
            Operation{ .sequence = .cat },
            Operation{ .sequence = .take },
            Operation{ .sequence = .drop },
        }),
        .left = union2(any_atom, union2(spine, dictionary)),
        .right = any_operand,
        .class = .generic_fallback,
        // boxed or keyed sources copy through the generic spine path
    },
    .{
        .operations = only(.{
            Operation{ .sequence = .cat },
            Operation{ .sequence = .take },
            Operation{ .sequence = .drop },
        }),
        .left = all_leaves,
        .right = union2(spine, dictionary),
        .class = .generic_fallback,
        // a boxed or keyed second operand forces the generic spine result
    },
    // in?
    .{
        .operations = only(.{Operation{ .sequence = .in_word }}),
        .left = without(any_operand, spine),
        .right = all_leaves,
        .class = .typed_loop,
        // typed membership scans a pinned haystack with exact cross-kind numeric identity; a flat
        // needle list writes its i64 mask directly and a scalar needle has stride zero
    },
    .{
        .operations = only(.{Operation{ .sequence = .in_word }}),
        .left = spine,
        .right = all_leaves,
        .class = .generic_fallback,
        // a recursive needle spine preserves its recursive result shape through bounded structural
        // descent
    },
    .{
        .operations = only(.{Operation{ .sequence = .in_word }}),
        .left = any_operand,
        .right = without(any_operand, all_leaves),
        .class = .generic_fallback,
        // a boxed, keyed, or atomic haystack compares through whole-value identity
    },
    // reshape
    .{
        .operations = only(.{Operation{ .sequence = .reshape }}),
        .left = union2(all_leaves, integers),
        .right = all_leaves,
        .class = .bulk_copy,
        // rank-one reshape is a typed cyclic fill selected before traversal; a shape above rank one
        // constructs its required spine through the shape-specific builder
    },
    .{
        .operations = only(.{Operation{ .sequence = .reshape }}),
        .left = without(any_operand, union2(all_leaves, integers)),
        .right = any_operand,
        .class = .generic_fallback,
        // a non-integer shape is rejected before any fill
    },
    .{
        .operations = only(.{Operation{ .sequence = .reshape }}),
        .left = union2(all_leaves, integers),
        .right = without(any_operand, all_leaves),
        .class = .generic_fallback,
        // a boxed or keyed source reshapes through the generic spine path
    },
    // unary sequence operations
    .{
        .operations = only(.{Operation{ .sequence = .where }}),
        .left = all_leaves,
        .class = .typed_loop,
        // typed count pass over a pinned slice, then one bounded fill per run of equal indices into
        // exact-size leaf_i64 storage
    },
    .{
        .operations = only(.{Operation{ .sequence = .reverse }}),
        .left = all_leaves,
        .class = .bulk_copy,
        // reversed typed copy, one representation in and out
    },
    .{
        .operations = only(.{Operation{ .sequence = .range }}),
        .left = integers,
        .class = .bulk_copy,
        // typed i64 fill of a known size, written straight into leaf storage
    },
    .{
        .operations = only(.{
            Operation{ .sequence = .first },
            Operation{ .sequence = .rest },
        }),
        .left = all_leaves,
        .class = .bulk_copy,
        // one typed read, or one typed copy of the tail
    },
    .{
        .operations = only(.{
            Operation{ .sequence = .len },
            Operation{ .sequence = .shape },
        }),
        .left = any_aggregate,
        .class = .bulk_copy,
        // header metadata; constant time in every representation
    },
    .{
        .operations = only(.{
            Operation{ .sequence = .raze },
            Operation{ .sequence = .flip },
        }),
        .left = any_aggregate,
        .class = .generic_fallback,
        // ragged and nested structure is the operand's point; descent stays boxed
    },
    .{
        .operations = only(.{
            Operation{ .sequence = .where },
            Operation{ .sequence = .reverse },
            Operation{ .sequence = .first },
            Operation{ .sequence = .rest },
        }),
        .left = union2(spine, dictionary),
        .class = .generic_fallback,
        // boxed or keyed operand; bounded descent re-enters at each leaf
    },
    .{
        .operations = only(.{Operation{ .sequence = .range }}),
        .left = without(any_aggregate, OperandSet{}),
        .class = .generic_fallback,
        // a non-integer count is rejected before any fill
    },
};

const order_rows = [_]Row{
    .{
        .operations = only(.{Operation{ .order = .cmp }}),
        .left = char_leaves,
        .right = char_leaves,
        .class = .sequential_typed,
        // codepoint-lexicographic string comparison over two pinned width-specialized slices
    },
    .{
        .operations = only(.{Operation{ .order = .cmp }}),
        .left = union2(any_atom, union2(spine, dictionary)),
        .right = any_operand,
        .class = .generic_fallback,
        // atoms compare directly; boxed or keyed operands are a type error
    },
    .{
        .operations = only(.{Operation{ .order = .cmp }}),
        .left = all_leaves,
        .right = without(any_operand, all_leaves),
        .class = .generic_fallback,
        // cross-kind comparison is a type error raised before any scan
    },
    .{
        .operations = only(.{Operation{ .order = .cmp }}),
        .left = without(all_leaves, char_leaves),
        .right = all_leaves,
        .class = .generic_fallback,
        // non-string lists are not whole-value comparable
    },
    .{
        .operations = only(.{Operation{ .order = .cmp }}),
        .left = char_leaves,
        .right = without(all_leaves, char_leaves),
        .class = .generic_fallback,
        // a string and a non-string list are not comparable
    },
    .{
        .operations = only(.{Operation{ .order = .grade }}),
        .left = union2(byte_leaf, union2(numeric_leaves, char_leaves)),
        .class = .sequential_typed,
        // stable merge sort over pinned typed keys, publishing its i64 index vector directly
    },
    .{
        .operations = only(.{Operation{ .order = .grade }}),
        .left = OperandSet{ .aggregates = &.{.leaf_symbol} },
        .class = .generic_fallback,
        // symbols are deliberately unordered and fail before sorting
    },
    .{
        .operations = only(.{Operation{ .order = .group }}),
        .left = all_leaves,
        .class = .sequential_typed,
        // first-appearance grouping scans pinned typed keys and publishes each stable i64 index
        // leaf directly
    },
    .{
        .operations = only(.{
            Operation{ .order = .grade },
            Operation{ .order = .group },
        }),
        .left = union2(spine, dictionary),
        .class = .generic_fallback,
        // boxed keys compare through whole-value ordering
    },
};

const text_rows = [_]Row{
    .{
        .operations = only(.{Operation{ .text = .split }}),
        .left = char_leaves,
        .right = char_leaves,
        .class = .sequential_typed,
        // width-specialized separator scan over pinned character slices; each result piece profiles
        // once before selecting its exact-width writer
    },
    .{
        .operations = only(.{Operation{ .text = .split }}),
        .left = without(any_operand, char_leaves),
        .right = any_operand,
        .class = .generic_fallback,
        // a non-string subject is rejected before traversal
    },
    .{
        .operations = only(.{Operation{ .text = .split }}),
        .left = char_leaves,
        .right = without(any_operand, char_leaves),
        .class = .generic_fallback,
        // a non-string separator is rejected before traversal
    },
    .{
        .operations = only(.{Operation{ .text = .join }}),
        .left = any_operand,
        .right = any_operand,
        .class = .generic_fallback,
        // the outer list is a spine of strings; each child crosses a once-per-source typed reader
        // before the exact-width joined result is selected
    },
    .{
        .operations = only(.{Operation{ .text = .str }}),
        .left = any_operand,
        .class = .generic_fallback,
        // canonical rendering follows whole values and may descend through any representation
    },
    .{
        .operations = only(.{
            Operation{ .text = .format },
            Operation{ .text = .merge },
        }),
        .left = any_operand,
        .right = any_operand,
        .class = .generic_fallback,
        // rendering and key-wise merging are value-shaped, not representation-shaped
    },
    .{
        .operations = only(.{Operation{ .text = .put }}),
        .left = all_leaves,
        .class = .bulk_copy,
        // a same-kind element store is an exact-size typed copy with one replaced position; a
        // heap-issued unique claim makes a solely-owned input one in-place store
    },
    .{
        .operations = only(.{Operation{ .text = .put }}),
        .left = union2(spine, dictionary),
        .class = .generic_fallback,
        // a boxed spine or a keyed collection stores through the generic path
    },
    .{
        .operations = only(.{
            Operation{ .text = .keys },
            Operation{ .text = .to_dict },
            Operation{ .text = .del },
            Operation{ .text = .has },
        }),
        .left = any_aggregate,
        .class = .generic_fallback,
        // dict identity hashing and key order are whole-value properties
    },
};

const random_rows = [_]Row{
    .{
        .operations = only(.{Operation{ .random = .rand_ints }}),
        .left = union2(byte_leaf, OperandSet{ .aggregates = &.{.leaf_i64} }),
        .class = .typed_loop,
        // counter-addressed typed i64 fill; element i depends only on its own index, so a resumed
        // fill needs no replay
    },
    .{
        .operations = only(.{
            Operation{ .random = .rand_int },
            Operation{ .random = .rand_float },
            Operation{ .random = .entropy },
        }),
        .left = any_aggregate,
        .class = .bulk_copy,
        // one draw and a two-element typed state; nothing user-sized
    },
    .{
        .operations = only(.{Operation{ .random = .rand_ints }}),
        .left = without(any_aggregate, union2(byte_leaf, OperandSet{ .aggregates = &.{.leaf_i64} })),
        .class = .generic_fallback,
        // a state that is not a typed int pair is rejected before any draw
    },
};

/// The dispatch domain. Atoms carry no representation, so an atom pair is not a
/// sized combination and is excluded: a scalar pair is answered by the shared
/// scalar semantics without a loop. `reserved_mask` is excluded because no live
/// list ever carries it, and the `task` and `module` capabilities appear only
/// as atoms.
const atom_domain = [_]AtomTag{ .int, .float, .char, .symbol, .word, .task, .module };
const aggregate_domain = [_]HeapKind{
    .generic_spine,
    .leaf_u8,
    .leaf_i64,
    .leaf_f64,
    .leaf_char1,
    .leaf_char2,
    .leaf_char4,
    .leaf_symbol,
    .dict,
};
const domain_size = atom_domain.len + aggregate_domain.len;

fn domainOperand(index: usize) Operand {
    if (index < atom_domain.len) return .{ .atom = atom_domain[index] };
    return .{ .aggregate = aggregate_domain[index - atom_domain.len] };
}

fn sameOperation(left: Operation, right: Operation) bool {
    return std.meta.eql(left, right);
}

fn rowNames(row: Row, operation: Operation) bool {
    for (row.operations) |candidate| {
        if (sameOperation(candidate, operation)) return true;
    }
    return false;
}

/// Every operation the installers publish, in one comptime list.
pub const all_operations = all_binary ++ all_unary ++
    operations(support.SequenceOp, "sequence") ++
    operations(support.OrderOp, "order") ++
    operations(support.TextOp, "text") ++
    operations(support.RandomOp, "random");

/// How many classifications match one dispatch point. Closed coverage means
/// this is 1 everywhere in the domain; the comptime validation below proves it,
/// and the typed-kernel test surfaces it as an assertion.
pub fn classificationCount(operation: Operation, left: Operand, right: ?Operand) usize {
    var count: usize = 0;
    for (registry) |row| {
        if (!rowNames(row, operation)) continue;
        if (!row.left.matches(left)) continue;
        if (right) |item| {
            const set = row.right orelse continue;
            if (!set.matches(item)) continue;
        } else if (row.right != null) continue;
        count += 1;
    }
    return count;
}

/// The single class for one dispatch point, or null outside the sized domain.
pub fn classify(operation: Operation, left: Operand, right: ?Operand) ?KernelClass {
    for (registry) |row| {
        if (!rowNames(row, operation)) continue;
        if (!row.left.matches(left)) continue;
        if (right) |item| {
            const set = row.right orelse continue;
            if (!set.matches(item)) continue;
        } else if (row.right != null) continue;
        return row.class;
    }
    return null;
}

/// The number of dispatch points the registry covers; the closure test compares
/// its own independent count against this.
pub fn domainPointCount() usize {
    var total: usize = 0;
    for (all_operations) |operation| {
        if (operation.arity() == .one) {
            total += aggregate_domain.len;
        } else {
            total += domain_size * domain_size - atom_domain.len * atom_domain.len;
        }
    }
    return total;
}

fn validateClosedCoverage() void {
    @setEvalBranchQuota(20_000_000);
    for (all_operations) |operation| {
        const two = operation.arity() == .two;
        // Arity-one operations dispatch on an aggregate only: an atom operand
        // carries no representation to classify.
        const left_start: usize = if (two) 0 else atom_domain.len;
        for (left_start..domain_size) |left_index| {
            const left = domainOperand(left_index);
            if (!two) {
                const count = classificationCount(operation, left, null);
                if (count != 1) @compileError(
                    "kernel registry classifies " ++ operation.spelling() ++ " " ++
                        operandName(left) ++ " " ++ countName(count) ++ " times; expected exactly one",
                );
                continue;
            }
            for (0..domain_size) |right_index| {
                const right = domainOperand(right_index);
                if (left == .atom and right == .atom) continue;
                const count = classificationCount(operation, left, right);
                if (count != 1) @compileError(
                    "kernel registry classifies " ++ operation.spelling() ++ " " ++
                        operandName(left) ++ " x " ++ operandName(right) ++ " " ++
                        countName(count) ++ " times; expected exactly one",
                );
            }
        }
    }
}

fn operandName(operand: Operand) []const u8 {
    return switch (operand) {
        .atom => |tag| @tagName(tag),
        .aggregate => |kind| @tagName(kind),
    };
}

fn countName(count: usize) []const u8 {
    return switch (count) {
        0 => "zero",
        1 => "one",
        2 => "two",
        else => "many",
    };
}

comptime {
    validateClosedCoverage();
}
