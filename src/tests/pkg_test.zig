//! The embedded `pkg` module: the package formats as data.
//!
//! Every case here passes only source strings to a Session, so the suite runs
//! on the traceless session heap and proves what it needs to prove about the
//! module — that its vocabulary is pure. There is no host IO to reach.
const support = @import("kernel_test_support.zig");

/// The order laws, written in ecl so that one Session proves all of them.
///
/// `trichotomy` counts how many of `a < b`, `b < a`, and `a = b` hold, which is
/// exactly one for a strict total order. `ascending-flags` asserts that every
/// earlier member of a list precedes every later one, which over a list already
/// known to be ascending is transitivity and totality together.
const order_laws =
    "((|a b| a b pkg.version< b a pkg.version< + a b match? +) call) " ++
    "(a b -- count) 'trichotomy def " ++
    "((|element corpus| corpus element (pair) partial each) call) " ++
    "(element corpus -- pairs) 'row-of def " ++
    "((|corpus| corpus corpus (row-of) partial each raze) call) " ++
    "(corpus -- pairs) 'pairs-of def " ++
    "((|index reference| reference index 1 + drop reference index at " ++
    "(swap pkg.version<) partial each) call) " ++
    "(index reference -- flags) 'ascending-row def " ++
    "((|reference| reference len range reference (ascending-row) partial each raze) call) " ++
    "(reference -- flags) 'ascending-flags def ";

/// Semver 2.0.0 §11's own precedence example, ascending.
const reference_corpus =
    "[\"1.0.0-alpha\" \"1.0.0-alpha.1\" \"1.0.0-alpha.beta\" \"1.0.0-beta\" " ++
    "\"1.0.0-beta.2\" \"1.0.0-beta.11\" \"1.0.0-rc.1\" \"1.0.0\" \"1.0.1\" " ++
    "\"1.1.0\" \"2.0.0\"] ";
test "pkg: every export carries a body and nonempty documentation" {
    // PENDING: Patch 4
    // Reflection reaches all seven exports and each one is annotated, the
    // module-level form of the prelude's embedded-vocabulary case.
    return error.SkipZigTest;
}

test "pkg: version ordering is a strict total order over a generated corpus" {
    // The corpus is generated rather than listed, and reproducible: a fresh
    // process starts from a fixed key, and this seeds explicitly anyway so the
    // intent is on the page. Sixteen versions, all distinct, built from draws
    // and then doubled with a prerelease suffix so both arms of the
    // core/prerelease decision are exercised. One Session proves all of it:
    // the tier this suite sits in budgets about a second per case.
    try support.expectStack(
        order_laws ++
            "7 rng.seed " ++
            "24 4 rng.ints [8 3] reshape ((str) each \".\" join) each " ++
            "dup (\"-alpha.1\" cat) each cat " ++
            "(|corpus| corpus distinct len " ++
            "corpus pairs-of (call trichotomy) each (1 =) all? " ++
            "corpus (dup pkg.version<) each (0 =) all?) call " ++
            reference_corpus ++ "ascending-flags (1 =) all?",
        "16 1 1 1",
    );
    // The laws can fail: a descending pair is not ascending. Without this the
    // three 1s above would also be produced by a check that asserts nothing.
    try support.expectStack(
        order_laws ++ "[\"1.0.0\" \"1.0.0-alpha\"] ascending-flags (1 =) all?",
        "0",
    );
    // Ordering survives a session that has imported `table`. That module
    // exports `where`, and `use` splices it over the core kernel that prelude
    // `find`, `filter`, and `partition` resolve through — so a `pkg` word
    // reaching any of those three answered "a table must be a dict of columns"
    // instead of ordering two versions. Expected to break loudly when `use`
    // becomes a single-name import, at which point the hazard is gone.
    try support.expectStack(
        "'table use \"1.2.0\" \"1.10.0\" pkg.version< " ++
            "[\"1.0.0-a\" \"1.0.0\"] pkg.version-max",
        "1 \"1.0.0\"",
    );
}

test "pkg: the version grammar rejects build metadata and leading-zero fields" {
    try support.expectErrors(&.{
        .{
            .name = "build metadata is outside the grammar",
            .source = "\"1.0.0+build\" \"1.0.1\" pkg.version<",
            .kind = "domain",
            .message_contains = "build metadata",
        },
        .{
            // Admitting this would give one version two spellings, and the
            // reader would not catch it: `"01" parse first` is 1.
            .name = "a leading zero in a core field",
            .source = "\"1.01.0\" \"1.2.0\" pkg.version<",
            .kind = "domain",
            .message_contains = "leading zero",
        },
        .{
            .name = "a leading zero in a numeric prerelease identifier",
            .source = "\"1.0.0-01\" \"1.2.0\" pkg.version<",
            .kind = "domain",
            .message_contains = "leading zero",
        },
        .{
            .name = "two core fields",
            .source = "\"1.0\" \"1.2.0\" pkg.version<",
            .kind = "domain",
            .message_contains = "major.minor.patch",
        },
        .{
            .name = "four core fields",
            .source = "\"1.0.0.0\" \"1.2.0\" pkg.version<",
            .kind = "domain",
            .message_contains = "major.minor.patch",
        },
        .{
            // A hyphen with nothing after it is one empty identifier, not the
            // absence of a prerelease.
            .name = "an empty prerelease",
            .source = "\"1.0.0-\" \"1.2.0\" pkg.version<",
            .kind = "domain",
            .message_contains = "prerelease identifier",
        },
        .{
            .name = "an empty identifier inside a prerelease",
            .source = "\"1.0.0-a..b\" \"1.2.0\" pkg.version<",
            .kind = "domain",
            .message_contains = "prerelease identifier",
        },
        .{
            .name = "an identifier character outside the charset",
            .source = "\"1.0.0-a_b\" \"1.2.0\" pkg.version<",
            .kind = "domain",
            .message_contains = "prerelease identifier",
        },
    });
    // A hyphen inside an identifier is legal, so the rejections above are the
    // grammar rather than a hyphen scan.
    try support.expectStack("\"1.0.0-a-b\" \"1.0.0-a-c\" pkg.version<", "1");
}

