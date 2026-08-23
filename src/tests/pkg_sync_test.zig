//! Public package-store and synchronization behavior over the hermetic HTTPS fixture.
//!
//! Patch 2 registers the complete proof surface before production symbols
//! exist. Each skipped case is activated by the patch that implements the
//! behavior named in its title.

test "pkg store: inspect returns exact root manifest" {
    // PENDING: Patch 4.
    return error.SkipZigTest;
}

test "pkg store: rejects invalid source package layouts before publication" {
    // PENDING: Patch 4.
    return error.SkipZigTest;
}

test "pkg store: atomically installs one valid source package" {
    // PENDING: Patch 4.
    return error.SkipZigTest;
}

test "pkg store: existing immutable entry wins concurrent install" {
    // PENDING: Patch 4.
    return error.SkipZigTest;
}

test "pkg store: present distinguishes absent directory and invalid node" {
    // PENDING: Patch 4.
    return error.SkipZigTest;
}

test "pkg store: atomic lock replacement preserves prior bytes on failure" {
    // PENDING: Patch 4.
    return error.SkipZigTest;
}

test "pkg sync: resolves transitive MVS and writes canonical lock" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}

test "pkg sync: deleting lock reproduces identical bytes without refetching present entries" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}

test "pkg sync: hash mismatch names package and hashes without store or lock" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}

test "pkg sync: prefix violation names offender without retained entry" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}

test "pkg sync: manifest identity mismatch retains no entry or lock" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}

test "pkg sync: non-success HTTP names package URL and status" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}

test "pkg sync: cache precedence selects ECL CACHE then XDG then HOME" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}
