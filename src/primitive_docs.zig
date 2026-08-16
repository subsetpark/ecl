//! Reflective metadata for the closed primitive vocabulary.
const std = @import("std");

pub const Metadata = struct {
    name: []const u8,
    effect: ?[]const u8,
    text: []const u8,
};

const entries = [_]Metadata{
    .{ .name = "dup", .effect = "x -- x x", .text = "Duplicate the top stack value." },
    .{ .name = "swap", .effect = "x y -- y x", .text = "Exchange the top two stack values." },
    .{ .name = "pop", .effect = "x --", .text = "Discard the top stack value." },
    .{ .name = "over", .effect = "x y -- x y x", .text = "Copy the value beneath the top of the stack onto the top." },
    .{ .name = "cons", .effect = "value list -- list", .text = "Prepend a value or executable form to a list." },
    .{ .name = "compose", .effect = "left right -- quotation", .text = "Concatenate two quotations in execution order." },
    .{ .name = "match", .effect = "left right -- bool", .text = "Return whether two complete values are structurally equal." },
    .{ .name = "type", .effect = "value -- type", .text = "Return the value kind as a symbol." },
    .{ .name = "str", .effect = "value -- string", .text = "Return the canonical printed representation of a value as a string." },
    .{ .name = "parse", .effect = "string -- quotation", .text = "Parse source text into an unevaluated quotation." },
    .{ .name = "dict-of", .effect = "entries -- dict", .text = "Build a dictionary from a flat list of adjacent key and value entries." },
    .{ .name = "attempt", .effect = "quotation -- outcome", .text = "Run a quotation in isolation and return an ok or error outcome dictionary." },
    .{ .name = "raise", .effect = "error --", .text = "Raise a language error from an error dictionary." },
    .{ .name = "pp", .effect = "value --", .text = "Pretty-print a value followed by a newline." },
    .{ .name = "prin", .effect = "string --", .text = "Write a string without adding a newline." },
    .{ .name = "args", .effect = "-- arguments", .text = "Return the process arguments as a list of strings." },
    .{ .name = "exit", .effect = "status --", .text = "Request root-session termination with the given exit status." },

    .{ .name = "dip", .effect = null, .text = "Run a quotation beneath a protected top stack value." },
    .{ .name = "call", .effect = null, .text = "Run a quotation on the current stack." },
    .{ .name = "if", .effect = null, .text = "Run one of two quotations according to a 0/1 boolean condition." },
    .{ .name = "while", .effect = null, .text = "Run a body quotation while a condition quotation returns the boolean 1." },
    .{ .name = "times", .effect = null, .text = "Run a quotation the requested nonnegative number of times." },
    .{ .name = "cond", .effect = null, .text = "Run the first action whose test quotation returns the boolean 1, or the final else quotation." },
    .{ .name = "each", .effect = "list quotation -- list", .text = "Apply a one-input, one-output quotation independently to each list element." },
    .{ .name = "each2", .effect = "left right quotation -- list", .text = "Apply a two-input, one-output quotation across two conforming lists." },
    .{ .name = "for", .effect = "list quotation --", .text = "Apply a one-input, zero-output quotation to each list element in order." },
    .{ .name = "fold", .effect = "list accumulator quotation -- accumulator", .text = "Reduce a list from the supplied accumulator with a binary quotation." },
    .{ .name = "scan", .effect = "list accumulator quotation -- list", .text = "Return the successive accumulator values produced while reducing a list." },
    .{ .name = "infra", .effect = "list quotation -- list", .text = "Run a quotation with a list's elements as its isolated stack and collect the results." },

    .{ .name = "def", .effect = null, .text = "Bind a quotation to a public word, with optional effect and documentation metadata." },
    .{ .name = "set", .effect = "value name --", .text = "Bind a value in the current environment." },
    .{ .name = "defp", .effect = "body annotation name --", .text = "Bind a private module word with required effect metadata." },
    .{ .name = "setp", .effect = "value name --", .text = "Bind a private value in the current module." },
    .{ .name = "body", .effect = "name -- quotation", .text = "Return the stored quotation body of a resolved word." },
    .{ .name = "doc", .effect = "name -- string", .text = "Return the canonical documentation string of a resolved binding." },
    .{ .name = "which", .effect = "name --", .text = "Print where a word resolves and any bindings it shadows." },
    .{ .name = "see", .effect = "name --", .text = "Print a canonical, re-readable representation of a binding." },

    .{ .name = "module", .effect = "name body --", .text = "Evaluate an isolated module body and register its definitions under a name." },
    .{ .name = "use", .effect = "name --", .text = "Import a module's public words into the current resolution scope." },
    .{ .name = "alias", .effect = "short name --", .text = "Register a short alias for a qualified module name." },
    .{ .name = "words", .effect = "--", .text = "Print the visible dictionary in sorted order." },
    .{ .name = "load", .effect = "path --", .text = "Read and evaluate a source file as one transactional unit." },

    .{ .name = "spawn", .effect = "quotation -- task", .text = "Run a quotation concurrently in an isolated child task." },
    .{ .name = "await", .effect = "task -- outcome", .text = "Wait for a task and return its success or error outcome." },
    .{ .name = "cancel", .effect = "task --", .text = "Request cancellation of a task, doing nothing if it is already complete." },
    .{ .name = "tasks", .effect = "-- tasks", .text = "Return pending descendant tasks in deterministic spawn order." },
    .{ .name = "await-any", .effect = "tasks -- index outcome", .text = "Wait for any task in a nonempty list and return its index and outcome." },
    .{ .name = "await-for", .effect = "task milliseconds -- outcome", .text = "Wait up to a nonnegative number of milliseconds for a task outcome." },
    .{ .name = "par-each", .effect = "sequence quotation -- results", .text = "Apply a quotation concurrently to every list element and return one result per element in input order." },
    .{ .name = "+", .effect = "x y -- z", .text = "Add numeric values or conforming numeric arrays pervasively." },
    .{ .name = "-", .effect = "x y -- z", .text = "Subtract numeric or character values or conforming arrays pervasively." },
    .{ .name = "*", .effect = "x y -- z", .text = "Multiply numeric values or conforming numeric arrays pervasively." },
    .{ .name = "/", .effect = "x y -- z", .text = "Divide numeric values or conforming numeric arrays pervasively, returning floats." },
    .{ .name = "div", .effect = "x y -- z", .text = "Compute checked integer division pervasively." },
    .{ .name = "mod", .effect = "x y -- z", .text = "Compute checked integer remainders pervasively." },
    .{ .name = "pow", .effect = "x y -- z", .text = "Raise numbers to powers pervasively, returning floats." },
    .{ .name = "atan2", .effect = "y x -- z", .text = "Compute the two-argument arctangent of numeric values pervasively." },
    .{ .name = "min", .effect = "x y -- z", .text = "Return the lesser of two comparable values pervasively." },
    .{ .name = "max", .effect = "x y -- z", .text = "Return the greater of two comparable values pervasively." },
    .{ .name = "=", .effect = "x y -- bool", .text = "Compare conforming values for pervasive equality, producing boolean masks." },
    .{ .name = "<>", .effect = "x y -- bool", .text = "Compare conforming values for pervasive inequality, producing boolean masks." },
    .{ .name = "<", .effect = "x y -- bool", .text = "Compare conforming values pervasively for ascending order." },
    .{ .name = ">", .effect = "x y -- bool", .text = "Compare conforming values pervasively for descending order." },
    .{ .name = "<=", .effect = "x y -- bool", .text = "Compare conforming values pervasively for less-than-or-equal order." },
    .{ .name = ">=", .effect = "x y -- bool", .text = "Compare conforming values pervasively for greater-than-or-equal order." },
    .{ .name = "and", .effect = "x y -- bool", .text = "Compute boolean conjunction pervasively over 0 and 1 values." },
    .{ .name = "or", .effect = "x y -- bool", .text = "Compute boolean disjunction pervasively over 0 and 1 values." },
    .{ .name = "neg", .effect = "x -- y", .text = "Negate numeric values pervasively with checked integer overflow." },
    .{ .name = "abs", .effect = "x -- y", .text = "Return absolute numeric values pervasively with checked integer overflow." },
    .{ .name = "sqrt", .effect = "x -- y", .text = "Return square roots of numeric values pervasively." },
    .{ .name = "floor", .effect = "x -- integer", .text = "Round numeric values downward pervasively to integers." },
    .{ .name = "ceil", .effect = "x -- integer", .text = "Round numeric values upward pervasively to integers." },
    .{ .name = "round", .effect = "x -- integer", .text = "Round numeric values to nearest integers pervasively." },
    .{ .name = "exp", .effect = "x -- y", .text = "Return natural exponentials of numeric values pervasively." },
    .{ .name = "log", .effect = "x -- y", .text = "Return natural logarithms of numeric values pervasively." },
    .{ .name = "sin", .effect = "x -- y", .text = "Return sines of numeric values pervasively." },
    .{ .name = "cos", .effect = "x -- y", .text = "Return cosines of numeric values pervasively." },
    .{ .name = "not", .effect = "bool -- bool", .text = "Invert boolean 0 and 1 values pervasively." },

    .{ .name = "at", .effect = "collection key -- value", .text = "Select a list index or dictionary key, pervading over list indices." },
    .{ .name = "where", .effect = "counts -- indices", .text = "Expand integer counts into their replicated zero-based indices." },
    .{ .name = "in", .effect = "value list -- bool", .text = "Test whole-value membership, pervading over the searched value." },
    .{ .name = "raze", .effect = "list -- list", .text = "Flatten one level of a list." },
    .{ .name = "cat", .effect = "left right -- list", .text = "Concatenate two lists." },
    .{ .name = "take", .effect = "list count -- list", .text = "Take a signed number of list elements, cycling when necessary." },
    .{ .name = "drop", .effect = "list count -- list", .text = "Drop a signed number of elements from a list." },
    .{ .name = "reverse", .effect = "list -- list", .text = "Return a list with its top-level element order reversed." },
    .{ .name = "first", .effect = "list -- value", .text = "Return the first element of a nonempty list." },
    .{ .name = "rest", .effect = "list -- list", .text = "Return all but the first element of a list." },
    .{ .name = "range", .effect = "bound -- list", .text = "Return the integers from zero through one less than a nonnegative bound." },
    .{ .name = "shape", .effect = "list -- shape", .text = "Return the dimensions of a rectangular list." },
    .{ .name = "len", .effect = "list -- count", .text = "Return a list's top-level element count." },
    .{ .name = "flip", .effect = "list -- list", .text = "Transpose a rectangular list." },
    .{ .name = "reshape", .effect = "list shape -- list", .text = "Cycle list data into the requested rectangular shape." },

    .{ .name = "cmp", .effect = "left right -- ordering", .text = "Return -1, 0, or 1 for the whole-value order of two comparable values." },
    .{ .name = "grade", .effect = "list -- indices", .text = "Return the stable ascending sort permutation of a comparable list." },
    .{ .name = "distinct", .effect = "list -- list", .text = "Return the first occurrence of each distinct list value in input order." },
    .{ .name = "group", .effect = "list -- dict", .text = "Group equal list values into a dictionary of zero-based index lists." },

    .{ .name = "keys", .effect = "dict -- keys", .text = "Return a dictionary's keys in insertion order." },
    .{ .name = "vals", .effect = "dict -- values", .text = "Return a dictionary's values in insertion order." },
    .{ .name = "put", .effect = "collection key value -- collection", .text = "Functionally update a list index or dictionary key." },
    .{ .name = "to-dict", .effect = "keys values -- dict", .text = "Build a dictionary from conforming key and value lists." },
    .{ .name = "del", .effect = "dict key -- dict", .text = "Functionally remove a key from a dictionary." },
    .{ .name = "merge", .effect = "left right -- dict", .text = "Merge two dictionaries, with right-hand values winning." },
    .{ .name = "has?", .effect = "dict key -- bool", .text = "Return whether a dictionary contains a whole-value key." },
    .{ .name = "split", .effect = "string separator -- parts", .text = "Split a string at every occurrence of a separator string." },
    .{ .name = "join", .effect = "strings separator -- string", .text = "Join a list of strings with a separator string." },
    .{ .name = "format", .effect = "values template -- string", .text = "Interpolate a list of values into a template's positional placeholders." },
};

