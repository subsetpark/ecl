# ECL environment

This document describes the environment shipped around the ECL language:
embedded modules, module discovery, native extensions, host-backed library
contracts, projects and packages, the `ecl` command, and source formatting.

[`SPEC.md`](SPEC.md) defines the language. [`STDLIB.md`](STDLIB.md) lists every
shipped word and its stack effect. This document covers behavior that depends
on files, processes, networks, package data, or distribution policy.

ECL is distributed as a CLI interpreter with a supported Zig extension SDK.
ECL can call Zig extensions through `ecl-native`; embedding ECL in a Zig
application is not a supported interface.

## Modules and host integration

### Embedded standard library

Every module listed in `STDLIB.md` ships inside the `ecl` binary. Embedded
modules load lazily at the first qualified reference or import. Loading needs
no filesystem access and works with no `ECL_PATH`.

Embedded modules use ECL source, linked native descriptors, builtin word
tables, or registered built-in capabilities. The transport is an implementation
property. Each publishes
ordinary module images and participates in registration, aliases, imports,
reflection, and shadowing through the same language operations.

`net.core.listener` and `proc.core.process` export the built-in factories used
by `port.open`. They are ordinary standard-library words; opening a resource uses the
Session's runtime I/O state.
The public `net` and `proc` modules are ECL compositions over these registered
capabilities and `port.*`. Their operation and endpoint selectors expose only
their corresponding resources and streams. First-party adapters use typed backend calls;
the extension adapter translates ABI v7 calls into the same runtime interfaces
for controller execution, transport, cancellation, ownership, and cleanup.

Embedded names have precedence over filesystem modules. A file on `ECL_PATH`
cannot replace an embedded module during automatic loading. A program may
replace a registration explicitly with `register` or `@defm`.

### Filesystem module search

`ECL_PATH` is an ordered platform path list. For each root, automatic loading
tries `<module-name>.ecl` and then `<module-name>.eclmod`. The first existing
candidate is authoritative, including any error raised while loading it.

Filesystem search applies only when the current Session has no module map.
With a map, resolution uses only its visible artifacts and embedded modules.

An ECL source candidate may register several modules. Successful loading
requires the requested registration to exist after the source unit completes.
All registrations from a failing source unit remain unavailable.

### Module maps

An `ecl.modules` document supplies inert module-resolution metadata. It contains
no package versions, fetching instructions, or cache policy. The nearest such
file is discovered by searching upward from the startup directory. `ecl --module-map FILE ...` selects a map explicitly;
its path is relative to the caller's working directory. A malformed discovered
or explicitly selected map fails Session construction, without falling back.

```ecl
{'format 1 'local "project" 'scopes {
 "project" {'root "." 'visible ["library"]
            'sources ["src/**/*.ecl"] 'artifacts []}
 "library" {'root "installed/library" 'visible [] 'sources []
            'artifacts [{'path "library.ecl" 'kind 'ecl
                         'exports ["library"]}]}}}
```

Every scope has exactly `root`, `visible`, `sources`, and `artifacts` fields.
Scope names are nonempty strings. Visibility includes the scope itself and
only the explicitly listed direct edges; it is checked even for loaded
modules. Missing, duplicate, or self visibility edges are invalid. Exported
module names and artifact paths must be unique across the map. Artifacts in
different scopes may reuse relative filenames when their roots differ.
Artifact paths are relative, without empty, dot, parent, glob, or drive
components. Scope roots resolve relative to the document containing them.

Source patterns use `/` separators, `*` and `?` within segments, and `**` as a
whole segment. Selected regular `.ecl` files are parsed without execution at
Session startup. Literal top-level module declarations become exports;
computed and nested registrations remain file-private. Explicit artifacts
name their exports directly and are read only on first use. Kinds are `ecl`
and `native`; a native artifact exports exactly one module and executes
trusted native code through the ordinary extension boundary. Test discovery
enumerates ECL artifacts from the designated `local` scope.

A reference document has exactly this shape:

```ecl
{'format 1 'map ".ecl/generations/current/ecl.modules"}
```

