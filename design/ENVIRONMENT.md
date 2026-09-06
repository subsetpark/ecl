# ECL environment

This document describes the environment shipped around the ECL language:
embedded modules, module discovery, native extensions, host-backed library
contracts, projects and packages, the `ecl` command, and source formatting.

[`SPEC.md`](SPEC.md) defines the language. [`STDLIB.md`](STDLIB.md) lists every
shipped word and its stack effect. This document covers behavior that depends
on files, processes, networks, package data, or distribution policy.

## Modules and host integration

### Embedded standard library

Every module listed in `STDLIB.md` ships inside the `ecl` binary. Embedded
modules load lazily at the first qualified reference or import. Loading needs
no filesystem access and works with no `ECL_PATH`.

Embedded modules use ECL source, linked native descriptors, or builtin word
tables. The transport is an implementation property. All three publish
ordinary module images and participate in registration, aliases, imports,
reflection, and shadowing through the same language operations.

Embedded names have precedence over filesystem modules. A file on `ECL_PATH`
cannot replace an embedded module during automatic loading. A program may
replace a registration explicitly with `register` or `@defm`.

### Filesystem module search

`ECL_PATH` is an ordered platform path list. For each root, automatic loading
tries `<module-name>.ecl` and then `<module-name>.eclmod`. The first existing
candidate is authoritative, including any error raised while loading it.

