## proc

Subprocess ports with bounded live counts, queues, and capture sizes.
Process creation is available as an ordinary standard-library operation.
Executable access is determined by the operating system.

The public words are ECL compositions over registered process capabilities,
common port transport, and task primitives.

`proc.core.process` is the registered process factory. Applying `port.open`
to it and a spawn specification creates a process resource subject to the
common structured-value and process limits as `proc.spawn`.
The returned resource supports the process words and common lifecycle words;
the factory is an opaque identity for the process resource kind.

The registered operations `proc.core.wait`, `proc.core.terminate`,
`proc.core.kill`, and `proc.core.capture-limits` require an empty request list.
Wait returns the termination dictionary described below. Terminate and kill
request the corresponding process action and return `[]`; they do not wait
for process exit. Capture-limits returns a dictionary with `'stdout` and
`'stderr` capture limits. Wait has its own FIFO lane; the
other operations share an independent control lane. Cancelling a wait leaves
the process running and makes its lane reusable after cancellation settles.
Each exchange result is claimable once, while completion observation is
repeatable. Process exit leaves the resource open for further operations;
closing the resource prevents new admission and joins backend cleanup.

`proc.core.stdin`, `proc.core.stdout`, and `proc.core.stderr` are endpoint
selectors for process resources. `port.endpoint` with stdin grants writing and
finishing; stdout and stderr grant reading. Their byte, EOF, and single-reader
contracts are shared with the corresponding process words. Finishing stdin
delivers accepted bytes before closing that direction, is idempotent, and
rejects subsequent writes, including empty writes. Endpoints share permitted
use without owning the resource; they cannot be transferred with `@give`.

A spawn specification is a dictionary whose keys are symbols, with only the
following fields. The nested environment dictionary uses **string** keys.

| Field | Value | Required / default |
| --- | --- | --- |
| `'executable` | Absolute executable path string; no `PATH` lookup | Required |
| `'args` | List of argument strings, excluding the executable name | `[]` |
| `'cwd` | Absolute directory path string without `.` or `..` components | Startup working directory |
| `'env` | String-to-string dictionary, for example `{"LANG" "C"}` | `{}`; overlay on the captured process environment |

Paths, arguments, and environment strings cannot contain NUL. Environment
names must be nonempty and contain no `=`. An environment overlay replaces
matching names and preserves other base entries; `{}` does not clear the base.
There is no shell-command form, expansion, or `PATH` search: spaces and shell
metacharacters in an argument are passed literally. Unknown fields and missing
`'executable` are `'domain`; non-symbol keys and wrongly typed fields are
`'type`; invalid field values are `'domain`. Validation precedes process creation.

For example, on a POSIX host with `/bin/cat`, capture a byte-exact round trip:

```ecl
{'executable "/bin/cat" 'stdin [104 101 108 108 111 10]} proc.run
# {'term {'kind 'exited 'code 0} 'stdout [104 101 108 108 111 10] 'stderr []}
```

A fuller specification adds arguments, a working directory, and environment:

```ecl
{'executable "/bin/echo"
 'args ["hello world"]
 'cwd "/tmp"
 'env {"LANG" "C"}
 'stdout-limit 4096
 'stderr-limit 4096
 'timeout-ms 1000} proc.run
'stdout at chars
# "hello world\n"
```

These examples require the named executables and directory to exist, and the
host to permit the requested paths and capture bounds. Use `bytes` to encode
text for stdin and `chars` to decode complete UTF-8 output. Arbitrary process
output may not be valid UTF-8.

Prefer `proc.run` when the output fits a known bound. With `proc.spawn`, feed
stdin and drain **both** output pipes concurrently when they can fill. A child
may wait for stdin EOF before exiting, so call `proc.close-input` when feeding
is complete. `proc.wait` does not drain output: waiting first can deadlock on a
full pipe. Reads may split text characters or application messages across
chunks. Close the resource with `port.close` when finished; waiting for exit
does not close it.