The referenced document must be a complete map, never another reference.
Its paths resolve relative to that document. Each Session captures its map
once; later file additions appear in new Sessions without synchronization.
Source execution remains lazy, once per artifact, with atomic registration.
Startup performs no fetching or repair. Maps are bounded to 16 MiB, 4,096
scopes and artifacts, 65,536 exports, 16 MiB per discovered source, and 64 MiB
of discovered source text. Names and paths are at most 4,096 UTF-8 bytes and
contain no control characters.

`ecl check-map FILE` validates a document using the same parser, limits,
reference resolution, and inert source discovery as Session startup. It exits
zero with no output on success, one with a diagnostic for an invalid map or
usage, and two on allocation failure. The filename resolves against the
caller's working directory; paths inside the document resolve against that
document. Validation does not construct a Session, inspect the caller's map,
execute source or native artifacts, or write files. An explicit
`--module-map` does not affect this command. This operation validates resolution
metadata; artifact content verification remains the publisher's responsibility.

`ecl check-map --document FILE -` reads at most 16 MiB from standard input and
uses `FILE` as the containing document's path. Neither that file nor its parent
directory needs to exist. Relative roots and a single map reference use the
same rules as a file-backed map. This supports validation before publishing a
staged document; validation never creates or replaces the named file. An input
read or size failure exits one with a diagnostic. Plain `check-map -` is invalid
because stdin alone does not identify a relative-path base.

### Native modules

A `<name>.eclmod` file is a target-specific shared library containing one
module. Its descriptor declares the same canonical name requested by the
loader. The complete word table validates before publication, and publication
is atomic.

The current pre-release native ABI is version 7, with entry symbol
`ecl_module_abi_v7`. Native modules built for earlier versions must be rebuilt;
the loader provides no legacy adapter.

Each native word has a declared effect and nonempty documentation. Native
words support qualified calls, imports, `doc`, `which`, and `see`. A failing
native call restores its operand stack. Native code may raise `'type`,
`'shape`, `'conform`, `'overflow`, `'domain`, `'parse`, `'io`, `'user`, or `'contract`;
other error kinds remain reserved to the runtime.

A loaded native module remains loaded for the session. Repeated resolution
uses its existing registration.

