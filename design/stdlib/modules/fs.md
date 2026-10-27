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

### open-dir
`( host-path -- directory )` — Open an absolute host directory path, subject to
OS permissions, and return a scope-owned port resource. Host symlinks may be
followed while opening this explicit root. Relative paths are rejected.
`port.close` closes the resource and joins cleanup; scope exit does the same.
A closing directory rejects new operations with `` `io ``. Closure waits for
admitted operations to release their independent descriptor leases, then joins
backend cleanup.

### lock
`( root path -- lock )` — Acquire an exclusive advisory lock on a regular file,
creating an empty file if the path is absent. Existing contents are preserved;
final symlinks and non-regular files are rejected. Contention parks the task
between attempts and is cancellable. The returned port owns the lock until
`port.close` or its owning scope exits. A lock is not a directory resource.
The lock file remains after release. Coordinating applications must keep its
directory entry in place: replacing or deleting it establishes a different
lock identity. Advisory locking coordinates participating applications and
does not prevent other filesystem access.

### child-dir
`( root path -- directory )` — Acquire an independent directory resource beneath
an existing root. Resolution, including final symlinks, is confined to that
root. The acquired directory becomes the new containment boundary; closing
its ordinary parent resource does not close it. Children of a staging resource,
including further descendants, close when staging is sealed or closed even
after task ownership transfer. `.` acquires the root itself.

### stage-dir
`( root destination -- stage )` — Create a private sibling of the destination
and return a scope-owned directory resource. The destination parent must exist.
Filesystem operations accept the stage as a root. `port.close` or scope exit
joins descendant closure and recursive rollback; no destination is published.
The staging directory uses mode `0700` under the process umask.

### reserve
`( root -- reservation )` — Retain a selected directory root and one filesystem
operation slot until joined closure. A reservation can be passed as a root;
its derived operations share that slot and reject overlapping work with
`` `overflow `` and reason `` `limit ``. Closure waits for admitted work. This supports
compositions that must retain admission across inspection and publication.

### open-reader
`( root path -- fd )` — Open a regular file, following a final link within the
root, as a readable byte endpoint for `fd.read`, `fd.read-line`, `fd.read-all`
and the `io` readers, with no size limit: the stream is read a chunk at a
time. The calling scope owns the file; `fd.close` closes it earlier and joins
cleanup, and a read after either is `` `io ``. A directory is `` `is-directory ``; a
non-regular object is `` `not-regular ``.

### open-writer
`( root path -- writer )` — Open private storage for an absent regular file.
The parent must exist and `.` is rejected. A writer is distinct from a directory.
It retains root lifetime and operation admission until joined cleanup. Staging
dependencies survive task transfer. Closing an uncommitted writer removes its
private contents and publishes no destination.

### write-chunk
`( writer bytes -- )` — Append at most 65536 integer bytes. The streaming transfer
limit (1 GiB by default) covers the complete stream, including previous chunks.
A failed or cancelled append prevents later publication of partial contents.

### commit-file
`( writer -- )` — Stop admission, flush the completed stream, and atomically
publish its previously absent destination. Publication is serialized against
cancellation. Success joins writer cleanup; failure retains unpublished private
state for explicit or scope cleanup. No allocation is required after the
publication permit is granted.

### open-list
`( root path -- cursor )` — Open a scope-owned incremental enumeration of a
confined directory. The cursor is a port resource, distinct from a directory
root. It owns its descriptor until `port.close` or scope exit. An enumeration
opened through staging or its descendants also closes when staging seals.

### next-entry
`( cursor -- entry )` — Return the next `{name string kind symbol}` dictionary,
or `{}` at stable end. Kinds are `` `file ``, `` `directory ``, `` `symlink ``, and `` `other ``;
dot entries are omitted and symlinks are described without following them.
Names must be UTF-8. Order and visibility of concurrent namespace changes follow
the host filesystem; this is not a directory snapshot. Concurrent calls reserve
distinct entries, though their results may complete out of order. Each result
owns its name independently of subsequent calls or cursor closure. A closed
cursor raises `` `io ``. Reading does not materialize the whole directory or apply
the aggregate limits of `list`; callers can stop and close at any entry.

### commit-dir
`( stage -- )` — Seal the stage, reject further operations, close its descendant
resources, and wait for admitted operations before atomically publishing to the
absent destination. Any existing entry causes an `` `io `` failure and is preserved;
failure retains the sealed staging resource for joined cleanup with `port.close`.
Success joins descriptor closure and keeps the published tree even if the task
is subsequently cancelled. Namespace publication is atomic; directory-entry
durability across a host crash is not promised.

