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
    .{
        .name = "stack",
        .effect = null,
        .text = "Copy the visible operand stack into a bottom-to-top list while leaving every original value in place.",
    },
    .{
        .name = "_ll",
        .effect = "... n --",
        .text = "Move the top n values into the head-binder locals, last name first. " ++
            "The reader emits this; write `|a b|` instead.",
    },
    .{
        .name = "_gl",
        .effect = "n -- x",
        .text = "Copy head-binder local n, counting from the most recently bound name. " ++
            "The reader emits this; write the local's name instead.",
    },
    .{
        .name = "_dl",
        .effect = "n --",
        .text = "Discard the top n head-binder locals. The reader emits this at the end " ++
            "of a binder body.",
    },
    .{ .name = "cons", .effect = "value list -- list", .text = "Prepend a value or executable form to a list." },
    .{ .name = "match?", .effect = "left right -- bool", .text = "Return whether two complete values are structurally equal." },
    .{ .name = "type", .effect = "value -- type", .text = "Return the value kind as a symbol." },
    .{ .name = "execute", .effect = "word -- ...", .text = "Execute a word through ordinary name resolution and dispatch." },
    .{ .name = "parse", .effect = "string -- quotation", .text = "Parse source text into an unevaluated quotation." },
    .{ .name = "parse-int", .effect = "string -- integer", .text = "Parse one ECL integer literal without evaluating source text." },
    .{ .name = "parse-float", .effect = "string -- float", .text = "Parse one ECL numeric literal and return its floating-point value." },
    .{ .name = "@attempt", .effect = "unit-input -- result", .text = "Run a quotation or unit plan in a fresh unit and return an ok or error result dictionary; observationally `@spawn await`." },
    .{ .name = "seed", .effect = "values quotation -- unit-plan", .text = "Seal a values list and a construction body into one immutable unit plan, holding both separately." },
    .{ .name = "unseed", .effect = "unit-plan -- values quotation", .text = "Return the exact values list and construction body a unit plan holds." },
    .{ .name = "raise", .effect = "error --", .text = "Raise a language error from an error dictionary." },
    .{ .name = "args", .effect = "-- arguments", .text = "Return the process arguments as a list of strings." },
    .{ .name = "exit", .effect = "status --", .text = "Request root-session termination with the given exit status." },
    .{ .name = "getenv", .effect = "name -- string", .text = "Return an environment variable's value from the session snapshot." },

    .{ .name = "call", .effect = "quotation -- ...", .text = "Run a quotation on the current stack." },
    .{ .name = "if", .effect = "bool then else -- ...", .text = "Run one of two quotations according to a 0/1 boolean condition." },
    .{ .name = "while", .effect = "cond body -- ...", .text = "Run a body while a destructively inspected, checkpointed stack condition has boolean 1 on top." },
    .{ .name = "times", .effect = "n quotation -- ...", .text = "Run a quotation the requested nonnegative number of times." },
    .{ .name = "cond", .effect = "clauses -- ...", .text = "Run the first action whose checkpointed stack test has boolean 1 on top, or the final else quotation." },
    .{ .name = "each", .effect = "list quotation -- list", .text = "Apply a one-input, one-output quotation independently to each list element." },
    .{ .name = "zip-with", .effect = "left right quotation -- list", .text = "Apply a two-input, one-output quotation across two conforming lists." },
    .{ .name = "for", .effect = "list quotation --", .text = "Apply a one-input, zero-output quotation to each list element in order." },
    .{ .name = "fold", .effect = "list accumulator quotation -- accumulator", .text = "Reduce a list from the supplied accumulator with a binary quotation." },
    .{ .name = "scan", .effect = "list accumulator quotation -- list", .text = "Return the successive accumulator values produced while reducing a list." },
    .{ .name = "stencil", .effect = "list width quotation -- list", .text = "Apply a one-input, one-output quotation independently to each overlapping window of a positive width." },
    .{ .name = "unfold", .effect = "state predicate step -- state list", .text = "Generate values while a one-input predicate holds; the step returns the next state and one output." },
    .{ .name = "infra", .effect = "list quotation -- list", .text = "Run a quotation with a list's elements as its isolated stack and collect the results." },

    .{ .name = "def", .effect = null, .text = "Bind a quotation to a public word, with optional effect and documentation metadata." },
    .{ .name = "defp", .effect = null, .text = "Bind a quotation to a private module word, with optional effect and documentation metadata." },
    .{ .name = "unset", .effect = "name --", .text = "Remove a binding from the current scope; do nothing when that scope does not bind the name." },
    .{ .name = "undef", .effect = "name --", .text = "Remove a binding from the current scope; an alias of unset." },
    .{ .name = "doc", .effect = "name -- string", .text = "Return the canonical documentation string of a resolved binding." },
    .{ .name = "which", .effect = "name --", .text = "Print where a word resolves and any bindings it shadows." },
    .{ .name = "see", .effect = "name --", .text = "Print the standard-formatted annotation and body of a binding." },

    .{ .name = "unmodule", .effect = "module-name --", .text = "Close, quiesce, and retire a registered module named by a symbol." },
    .{ .name = "*file*", .effect = "-- string", .text = "Return the source name dynamically supplied by the currently executing reader-authored occurrence." },
    .{ .name = "*module*", .effect = "-- module-name", .text = "Return the canonical registration name dynamically supplied by the current module activation." },
    .{ .name = "within", .effect = "quotation -- ...", .text = "Run a quotation against a private draft of the home module's durable stack and publish the result." },
    .{ .name = "without", .effect = null, .text = "Move the draft's top value onto the pending outputs a within application returns to its caller." },
    .{ .name = "@module", .effect = "unit-input -- module", .text = "Evaluate a module body in a fresh unit and return its definitions as an anonymous immutable module value." },
    .{ .name = "register", .effect = "module module-name --", .text = "Register a module value under a canonical name, creating that registration or replacing its code while keeping its durable state." },
    .{ .name = "@defm", .effect = "unit-input module-name --", .text = "Evaluate a module body and register the resulting module value under a name; exactly `@module` followed by `register`." },
    .{ .name = "import", .effect = "original binding --", .text = "Bind one qualified module word under a bare local name while preserving its effect and documentation." },
    .{ .name = "alias", .effect = "short name --", .text = "Register a short alias for a qualified module name." },
    .{ .name = "qualify", .effect = "module-name binding-name -- qualified-word", .text = "Construct an executable qualified word without reparsing source text." },
    .{ .name = "invoke", .effect = "module binding-name -- ...", .text = "Call one public export of a module value, which carries no name to qualify." },
    .{ .name = "words", .effect = "--", .text = "Print the visible dictionary in sorted order." },
    .{ .name = "load", .effect = "path --", .text = "Read and evaluate a source file as one transactional unit." },

    .{ .name = "@spawn", .effect = "unit-input -- task", .text = "Run a quotation or unit plan concurrently in a fresh child unit." },
    .{ .name = "await", .effect = "task -- result", .text = "Wait for a task and return its success or error result." },
    .{ .name = "cancel", .effect = "task --", .text = "Request cancellation of a task, doing nothing if it is already complete." },
    .{ .name = "tasks", .effect = "-- tasks", .text = "Return pending descendant tasks in deterministic spawn order." },
    .{ .name = "await-any", .effect = "tasks -- index result", .text = "Wait for any task in a nonempty list and return its index and result." },
    .{ .name = "await-for", .effect = "task milliseconds -- result", .text = "Wait up to a nonnegative number of milliseconds for a task result." },
    .{ .name = "@each", .effect = "sequence unit-input -- results", .text = "Apply a quotation or unit plan concurrently in one fresh unit per element and return one result per element in input order." },
    .{ .name = "+", .effect = "x y -- z", .text = "Add numeric values or conforming numeric arrays pervasively." },
    .{ .name = "-", .effect = "x y -- z", .text = "Subtract numeric or character values or conforming arrays pervasively." },
    .{ .name = "*", .effect = "x y -- z", .text = "Multiply numeric values or conforming numeric arrays pervasively." },
    .{ .name = "/", .effect = "x y -- z", .text = "Divide numeric values or conforming numeric arrays pervasively, returning floats." },
    .{ .name = "div", .effect = "x y -- z", .text = "Compute checked integer division pervasively." },
    .{ .name = "pow", .effect = "x y -- z", .text = "Raise numbers to powers pervasively, returning floats." },
    .{ .name = "atan2", .effect = "y x -- z", .text = "Compute the two-argument arctangent of numeric values pervasively." },
    .{ .name = "min", .effect = "x y -- z", .text = "Return the lesser of two comparable values pervasively." },
    .{ .name = "max", .effect = "x y -- z", .text = "Return the greater of two comparable values pervasively." },
    .{ .name = "=", .effect = "x y -- bool", .text = "Compare conforming values for pervasive equality, producing boolean masks." },
    .{ .name = "<", .effect = "x y -- bool", .text = "Compare conforming values pervasively for ascending order." },
    .{ .name = ">", .effect = "x y -- bool", .text = "Compare conforming values pervasively for descending order." },
    .{ .name = "sqrt", .effect = "x -- y", .text = "Return square roots of numeric values pervasively." },
    .{ .name = "floor", .effect = "x -- integer", .text = "Round numeric values downward pervasively to integers." },
    .{ .name = "ceil", .effect = "x -- integer", .text = "Round numeric values upward pervasively to integers." },
    .{ .name = "round", .effect = "x -- integer", .text = "Round numeric values to nearest integers pervasively." },
    .{ .name = "exp", .effect = "x -- y", .text = "Return natural exponentials of numeric values pervasively." },
    .{ .name = "log", .effect = "x -- y", .text = "Return natural logarithms of numeric values pervasively." },
    .{ .name = "sin", .effect = "x -- y", .text = "Return sines of numeric values pervasively." },
    .{ .name = "cos", .effect = "x -- y", .text = "Return cosines of numeric values pervasively." },
    .{ .name = "not", .effect = "bool -- bool", .text = "Invert boolean 0 and 1 values pervasively." },
    .{ .name = "band", .effect = "x y -- z", .text = "Bitwise and over integer bit patterns pervasively." },
    .{ .name = "bor", .effect = "x y -- z", .text = "Bitwise or over integer bit patterns pervasively." },
    .{ .name = "bxor", .effect = "x y -- z", .text = "Bitwise exclusive or over integer bit patterns pervasively." },
    .{ .name = "bnot", .effect = "x -- y", .text = "Invert every bit of an integer pattern pervasively." },
    .{ .name = "bsl", .effect = "x count -- y", .text = "Shift an integer pattern left, truncating bits off the top." },
    .{ .name = "bsr", .effect = "x count -- y", .text = "Shift an integer pattern right, filling zeros from the top." },
    .{ .name = "at", .effect = "collection key -- value", .text = "Select a list index or dictionary key, pervading over list indices." },
    .{ .name = "where", .effect = "counts -- indices", .text = "Expand integer counts into their replicated zero-based indices." },
    .{ .name = "in?", .effect = "value list -- bool", .text = "Test whole-value membership, pervading over the sought value and never into the list." },
    .{ .name = "raze", .effect = "list -- list", .text = "Flatten one level of a list." },
    .{ .name = "cat", .effect = "left right -- list", .text = "Concatenate two lists." },
    .{ .name = "take", .effect = "list count -- list", .text = "Take a signed number of list elements, cycling when necessary." },
    .{ .name = "drop", .effect = "list count -- list", .text = "Drop a signed number of elements from a list." },
    .{ .name = "range", .effect = "bound -- list", .text = "Return the integers from zero through one less than a nonnegative bound." },
    .{ .name = "shape", .effect = "list -- shape", .text = "Return the dimensions of a rectangular list." },
    .{ .name = "len", .effect = "list -- count", .text = "Return a list's top-level element count." },
    .{ .name = "flip", .effect = "list -- list", .text = "Transpose a rectangular list." },
    .{ .name = "reshape", .effect = "list shape -- list", .text = "Cycle list data into the requested rectangular shape." },

    .{ .name = "cmp", .effect = "left right -- ordering", .text = "Return -1, 0, or 1 for the whole-value order of two comparable values." },
    .{ .name = "grade", .effect = "list -- indices", .text = "Return the stable ascending sort permutation of a comparable list." },
    .{ .name = "group", .effect = "list -- dict", .text = "Group equal list values into a dictionary of zero-based index lists." },

    .{ .name = "put", .effect = "collection key value -- collection", .text = "Functionally update a list index or dictionary key." },
    .{ .name = "del", .effect = "collection key -- collection", .text = "Functionally remove an in-bounds list index or a dictionary key; a missing dictionary key is unchanged." },
    .{ .name = "split", .effect = "string separator -- parts", .text = "Split a string at every occurrence of a separator; an empty separator yields its Unicode scalar strings." },
    .{ .name = "join", .effect = "strings separator -- string", .text = "Join a list of strings with a separator string." },
    .{ .name = "str", .effect = "value -- string", .text = "Return the canonical printed representation of a value as a string." },
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