Native modules may declare typed port kinds with persistent private state.
The SDK's `Port` spec declares named endpoints and operations. Each operation
carries its handler, documentation, lane, and enabled exchange endpoints.
Adding a kind to `module.ports` exports its declared selector bindings; factories
are exported explicitly with `ecl.factory`. A declaration's optional `name`
overrides its public spelling. Bindings are ordinary opaque ECL values with
module-instance identity. Their complete registration validates before the
module is visible.
Resource operations belong to host-owned exchanges. Ordinary native callbacks
can forward their opaque identities; controller execution and cleanup continue
independently of callback return. Suspension of an ordinary word uses its
separate `Reschedule` capability.
`port.open` and `port.begin` accept structured configuration and parameters;
controllers read them through bounded `Controller.input` paths. Each request
allows at most 64 KiB of scalar/text data, 4,096 aggregate nodes, and 16 port
attachments. Executable words, tasks, and modules are rejected recursively.
Registered endpoints are selected by opaque ECL capabilities. Controllers acquire
borrowed capabilities with `controller.endpoint(Port, .name)`. Their types expose
only the declared byte or message direction. Selectors declare resource or
exchange ownership; resource endpoints remain available across operations,
and shutdown joins all users before releasing their transport.
Each enabled byte endpoint has a bounded ring using the host's configured byte
capacity. Reads return positive chunk lengths, or `null` at stable EOF. Writes
accept a complete slice with one FIFO admission; an error may leave an accepted
prefix, so automatic retries are unsafe. Cancellation and closure interrupt
blocked transport. Output and diagnostics require concurrent consumption when
both may fill. Finishing one output is distinct from controller completion.
Message endpoints default to 16 queued messages each and a shared 1 MiB budget
per resource; hosts may reduce either limit for pressure testing. Messages held
by a controller retain their budget reservation until forwarding or release.
A receiver's `receive` returns a borrowed message view or `null` at stable EOF.
The controller owns that message until consuming it through a sender's
`forward`, `resultMessage`, or `discardMessage`. Bounded `received` paths inspect
nested data. A second receive while a message is held is rejected. Failed
consuming calls retain ownership; controller return cleans up an unconsumed
message. `discardMessage` releases its budget reservation and reports
`InvalidValue` if no message is held. Builder copies remain valid, while borrowed
received-message views expire on consumption or the next view lookup.
The controller-local `MessageBuilder` constructs scalars, nested lists and
dictionaries, and copies permitted input capabilities without exposing ECL
storage. Builder methods settle construction and validation in bounded host
steps before returning; authors use ordinary `try` expressions.
A sender's `send` and the builder's `result` consume the completed message on
success. Failure retains it for cleanup or an explicit library decision.
Construction errors invalidate the partial message, and `clear` explicitly
starts another. Controller return discards unfinished work.
`child(Port, dependency)` replaces the builder's top configuration with a newly
initialized resource of a kind registered by the same module instance. Earlier
builder values remain available for aggregate construction. The host retains
provisional ownership until ECL receives or claims the containing value; failed
creation retains the configuration and cleans up partial startup. The dependency
argument is explicit: dependent children retire before the parent backend,
while independent children can survive it. Cancellation interrupts blocked child
startup. No child handle grants native code ECL storage or interpreter access.
`Controller.parent(Port)` borrows the issuing parent's native state only for a
dependent child of that registered kind in the same module instance. Roots,
independent children, and wrong kinds return null. The borrow remains valid
through child cleanup, including parent closure and scope transfers. Native
libraries synchronize shared state across controllers; this access grants no
ECL heap, allocator, or interpreter authority.
A message receiver's `reply` appends an opaque sender to the current builder.
A controller can send it with a request and receive ECL's response through that
input. The sender follows the input's resource or exchange lifetime; retaining
it does not extend scope ownership. Output endpoints and inputs excluded by the
operation cannot grant reply authority. Native controllers never synchronously
invoke ECL; notification, correlation, and reply ordering are library protocols.
Controllers report allocation exhaustion with `failOutOfMemory`; observation
through results, endpoints, opening, or shutdown preserves the runtime OOM
outcome and still performs normal cleanup.
Their words can forward opaque ports through aggregates, stream operations,
and explicitly close them. Operations execute in FIFO order within a declared
lane. A port defaults to one lane; multiple lanes and different ports can
progress independently. An ordinary operation error leaves the port usable.
`Controller.failResource` reports a terminal error that also makes the resource
unusable after the controller returns. Accepted output on that exchange remains
readable before its error; other operations and dependent children are
interrupted. `port.close` joins the resulting cleanup. Native backend workers
must be joined before their controller returns, including when it reports a
resource failure.
Cancelling queued work removes only that operation. Active cancellation closes
the resource by default. A kind may instead support recovery: its interrupted
controller must acknowledge reusable state and finish before the lane executes
more work. Missing acknowledgement closes the resource and cancels all lanes. Explicit close is
idempotent and waits for cleanup. Scope closure also waits for cleanup, and
`@give` transfers ownership atomically without interrupting active work.

Kinds belong to a loaded module instance, not to a textual name. A mismatched
kind raises `'type`; operations on closed ports raise `'io`. Retained closed
ports remain opaque identities. Tasks and modules are unsupported native inputs.

The default Session limits are 64 live native ports, 16 admitted operations per
port (including the active one), and 64 KiB for each request and response ring.
The runtime validates native port limits at construction:
live capacity is 1–4096, operation capacity is 1–256,
and ring capacity is 1 byte–16 MiB. Invalid limits reject Session initialization.
Creation beyond live capacity raises `'domain`; operations wait for admission
when their lane is full. The operation budget is partitioned across lanes,
reserving at least one slot for each; creation fails with `'domain` when the
budget cannot cover the declared lanes. Idle capacity is not borrowed across
lanes. Forced close interrupts all lanes and waits for terminal cleanup.
A kind may register an optional `shutdown` callback. `port.shutdown` invokes it
once on an independent control lane and waits for all callbacks and cleanup.
It may overlap operation callbacks; `cancel` must interrupt its backend waits.
Failure remains observable on repeated shutdown calls. Unsupported shutdown
raises `'domain`, and abortive `port.close` remains available. Cancellation
never promises to reverse external effects or accepted stream bytes.
These resource limits do not sandbox native code.

Opening a shared library executes machine code before ECL validates its
descriptor. Every directory used for native loading is a trusted-code
boundary.

