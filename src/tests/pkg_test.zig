//! The embedded `pkg.*` modules: package formats and resolution as data.
//!
//! Every case here passes only source strings to a Session, so the suite runs
//! on the traceless session heap and proves what it needs to prove about the
//! modules — that their vocabulary is pure. There is no host IO to reach.
const support = @import("kernel_test_support.zig");

/// The order laws, written in ecl so that one Session proves all of them.
///
/// `trichotomy` counts how many of `a < b`, `b < a`, and `a = b` hold, which is
/// exactly one for a strict total order. `ascending-flags` asserts that every
/// earlier member of a list precedes every later one, which over a list already
/// known to be ascending is transitivity and totality together.
const order_laws =
    "(a b -- count) ((|a b| a b pkg.version.less? b a pkg.version.less? + a b match? +) call) " ++
    "'trichotomy def " ++
    "(element corpus -- pairs) ((|element corpus| corpus element (pair) partial each) call) " ++
    "'row-of def " ++
    "(corpus -- pairs) ((|corpus| corpus corpus (row-of) partial each raze) call) " ++
    "'pairs-of def " ++
    "(index reference -- flags) ((|index reference| reference index 1 + drop reference index at " ++
    "(swap pkg.version.less?) partial each) call) 'ascending-row def " ++
    "(reference -- flags) ((|reference| reference len range reference (ascending-row) partial each raze) call) " ++
    "'ascending-flags def ";

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

fn requirement(
    comptime version: []const u8,
    comptime url: []const u8,
    comptime hash: []const u8,
) []const u8 {
    return "{'version \"" ++ version ++ "\" 'url \"" ++ url ++ "\" 'hash \"" ++ hash ++ "\"}";
}

fn manifest(
    comptime name: []const u8,
    comptime version: []const u8,
    comptime requires: []const u8,
) []const u8 {
    return "{'format 1 'name \"" ++ name ++ "\" 'version \"" ++ version ++
        "\" 'requires " ++ requires ++ "}";
}

const requirement_b_100 = requirement("1.0.0", "https://e.com/b.tgz", hash_a);
const requirement_c_120 = requirement("1.2.0", "https://e.com/c12.tgz", hash_a);
const requirement_c_150 = requirement("1.5.0", "https://e.com/c15.tgz", hash_b);
const manifest_b_100 = manifest("b", "1.0.0", "{\"c\" " ++ requirement_c_150 ++ "}");
const manifest_c_120 = manifest("c", "1.2.0", "{}");
const manifest_c_150 = manifest("c", "1.5.0", "{}");
const mvs_root = manifest(
    "app",
    "0.1.0",
    "{\"b\" " ++ requirement_b_100 ++ " \"c\" " ++ requirement_c_120 ++ "}",
);
const mvs_root_without_c = manifest("app", "0.1.0", "{\"b\" " ++ requirement_b_100 ++ "}");
const mvs_catalog =
    "{\"b\" {\"1.0.0\" " ++ manifest_b_100 ++ "} " ++
    "\"c\" {\"1.2.0\" " ++ manifest_c_120 ++ " \"1.5.0\" " ++ manifest_c_150 ++ "}} ";
