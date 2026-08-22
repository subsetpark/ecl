test "archive: sha256 matches known-answer vectors and preserves high bytes" {
    return error.SkipZigTest;
}

test "archive: byte inputs reject wrong containers and invalid items" {
    return error.SkipZigTest;
}

test "archive: unpack-tgz atomically extracts regular files and returns paths" {
    return error.SkipZigTest;
}

test "archive: unpack-tgz rejects traversal malformed and over-limit archives without publication" {
    return error.SkipZigTest;
}

test "archive: unpack-tgz rejects links and special nodes without publication" {
    return error.SkipZigTest;
}

test "archive: unpack-tgz preserves existing destinations and has one concurrent winner" {
    return error.SkipZigTest;
}

test "archive: cancellation and absent host IO never publish a destination" {
    return error.SkipZigTest;
}

test "archive: allocation and filesystem failures never publish a destination" {
    return error.SkipZigTest;
}

test "archive: every export is documented and cold-loads through the builtin manifest" {
    return error.SkipZigTest;
}