## Filesystem access

Filesystem work goes through the `fs` module and the `path` module documented
in `STDLIB.md`. `path` is pure string manipulation over `/`-separated Unicode
paths and applies no host convention. Every `fs` word names one root by symbol
and one canonical relative path beneath it. All filesystem operations are
available on every named root, subject to operating-system permissions and
runtime limits. Modules within one Session share its roots.

The `ecl` command uses one root, `'cwd`, for the working directory captured
once at startup. Package commands add the `'project` root described below.
Session construction opens the roots once; a relative, missing, non-directory,
duplicate, or malformed root, a zero limit, or an unsupported target is a
construction error distinct from allocation failure.

Supported targets are Linux and macOS. Paths are UTF-8 slash paths; a host
filename that is not valid UTF-8 cannot be listed and fails the whole listing.
Backslash is an ordinary filename character. Symlinks are followed only while
their target remains beneath the root: an absolute target, a relative target
that would rise above the root, a loop, and an expansion limit are refused, and
containment is enforced at the root's retained directory handle rather than by
inspecting path text. The root handle remains the authority if the directory
is renamed after Session construction.

Created and replaced files are new inodes with the host's ordinary creation
mode under the process umask. Ownership, permissions, timestamps, extended
attributes, and sparse layout are not preserved by `replace-*` or `copy`.
Publication is atomic with respect to the namespace and to failure; no
`fsync`, crash durability, or persistence across power loss is promised.
Concurrent external mutation may decide which ordinary result wins but can
never redirect an operation outside the retained handles. Recursive copy or
removal, recursive directory creation, globbing, watching, memory mapping,
locking, link creation, permission changes, timestamps, and Windows support are
outside this contract.

## Network listeners

Inbound TCP listening goes through the `net` module documented in
`STDLIB.md`. A program requests a local address and port; port `0` requests
an ephemeral port. Addresses are IPv4 or IPv6 literals normalized before
binding, so `::ffff:127.0.0.1` uses IPv4. No name is resolved and no interface
scope id is accepted. Any local address and port may be requested, subject to
operating-system restrictions.

The runtime bounds live listeners, the kernel accept backlog, live connections
(default 64), and each connection's receive and send queues (default 64 KiB
each). Zero limits and unsupported targets fail Session construction distinctly
from allocation failure.

Supported targets are Linux and macOS. A listener is an opaque port owned by
the task scope that created it; the socket closes when that scope closes or
when `net.close` runs, whichever comes first, and the same address and port
can then be bound again, as can a port that a closed connection left in
`TIME_WAIT`; two live listeners still never share one address and port.

Accepting connections, reading, and writing are inside the contract.
`net.accept` parks until a peer connects and returns a connection port owned
by the accepting unit's task scope; a connection is taken from the kernel
backlog only while an accept is outstanding and a live-connection slot is
free. `net.read` and `net.write` exchange exact byte lists through bounded
queues of the host capacities, parking on readiness without holding a worker;
`net.peer-address` and `net.local-address` report both ends. `net.close` on a
connection delivers queued bytes and then shuts the socket down, while scope
closure aborts it. Registered TCP factories and operations use the common
resource controller service, with 16 admitted operations per resource. Accepts
occupy one FIFO lane; address operations have an independent lane. An accepted
connection remains provisionally owned by its exchange until result publication
and is independent of the listener after acceptance.

The live-connection maximum bounds descriptors and backend controllers per
Session: at the maximum `net.accept` waits, leaving
the peer in the kernel backlog, and proceeds when a connection closes; a
waiting accept holds no slot. The listener maximum is refused as `'domain`.
Controller failures use the common port error contract. Zero for any limit is a Session construction
error. TLS and protocol framing remain outside this contract; they belong to
the protocol modules built over a connection.

## Clocks

The `clock` and `time` modules documented in `STDLIB.md` split effectful time
from pure conversion. `time` is pure and available everywhere. `clock` reads
the scheduler's monotonic clock and the process realtime clock.

