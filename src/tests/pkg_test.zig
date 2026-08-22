//! The embedded `pkg` module: the package formats as data.
//!
//! Every case here passes only source strings to a Session, so the suite runs
//! on the traceless session heap and proves what it needs to prove about the
//! module — that its vocabulary is pure. There is no host IO to reach.
test "pkg: every export carries a body and nonempty documentation" {
    // PENDING: Patch 4
    // Reflection reaches all seven exports and each one is annotated, the
    // module-level form of the prelude's embedded-vocabulary case.
    return error.SkipZigTest;
}

test "pkg: version ordering is a strict total order over a generated corpus" {
    // PENDING: Patch 3
    // Irreflexive, asymmetric, transitive, and trichotomous over a corpus
    // built inside one Session from `rng`'s fixed starting key, plus
    // agreement with a checked-in ascending reference list of semver §11
    // prerelease cases.
    return error.SkipZigTest;
}

test "pkg: the version grammar rejects build metadata and leading-zero fields" {
    // PENDING: Patch 3
    // Build metadata is outside the grammar rather than parsed and discarded,
    // and a leading zero in a numeric field would give one version two
    // spellings.
    return error.SkipZigTest;
}

test "pkg: version< classifies a malformed operand rather than answering" {
    // PENDING: Patch 3
    // A malformed spelling is 'domain and a non-string is 'type; neither is a
    // false answer, because a total order over a subset is not a total order.
    return error.SkipZigTest;
}

test "pkg: version-max returns a member no element exceeds" {
    // PENDING: Patch 3
    // The maximum is a member of its input; the empty list is 'shape and a
    // non-string element is 'type wherever it sits in the list.
    return error.SkipZigTest;
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