Filesystem search applies only when the current session has no discovered
project. A project uses its lock-derived catalog as described under
[Runtime module resolution](#runtime-module-resolution).

An ECL source candidate may register several modules. Successful loading
requires the requested registration to exist after the source unit completes.
All registrations from a failing source unit remain unavailable.

### Native modules

A `<name>.eclmod` file is a target-specific shared library containing one
module. Its descriptor declares the same canonical name requested by the
loader. The complete word table validates before publication, and publication
is atomic.

The current pre-release native ABI is version 2, with entry symbol
`ecl_module_abi_v2`. Native modules built for earlier versions must be rebuilt;
the loader provides no legacy adapter.

Each native word has a declared effect and nonempty documentation. Native
words support qualified calls, imports, `doc`, `which`, and `see`. A failing
native call restores its operand stack. Native code may raise `'type`,
`'shape`, `'conform`, `'overflow`, `'domain`, `'parse`, `'io`, or `'user`;
other error kinds remain reserved to the runtime.

A loaded native module remains loaded for the session. Repeated resolution
uses its existing registration.

Opening a shared library executes machine code before ECL validates its
descriptor. Every directory used for native loading is a trusted-code
boundary.

## Filesystem access

Caller-selected filesystem work goes through the `fs` module and the `path`
module documented in `STDLIB.md`. `path` is pure string manipulation over
`/`-separated Unicode paths and applies no host convention. `fs` is a
capability: the Session host names root directories once, each with an
explicit permission set and shared limits, and every word names one root by
symbol and one canonical relative path beneath it. Roots are authority names,
not paths or transferable values; the boundary is Host versus evaluated ECL,
and modules within one Session are not isolated from each other.

The `ecl` command grants exactly one root, `'cwd`, for the working directory
captured once at startup, with every permission. Package commands add the
`'project` root described below. Embedded Sessions are default-deny: without a
`FilesystemPolicy` every `fs` word raises `'domain` with reason `'unavailable`,
and an unsatisfiable policy (a relative, missing, or non-directory root, a
duplicate or malformed name, a zero limit, or an unsupported target) is a
Session construction error distinct from allocation failure.

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
`STDLIB.md`. It is a capability: the Session host names, once, either an
unrestricted grant or an exact allowlist of address and port pairs, together
with a maximum number of live listeners, the kernel accept backlog, a maximum
number of live connections (default 64), and the receive and send queue
capacities of each connection (default 64 KiB each). A
program requests one address and one port; a grant entry whose port is `0`
admits only requests for an ephemeral port. Addresses are IPv4 or IPv6
literals compared after normalization, so `::ffff:127.0.0.1` matches a grant
for `127.0.0.1`; no name is resolved and no interface scope id is accepted.
Listen authority is separate from outbound HTTP, filesystem, and process
authority, and none of those implies it.

The `ecl` command grants an unrestricted listen policy: any local address, any
port. Embedded Sessions are default-deny: without a `NetPolicy` every `net`
word that needs authority raises `'domain` with reason `'unavailable`, a
request outside the grant raises `'domain` with reason `'denied`, and an
unsatisfiable policy (a literal that does not parse, a duplicate entry, a zero
limit, or an unsupported target) is a Session construction error distinct from
allocation failure.

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
closure aborts it. The live-connection maximum bounds descriptors and
controller threads per Session: at the maximum `net.accept` waits, leaving
the peer in the kernel backlog, and proceeds when a connection closes; a
waiting accept holds no slot. Only the listener maximum is refused, as
`'domain` with reason `'limit`. Zero for any limit is a Session construction
error. TLS and protocol framing remain outside this contract; they belong to
the protocol modules built over a connection.

## Clocks

The `clock` and `time` modules documented in `STDLIB.md` split effectful time
from pure conversion. `time` is pure and available everywhere. `clock` reads
two distinct authorities that a Session's host configures separately.

Monotonic time belongs to the scheduler and always exists. The host selects
its source once, at Session construction: the process's awake clock, or a
manual clock that starts at zero and moves only when the embedder advances it
through the Session by whole milliseconds. An advance that would carry the
reading past the int range is refused and leaves the reading unchanged, so
the manual clock never wraps or runs backwards. Every deadline —
`clock.sleep`, `await-for`, and any future timed wait — captures its absolute
instant on that one clock before registering any timer state; an instant the
clock could never report is refused with `'overflow` instead of being
registered, and the timer thread reconsiders its heap on every advance. Under a manual clock no wait, wake, or `clock.now` sample
touches host time, so an embedding can drive sleeping programs to exact
instants; a sleeping unit is never woken early, and one is never woken at all
unless the clock reaches its deadline or it is cancelled. Evaluated code
cannot advance a clock or discover which source it runs on beyond observing
the readings.

Wall-clock time is a grant, absent by default like process and filesystem
authority. A host may withhold it (`clock.unix` raises `'domain` with reason
`'unavailable`), fix it at one Unix millisecond value, anchor a base value to
the monotonic clock so a manual clock yields a deterministic advancing wall
time, or pass the process realtime clock through. The `ecl` command grants the
process clock. Host I/O, a TLS verification timestamp, and every other
capability confer no wall clock; nothing in the environment or ECL source can
widen the grant.

Time zones, locale-sensitive formatting, leap-second tables, timers that run
callbacks, and periodic scheduling are outside this contract. Process
deadlines (`'timeout-ms`) continue to run on a per-process host timer.

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
named `fs` root that grants `create`. It accepts ustar regular files and
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
`'index`. A missing filesystem policy, unknown root, denied `create` grant, or
non-canonical destination raises `'domain` with the `fs` failure data. Host or
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

An embedder may supply a TLS trust override containing an absolute CA-file
path and a fixed verification timestamp. That configuration uses only the
named CA file and timestamp. The default configuration uses system trust
roots and the current time. ECL code and process environment variables cannot
change the override.

Each request occupies the calling unit's worker thread until completion. The
worker count therefore bounds concurrent requests. Requests have no ECL-level
deadline.

## Projects and packages

A project declares dependencies in `ecl.pkg` and records a resolved selection
in `ecl.lock`. Both files contain one ECL data form. Readers parse and validate
them without evaluation.

Module references continue to use module and binding names. Package paths,
URLs, and versions stay in project data and the derived catalog.

### Project discovery

The `ecl` command discovers a project by walking upward from the process
working directory. The first directory containing `ecl.pkg` is the project
root. Discovery stops at the filesystem root. `ecl.lock` is read only from
the project root.

An embedded session opts into discovery by supplying `Host.project_start`.
The default embedded session has no project start path and reads no ambient
project files.

Discovery runs once per session. The resulting project, lock, and catalog
state remains fixed for the lifetime of the session and all its units. A
missing manifest, missing lock, or unavailable host filesystem produces an
absent project tier. An unreadable or invalid sibling lock is retained as a
session error and is reported by the first non-embedded module lookup.

### Versions

A package version is a string with this grammar:

```text
version     := core ("-" prerelease)?
core        := num "." num "." num
num         := "0" | [1-9] [0-9]*
prerelease  := ident ("." ident)*
ident       := [0-9A-Za-z-]+
```

A numeric prerelease identifier has no leading zero. Build metadata is outside
the grammar, so any `+` makes the version malformed.

Precedence follows Semantic Versioning 2.0.0 section 11:

1. Compare major, minor, and patch numerically.
2. A prerelease precedes the same core version without a prerelease.
3. Compare prerelease identifiers from left to right. Numeric identifiers
   precede alphanumeric identifiers; numeric identifiers compare numerically;
   alphanumeric identifiers compare by ECL string order.
4. When every shared identifier is equal, the shorter prerelease precedes the
   longer one.

The admitted grammar has a strict total order. Minimal version selection
chooses among minimum versions declared by reachable manifests.

### Manifest

`ecl.pkg` has this shape:

```ecl
{'format 1
 'name "my.proj"
 'version "0.1.0"
 'exports
 {"my.proj" ["src/**/*.ecl"]}
 'requires
 {"statistics" {'package "foo"
                 'version "1.2.0"
                 'url "https://example.com/foo-1.2.0.tgz"
                 'hash "sha256-<64 lowercase hex digits>"}}}
```

`'format` is the integer `1`. `'name` is the package's canonical name, and
`'version` is its version. `'exports` maps owned module namespaces to portable
source globs. `'requires` maps consumer-local aliases to requirements.

A requirement contains exactly `'package`, `'version`, `'url`, and `'hash`.
The version is a minimum. The URL begins with `https://`. The hash has the
form `sha256-` followed by 64 lowercase hexadecimal digits. Aliases do not
change ECL module names.

Every dictionary key is declared by the format. A requirement cannot target
the containing manifest's package. One consumer cannot target the same
package through multiple aliases. Selected package names cannot overlap under
the ownership rule below.

Manifest values may contain ints, floats, chars, symbols, strings, lists, and
dictionaries. An executable word anywhere in the value raises `'domain`.
Comments are accepted by the reader and omitted by manifest rewrites.

### Package names and exports

A canonical package name contains dot-separated segments. Each segment
matches `[a-z][a-z0-9-]*`. Every package name is also a valid module name.

Package `foo` owns module namespaces `foo` and `foo.<rest>`. The ownership
boundary is a dot, so `foo` owns `foo.bar` and excludes `foobar`.

Each exported namespace maps to a nonempty list of distinct portable globs.
Globs use relative `/`-separated paths and support `*`, `?`, and a
whole-segment `**`. They exclude absolute paths, backslashes, and empty, `.`,
or `..` segments.

The package catalog is derived from matching source files and their parsed
forms. Each matched `.ecl` file declares one or more top-level modules through
a literal module symbol followed by `@defm`. Every declaration is the export
namespace or one of its dotted children. A source file may declare several
modules. Every glob matches at least one file, one file belongs to one export
namespace, and one module name maps to one source file across the selection.
File and directory names carry no module-name meaning beyond glob matching.

### Resolution

`pkg.mvs.resolve` receives a validated root manifest and an exact-version
manifest catalog:

```ecl
{"foo" {"1.2.0" <foo 1.2.0 manifest>
        "1.5.0" <foo 1.5.0 manifest>}
 "bar" {"2.0.0" <bar 2.0.0 manifest>}}
```

Each outer key is a package name. Each inner key is a version, and the stored
manifest has the same name and version. The root manifest is supplied
separately.

Resolution visits every exact `(package, version)` node reachable from the
root requirements. It selects the greatest reachable declared minimum for each
package and rejects an active-path requirement cycle. Unreachable catalog
entries are ignored.

The lock records the selected packages and every requirement edge from the
root and selected manifests. Each selected version satisfies every recorded
minimum.

Traversal and diagnostics use canonical package, version, and requirer order.
If declarations for one name and version share a hash and use different URLs,
the lexicographically least URL is recorded. Different hashes conflict. A
cycle reports its sorted distinct package names.

Resolver failures use these messages and data fields:

- malformed reachable version: `a reachable package version is malformed`,
  with `'package`, `'required-package`, and `'version`;
- missing manifest: `pkg.mvs.resolve is missing a declared manifest`, with
  `'package`, `'required-package`, and `'version`;
- hash conflict: `one package version has conflicting hashes`, with
  `'package`, `'version`, `'left-package`, `'left-hash`, `'right-package`, and
  `'right-hash`;
- selected-prefix collision: `selected packages have overlapping prefixes`,
  with `'left-package` and `'right-package`;
- requirement cycle: `the package requirement graph has a cycle`, with
  `'packages`.

Wrong root and catalog containers retain their type diagnostics. Catalog
identity mismatch reports `a catalog manifest must match its name and version
keys`.

### Lock file

`ecl.lock` is derived project data with this shape:

```ecl
{'format 1
 'root "my.proj"
 'packages
 {"bar" {'version "0.3.0" 'url "https://…" 'hash "sha256-…"}
  "foo" {'version "1.2.0" 'url "https://…" 'hash "sha256-…"}}
 'requires
 {"foo" {"database" {'package "bar" 'version "0.3.0"}}
  "my.proj" {"statistics" {'package "foo" 'version "1.2.0"}}}}
```

A cache-backed lock has exactly `'format`, `'root`, `'packages`, and
`'requires`. A vendored lock also has `'store 'vendor`. No other store value
is valid.

`'packages` maps each selected package name to its version, URL, and hash.
`'requires` maps each requiring package to its alias-to-minimum edges. The root
always appears under its own name. A selected package with no requirements may
be omitted from `'requires`.

Package maps, requirer maps, and inner requirement maps use ascending key
order. The writer uses canonical scalar spellings, places top-level and map
entries on stable lines, and ends the file with a newline. Reading and writing
a canonical lock reproduces its bytes. Lock rewrites omit comments.

### Store and cache selection

A store entry is the immutable directory
`<name>-<version>-<hex>`, where `<hex>` is the package hash without its
`sha256-` prefix. A present entry is reused and never overwritten.

The shared store root is selected by the host, not by evaluated code, from
the process environment at command startup:

1. nonempty `ECL_CACHE` supplies the complete root;
2. nonempty `XDG_CACHE_HOME` supplies `$XDG_CACHE_HOME/ecl/pkg`;
3. nonempty `HOME` supplies `$HOME/.cache/ecl/pkg`;
4. absence of all three leaves the `'cache` store unavailable, and the first
   store operation that needs it fails with `'io` naming the three variables.

An empty environment value is treated as absent. A relative selection is
resolved once against the working directory captured at command startup.
Package commands that may install (`add`, `sync`) create an absent cache
directory at startup; read-only commands leave absence visible. A
package-command Session holds the selected cache and the project's `vendor`
directory as retained handles behind an opaque package authority; `pkg.store`
words name a store as `'cache` or `'vendor` and an entry by canonical key. The
vendor store is always the entry named `vendor` directly inside the discovered
project root, opened without following a symlink; a project whose `vendor` is
a link is rejected when the command starts, and no store is ever opened
behind it. `pkg.store.present?` returns `0` for an absent
entry and `1` for a real directory. Symlinks, other node kinds, access denial,
and probe failures raise `'io` with the key as `'path`.

### Package archives and publication

A package artifact is a gzip-compressed tar byte list satisfying the archive
rules above and these additional rules:

- exactly one regular root file is named `ecl.pkg`;
- the manifest is valid UTF-8 and valid format-1 package data;
- ordinary directories and data files are allowed;
- `.eclmod` files, links, and special nodes are forbidden;
- every exported source file satisfies the manifest's glob, namespace,
  uniqueness, and parse requirements.

Installation parses package source to build the module catalog and never
evaluates it.

`pkg.store.inspect` performs the full archive and package-layout scan and
returns the exact root manifest text without creating a destination.
`pkg.store.install` repeats validation at the mutation boundary, extracts to a
unique sibling staging directory, and publishes with an absent-destination
rename. It returns regular-file paths after commit. A destination conflict
raises `'io` with `'destination-exists 1`; a caller may accept a concurrent
winner after `present?` confirms a real directory.

Each installed entry retains its source archive as a reserved seal.
`pkg.store.verify` streams the seal and compares its SHA-256 with the lock.
`pkg.store.read-seal` performs the same verification and returns the exact seal
bytes. It accepts no caller-selected child path.

Project files are published through the `'project` filesystem root:
`pkg.sync.write-project-file` uses `fs.create-text` for an absent file and the
strict `fs.replace-text` otherwise, so a racing collision surfaces as the `fs`
failure rather than becoming an upsert. Both publish through a private staging
entry and preserve the prior file until the atomic commit.

The package store exposes no general filesystem handles, recursive deletion,
copy, rename, absolute path, or caller-selected garbage-collection root.

### Synchronization

`pkg.sync.run` receives a root manifest and performs a discovery pass followed
by an installation pass inside a package-command Session, using the store the
project lock selects.

The discovery pass visits exact requirements in canonical order. A present
store entry supplies its manifest locally through `pkg.store.manifest`. A
missing entry is fetched with
`http.get-bytes`; synchronization requires a successful status, computes the
archive hash before inspection, validates the archive manifest, checks its
exact package identity, and follows its requirements.

HTTP status failure raises `'io` with `'package`, `'url`, and `'status`. Hash
mismatch raises `'domain` with `'package`, `'declared-hash`, and
`'actual-hash`. Manifest identity mismatch raises `'domain` with requested and
actual names and versions. Archive errors carry the package and member when
available. Discovery failure installs nothing and leaves the lock unchanged.

After resolution, the installation pass visits selected packages in canonical
order. It re-fetches each missing selection, repeats status, hash, archive, and
identity validation, and installs the entry. Repeating verification at the
publication boundary limits retained archive memory and makes the installer
independent of discovery state.

Synchronization writes `ecl.lock` only after every selected entry is present.
It renders the lock once and publishes it with `pkg.sync.write-project-file`.
Failure preserves the previous lock. Immutable entries installed before a later
failure remain available for a subsequent run.

`pkg.sync.run-offline` performs the same discovery, resolution, and
publication using present store entries. It opens no network request.

### Runtime module resolution

A session without a discovered project resolves embedded modules and then
uses `ECL_PATH`.

A session with a discovered project resolves embedded modules and then uses
its immutable lock-derived catalog. `ECL_PATH` is excluded from project
resolution. A cache-backed lock uses the selected shared store; a vendored
lock uses `<project-root>/vendor` and ignores cache environment variables.

The catalog maps each module to an exact package entry and source path. A
missing selected directory raises `'io` and directs the user to `ecl pkg
sync`. An unexported module or a module outside the current package's direct
requirements raises `'undefined-word`. Package lookup never falls through to
`ECL_PATH` and never performs network or package writes.

Runtime package visibility is lexical. Root and package code can resolve their
own package and packages named by their direct requirement edges. Loading a
transitive package into the shared registry does not grant visibility to an
unrelated caller.

One source artifact is evaluated once. Its cataloged registrations and package
provenance are verified before commit. Qualified resolution ignores
registrations from an uncommitted artifact.

Runtime lookup uses these stable diagnostics:

- missing entry: `locked package <package> is missing from the package store;
  run ecl pkg sync`;
- unavailable cache root: `locked package <package> has no package store; set
  ECL_CACHE, XDG_CACHE_HOME, or HOME before running ecl pkg sync`;
- failed entry probe: `cannot inspect locked package <package> in the package
  store: <host-error>; run ecl pkg sync`;
- invalid entry node: `locked package <package> is not a real package-store
  directory; run ecl pkg sync`;
- absent source: `locked module <module> is absent from package <package>`.

The first four raise `'io`; the final message raises `'undefined-word`. An
invalid discovered lock raises `'io` prefixed by `invalid project lock
<path>:`.

### Vendoring and cache collection

`ecl pkg vendor` verifies every selected entry's seal and installs it at
`<project-root>/vendor/<store-key>`. Existing vendor entries are verified and
preserved. After every entry is present, the command atomically rewrites the
lock with `'store 'vendor`. Failure preserves the prior lock and may leave
valid immutable entries for reuse. Repetition is idempotent.

`ecl pkg gc <lock-file> [lock-file ...]` parses each named lock without
evaluation and retains the union of their selected store keys. Each lock file
is a canonical relative path beneath the working directory; an absolute or
escaping path is a `'domain` error. Collection uses the shared cache the host
selected at startup and preserves retained keys, symlinks, non-directory
nodes, and unknown child names.

An unretained real directory with a canonical store-key name is renamed to a
private `.ecl-gc-*` name and deleted through bounded work without following
links. A later collection finishes interrupted private entries. The reported
count includes live entries detached by the current invocation.

### Package commands

`ecl pkg` dispatches to the ordinary `pkg.*` modules inside a package-command
Session. Every command except `init` and `gc` uses project discovery and
grants the discovered root to evaluated code as the `'project` filesystem root
with `read-data`, `inspect`, `create`, and `replace`; the discovered path
itself never enters evaluated code. `init` acts on the `'cwd` root.

- `init [name]` creates a format-1 manifest at version `0.1.0`. The working
  directory basename supplies the default name. Creation never replaces an
  existing or racing file.
- `add <name> <version> <url>` fetches and validates an exact package, derives
  its hash, and records the requirement through an atomic manifest rewrite.
- `sync` performs network-enabled synchronization. `sync --offline` uses only
  immutable store entries.
- `tree` prints the lock root and dependency edges in requirer/package order.
- `why <module>` prints one deterministic root-to-owner path.
- `verify` streams and hashes every selected package seal without network
  access.
- `vendor` creates or verifies the project-local store and marks the lock as
  vendored.
- `gc <lock-file> [lock-file ...]` collects the shared cache against one or
  more explicitly named locks.

Successful package commands produce stable line-oriented output. Package and
host failures remain structured ECL errors rendered by the process boundary.

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
once at startup, as the `'cwd` filesystem root with every permission, and an
unrestricted process policy anchored at the same directory. The two policies
are independent grants.

The command reads these environment variables at startup:

- `ECL_PATH` supplies the unmanaged module search path;
- `ECL_WORKERS` supplies a positive base-10 worker count and defaults to the
  CPU count;
- `ECL_NATIVE_DIAGNOSTICS` enables native-loading diagnostics when present;
- `ECL_CACHE`, `XDG_CACHE_HOME`, and `HOME` participate in package cache
  selection as described above;
- `HOME` also selects the REPL history path `.ecl_history`.

### Standard input

`io.stdin` is available in `-e` and script-file modes. It reads the complete
input stream once. There is no ambient file access: file words live in `fs`
and act beneath the `'cwd` root. Standard input carries program source in `ecl -` and in
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

`ecl test` requires a lock-backed root project. It loads modules exported by
the root package, discovers their declared tests, and invokes the selected
runner in a Test Session. The default runner is `test.default.run`.

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