test "pkg: version< classifies a malformed operand rather than answering" {
    try support.expectErrors(&.{
        .{
            .name = "a non-string left operand",
            .source = "5 \"1.2.0\" pkg.version<",
            .kind = "type",
            .message_contains = "a package version is a string",
        },
        .{
            // Both operands are validated, so a malformed right side cannot
            // ride along behind a well-formed left one.
            .name = "a non-string right operand",
            .source = "\"1.2.0\" 5 pkg.version<",
            .kind = "type",
            .message_contains = "a package version is a string",
        },
        .{
            .name = "a malformed right operand",
            .source = "\"1.2.0\" \"nope\" pkg.version<",
            .kind = "domain",
        },
    });
}

test "pkg: version-max returns a member no element exceeds" {
    try support.expectStacks(&.{
        .{
            .name = "the maximum of declared minimums",
            .source = "[\"1.2.0\" \"1.5.0\" \"1.10.0\" \"1.5.0\"] pkg.version-max",
            .expected = "\"1.10.0\"",
        },
        .{
            .name = "a release beats every prerelease of its own core",
            .source = "[\"1.0.0-rc.1\" \"1.0.0\" \"1.0.0-alpha\"] pkg.version-max",
            .expected = "\"1.0.0\"",
        },
        .{
            .name = "one element is its own maximum",
            .source = "[\"0.1.0\"] pkg.version-max",
            .expected = "\"0.1.0\"",
        },
        .{
            // The two halves of "maximum": nothing in the input exceeds the
            // result, and the result is one of the input's own members.
            .name = "the result dominates the input and belongs to it",
            .source = "[\"2.0.0\" \"1.9.9\" \"2.0.0-rc.1\"] dup pkg.version-max " ++
                "(|corpus max| " ++
                "corpus max (swap pkg.version<) partial each (1 =) any? not " ++
                "corpus max (match?) partial each (1 =) any?) call",
            .expected = "1 1",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "an empty list has no maximum",
            .source = "[] pkg.version-max",
            .kind = "shape",
            .message_contains = "at least one version",
        },
        .{
            .name = "a non-list",
            .source = "5 pkg.version-max",
            .kind = "type",
            .message_contains = "list of version strings",
        },
        .{
            // Validation runs over every element before any comparison, so a
            // malformed element the maximum would never reach is still caught.
            .name = "a malformed element behind the maximum",
            .source = "[\"9.0.0\" \"1.0\"] pkg.version-max",
            .kind = "domain",
        },
    });
}

test "pkg: read-manifest accepts the canonical manifest and rejects undeclared keys" {
    // PENDING: Patch 4
    // Every key is declared, so a misspelling is an error rather than an
    // entry that is silently ignored.
    return error.SkipZigTest;
}

test "pkg: a manifest holding an executable form is rejected, not evaluated" {
    // PENDING: Patch 4
    // A word value anywhere in the candidate is 'domain naming the offending
    // key. `type` reports 'word for an executable reference while a quotation
    // is an ordinary 'list, so this is the whole inertness test.
    return error.SkipZigTest;
}

test "pkg: read-lock and write-lock round-trip a canonical lock byte for byte" {
    // PENDING: Patch 4
    // The lock format is a documented artifact contract, so comparing text is
    // the assertion rather than an inspection of implementation detail.
    return error.SkipZigTest;
}

test "pkg: write-lock canonicalizes entry order and refuses an invalid lock" {
    // PENDING: Patch 4
    // Dict equality ignores insertion order, so only the emitted text can
    // catch a missing sort. An invalid lock raises instead of emitting.
    return error.SkipZigTest;
}

test "pkg: owns-prefix? admits a package's own name and its dotted children only" {
    // PENDING: Patch 4
    // Ownership continues across a `.` boundary and nowhere else, which is
    // what stops `foo` from owning `foobar`.
    return error.SkipZigTest;
}

test "pkg: the lock keys requirements by the requiring package" {
    // PENDING: Patch 4
    // The retrofit door: requirements are keyed by requirer, the root under
    // its own name, and no selection sits below a minimum recorded for it.
    return error.SkipZigTest;
}