Bytes are ordinary integer lists whose elements are all in `0...255`. Process
streams do not decode Unicode. A port is an opaque identity capability that
prints `<port:N>` and has type `'port`; it exposes no PID and cannot be passed
through JSON. Native words can view and forward its opaque identity.

### close-input
`( port -- )` — Close the process's stdin after queued bytes have been written.
Idempotent. A concurrent or later `write` is `'io`.

### kill
`( port -- )` — Force termination of the port's process group and arrange for
direct-child reap. Idempotent and safe after natural exit.

### read-stderr
`( port max -- bytes )` — Read at most positive `max` exact bytes from stderr,
parking when no data is ready. Return `[]` only at stable EOF; later reads also
return `[]`. At most one stderr read may be pending; overlap is `'contract`.

### read-stdout
`( port max -- bytes )` — Read at most positive `max` exact bytes from stdout
with the same readiness, EOF, and single-reader contract as `read-stderr`.

### run
`( spec -- result )` — Spawn through the ordinary port controller, supply all
stdin while draining stdout and stderr concurrently, wait for direct-child
reap, and return
`{'term termination 'stdout stdout-bytes 'stderr stderr-bytes}`. In addition to
the spawn fields, `spec` accepts:

| Field | Value | Default |
| --- | --- | --- |
| `'stdin` | List of integer bytes in `0...255`; strings require explicit `bytes` conversion | `[]` |
| `'stdout-limit` | Nonnegative integer maximum total captured stdout bytes | Host stdout capture maximum |
| `'stderr-limit` | Nonnegative integer maximum total captured stderr bytes | Host stderr capture maximum |
| `'timeout-ms` | Nonnegative integer deadline in milliseconds, including spawn and execution | No process deadline; scheduler cancellation remains effective |

Each capture limit must be no larger than its corresponding host maximum.
Zero permits only empty output on that stream. Stdin is finished after feeding,
including when omitted. The result always contains all three symbol keys:
`'term` is a termination dictionary described by `proc.wait`, and `'stdout`
and `'stderr` are byte lists, empty when nothing was captured. Nonzero exit codes are returned
as data; inspect `'term` to decide whether the command succeeded.

Capture overflow kills and cleans the process before raising `'overflow`.
Deadline expiry does the same before raising `'timeout`; task cancellation is
`'cancelled`. Spawn, pipe, broken-input, and reap failures are `'io`. These
run-only fields are rejected by `spawn`.
The deadline covers the child task that opens and runs the process. Output
collectors enforce their limits independently; a failed collector cancels the
remaining work and joins resource cleanup. Successful input acceptance is
distinct from backend pipe completion, and a later broken pipe still fails
the run.

### spawn
`( spec -- port )` — Start the directly named executable with stdin, stdout,
and stderr pipes. The child and its process group, pipe tasks, and spawning
task-scope membership commit before the port becomes visible. The scope owns
the live child: scope closure cancels the process group and waits for reap even
if a port value remains stored elsewhere. Returning or storing the port does
not detach it; `@give` is the one way to change owner, and the unit it is
given to kills the group when it ends.

### terminate
`( port -- )` — Request ordinary termination of the process group, escalating
to force termination during cleanup when needed. Idempotent and safe after
natural exit.

### wait
`( port -- termination )` — Park until the immutable terminal result is
available. Any number of waiters and later calls receive the same dictionary:

- `{'kind 'exited 'code n}`;
- `{'kind 'signaled 'signal n}`;
- `{'kind 'stopped 'signal n}`; or
- `{'kind 'unknown 'status n}`.

A nonzero exit code is ordinary termination data, not an ECL error.
A pipe failure raises `'io`. Waiting requires an open resource; after closure,
observe a previously completed exchange instead of admitting another wait.

### write
`( port bytes -- )` — Queue exact stdin bytes, parking under bounded pressure.
Calls are serialized in scheduler-arrival order and each call's bytes remain
contiguous. A closed or broken stdin is `'io`.