### copy
`( source-root source-path destination-root destination-path -- )` — Copy a
regular file, following a final source link within its root, into an absent
destination entry; the roots may differ. The copy is staged and published
atomically without replacing; an existing destination of any kind is
`` `already-exists ``, a non-regular source is `` `not-regular `` or `` `is-directory ``,
and no metadata is preserved.

### create-bytes
`( bytes root path -- )` — Atomically create an absent regular file holding
exact bytes. Members are validated before any external state exists. An
existing regular file, directory, symlink (including a dangling one), or other
entry is `` `already-exists ``; a missing parent is `` `not-found ``.

### create-text
`( string root path -- )` — Atomically create an absent regular file holding
the string as UTF-8, with the same collision contract as `create-bytes`.

### exists?
`( root path -- bool )` — Return 1 when the final entry exists and 0 when it is
definitely absent, without following a final link: a dangling link is 1.
Malformed paths, unknown roots, denial, traversal failures such as a missing or
escaping intermediate component, and host failures are errors rather than 0.

### list
`( root path -- entries )` — Follow the path to a directory and return its
children as `{name string kind file}`, `{name string kind directory}`,
`{name string kind symlink}`, or `{name string kind other}`, classified
without following, excluding `.` and `..`, and sorted by Unicode scalar order
of `` `name ``. A child name that is not valid UTF-8, an entry that vanishes or
cannot be classified, or an exceeded listing limit fails the whole listing;
nothing is silently omitted.

### lstat
`( root path -- metadata )` — Describe the final entry without following it:
`{kind file size n}` for a regular file, `{kind directory}`,
`{kind symlink}`, or `{kind other}`. An absent entry is `` `not-found ``.

### mkdirs
`( root path -- )` — Create missing intermediate and final directories. Existing
directories are preserved, including contained symlink targets. `.` is a no-op.
Every component uses the ordinary confined resolver. Failure or cancellation
may leave directories created before that point.

### remove-tree
`( root path -- )` — Recursively remove a directory and its contents. The final
entry must be a directory, and `.` is rejected. Symlinks inside the tree are
removed without following their targets. Work is incremental and cancellable;
failure may leave partially removed contents with temporary entry names.
Removal uses bounded descriptor storage and needs no new allocations once the
selected directory has been opened.

### mkdir
`( root path -- )` — Create exactly one absent directory beneath an existing
parent. There is no recursive parent creation; an existing entry of any kind is
`` `already-exists ``.

### read-bytes
`( root path -- bytes )` — Read one regular file, following a final link within
the root, and return its exact bytes as an integer list. The size observed at
open is the size read; growth or shrink meanwhile is `` `changed ``. A directory is
`` `is-directory ``; a non-regular object is `` `not-regular ``; a file over the
transfer limit is `` `overflow ``.

### read-text
`( root path -- string )` — Read one regular file as `read-bytes` does and
decode it as UTF-8. Invalid UTF-8 is `` `io `` with reason `` `invalid-utf8 ``.

### remove-dir
`( root path -- )` — Remove one empty directory without following a final
link. A nonempty directory is `` `not-empty ``; a file or symlink is
`` `not-directory ``.

### remove-file
`( root path -- )` — Remove one non-directory entry, including a symlink
itself, without following it. A directory is `` `is-directory ``.

### rename
`( root source-path destination-path -- )` — Rename an entry within one root
without replacing. The source may be a regular file, symlink, or directory and
is not followed; an existing destination is `` `already-exists ``, and a
destination on another device is `` `cross-device `` rather than an emulated
copy.

### publish-bytes
`( bytes root path -- )` — Atomically publish complete file contents, creating
an absent destination or replacing one that exists. An entry observed before
staging must be a regular file; a symlink, directory, or other entry is
`` `not-regular ``. Use the observed file's permissions, or host defaults on first
creation. Publication replaces the final directory entry without following it;
concurrent publications each succeed and the last commit wins. An intervening
directory causes failure. A failed operation preserves its destination, and
cancellation before commit removes staging. Cancellation after commit does not
roll back publication. Visibility is atomic; directory-entry durability across
a crash is not promised.

### publish-text
`( string root path -- )` — Publish UTF-8 text under the `publish-bytes` contract.

### replace-bytes
`( bytes root path -- )` — Atomically replace an existing regular file with
exact bytes. The final entry must be observed as a regular file without
following: absence is `` `not-found ``, and a symlink, directory, or other entry
is `` `not-regular ``. The replacement is a new inode published by an atomic
exchange; the word never becomes create-or-replace.

### replace-text
`( string root path -- )` — Replace an existing regular file with UTF-8 text
under the `replace-bytes` contract.

### stat
`( root path -- metadata )` — Follow the path, including a final link within
the root, and describe the object reached with the same shapes as `lstat`. A
dangling link is `` `not-found ``.