Monotonic time belongs to the scheduler and always exists. Ordinary execution
uses the process's awake clock. Internal tests can select a
manual clock that starts at zero and moves only when the test advances it
through the Session by whole milliseconds. An advance that would carry the
reading past the int range is refused and leaves the reading unchanged, so
the manual clock never wraps or runs backwards. Every deadline —
`clock.sleep`, `task.await-for`, and any future timed wait — captures its absolute
instant on that one clock before registering any timer state; an instant the
clock could never report is refused with `'overflow` instead of being
registered, and the timer thread reconsiders its heap on every advance. Under a manual clock no wait, wake, or `clock.now` sample
touches host time, so a test can drive sleeping programs to exact
instants; a sleeping unit is never woken early, and one is never woken at all
unless the clock reaches its deadline or it is cancelled. Evaluated code
cannot advance a clock or discover which source it runs on beyond observing
the readings.

Wall-clock time always exists. `clock.unix` reads the process realtime clock.
Internal tests may fix it at one Unix millisecond value or anchor a base value
to the monotonic clock. These are deterministic inputs, independent of TLS
verification time or permissions; they have no CLI options.

Time zones, locale-sensitive formatting, leap-second tables, timers that run
callbacks, and periodic scheduling are outside this contract. Process
deadlines (`'timeout-ms`) use the same scheduler clock through `task.await-for`.

## Host-backed data contracts

### Byte lists and archives

Binary data crosses the standard-library boundary as an ordinary list of
integers in `0..255`. Strings represent Unicode text and are not byte
containers. A packed byte representation may be used internally, while ECL
operations continue to observe ordinary integer list elements.

`archive.sha256` returns the SHA-256 digest of a byte list as 64 lowercase
hexadecimal characters.

`archive.unpack-tgz` validates a gzip-compressed tar byte list and extracts it
beneath a previously absent destination, a canonical relative path under a
named `fs` root. It accepts ustar regular files and
directories, per-entry PAX `path` and `size` records, and GNU long-name
records. Other PAX fields may not alter a member's path, size, or kind. The
result contains normalized regular-file paths in archive order and omits
directory entries.

Every member name must be valid UTF-8, relative, and nonempty after
normalization. A name may contain no empty, `.`, or `..` component. Absolute
paths, platform-rooted paths, duplicate normalized paths, links, devices,
FIFOs, unsupported member kinds, malformed gzip/tar/PAX data, checksum
failures, and size disagreement raise `'domain`.

The uncompressed tar stream is limited to 1,073,741,824 bytes and 100,000
regular-file or directory members. Exceeding either limit raises `'domain`.

Extraction resolves the destination's parent beneath the root through the
confined `fs` resolver, then uses a unique `.ecl-fs-*` sibling staging
directory relative to that parent handle. Files are created exclusively.
Failure and cancellation remove the staging tree through bounded reverse-order
work. A same-parent no-clobber rename publishes the completed tree after
validation and handle closure. The destination is never overwritten or merged.
Concurrent extractors may stage independently; one may publish, and the others
receive an `'io` destination-exists error.

A non-list byte container, non-symbol root, or non-string destination raises
`'type`. A byte outside `0..255` raises `'domain` with its zero-based
`'index`. An unknown root or non-canonical destination raises `'domain` with the `fs` failure data. Host or
filesystem failures raise `'io` with the relevant `'path`. Failure exposes no
partial destination and opens no member outside the staging root.

### Tables

A table is an ordinary insertion-ordered dictionary. It has at least one
entry, every key is a distinct nonempty string, and every value is a list of
the same length. Zero-row tables are valid. `type` reports `'dict`, and core
dictionary operations may produce a value that no longer satisfies the table
convention. Each `table.*` operation validates its table inputs.

Table validation uses these error kinds:

- `'type` for non-dictionaries, non-string names, non-list columns, and
  ill-typed masks or specifications;
- `'shape` for zero-column schemas, unequal column lengths, and row-width
  mismatches;
- `'domain` for missing, empty, or duplicate names, schema disagreement,
  join or rename collisions, and incomplete join fills;
- `'contract` when an aggregation quotation violates its declared shape.

Joins are stable equijoins over `[left-name right-name]` pairs. Duplicate keys
expand to the full many-to-many product in left-row order and then right-row
order. A result contains the left columns in their original order followed by
right non-key columns in right-column order. `table.left-join-with` emits one
row for an unmatched left row and requires a fill value for every appended
right column.

