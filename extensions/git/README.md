# Git snapshot extension

`zig build git-extension` builds `zig-out/extensions/git/git.eclmod`. The
extension imports only `std` and `ecl-native` and links libgit2 and its native
dependencies. Install or map that artifact as module `git`; it has no dependency
on the package application. `zig build test-git-extension` runs its public port
acceptance against a controlled HTTPS server on Linux and macOS.

The Docker TSan gate uses `zig build test-git-extension -Dgit-tsan=true`.
It compiles the executable and extension with LLVM instrumentation and keeps
one sanitizer runtime in the executable. Native safety failures retain a
bounded diagnostic and abort; the extension never initializes a separate host
I/O runtime to report a programming defect.

`git.snapshot [] port.open` creates a scope-owned resource. Start an exchange
with `resource git.fetch request port.begin`, acquire its readable byte endpoint
with `exchange git.output port.endpoint`, and consume `port.read` until `[]`.
Then `exchange port.result` returns the resolved 40-character lowercase commit
string. Close the exchange and resource through `port.close`. A streaming
exchange requires a concurrent consumer; waiting for its result before consuming
the output can block on backpressure.

The request is a dictionary with required fields:

| Field | Value |
| --- | --- |
| `url` | HTTPS URL, at most 8,192 bytes, without credentials, fragments, controls, or backslashes |
| `selector` | Symbol `tag` or `commit` |
| `revision` | Tag name, or full 40-character lowercase commit ID; at most 1,024 bytes |

Optional `ca-file` selects an explicit trust file; empty uses libgit2's system
trust roots (`/etc/ssl/cert.pem` on macOS). Certificate and hostname verification
remain enabled. `scratch` selects an absolute directory under which the extension
creates a private temporary repository, default `/tmp`. Neither field names an
installation destination. Unknown request fields fail closed.

The following positive integer limits can only lower their defaults:

| Field | Default and maximum |
| --- | --- |
| `transfer-bytes` | 512 MiB received pack data |
| `objects` | 200,000 objects in the received pack |
| `files` | 100,000 exported regular files |
| `export-bytes` | 1 GiB of uncompressed tar data, including headers and padding |
| `memory-bytes` | 3 GiB of tracked libgit2 and exporter allocations |
| `timeout-ms` | 180,000 ms, including time waiting for library admission |

The byte stream is a deterministic gzip-compressed POSIX tar archive: paths in
byte order, regular files only, mode 0644, zero owners and timestamps, and PAX
path records for long names. Executable blobs become ordinary files. Links,
submodules, and `.git` entries are rejected. Empty committed trees and arbitrary
regular files are valid; no manifest or package naming rules apply. A failed
exchange can leave a prefix in its output; discard that prefix. Only successful
completion establishes a complete archive and resolved commit.

Every invocation owns its scratch repository, native objects, export index,
and allocation budget until cleanup has joined. Cancellation interrupts host
byte-stream waits and is checked during library admission, network progress,
tree traversal, and chunked export. Network connect/read waits are finite and
at most ten seconds each, reduced for shorter requested deadlines. Deadline
checks are cooperative: an in-progress library or OS call can finish after
the deadline, and cleanup still runs to completion. There are no process-wide
alarms, resource limits, working-directory changes, or environment mutations.

All calls into libgit2, including initialization, configuration, allocator
selection, and teardown, are serialized by one extension-owned mutex. This
matches libgit2's [library-global configuration and allocator API](https://libgit2.org/docs/reference/v1.9.0/common/git_libgit2_opts.html).
Concurrent resources remain independently cancellable while waiting for that
mutex. The budget covers allocations through libgit2's configured allocator
and the exporter; OS buffers, thread stacks, TLS-library allocations that bypass
that allocator, and unrelated native code are outside it. Neither cancellation
nor memory accounting provides process isolation or a hard termination deadline.
