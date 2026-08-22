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

/// A hash is `sha256-` and exactly 64 lowercase hex digits.
const hash_a = "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const hash_b = "sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";

/// One canonical manifest, as ecl source that evaluates to its text.
const manifest_text =
    "\"{'format 1 'name \\\"my.proj\\\" 'version \\\"0.1.0\\\" 'requires " ++
    "{\\\"foo\\\" {'version \\\"1.2.0\\\" 'url \\\"https://e.com/f.tgz\\\" " ++
    "'hash \\\"" ++ hash_a ++ "\\\"}}}\" ";

/// The canonical text of one lock, byte for byte — the artifact contract this
/// suite is entitled to compare against, since the format is documented output.
const canonical_lock =
    "{'format 1\n" ++
    " 'root \"my.proj\"\n" ++
    " 'packages\n" ++
    " {\"bar\" {'version \"0.3.0\" 'url \"https://e.com/b.tgz\" 'hash \"" ++ hash_b ++ "\"}\n" ++
    "  \"foo\" {'version \"1.2.0\" 'url \"https://e.com/f.tgz\" 'hash \"" ++ hash_a ++ "\"}}\n" ++
    " 'requires\n" ++
    " {\"foo\" {\"bar\" \"0.3.0\"}\n" ++
    "  \"my.proj\" {\"foo\" \"1.2.0\"}}}\n";

/// Escape text into an ecl string literal, so the readable reference above
/// stays the single source of truth for both the comparison and the layout.
fn eclLiteral(comptime text: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "\"";
        for (text) |byte| out = out ++ switch (byte) {
            '\n' => "\\n",
            '"' => "\\\"",
            '\\' => "\\\\",
            else => &[_]u8{byte},
        };
        return out ++ "\"";
    }
}

const canonical_lock_source = eclLiteral(canonical_lock) ++ " ";

/// The same lock as ecl source, with its entries deliberately out of order so
/// only the emitted text can catch a missing sort.
const unsorted_lock_source =
    "{'format 1 'root \"my.proj\" 'packages " ++
    "{\"foo\" {'version \"1.2.0\" 'url \"https://e.com/f.tgz\" 'hash \"" ++ hash_a ++ "\"} " ++
    "\"bar\" {'version \"0.3.0\" 'url \"https://e.com/b.tgz\" 'hash \"" ++ hash_b ++ "\"}} " ++
    "'requires {\"my.proj\" {\"foo\" \"1.2.0\"} \"foo\" {\"bar\" \"0.3.0\"}}} ";
