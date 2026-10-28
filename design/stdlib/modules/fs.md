## fs

Filesystem words accept a named `root` symbol or a directory resource and a `path` string.
The command line uses `` `cwd `` for the startup working directory. Applications
may explicitly open other host directories. All filesystem operations are available on each root,
subject to operating-system permissions and runtime limits.

A path is a UTF-8 slash path in the canonical grammar: `.` names the root
itself, and every other path is one or more nonempty components separated by
exactly one `/`, with no `.`, `..`, or NUL component and no leading, trailing,
or repeated separator. Backslash is an ordinary filename character. Paths are
never normalized here; normalize with `path.normalize` and accept the result
with `path.valid-relative?` first. Words that act on a child entry (`create-*`,
`replace-*`, `mkdir`, `rename`, `remove-file`, `remove-dir`) reject `.`.

Resolution is descriptor-relative beneath the root's retained handle. An
intermediate symlink is followed only while its target stays within the root;
an absolute target, a relative target that would pop above the root, more than
40 followed links, or more than 64 KiB of expanded resolver input is refused.
`child-dir`, `open-list`, `open-reader`, `read-bytes`, `read-text`, `stat`, `list`, and the source side of `copy`
follow a final link under the same rule; every other word acts on the final
entry itself. Containment is never a lexical prefix check.

Path-taking failures carry a data dictionary with `` `operation `` (the word's own
symbol), `` `root `` and `` `path `` (or `` `source-root ``, `` `source-path ``,
`` `destination-root ``, and `` `destination-path `` for `copy`), and a closed
`` `reason `` symbol: `` `invalid-path ``, `` `unknown-root ``,
`` `not-found ``, `` `already-exists ``, `` `not-directory ``, `` `is-directory ``,
`` `not-regular ``, `` `not-empty ``, `` `symlink-loop ``, `` `symlink-escape ``,
`` `invalid-utf8 ``, `` `limit ``, `` `access-denied ``, `` `read-only ``, `` `no-space ``,
`` `busy ``, `` `cross-device ``, `` `unsupported ``, `` `changed ``, or `` `io ``. The kind is
`` `type `` for wrong value kinds or byte-list members outside `0..255`, `` `domain ``
for malformed paths and unknown roots,
`` `overflow `` for a configured limit, `` `cancelled `` for cancellation, and `` `io ``
for filesystem state and host failures. Host error names never appear as data.

Reads, writes, and copies are bounded by the transfer limit
(1 GiB by default) and advance in 64 KiB quanta; listings are bounded by an
entry count (100,000) and aggregate name bytes (64 MiB); a Session runs at most
64 filesystem operations at once. Mutation stages complete contents in a
private sibling entry and publishes with one atomic namespace operation, so
failure or cancellation before the commit leaves the destination unchanged.
Staged contents are flushed to the device before publication, so a crash
after the commit cannot leave an empty file under the final name; directory
entry durability, ownership, timestamps, and extended attributes are not
promised. Created files use the host's ordinary creation mode under the
process umask, a replaced file keeps its permission bits, and a copy carries
the source's permission bits under the umask.
