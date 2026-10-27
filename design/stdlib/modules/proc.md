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
for process exit. Capture-limits returns a dictionary with `` `stdout `` and
`` `stderr `` capture limits. Wait has its own FIFO lane; the
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
| `` `executable `` | Absolute executable path string; no `PATH` lookup | Required |
| `` `args `` | List of argument strings, excluding the executable name | `[]` |
| `` `cwd `` | Absolute directory path string without `.` or `..` components | Startup working directory |
| `` `env `` | String-to-string dictionary, for example `{"LANG" "C"}` | `{}`; overlay on the captured process environment |

Paths, arguments, and environment strings cannot contain NUL. Environment
names must be nonempty and contain no `=`. An environment overlay replaces
matching names and preserves other base entries; `{}` does not clear the base.
There is no shell-command form, expansion, or `PATH` search: spaces and shell
metacharacters in an argument are passed literally. Unknown fields and missing
`` `executable `` are `` `domain ``; non-symbol keys and wrongly typed fields are
`` `type ``; invalid field values are `` `domain ``. Validation precedes process creation.

For example, on a POSIX host with `/bin/cat`, capture a byte-exact round trip:

```ecl
{executable "/bin/cat" stdin [104 101 108 108 111 10]} proc.run
# {term {kind exited code 0} stdout [104 101 108 108 111 10] stderr []}
```

A fuller specification adds arguments, a working directory, and environment:

```ecl
{executable "/bin/echo"
 `args ["hello world"]
 `cwd "/tmp"
 `env {"LANG" "C"}
 `stdout-limit 4096
 `stderr-limit 4096
 `timeout-ms 1000} proc.run
`stdout at chars
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
prints `<port:N>` and has type `` `port ``; it exposes no PID and cannot be passed
through JSON. Native words can view and forward its opaque identity.

### close-input

### kill

### read-stderr

### read-stdout

### run

### spawn

### terminate

### wait

### write