test "pkg: every export carries a body and nonempty documentation" {
    // The module-level form of the prelude's embedded-vocabulary case. Seven
    // exports, no more: everything else the module needs is private.
    const exports = [_][]const u8{
        "owns-prefix?", "read-lock", "read-manifest", "validate-manifest",
        "version-max",  "version<",  "write-lock",
    };
    inline for (exports) |name| {
        try support.expectStack(
            "'pkg." ++ name ++ " body type 'pkg." ++ name ++ " doc len 0 >",
            "'list 1",
        );
    }
    // And nothing else is exported: a private helper is absent from the
    // module's public face rather than merely undocumented.
    try support.expectErrors(&.{
        .{
            .name = "a private helper is not reachable",
            .source = "\"1.0.0\" pkg.version-checked",
            .kind = "undefined-word",
            .word = "pkg.version-checked",
        },
        .{
            .name = "an internal predicate is not reachable",
            .source = "\"foo\" pkg.name?",
            .kind = "undefined-word",
            .word = "pkg.name?",
        },
    });
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
    try support.expectStacks(&.{
        .{
            .name = "a canonical manifest reads back as itself",
            .source = manifest_text ++ "pkg.read-manifest 'name at",
            .expected = "\"my.proj\"",
        },
        .{
            // Comments are permitted in a manifest and the reader drops them,
            // which is why nothing that rewrites the file can preserve them.
            .name = "comments are permitted",
            .source = "\"# a comment\\n{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" " ++
                "'requires {}}\" pkg.read-manifest 'requires at keys len",
            .expected = "0",
        },
        .{
            .name = "validate-manifest returns its argument unchanged",
            .source = manifest_text ++ "parse first dup pkg.validate-manifest match?",
            .expected = "1",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "unreadable text is the reader's own failure",
            .source = "\"{'format 1\" pkg.read-manifest",
            .kind = "parse",
        },
        .{
            .name = "two forms are not a manifest",
            .source = "\"{} {}\" pkg.read-manifest",
            .kind = "shape",
            .message_contains = "exactly one form",
        },
        .{
            .name = "no forms are not a manifest",
            .source = "\"\" pkg.read-manifest",
            .kind = "shape",
            .message_contains = "exactly one form",
        },
        .{
            .name = "a non-dict is not a manifest",
            .source = "\"[1 2]\" pkg.read-manifest",
            .kind = "type",
            .message_contains = "a manifest is a dict",
        },
        .{
            // The case the declared-key rule exists for: a misspelling that a
            // tolerant reader would ignore, leaving the requirement unapplied.
            .name = "an undeclared key",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" " ++
                "'requires {} 'require {}}\" pkg.read-manifest",
            .kind = "domain",
            .message_contains = "exactly the keys",
        },
        .{
            .name = "a missing key",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\"}\" pkg.read-manifest",
            .kind = "domain",
            .message_contains = "exactly the keys",
        },
        .{
            .name = "an unsupported format",
            .source = "\"{'format 2 'name \\\"a\\\" 'version \\\"0.1.0\\\" " ++
                "'requires {}}\" pkg.read-manifest",
            .kind = "domain",
            .message_contains = "format is 1",
        },
        .{
            .name = "a name that is not a canonical package name",
            .source = "\"{'format 1 'name \\\"My.Proj\\\" 'version \\\"0.1.0\\\" " ++
                "'requires {}}\" pkg.read-manifest",
            .kind = "domain",
            .message_contains = "lowercase segments",
        },
        .{
            .name = "a requirement url that is not https",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" 'requires " ++
                "{\\\"foo\\\" {'version \\\"1.0.0\\\" 'url \\\"http://e.com/f.tgz\\\" " ++
                "'hash \\\"" ++ hash_a ++ "\\\"}}}\" pkg.read-manifest",
            .kind = "domain",
            .message_contains = "https",
        },
        .{
            .name = "a hash that is not sha256 and 64 lowercase hex digits",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" 'requires " ++
                "{\\\"foo\\\" {'version \\\"1.0.0\\\" 'url \\\"https://e.com/f.tgz\\\" " ++
                "'hash \\\"sha256-ABC\\\"}}}\" pkg.read-manifest",
            .kind = "domain",
            .message_contains = "lowercase hex",
        },
        .{
            // Self-requirement and a prefix collision are the same question,
            // so one rule answers both.
            .name = "a package may not require itself",
            .source = "\"{'format 1 'name \\\"foo\\\" 'version \\\"0.1.0\\\" 'requires " ++
                "{\\\"foo\\\" {'version \\\"1.0.0\\\" 'url \\\"https://e.com/f.tgz\\\" " ++
                "'hash \\\"" ++ hash_a ++ "\\\"}}}\" pkg.read-manifest",
            .kind = "domain",
            .message_contains = "own another's name",
        },
        .{
            .name = "two requirements may not own one another",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" 'requires " ++
                "{\\\"foo\\\" {'version \\\"1.0.0\\\" 'url \\\"https://e.com/f.tgz\\\" " ++
                "'hash \\\"" ++ hash_a ++ "\\\"} " ++
                "\\\"foo.bar\\\" {'version \\\"1.0.0\\\" 'url \\\"https://e.com/g.tgz\\\" " ++
                "'hash \\\"" ++ hash_b ++ "\\\"}}}\" pkg.read-manifest",
            .kind = "domain",
            .message_contains = "own another's name",
        },
    });
}

test "pkg: a manifest holding an executable form is rejected, not evaluated" {
    try support.expectErrors(&.{
        .{
            // The quotation would write a file if anything called it. Nothing
            // does: validation classifies it and the error names the key it
            // was found under.
            .name = "a quotation holding an executable reference",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" " ++
                "'requires ((\\\"pwned\\\" \\\"/tmp/pkg-pwned\\\" io.spit))}\" " ++
                "pkg.read-manifest",
            .kind = "domain",
            .message_contains = "inert data",
            .data = &.{.{ .name = "key", .expected = .{ .symbol = "requires" } }},
        },
        .{
            .name = "a bare word as a value",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" " ++
                "'requires exit}\" pkg.read-manifest",
            .kind = "domain",
            .message_contains = "inert data",
            .data = &.{.{ .name = "key", .expected = .{ .symbol = "requires" } }},
        },
        .{
            // A dict literal stores a bare word as a word value, keys
            // included, so the key side is checked too.
            .name = "a word nested deep inside a requirement",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" 'requires " ++
                "{\\\"foo\\\" {'version \\\"1.0.0\\\" 'url \\\"https://e.com/f.tgz\\\" " ++
                "'hash exit}}}\" pkg.read-manifest",
            .kind = "domain",
            .message_contains = "inert data",
            .data = &.{.{ .name = "key", .expected = .{ .symbol = "requires" } }},
        },
    });
    // Inertness is about executable references and not about lists. Nothing in
    // the manifest grammar admits a bare list, so the way to see the
    // distinction through the public surface is that an ordinary manifest —
    // whose every string is itself a list of chars — validates at all.
}