### HTTP

The HTTP module is a client with content decoding. Responses have the shape
`{'status int, 'headers dict, 'body value}`. `http.get`, `http.post`, and
`http.send` return the body as a string. `http.get-bytes` returns decoded
response octets as a byte list. Transfer framing and compressed wire bytes are
not exposed.

Each client word consumes one partial or complete `http.request` dictionary
with a required `'target` URL. `http.get` and `http.get-bytes` supply GET and
follow redirects for bodyless requests; `http.post` supplies POST, an empty
body, and no redirect following. `http.send` requires the request's own
`'method` and does not follow redirects. Request fields override method,
headers, and exact body bytes without changing the Session's network
authority. POST, PUT, and PATCH admit bodies; a nonempty body with another
method is `'domain`.

Connection refusal, TLS failure, invalid URLs, and protocol errors raise
`'io` with the URL in `'path`. Every HTTP status is returned as response data.

Internal tests may supply a TLS trust override containing an absolute CA-file
path and a fixed verification timestamp. That configuration uses only the
named CA file and timestamp. The default configuration uses system trust
roots and the current time. ECL code and process environment variables cannot
change the override.

Requests yield during network I/O, so unrelated tasks, timers, and servers in
the same Session progress even with one worker. A Session admits at most 16 live
requests by default and retains admission through response construction and
cleanup. Each request has one total 30-second monotonic deadline, including
redirects and construction; expiry raises `'timeout`. Finite transfer and backend
scratch limits raise `'overflow` with the target URL. These internal Session
limits are detailed in the standard-library HTTP contract. Task cancellation
interrupts in-flight I/O, and Session teardown joins it before releasing TLS
configuration.

## Projects and packages

The maintained application in `apps/pkg/` implements `ecl pkg` through the
installed-application dispatch described below. It owns `ecl.pkg`, the portable
version-controlled `ecl.lock`, source acquisition, dependency selection, cache
policy, immutable generations, verification, and publication recovery.
See its [application contract](../apps/pkg/README.md) and
[manifest format](../apps/pkg/FORMATS.md).

The interpreter reads only `ecl.modules`. A hand-written map supports imports
and tests without a package application. A fresh checkout with a manifest and
lock reproduces the exact locked graph through `ecl pkg sync`; updates require
`ecl pkg update`. Each published generation retains its own resolution snapshot,
so separate atomic updates of the root lock and active map never mix dependency
state inside an existing runnable generation.

## Installed applications

An installation may provide applications beneath `share/ecl/apps/<name>/`,
relative to the prefix containing `bin/ecl`. A name starts with an ASCII letter
and contains only ASCII letters, digits, and hyphens, up to 64 bytes. Built-in
CLI commands take precedence. Otherwise `ecl <name> ...` consults only that
installation directory, never the project or `PATH`.

Each application's `application.json` has exactly these fields:

```json
{"format": 1, "entry": "main.ecl", "module_map": "ecl.modules"}
```

Both paths are nonempty UTF-8 paths beneath the application's directory,
without empty, dot, parent, drive, or backslash components. Descriptors are
limited to 16 KiB and entry source to 16 MiB. Unknown fields and unsupported
formats are errors. A descriptor is data and executes no code.

The entry script runs in an ordinary Session using the application's map.
The caller's working directory, trailing arguments, environment, and standard
streams are preserved, including standard input as data. The caller's project
map, including an explicitly selected map, does not replace the application
map. A malformed project therefore cannot prevent application startup. The
application and its artifacts must be installed directly; startup does not
fetch, synchronize, or bootstrap them through a package manager.

## The `ecl` command

```text
ecl                              start a REPL on a terminal; otherwise read stdin
ecl -e <SOURCE> [ARGS…]          evaluate source and print the final stack
ecl <FILE> [ARGS…]               run a UTF-8 script
ecl <SOURCE> [ARGS…]             evaluate source and print the final stack
ecl - [ARGS…]                    read stdin as one unit
ecl fmt <FILE|->                 format source to stdout
ecl fmt -w <FILE>                format and atomically rewrite a file
ecl pkg <SUBCOMMAND>             manage the current project
ecl test [OPTIONS] [-- ARGS…]    run the root project's tests
ecl -h | --help                  print usage
ecl -V | --version               print the version
```

