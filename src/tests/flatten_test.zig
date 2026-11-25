//! Flattened code lists, observed through a Session: what they compute, how
//! they fail, and where they report it.
test "flatten: apply and dip over literals compute what the words do" {
    // PENDING: patch 2.
    return error.SkipZigTest;
}

test "flatten: a failure inside a flattened quotation reports the quotation and position" {
    // PENDING: patch 2.
    return error.SkipZigTest;
}

test "flatten: a word called from a flattened quotation records its original call site" {
    // PENDING: patch 2.
    return error.SkipZigTest;
}

test "flatten: a redefinition during a flattened list reaches the rest of it" {
    // PENDING: patch 2.
    return error.SkipZigTest;
}

test "flatten: a tail apply under a contract keeps its selected quotation" {
    // PENDING: patch 2.
    return error.SkipZigTest;
}

test "flatten: cleaves, spreads and measured words over literals compute what the words do" {
    // PENDING: patch 3.
    return error.SkipZigTest;
}

test "flatten: a phrase short of inputs fails as the unflattened phrase does" {
    // PENDING: patch 3.
    return error.SkipZigTest;
}

test "flatten: definitions changed during a flattened cleave fail as a counted cleave does" {
    // PENDING: patch 3.
    return error.SkipZigTest;
}

test "flatten: a source combinator over literals computes what the word does" {
    // PENDING: patch 4.
    return error.SkipZigTest;
}

test "flatten: an inlined source word keeps its trace and call site" {
    // PENDING: patch 4.
    return error.SkipZigTest;
}