test "pkg: read-lock and write-lock round-trip a canonical lock byte for byte" {
    try support.expectStacks(&.{
        .{
            // Reading the canonical text and writing it back reproduces its
            // bytes. The lock format is documented output, so comparing text
            // is the contract rather than an inspection of internals.
            .name = "writing a read lock reproduces its text",
            .source = canonical_lock_source ++ "dup pkg.read-lock pkg.write-lock match?",
            .expected = "1",
        },
        .{
            // And the other direction: a lock value survives the trip.
            .name = "reading a written lock reproduces its value",
            .source = unsorted_lock_source ++ "dup pkg.write-lock pkg.read-lock match?",
            .expected = "1",
        },
        .{
            .name = "the text ends with a newline, because a lock is a file",
            .source = unsorted_lock_source ++ "pkg.write-lock \"\\n\" str.ends?",
            .expected = "1",
        },
    });
}

test "pkg: write-lock canonicalizes entry order and refuses an invalid lock" {
    // The input's entries are in the opposite order to the output's. Dict
    // equality ignores insertion order, so only the emitted text can catch a
    // missing sort.
    try support.expectStack(
        unsorted_lock_source ++ "pkg.write-lock " ++ canonical_lock_source ++ "match?",
        "1",
    );
    try support.expectErrors(&.{
        .{
            .name = "an invalid lock raises instead of emitting partial text",
            .source = "{'format 1 'root \"a\"} pkg.write-lock",
            .kind = "domain",
            .message_contains = "exactly the keys",
        },
        .{
            .name = "a non-dict is not a lock",
            .source = "5 pkg.write-lock",
            .kind = "type",
            .message_contains = "a lock is a dict",
        },
    });
}

test "pkg: owns-prefix? admits a package's own name and its dotted children only" {
    try support.expectStacks(&.{
        .{
            // The middle case is the whole point of the word: ownership
            // continues across a dot boundary and nowhere else.
            .name = "own name, dotted child, and a shared prefix that is neither",
            .source = "\"foo\" \"foo\" pkg.owns-prefix? " ++
                "\"foo\" \"foo.bar\" pkg.owns-prefix? " ++
                "\"foo\" \"foo.bar.baz\" pkg.owns-prefix? " ++
                "\"foo\" \"foobar\" pkg.owns-prefix?",
            .expected = "1 1 1 0",
        },
        .{
            .name = "ownership is not symmetric",
            .source = "\"foo.bar\" \"foo\" pkg.owns-prefix? " ++
                "\"a.b\" \"a.b.c\" pkg.owns-prefix? " ++
                "\"a.b\" \"a.c\" pkg.owns-prefix?",
            .expected = "0 1 0",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "a non-string",
            .source = "5 \"foo\" pkg.owns-prefix?",
            .kind = "type",
            .message_contains = "two package names",
        },
        .{
            .name = "a malformed name is not merely unowned",
            .source = "\"foo\" \"Foo.Bar\" pkg.owns-prefix?",
            .kind = "domain",
            .message_contains = "lowercase segments",
        },
        .{
            .name = "a doubled dot leaves an empty segment",
            .source = "\"foo\" \"foo..bar\" pkg.owns-prefix?",
            .kind = "domain",
            .message_contains = "lowercase segments",
        },
    });
}

test "pkg: the lock keys requirements by the requiring package" {
    try support.expectStacks(&.{
        .{
            // The retrofit door: the table is keyed by the package that
            // declared the requirement, root included, so a later format can
            // record two versions of one name without a break.
            .name = "requirements are keyed by requirer, the root under its own name",
            .source = canonical_lock_source ++ "pkg.read-lock dup 'requires at keys sort " ++
                "swap dup 'root at swap 'requires at over at keys",
            .expected = "(\"foo\" \"my.proj\") \"my.proj\" (\"foo\")",
        },
    });
    try support.expectErrors(&.{
        .{
            // A lock whose selection is below a recorded minimum cannot be
            // trusted without re-resolving, so it is not a lock.
            .name = "a selection below a recorded minimum",
            .source = "{'format 1 'root \"a\" 'packages " ++
                "{\"foo\" {'version \"1.0.0\" 'url \"https://e.com/f.tgz\" " ++
                "'hash \"" ++ hash_a ++ "\"}} " ++
                "'requires {\"a\" {\"foo\" \"1.2.0\"}}} pkg.write-lock",
            .kind = "domain",
            .message_contains = "never below a minimum",
        },
        .{
            .name = "a required name with no selection",
            .source = "{'format 1 'root \"a\" 'packages {} " ++
                "'requires {\"a\" {\"foo\" \"1.2.0\"}}} pkg.write-lock",
            .kind = "domain",
            .message_contains = "has a selection",
        },
        .{
            .name = "the root does not key the requirement table",
            .source = "{'format 1 'root \"a\" 'packages {} 'requires {}} pkg.write-lock",
            .kind = "domain",
            .message_contains = "root's own requirements",
        },
    });
}