test "pkg: every module export carries a body and nonempty documentation" {
    // Cross-module helpers are public because ordinary ECL modules have no
    // privileged friendship relation. Each remains documented and callable.
    const exports = [_][]const u8{
        "pkg.version.validate",
        "pkg.version.less?",
        "pkg.version.max",
        "pkg.name.valid?",
        "pkg.name.hash?",
        "pkg.name.url?",
        "pkg.name.owns?",
        "pkg.name.collides?",
        "pkg.data.assert-inert-entry",
        "pkg.data.read-one",
        "pkg.data.sorted-entries",
        "pkg.manifest.validate-requirement",
        "pkg.manifest.validate",
        "pkg.manifest.read",
        "pkg.lock.validate",
        "pkg.lock.read",
        "pkg.lock.write",
        "pkg.mvs.resolve",
    };
    inline for (exports) |qualified| {
        try support.expectStack(
            "'" ++ qualified ++ " body type '" ++ qualified ++ " doc len 0 >",
            "'list 1",
        );
    }
    // Private implementation words stay absent from each module's public face.
    try support.expectErrors(&.{
        .{
            .name = "a private helper is not reachable",
            .source = "\"1.0.0\" pkg.version.version-cmp",
            .kind = "undefined-word",
            .word = "pkg.version.version-cmp",
        },
        .{
            .name = "an internal predicate is not reachable",
            .source = "\"foo\" pkg.name.related?",
            .kind = "undefined-word",
            .word = "pkg.name.related?",
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
            "corpus (dup pkg.version.less?) each (0 =) all?) call " ++
            reference_corpus ++ "ascending-flags (1 =) all?",
        "16 1 1 1",
    );
    // The laws can fail: a descending pair is not ascending. Without this the
    // three 1s above would also be produced by a check that asserts nothing.
    try support.expectStack(
        order_laws ++ "[\"1.0.0\" \"1.0.0-alpha\"] ascending-flags (1 =) all?",
        "0",
    );
    // Ordering survives a session that has deliberately shadowed `where`,
    // which prelude `find`, `filter`, and `partition` resolve through. When
    // this could once happen wholesale and silently — bulk module splicing added every
    // export at once — a `pkg` word reaching any of those three answered "a
    // table must be a dict of columns" instead of ordering two versions. It
    // now takes naming `where`, and it still must not reach this module.
    try support.expectStack(
        "'table.where 'where import \"1.2.0\" \"1.10.0\" pkg.version.less? " ++
            "[\"1.0.0-a\" \"1.0.0\"] pkg.version.max",
        "1 \"1.0.0\"",
    );
}

test "pkg: the version grammar rejects build metadata and leading-zero fields" {
    try support.expectErrors(&.{
        .{
            .name = "build metadata is outside the grammar",
            .source = "\"1.0.0+build\" \"1.0.1\" pkg.version.less?",
            .kind = "domain",
            .message_contains = "build metadata",
        },
        .{
            // Admitting this would give one version two spellings, and the
            // reader would not catch it: `"01" parse first` is 1.
            .name = "a leading zero in a core field",
            .source = "\"1.01.0\" \"1.2.0\" pkg.version.less?",
            .kind = "domain",
            .message_contains = "leading zero",
        },
        .{
            .name = "a leading zero in a numeric prerelease identifier",
            .source = "\"1.0.0-01\" \"1.2.0\" pkg.version.less?",
            .kind = "domain",
            .message_contains = "leading zero",
        },
        .{
            .name = "two core fields",
            .source = "\"1.0\" \"1.2.0\" pkg.version.less?",
            .kind = "domain",
            .message_contains = "major.minor.patch",
        },
        .{
            .name = "four core fields",
            .source = "\"1.0.0.0\" \"1.2.0\" pkg.version.less?",
            .kind = "domain",
            .message_contains = "major.minor.patch",
        },
        .{
            // A hyphen with nothing after it is one empty identifier, not the
            // absence of a prerelease.
            .name = "an empty prerelease",
            .source = "\"1.0.0-\" \"1.2.0\" pkg.version.less?",
            .kind = "domain",
            .message_contains = "prerelease identifier",
        },
        .{
            .name = "an empty identifier inside a prerelease",
            .source = "\"1.0.0-a..b\" \"1.2.0\" pkg.version.less?",
            .kind = "domain",
            .message_contains = "prerelease identifier",
        },
        .{
            .name = "an identifier character outside the charset",
            .source = "\"1.0.0-a_b\" \"1.2.0\" pkg.version.less?",
            .kind = "domain",
            .message_contains = "prerelease identifier",
        },
    });
    // A hyphen inside an identifier is legal, so the rejections above are the
    // grammar rather than a hyphen scan.
    try support.expectStack("\"1.0.0-a-b\" \"1.0.0-a-c\" pkg.version.less?", "1");
}

test "pkg: version< classifies a malformed operand rather than answering" {
    try support.expectErrors(&.{
        .{
            .name = "a non-string left operand",
            .source = "5 \"1.2.0\" pkg.version.less?",
            .kind = "type",
            .message_contains = "a package version is a string",
        },
        .{
            // Both operands are validated, so a malformed right side cannot
            // ride along behind a well-formed left one.
            .name = "a non-string right operand",
            .source = "\"1.2.0\" 5 pkg.version.less?",
            .kind = "type",
            .message_contains = "a package version is a string",
        },
        .{
            .name = "a malformed right operand",
            .source = "\"1.2.0\" \"nope\" pkg.version.less?",
            .kind = "domain",
        },
    });
}

test "pkg: version-max returns a member no element exceeds" {
    try support.expectStacks(&.{
        .{
            .name = "the maximum of declared minimums",
            .source = "[\"1.2.0\" \"1.5.0\" \"1.10.0\" \"1.5.0\"] pkg.version.max",
            .expected = "\"1.10.0\"",
        },
        .{
            .name = "a release beats every prerelease of its own core",
            .source = "[\"1.0.0-rc.1\" \"1.0.0\" \"1.0.0-alpha\"] pkg.version.max",
            .expected = "\"1.0.0\"",
        },
        .{
            .name = "one element is its own maximum",
            .source = "[\"0.1.0\"] pkg.version.max",
            .expected = "\"0.1.0\"",
        },
        .{
            // The two halves of "maximum": nothing in the input exceeds the
            // result, and the result is one of the input's own members.
            .name = "the result dominates the input and belongs to it",
            .source = "[\"2.0.0\" \"1.9.9\" \"2.0.0-rc.1\"] dup pkg.version.max " ++
                "(|corpus max| " ++
                "corpus max (swap pkg.version.less?) partial each (1 =) any? not " ++
                "corpus max (match?) partial each (1 =) any?) call",
            .expected = "1 1",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "an empty list has no maximum",
            .source = "[] pkg.version.max",
            .kind = "shape",
            .message_contains = "at least one version",
        },
        .{
            .name = "a non-list",
            .source = "5 pkg.version.max",
            .kind = "type",
            .message_contains = "list of version strings",
        },
        .{
            // Validation runs over every element before any comparison, so a
            // malformed element the maximum would never reach is still caught.
            .name = "a malformed element behind the maximum",
            .source = "[\"9.0.0\" \"1.0\"] pkg.version.max",
            .kind = "domain",
        },
    });
}

test "pkg: read-manifest accepts the canonical manifest and rejects undeclared keys" {
    try support.expectStacks(&.{
        .{
            .name = "a canonical manifest reads back as itself",
            .source = manifest_text ++ "pkg.manifest.read 'name at",
            .expected = "\"my.proj\"",
        },
        .{
            // Comments are permitted in a manifest and the reader drops them,
            // which is why nothing that rewrites the file can preserve them.
            .name = "comments are permitted",
            .source = "\"# a comment\\n{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" " ++
                "'requires {}}\" pkg.manifest.read 'requires at keys len",
            .expected = "0",
        },
        .{
            .name = "validate-manifest returns its argument unchanged",
            .source = manifest_text ++ "parse first dup pkg.manifest.validate match?",
            .expected = "1",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "unreadable text is the reader's own failure",
            .source = "\"{'format 1\" pkg.manifest.read",
            .kind = "parse",
        },
        .{
            .name = "two forms are not a manifest",
            .source = "\"{} {}\" pkg.manifest.read",
            .kind = "shape",
            .message_contains = "exactly one form",
        },
        .{
            .name = "no forms are not a manifest",
            .source = "\"\" pkg.manifest.read",
            .kind = "shape",
            .message_contains = "exactly one form",
        },
        .{
            .name = "a non-dict is not a manifest",
            .source = "\"[1 2]\" pkg.manifest.read",
            .kind = "type",
            .message_contains = "a manifest is a dict",
        },
        .{
            // The case the declared-key rule exists for: a misspelling that a
            // tolerant reader would ignore, leaving the requirement unapplied.
            .name = "an undeclared key",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" " ++
                "'requires {} 'require {}}\" pkg.manifest.read",
            .kind = "domain",
            .message_contains = "exactly the keys",
        },
        .{
            .name = "a missing key",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\"}\" pkg.manifest.read",
            .kind = "domain",
            .message_contains = "exactly the keys",
        },
        .{
            .name = "an unsupported format",
            .source = "\"{'format 2 'name \\\"a\\\" 'version \\\"0.1.0\\\" " ++
                "'requires {}}\" pkg.manifest.read",
            .kind = "domain",
            .message_contains = "format is 1",
        },
        .{
            .name = "a name that is not a canonical package name",
            .source = "\"{'format 1 'name \\\"My.Proj\\\" 'version \\\"0.1.0\\\" " ++
                "'requires {}}\" pkg.manifest.read",
            .kind = "domain",
            .message_contains = "lowercase segments",
        },
        .{
            .name = "a requirement url that is not https",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" 'requires " ++
                "{\\\"foo\\\" {'version \\\"1.0.0\\\" 'url \\\"http://e.com/f.tgz\\\" " ++
                "'hash \\\"" ++ hash_a ++ "\\\"}}}\" pkg.manifest.read",
            .kind = "domain",
            .message_contains = "https",
        },
        .{
            .name = "a hash that is not sha256 and 64 lowercase hex digits",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" 'requires " ++
                "{\\\"foo\\\" {'version \\\"1.0.0\\\" 'url \\\"https://e.com/f.tgz\\\" " ++
                "'hash \\\"sha256-ABC\\\"}}}\" pkg.manifest.read",
            .kind = "domain",
            .message_contains = "lowercase hex",
        },
        .{
            // Self-requirement and a prefix collision are the same question,
            // so one rule answers both.
            .name = "a package may not require itself",
            .source = "\"{'format 1 'name \\\"foo\\\" 'version \\\"0.1.0\\\" 'requires " ++
                "{\\\"foo\\\" {'version \\\"1.0.0\\\" 'url \\\"https://e.com/f.tgz\\\" " ++
                "'hash \\\"" ++ hash_a ++ "\\\"}}}\" pkg.manifest.read",
            .kind = "domain",
            .message_contains = "own another's name",
        },
        .{
            .name = "two requirements may not own one another",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" 'requires " ++
                "{\\\"foo\\\" {'version \\\"1.0.0\\\" 'url \\\"https://e.com/f.tgz\\\" " ++
                "'hash \\\"" ++ hash_a ++ "\\\"} " ++
                "\\\"foo.bar\\\" {'version \\\"1.0.0\\\" 'url \\\"https://e.com/g.tgz\\\" " ++
                "'hash \\\"" ++ hash_b ++ "\\\"}}}\" pkg.manifest.read",
            .kind = "domain",
            .message_contains = "own another's name",
        },
        .{
            // Appending the ownership boundary before sorting keeps `p-`
            // outside the contiguous `p.` prefix range.
            .name = "a hyphenated sibling cannot separate an owner from its child",
            .source = "\"{'format 1 'name \\\"p\\\" 'version \\\"0.1.0\\\" 'requires " ++
                "{\\\"p-\\\" {'version \\\"1.0.0\\\" 'url \\\"https://e.com/f.tgz\\\" " ++
                "'hash \\\"" ++ hash_a ++ "\\\"} " ++
                "\\\"p.a\\\" {'version \\\"1.0.0\\\" 'url \\\"https://e.com/g.tgz\\\" " ++
                "'hash \\\"" ++ hash_b ++ "\\\"}}}\" pkg.manifest.read",
            .kind = "domain",
            .message_contains = "own another's name",
        },
        .{
            // Digits sort on the other side of `.`, and must likewise leave
            // the owner adjacent to its dotted child.
            .name = "a numeric sibling cannot separate an owner from its child",
            .source = "\"{'format 1 'name \\\"p\\\" 'version \\\"0.1.0\\\" 'requires " ++
                "{\\\"p0\\\" {'version \\\"1.0.0\\\" 'url \\\"https://e.com/f.tgz\\\" " ++
                "'hash \\\"" ++ hash_a ++ "\\\"} " ++
                "\\\"p.a\\\" {'version \\\"1.0.0\\\" 'url \\\"https://e.com/g.tgz\\\" " ++
                "'hash \\\"" ++ hash_b ++ "\\\"}}}\" pkg.manifest.read",
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
                "pkg.manifest.read",
            .kind = "domain",
            .message_contains = "inert data",
            .data = &.{.{ .name = "key", .expected = .{ .symbol = "requires" } }},
        },
        .{
            .name = "a bare word as a value",
            .source = "\"{'format 1 'name \\\"a\\\" 'version \\\"0.1.0\\\" " ++
                "'requires exit}\" pkg.manifest.read",
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
                "'hash exit}}}\" pkg.manifest.read",
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
            .source = canonical_lock_source ++ "dup pkg.lock.read pkg.lock.write match?",
            .expected = "1",
        },
        .{
            // And the other direction: a lock value survives the trip.
            .name = "reading a written lock reproduces its value",
            .source = unsorted_lock_source ++ "dup pkg.lock.write pkg.lock.read match?",
            .expected = "1",
        },
        .{
            .name = "the text ends with a newline, because a lock is a file",
            .source = unsorted_lock_source ++ "pkg.lock.write \"\\n\" str.ends?",
            .expected = "1",
        },
    });
}

test "pkg: write-lock canonicalizes entry order and refuses an invalid lock" {
    // The input's entries are in the opposite order to the output's. Dict
    // equality ignores insertion order, so only the emitted text can catch a
    // missing sort.
    try support.expectStack(
        unsorted_lock_source ++ "pkg.lock.write " ++ canonical_lock_source ++ "match?",
        "1",
    );
    try support.expectErrors(&.{
        .{
            .name = "an invalid lock raises instead of emitting partial text",
            .source = "{'format 1 'root \"a\"} pkg.lock.write",
            .kind = "domain",
            .message_contains = "exactly the keys",
        },
        .{
            .name = "a non-dict is not a lock",
            .source = "5 pkg.lock.write",
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
            .source = "\"foo\" \"foo\" pkg.name.owns? " ++
                "\"foo\" \"foo.bar\" pkg.name.owns? " ++
                "\"foo\" \"foo.bar.baz\" pkg.name.owns? " ++
                "\"foo\" \"foobar\" pkg.name.owns?",
            .expected = "1 1 1 0",
        },
        .{
            .name = "ownership is not symmetric",
            .source = "\"foo.bar\" \"foo\" pkg.name.owns? " ++
                "\"a.b\" \"a.b.c\" pkg.name.owns? " ++
                "\"a.b\" \"a.c\" pkg.name.owns?",
            .expected = "0 1 0",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "a non-string",
            .source = "5 \"foo\" pkg.name.owns?",
            .kind = "type",
            .message_contains = "two package names",
        },
        .{
            .name = "a malformed name is not merely unowned",
            .source = "\"foo\" \"Foo.Bar\" pkg.name.owns?",
            .kind = "domain",
            .message_contains = "lowercase segments",
        },
        .{
            .name = "a doubled dot leaves an empty segment",
            .source = "\"foo\" \"foo..bar\" pkg.name.owns?",
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
            .source = "(lock -- root names) (|lock| lock 'root at " ++
                "lock 'requires lock 'root at pair at-path keys) " ++
                "'root-requirements def " ++
                canonical_lock_source ++
                "pkg.lock.read dup 'requires at keys sort swap root-requirements",
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
                "'requires {\"a\" {\"foo\" \"1.2.0\"}}} pkg.lock.write",
            .kind = "domain",
            .message_contains = "never below a minimum",
        },
        .{
            .name = "a required name with no selection",
            .source = "{'format 1 'root \"a\" 'packages {} " ++
                "'requires {\"a\" {\"foo\" \"1.2.0\"}}} pkg.lock.write",
            .kind = "domain",
            .message_contains = "has a selection",
        },
        .{
            .name = "the root does not key the requirement table",
            .source = "{'format 1 'root \"a\" 'packages {} 'requires {}} pkg.lock.write",
            .kind = "domain",
            .message_contains = "root's own requirements",
        },
    });
}

test "pkg: resolve selects the maximum of every reachable declared minimum" {
    try support.expectStack(
        mvs_root ++ " " ++ mvs_catalog ++
            "pkg.mvs.resolve 'packages at dup keys len swap [\"c\" 'version] at-path",
        "2 \"1.5.0\"",
    );
}

test "pkg: every resolved selection meets every recorded minimum" {
    try support.expectStack(
        "(entry packages -- bool) (|entry packages| packages entry first 'version pair at-path " ++
            "entry 1 at pkg.version.less? not) " ++
            "'selection-meets? def " ++
            mvs_root ++ " " ++ mvs_catalog ++
            "pkg.mvs.resolve dup 'requires at vals (pairs) each raze " ++
            "swap 'packages at (selection-meets?) partial all?",
        "1",
    );
}

test "pkg: resolution is deterministic and order-independent over shuffled graph inputs" {
    const shuffled_root = comptime manifest(
        "app",
        "0.1.0",
        "{\"c\" " ++ requirement_c_120 ++ " \"b\" " ++ requirement_b_100 ++ "}",
    );
    const unreachable_c_900 = comptime manifest("c", "9.0.0", "{}");
    const shuffled_catalog = comptime "{\"c\" {\"9.0.0\" " ++ unreachable_c_900 ++ " \"1.5.0\" " ++ manifest_c_150 ++
        " \"1.2.0\" " ++ manifest_c_120 ++ "} " ++
        "\"b\" {\"1.0.0\" " ++ manifest_b_100 ++ "}} ";
    try support.expectStack(
        mvs_root ++ " " ++ mvs_catalog ++ "pkg.mvs.resolve pkg.lock.write " ++
            shuffled_root ++ " " ++ shuffled_catalog ++ "pkg.mvs.resolve pkg.lock.write match?",
        "1",
    );
}

test "pkg: adding an already satisfied requirement preserves selections" {
    try support.expectStack(
        "(packages lock -- bool version) (|packages lock| packages lock 'packages at match? " ++
            "lock ['requires \"app\" \"c\"] at-path) " ++
            "'compare-augmentation def " ++
            mvs_root_without_c ++ " " ++ mvs_catalog ++ "pkg.mvs.resolve 'packages at " ++
            mvs_root ++ " " ++ mvs_catalog ++ "pkg.mvs.resolve compare-augmentation",
        "1 \"1.2.0\"",
    );
}

test "pkg: resolve reports a hash conflict with both declarations" {
    const root = comptime manifest(
        "app",
        "0.1.0",
        "{\"b\" " ++ requirement_b_100 ++ " \"c\" " ++
            requirement("1.5.0", "https://mirror.example/c.tgz", hash_a) ++ "}",
    );
    const catalog = comptime "{\"b\" {\"1.0.0\" " ++ manifest_b_100 ++ "} " ++
        "\"c\" {\"1.5.0\" " ++ manifest_c_150 ++ "}} ";
    try support.expectError(.{
        .name = "same package version declared with two hashes",
        .source = root ++ " " ++ catalog ++ "pkg.mvs.resolve",
        .kind = "domain",
        .message_contains = "conflicting hashes",
        .data = &.{
            .{ .name = "package", .expected = .{ .string = "c" } },
            .{ .name = "version", .expected = .{ .string = "1.5.0" } },
            .{ .name = "left-package", .expected = .{ .string = "app" } },
            .{ .name = "left-hash", .expected = .{ .string = hash_a } },
            .{ .name = "right-package", .expected = .{ .string = "b" } },
            .{ .name = "right-hash", .expected = .{ .string = hash_b } },
        },
    });
}

test "pkg: resolve reports a prefix collision with both packages" {
    const requirement_a = comptime requirement("1.0.0", "https://e.com/a.tgz", hash_a);
    const requirement_b = comptime requirement("1.0.0", "https://e.com/b.tgz", hash_b);
    const requirement_foo = comptime requirement("1.0.0", "https://e.com/foo.tgz", hash_a);
    const requirement_foo_bar = comptime requirement("1.0.0", "https://e.com/foo-bar.tgz", hash_b);
    const root = comptime manifest(
        "app",
        "0.1.0",
        "{\"a\" " ++ requirement_a ++ " \"b\" " ++ requirement_b ++ "}",
    );
    const catalog = comptime "{\"a\" {\"1.0.0\" " ++ manifest("a", "1.0.0", "{\"foo\" " ++ requirement_foo ++ "}") ++
        "} \"b\" {\"1.0.0\" " ++ manifest("b", "1.0.0", "{\"foo.bar\" " ++ requirement_foo_bar ++ "}") ++
        "} \"foo\" {\"1.0.0\" " ++ manifest("foo", "1.0.0", "{}") ++
        "} \"foo.bar\" {\"1.0.0\" " ++ manifest("foo.bar", "1.0.0", "{}") ++ "}} ";
    try support.expectError(.{
        .name = "two selected package names overlap",
        .source = root ++ " " ++ catalog ++ "pkg.mvs.resolve",
        .kind = "domain",
        .message_contains = "overlapping prefixes",
        .data = &.{
            .{ .name = "left-package", .expected = .{ .string = "foo" } },
            .{ .name = "right-package", .expected = .{ .string = "foo.bar" } },
        },
    });
}

test "pkg: resolve reports a requirement cycle with every responsible package" {
    const requirement_a = comptime requirement("1.0.0", "https://e.com/a.tgz", hash_a);
    const requirement_b = comptime requirement("1.0.0", "https://e.com/b.tgz", hash_b);
    const root = comptime manifest("app", "0.1.0", "{\"a\" " ++ requirement_a ++ "}");
    const catalog = comptime "{\"a\" {\"1.0.0\" " ++ manifest("a", "1.0.0", "{\"b\" " ++ requirement_b ++ "}") ++
        "} \"b\" {\"1.0.0\" " ++ manifest("b", "1.0.0", "{\"a\" " ++ requirement_a ++ "}") ++ "}} ";
    try support.expectStack(
        root ++ " " ++ catalog ++ "2 pack (pkg.mvs.resolve) with @attempt " ++
            "'err at dup 'kind at swap ['data 'packages] at-path",
        "'domain (\"a\" \"b\")",
    );
}

test "pkg: resolve reports malformed versions and missing manifests with their requirers" {
    const malformed = comptime manifest(
        "app",
        "0.1.0",
        "{\"b\" " ++ requirement("not-a-version", "https://e.com/b.tgz", hash_a) ++ "}",
    );
    const missing = comptime manifest("app", "0.1.0", "{\"b\" " ++ requirement_b_100 ++ "}");
    try support.expectErrors(&.{
        .{
            .name = "malformed reachable version",
            .source = malformed ++ " {} pkg.mvs.resolve",
            .kind = "domain",
            .message_contains = "version is malformed",
            .data = &.{
                .{ .name = "package", .expected = .{ .string = "app" } },
                .{ .name = "required-package", .expected = .{ .string = "b" } },
                .{ .name = "version", .expected = .{ .string = "not-a-version" } },
            },
        },
        .{
            .name = "missing exact manifest",
            .source = missing ++ " {} pkg.mvs.resolve",
            .kind = "domain",
            .message_contains = "missing a declared manifest",
            .data = &.{
                .{ .name = "package", .expected = .{ .string = "app" } },
                .{ .name = "required-package", .expected = .{ .string = "b" } },
                .{ .name = "version", .expected = .{ .string = "1.0.0" } },
            },
        },
    });
}