For an ambiguous first argument, an existing readable path is a script and
any other value is source text. A missing argument ending in `.ecl` is
reported as a missing script. Trailing arguments are available through
`args`.

Evaluation requested with `-e`, source text, or standard input prints the
final stack. Script-file mode leaves the final stack unprinted. Errors are
printed to standard error.

Process status is `0` on success, the status supplied to `exit`, `1` for a
failed unit or command usage error, and `2` for out-of-memory.

Every Session the command starts receives the working directory, resolved
once at startup, as the `'cwd` filesystem root and the default child-process
working directory. Filesystem, process, and network words are available
without separate grants.

The command reads these environment variables at startup:

- `ECL_PATH` supplies the unmanaged module search path;
- `ECL_WORKERS` supplies a positive base-10 worker count and defaults to the
  CPU count;
- `ECL_NATIVE_DIAGNOSTICS` enables native-loading diagnostics when present;
- `HOME` selects the REPL history path `.ecl_history`.

### Standard input

`io.stdin` is available in `-e` and script-file modes. It reads the complete
input stream once. There is no ambient file access: file words live in `fs`
and act beneath the selected named root or directory resource. Standard input carries program source in `ecl -` and in
non-terminal invocation with no arguments, so `io.stdin` raises `'io` in those
modes. A second read also raises `'io`.

### REPL

The REPL reads one unit per logical line and continues while a delimiter or
string remains open. Ctrl-C discards the pending unit. Ctrl-D exits at an empty
prompt and reports an incomplete pending unit as a parse error.

Completion includes visible words. History is stored in
`$HOME/.ecl_history`, keeps the last 100 single-line valid-UTF-8 entries, and
merges concurrent sessions. History failures produce a warning while the
editor remains usable.

### Test command

`ecl test` requires a module map with a designated local scope. It loads every
ECL artifact in that scope, including files with no exported modules, discovers their declared tests, and invokes the selected runner in a
Test Session. Each source artifact is loaded once, including when an earlier
source already loaded it through an exported module. Private modules keep
their defining-file visibility. Dependency sources are loaded only as needed.
The default runner is `test.default.run`.

`--runner <qualified-word>` selects another public runner. Arguments after
`--` are exposed to that runner through `args`. Test bodies remain private to
the test catalog; runners receive descriptors and invoke tests through
`@test`.

## Source formatting

`ecl fmt` parses valid UTF-8 source without evaluating it and writes canonical
source. Formatting is idempotent and preserves program structure. Ordinary
literal spellings are byte-preserved. Definition docstrings may be refilled
without changing the documentation value.

`ecl fmt -w` formats the complete input before modifying the source, preserves
file permissions, and publishes through a same-directory atomic replacement.
It accepts only regular files and refuses standard input and symlinks.

The canonical layout follows these rules:

- Space-separated forms pack into local groups up to 100 columns. Continuation
  lines begin immediately inside their opening delimiter. A standalone
  closing delimiter aligns with its opener.
- An inline literal module registration's seed and body share the body's
  opening line when that physical line fits. Later body lines do not force
  their separator to break; an authored newline remains a hard boundary.
- Existing newlines remain hard boundaries. Comments break their local groups;
  multiline children retain their internal breaks without forcing a following
  sibling onto a separate line. An indivisible token or preserved comment may
  exceed 100 columns.
- Comments remain attached to neighboring forms and preserve physical line
  boundaries.
- Strings are indivisible. A structurally recognized definition annotation
  may refill its docstring paragraph.
- Literal module registrations receive `### module <name>` navigation
  headers.
- Literal declarations receive a header containing their exact defining word:
  `### def <name>`, `### defp <name>`, `### set <name>`, or
  `### setp <name>`. Test declarations receive `### test <name>` headers.
- Navigation headers are derived from structural terminators. Existing header
  text is normalized. Dictionary-contained forms are excluded from header
  recognition.

### Git dependency acquisition

Git snapshot acquisition is provided by the independently loaded
[Git extension](../extensions/git/README.md), built against the public native
SDK. It accepts HTTPS source requests and streams deterministic archives. It
has no package or installation policy; the package application validates the
result using public archive and source-inspection facilities.