comptime {
    @setEvalBranchQuota(100_000);
    for (entries, 0..) |entry, index| {
        if (entry.text.len == 0) @compileError("empty primitive documentation: " ++ entry.name);
        if (entry.effect) |effect| validateEffect(entry.name, effect);
        for (entries[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, entry.name)) {
                @compileError("duplicate primitive metadata: " ++ entry.name);
            }
        }
    }
}

fn validateEffect(comptime name: []const u8, comptime effect: []const u8) void {
    if (effect.len == 0 or effect[0] == ' ' or effect[effect.len - 1] == ' ') {
        @compileError("invalid primitive effect: " ++ name);
    }
    for (effect[1..], effect[0 .. effect.len - 1]) |byte, previous| {
        if (byte == ' ' and previous == ' ') @compileError("invalid primitive effect spacing: " ++ name);
    }
    var separators: usize = 0;
    var iterator = std.mem.tokenizeScalar(u8, effect, ' ');
    while (iterator.next()) |token| separators += @intFromBool(std.mem.eql(u8, token, "--"));
    if (separators != 1) @compileError("primitive effect requires exactly one separator: " ++ name);
}

pub fn forName(comptime name: []const u8) Metadata {
    @setEvalBranchQuota(10_000);
    inline for (entries) |entry| {
        if (comptime std.mem.eql(u8, entry.name, name)) return entry;
    }
    @compileError("missing primitive metadata: " ++ name);
}
