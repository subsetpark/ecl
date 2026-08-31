# Legacy environment and tooling material

This file preserves, verbatim, standard-environment, package, native-module,
command-line, and formatter sections removed from the former monolithic
specification. These subjects are outside the core language report and this
text records no design decisions made during the current specification
session. It is not assembled into `SPEC.md`.

The material remains available as migration input for future companion
specifications.

### Native modules

A `<name>.eclmod` is a precompiled native module: one artifact is one
module, whose complete word table validates and publishes atomically — an
artifact cannot partially register. Its canonical name must equal the
requested name. Native words are ordinary module words: they carry a
  mandatory effect and nonempty documentation, participate in `import`, dotted
  access, `doc`, `which`, and `see` (which display the native origin), and
their calls are transactional — a failing native call leaves the stack
unchanged. A native word can raise only the kinds `'type`, `'shape`,
`'conform`, `'overflow`, `'domain`, `'parse`, `'io`, or `'user`; the
runtime alone raises the rest. Native modules are neither reloaded nor
unloaded within a session.

Opening a shared library executes arbitrary machine code before ecl can
inspect it, so every directory on an `ECL_PATH` used for native loading is
a trusted-code boundary.

## The standard library

The exhaustive core and module word list lives in
[`STDLIB.md`](STDLIB.md). This section specifies the semantic conventions that
tie those ordinary modules into the language.

Twenty modules ship inside the binary. They are ordinary modules — registered,
enumerable, shadowable — and they load lazily on the first qualified mention of
their name, whether that is a bare `str.upper` or `'str ('upper) import`. Resolution consults
the embedded manifest before `ECL_PATH`, so a stray `csv.ecl` on the search
path cannot silently replace a stdlib name; in-session shadowing and explicit
`@defm` registration remain the documented overrides. All twenty resolve with no
`ECL_PATH` set and no filesystem access at all.

Three transports back them, chosen per module rather than uniformly:
embedded ECL source (`dict`, `error`, `result`, `str`, `table`, `rng`, and the
eight `pkg.*` modules), a linked first-party
native descriptor published through the same contract as an external
extension (`csv`), and builtin word tables published under a module name
(`io`, `json`, `http`, `archive`, `pkg.store`).
The last is reserved for authority the native SDK deliberately withholds — an
allocator, TLS, sockets — which is why `json` and `http` are not SDK modules
and `csv` is.

### error

Errors remain ordinary immutable dictionaries. `error.new` starts one from its
required kind symbol; `error.with-message` and `error.with-data` return updated
values without raising. `error.valid?` recognizes the same typed fields as
`raise`: required symbol `'kind`, optional string `'msg`, optional symbol
`'word`, optional list-of-symbols `'trace`, and optional dict `'data`. Other
diagnostic keys are permitted. `error.kind?` and `error.kind-in?` inspect a
validated error without repeating raw dictionary plumbing.

This module owns data construction and inspection only. `raise`, `fail`,
`assert`, and `@attempt` remain core because they are control effects rather
than error values.

- `error.new` `( kind -- error )`
- `error.with-message` `( error message -- error )`
- `error.with-data` `( error data -- error )`
- `error.valid?` `( value -- bool )`
- `error.kind?` `( error kind -- bool )`
- `error.kind-in?` `( error kinds -- bool )`

### result

Over the same `{'ok values}` / `{'err error}` shape `@attempt` produces. A
success payload is always a list standing for a stack, never one privileged
scalar. Every word rejects a malformed tagged result *before* invoking any
quotation it was given.

Every word that *interprets* an envelope lives here — that is the boundary.
The words that *produce* an error — `raise`, `fail`, `assert` — stay core,
because an error dict in flight is not a result: it becomes one only when
`@attempt` or `await` reifies it.

- `result.ok` `( values -- result )`, `result.err` `( error -- result )`
- `result.ok?` / `result.err?` `( result -- bool )`
- `result.or-raise` `( result -- values )` — the success payload, or the
  captured error dict re-raised unchanged. (`result.or-raise call` unpacks
  the values onto the stack.)
- `result.or-else` `( result fallback -- value )` — the success payload, or
  the fallback value.
- `result.and-then` `( result quotation -- result )` — seeds the success
  stack through the explicit values operand of `@attempt`; an existing failure is returned unchanged.
  There is no separate `result.map`: `@attempt`'s automatic `{'ok [...]}`
  wrapping collapses the functor map and the monadic bind into one word on
  the success side. The distinction survives only on the failure side, which
  is why that side carries both `map-err` and `recover`.
- `result.map-err` `( result quotation -- result )` — replaces a failure's
  error dict with what its `( error -- error )` quotation returns, never
  leaving the failure arm.
- `result.recover` `( result quotation -- result )` — seeds the error dict as
  one value; `result.recover-kinds` `( result kinds quotation -- result )`
  does so only for a listed kind and leaves every other result unchanged.
- `result.either` `( result on-ok on-err -- ... )` — exhaustive eliminator;
  neither branch is isolated.
- `result.all` `( results -- result )` — the leftmost failure unchanged, or
  one success holding every success stack in input order.
- `result.partition` `( results -- successes errors )` — both in input order,
  without re-raising.

### str

ASCII-only case mapping per the character model: a non-ASCII scalar passes
through untouched, and codepoint count is preserved. Its exports are `str.upper`,
`str.lower`, `str.trim`, `str.trim-left`, `str.trim-right`, `str.starts?`,
`str.ends?`, `str.contains?`, `str.index-of` (`'domain` when absent),
`str.replace`, `str.repeat`, `str.pad-left`, `str.pad-right`, and `str.str?`.

`str.str?` is the recognizer every boundary that accepts text needs, and it
lives here rather than in core because it is derived: a string is a rank-1 char
vector, so the test is a `'list` whose every element is a `'char`. It answers 1
for the empty string — which is also the empty list, the two being one value —
and 0 rather than raising for every other kind. `type` reports `'list` for every
list, so this is the honest form of the question.

### archive

Binary package archives cross the language boundary as **byte lists**: ordinary
ECL lists whose items are integers in `0..255`. Strings are Unicode values and
are never accepted or coerced at this boundary; hashing and extraction consume
each integer as exactly one octet in list order.

Byte lists have no distinct language-level type. List construction may store an
all-`0..255` integer list in a packed one-byte leaf, and host producers may build
that representation directly. Indexing, equality, printing, reflection, and
all other language operations still observe ordinary integers. A mutation that
introduces an integer outside `0..255` transparently widens the list to the
ordinary integer representation. Whether packed storage is present is never
observable program behavior.

`archive.sha256` `( bytes -- lowercase-hex )` returns the standard SHA-256
digest as exactly 64 lowercase hexadecimal characters. It is pure and does not
require host I/O.

`archive.unpack-tgz` `( bytes destination -- regular-file-paths )` validates a
gzip-compressed tar archive and extracts it beneath a previously absent
destination. It accepts ordinary ustar regular-file and directory entries,
per-entry PAX `path` and `size` records, and GNU long-name records. Other PAX
metadata may not change a member's path, size, or kind. The result lists only
regular-file paths, normalized with `/` separators and in archive order;
directory entries are omitted.

Extraction is contained and fail-closed. Member names must be valid UTF-8,
relative, nonempty after normalization, and contain no empty, `.` or `..`
component. Absolute names, platform-rooted names, duplicate normalized paths,
links, devices, FIFOs, unsupported member kinds, malformed gzip/tar/PAX data,
and checksum or size disagreement are `'domain`. The uncompressed tar stream
may contain at most 1,073,741,824 bytes and at most 100,000 regular-file or
directory members; exceeding either ceiling is `'domain`.

The destination must not exist. The extractor creates a unique
`.ecl-unpack-*` sibling staging directory, creates files exclusively, records
every created path, and removes that staging tree in bounded reverse-order work
on every pre-commit failure or cancellation. Only after the complete archive
has validated and all handles are closed does one same-parent rename publish
the staging tree as the destination. Concurrent calls may perform independent
staging work, but at most one can publish; the others raise `'io` reporting
that the destination exists. An existing destination is never overwritten,
merged, or inspected as though it were a completed cache entry.

A non-list byte container or non-string destination is `'type`. A non-integer
byte item or an integer outside `0..255` is `'domain` carrying its zero-based
`'index`. Missing host I/O, filesystem denial, exclusive-create failure,
staging cleanup failure, and commit failure are `'io` carrying the relevant
`'path`. No failure publishes a partial destination or opens a member path
outside the staging root.

### io

Observable text I/O lives here: `io.pp`, `io.prin`, `io.print`, `io.inspect`,
`io.debug`, `io.stack`, `io.stdin`, `io.slurp`, `io.spit`, and `io.lines`. A qualified
reference or an explicit import such as `'io ('print) import` makes the
boundary explicit. Core `str` canonically renders any value *as a string
value* without performing I/O.

### csv

`csv.parse` `( string -- rows )` and `csv.emit` `( rows -- string )`,
RFC 4180 and text-preserving. Parsing accepts CRLF or LF record endings,
quoted commas and newlines, and doubled-quote escapes; it preserves empty
fields and record widths and returns every field as a string, with no header
interpretation, delimiter sniffing, or scalar inference. Emission is
canonical CRLF-terminated output quoting exactly the fields that require it.
Empty input is an empty record list. Malformed quoting is `'parse`, non-list
rows and non-string cells are `'type`, and a zero-field row is `'shape`.

### json

`json.parse` `( string -- value )` and `json.emit` `( value -- string )` per
RFC 8259. Integral in-range numbers become ints and everything else numeric
becomes a float; objects become dicts with string keys and arrays become
lists. **`null`, `true`, and `false` become the ordinary symbols `'null`,
`'true`, and `'false`** — data, not language nil and not language booleans,
which is what lets a document round-trip. Emission requires string or symbol
dict keys (`'type` otherwise) and rejects any other symbol.

### table

A table is a validated ordinary column dictionary, never a new runtime kind:
a nonempty insertion-ordered dict whose keys are unique nonempty strings and
whose values are lists sharing one length. Zero rows are legal; zero columns
never. Core reflection stays honest — `type` reports `'dict`, and
`dict.keys`/`at`/`put`/`match?` behave as they do for any dict — so a core
operation can produce an invalid candidate, which the next `table.*` boundary
rejects rather than repairing.

- construction: `from-columns`, `from-rows`, `from-header-rows`,
  `from-records`
- conversion: `rows`, `header-rows` (schema-preserving, zero rows included),
  `records` (necessarily schema-less when empty)
- inspection: `valid?`, `names`, `height`, `column`
- transformation: `cast`, `select`, `rename`, `with-column`, `where`
- analysis: `group-by`, `aggregate`, `inner-join`, `left-join-with`

`table.valid?` answers 0 only for a convention mismatch; cancellation and
allocation failure still propagate. Failures follow the frozen kinds:
non-dicts, non-string names, non-list columns, and invalid masks or spec
members are `'type`; zero-column schemas, unequal column lengths, and
width mismatches are `'shape`; missing, empty, or duplicate names, schema
disagreement, join and rename collisions, and incomplete fills are
`'domain`; an aggregation quotation of the wrong shape is `'contract`.

Joins are stable equijoins on `[left-name right-name]` pairs. Duplicate keys
expand to the full many-to-many product in left-row order and, within one
left row, right-row order. Results carry every left column in its original
order followed by the right non-key columns in right order.
`table.left-join-with` emits one row for an unmatched left row and requires a
fill dict covering exactly every appended right column — it never invents a
value.

### http

Client only. `http.get` `( url headers -- response )`, `http.get-bytes`
`( url headers -- response )`, and `http.post`
`( url headers body -- response )`, with `{}` for no headers, return
`{'status int, 'headers dict, 'body value}`. `get` and `post` materialize
`'body` as a string. `get-bytes` follows the same request, redirect, response-
header, status, and content-decoding rules but materializes the resulting
octets directly as an ordinary integer byte list; it never passes them through
Unicode conversion. "Bytes" here means the representation after HTTP content
decoding, not transfer framing or a compressed wire representation. A refused
connection, TLS failure, unparseable url, or protocol error is `'io` carrying
the url in `'path`; a non-2xx status is an ordinary value, not an error.

A `Session.Host` may carry an optional TLS trust override consisting of an
absolute CA-file path plus a fixed verification timestamp. In that mode the
HTTP client loads only that CA file and verifies at that timestamp; it does not
scan system roots or read the wall clock. A null override preserves system
roots and current-time verification. This is explicit host configuration for
hermetic HTTPS tests, not an ECL value or a process environment switch.

**The request blocks the calling unit's worker thread.** That is the one
documented first-party exception to cooperative scheduling: a `@each`
over N urls at N workers runs at most N concurrent requests, and at one
worker it serializes. v1 imposes no request deadline, so an unresponsive
server occupies its worker until the host gives up. Both change with the
future `Offload` capability without changing this value-level API.

### rng

Threaded generator state over the counter-based kernels, so ordinary code
draws without carrying a `[key counter]` list by hand (see Randomness).
The module's binding holds one state; each word reads it, draws, and
stores the advanced state back.

- `rng.seed` `( key -- )` — rekey and reset the counter. Every later draw
  is a function of this key.
- `rng.int` `( bound -- result )`, `rng.ints` `( count bound -- results )`.
- `rng.float` `( -- result )` — one uniform float in `[0, 1)`.
- `rng.deal` `( count pool -- results )` — `count` distinct values below
  `pool`, drawn without replacement. Selection sampling, so the sample is
  unbiased rather than a filtered sequence of independent draws; `count`
  above `pool` is `'domain`.
- `rng.shuffle` `( values -- values )` — a uniform permutation, defined as
  `deal` over the list's own length.

A fresh process starts from a fixed key, so a program using `rng` and
never calling `rng.seed` is fully reproducible. Seeding from `rand.entropy` is
the explicit opt out.

### Package modules

The package formats are data (see Packages). Eight ordinary source modules
divide value operations and orchestration by responsibility: `pkg.version`,
`pkg.name`, `pkg.data`, `pkg.manifest`, `pkg.lock`, `pkg.mvs`, `pkg.sync`, and
`pkg.cli`. There is no root `pkg` facade. The first six are pure: every word
takes and returns text or values and none reaches a host capability. `pkg.sync`
is the explicit network/filesystem orchestration boundary and composes those
pure modules with `http`, `archive`, and the narrow builtin `pkg.store`
capability. `pkg.cli` is the line-oriented command adapter invoked by `ecl pkg`.

- versions: `pkg.version.less?` `( left right -- bool )`, `pkg.version.max`
  `( versions -- version )`
- manifest: `pkg.manifest.read` `( text -- manifest )`,
  `pkg.manifest.validate` `( candidate -- manifest )`, `pkg.manifest.write`
  `( manifest -- text )`
- lock: `pkg.lock.read` `( text -- lock )`, `pkg.lock.write`
  `( lock -- text )`, `pkg.lock.tree` `( lock -- text )`, and `pkg.lock.why`
  `( lock module -- text )`; `pkg.lock.vendor` `( lock -- lock )` selects the
  one project-local store mode
- resolution: `pkg.mvs.resolve` `( root-manifest manifests -- lock )`
- names: `pkg.name.owns?` `( package-name module-name -- bool )`
- store derivation: `pkg.sync.cache-root` `( -- store-root )`,
  `pkg.sync.store-key` `( package requirement -- key )`,
  `pkg.sync.store-path` `( store package requirement -- path )`,
  `pkg.sync.store-keys` `( lock -- keys )`, and `pkg.sync.store-root`
  `( lock project-root -- store-root )`
- synchronization: `pkg.sync.requirement`
  `( package version url -- requirement )`, `pkg.sync.run`
  `( root-manifest project-root -- lock )`, `pkg.sync.run-offline`
  `( root-manifest project-root -- lock )`, and `pkg.sync.verify`
  `( lock project-root -- count )`
- CLI adapters: `pkg.cli.init`, `add`, `sync`, `sync-offline`, `tree`, `why`,
  `verify`, `vendor`, and `gc`; `src/main.zig` supplies their validated argv
  shapes and the nominal project root where required

The builtin `pkg.store` module exposes only the package mutations ordinary ECL
cannot express safely: `inspect`, `install`, `present?`, `verify`, `read-seal`,
`write-lock`, and `gc`. `read-seal` returns bytes only after package-and-hash
verification. `gc` derives the shared cache root from the Session environment
and accepts store keys rather than a path. The module does not expose raw
directories, handles, generic rename, recursive delete, or a caller-selected
garbage-collection root.

`pkg.manifest.validate` returns its argument unchanged or raises; it is not a
`valid?`-style predicate. Failures follow the frozen kinds and introduce no
user kind: unreadable text is `'parse`; text that is not exactly one form, and
an empty `pkg.version.max` list, are `'shape`; a wrong value kind is `'type`; and
everything inside a legal type but outside the grammar — an undeclared key, an
unsupported `'format`, a malformed name, version, hash, or URL, a
self-requirement, an ownership collision, a word value anywhere — is
`'domain`.

`resolve` returns a lock value directly. It raises the ordinary structured
ECL error on failure; it does not return a `result` envelope. A wrong root or
manifest-catalog container is `'type`. Malformed graph data, a missing
manifest, a hash conflict, a selected-prefix collision, and a requirement
cycle are `'domain`.

## Packages

A project declares its dependencies in `ecl.pkg`, and resolution derives
`ecl.lock` from it. Both files are ECL data: read with `parse` and **never
evaluated**, so resolving a dependency graph cannot run code from a
dependency. Importing stays by module and attribute name —
`'foo.bar ('baz) import`
never mentions a file, a URL, or a version — and a checkout plus a lock reproduces the same module
images on any machine.

The `pkg.manifest`, `pkg.lock`, `pkg.version`, and `pkg.name` modules read,
validate, order, and write these values (see The standard library). Those
format operations are pure. `pkg.sync.run` is the explicit network and
filesystem boundary that derives and publishes a lock; ordinary evaluation
reads a lock and never fetches or writes one.

### Versions

A version is a **string**, always:

```
version     :=  core ( "-" prerelease )?
core        :=  num "." num "." num
num         :=  "0" | [1-9] [0-9]*
prerelease  :=  ident ( "." ident )*
ident       :=  [0-9A-Za-z-]+
```

A numeric `ident` — one whose every character is a digit — may not carry a
leading zero. **Build metadata is not in the grammar**: a `+` anywhere makes
the spelling malformed rather than being parsed and discarded.

The string requirement is not a convention. A bare `1.2.3` reads as the
*word* `1.2.3` — an executable reference — so an unquoted version in a
manifest is malformed by construction rather than by rule.

Precedence is Semantic Versioning 2.0.0 §11, and it is a strict total order
over what the grammar admits:

- Compare `major`, then `minor`, then `patch`, numerically.
- On equal cores, a version carrying a prerelease is below the same core
  without one.
- Otherwise compare prereleases identifier by identifier from the left: a
  numeric identifier is below an alphanumeric one, two numeric identifiers
  compare numerically, and two alphanumeric identifiers compare in codepoint
  order — the ordering `cmp` already gives strings.
- When every shared identifier is equal, the shorter prerelease is below the
  longer one.

Anything outside the grammar is an error, not an incomparable value, so there
is no partial order to reason about.

Minimal version selection takes the maximum of *declared* minimums and never
enumerates available versions, so every selected version is one some manifest
wrote down. A prerelease is therefore selected only when it was declared; no
separate rule is needed to prevent it.

### The manifest

`ecl.pkg` holds exactly one dict form. It is found by walking up from the
process working directory toward the filesystem root: the first one found is
the project root, and `ecl.lock` is read from beside it and never from a
different directory. There is no repository-boundary stop and no environment
override. The walk costs one directory probe per level — bounded by depth,
paid once per session — and no `ecl.pkg` anywhere up the chain means there is
no lock at all.

```
{'format 1
 'name "my.proj"
 'version "0.1.0"
 'exports
 {"my.proj" ["src/**/*.ecl"]}
 'requires
 {"statistics" {'package "foo"
         'version "1.2.0"
         'url "https://example.com/foo-1.2.0.tar.gz"
         'hash "sha256-<64 lowercase hex digits>"}}}
```

- `'format` is the int 1. An unrecognized value is `'domain` rather than a
  best-effort read: more than one reader consumes these files, so all of them
  must agree on when to stop reading.
- `'name` is this package's canonical name and `'version` is its own version.
  `'exports` maps an owned module namespace to one or more portable source
  globs. `'requires` maps a consumer-local alias to a requirement.
- A requirement is exactly the target `'package`, `'version` — the declared
  *minimum* — `'url`, and `'hash`. Aliases never rewrite ECL module names. The
  URL must begin `https://`: a tarball over HTTPS is the only transport, and a
  git dependency is a codeload tarball URL.
- Every key is declared. An undeclared key at any level is `'domain`, so a
  misspelling is an error rather than an entry that is silently ignored.
- A requirement may not target the manifest's own `'name`; a consumer may not
  target one package through two aliases; and selected package names may not
  overlap under the ownership relation below.
- `#` comments are permitted, and nothing that rewrites the file preserves
  them.

**Inertness is a property of the format, not of the reader.** A manifest may
hold ints, floats, chars, symbols, strings, lists, and dicts; a **word** value
anywhere in it is `'domain`. A quotation is an ordinary list and is legal as
data — what is forbidden is the executable reference, which is the thing an
evaluated manifest would run.

### Canonical names and prefix ownership

A canonical package name is one or more segments joined by `.`, each matching
`[a-z] [a-z0-9-]*`. Every package name is therefore a legal module name by
construction.

Package `foo` may export namespaces `foo` and `foo.<rest>` and nothing else.
Ownership continues only across a `.` boundary: `foo` owns `foo.bar` and does
not own `foobar`. Each exported namespace maps to nonempty, distinct portable
globs: relative `/`-separated paths with `*`, `?`, and whole-segment `**`, but
no absolute path, backslash, empty segment, `.` segment, or `..` segment.

The runtime derives an inert catalog from those globs and parsed source forms.
Every matched `.ecl` artifact must declare one or more top-level modules as a
literal symbol immediately followed by `@defm`; every declaration must equal
its export namespace or be its dotted child. A file may declare several
modules. Different export namespaces may not claim one file, every glob must
match at least one source artifact, and every full module name maps to exactly
one artifact across the selected graph. Filename and directory layout carry no
module-name semantics.

### Resolution

`pkg.mvs.resolve` takes a validated root manifest and a catalog of already-read
dependency manifests. The catalog is nested by exact package version:

```
{"foo" {"1.2.0" <foo 1.2.0 manifest>
        "1.5.0" <foo 1.5.0 manifest>}
 "bar" {"2.0.0" <bar 2.0.0 manifest>}}
```

Each outer key is a canonical package name. Each inner key is a version, and
the manifest stored there has that same `'name` and `'version`. The root is
passed separately and does not appear in the lock's `'packages` map.

Resolution implements minimal version selection over the exact
package-version requirement graph. Starting from the root's requirements, it
visits every reachable `(name, version)` node and its requirements. It then
keeps the greatest reachable version of each package name under
`pkg.version.less?`. Catalog entries that no reachable requirement names are not
candidates, are not validated, and cannot affect either the lock or an error.
An active-path repeat is a requirement cycle and is rejected; this is a
deliberate restriction of the otherwise cycle-tolerant MVS graph traversal.

The returned lock uses the format below. `'root` is the root manifest's name.
`'packages` contains one selected requirement value per dependency name.
`'requires` contains the root and every selected package as requirers, each
mapped to the minimum versions in its manifest. Every selected version is at
least every recorded minimum, and the complete value satisfies the same
validation as `pkg.lock.read` and `pkg.lock.write`.

Traversal and diagnostics do not depend on dict insertion order. Requirements
are considered in canonical name/version/requirer order. If equal
name/version declarations have the same hash but different URLs, the
lexicographically least URL is recorded; the content hash, not its mirror, is
the artifact identity. Different hashes for one name/version are a hard
conflict. Selected prefix-collision pairs and conflicting declarations are
reported in package-name order. A cycle reports the sorted distinct package
names in the cycle. When more than one malformed or missing edge exists, the
least edge in canonical order is reported.

Resolver errors use the frozen kinds and carry the following `'data` fields:

- malformed reachable version: exact message `a reachable package version is
  malformed`; fields `'package`, `'required-package`, `'version`
- missing manifest: exact message `pkg.mvs.resolve is missing a declared
  manifest`; fields `'package`, `'required-package`, `'version`
- hash conflict: exact message `one package version has conflicting hashes`;
  fields `'package`, `'version`, `'left-package`, `'left-hash`,
  `'right-package`, `'right-hash`
- selected-prefix collision: exact message `selected packages have overlapping
  prefixes`; fields `'left-package`, `'right-package`
- requirement cycle: exact message `the package requirement graph has a
  cycle`; field `'packages`

Wrong root or catalog containers retain their exact type diagnostics: `a
manifest is a dict` and `pkg.mvs.resolve expects a manifest catalog dict`.
Catalog identity mismatch is `a catalog manifest must match its name and
version keys`. Every graph diagnostic names the responsible package and, where
an edge is responsible, the requiring package and conflicting requirement.

Adding a requirement whose exact node is already reachable and whose minimum
is already met does not change `'packages`. It does change `'requires`, which
records the new declaration under its requirer; selection stability is not a
claim that the whole lock value is byte-identical.

### The lock

`ecl.lock` holds exactly one dict form. It is derived rather than recorded:
deleting it and resolving again reproduces it.

```
{'format 1
 'root "my.proj"
 'packages
 {"bar" {'version "0.3.0" 'url "https://…" 'hash "sha256-…"}
  "foo" {'version "1.2.0" 'url "https://…" 'hash "sha256-…"}}
 'requires
 {"foo" {"database" {'package "bar" 'version "0.3.0"}}
  "my.proj" {"statistics" {'package "foo" 'version "1.2.0"}}}}
```

A cache-backed lock has exactly those four keys. A vendored lock adds exactly
`'store 'vendor` between `'root` and `'packages` in canonical output. No other
store value is legal, and the value is a symbol rather than a path: the mode
derives the fixed `<project-root>/vendor` directory, so lock data cannot grant
filesystem authority or escape the discovered project root.

- `'packages` is the selection: one entry per canonical name, carrying the
  selected version and the URL and hash it was declared with.
- `'requires` is keyed by the **requiring** package — the root under its own
  `'name` — and maps each local alias to an exact `{'package … 'version …}`
  edge. Under minimal version selection every edge agrees with `'packages`.
  Only one selected version of a package is supported in format 1. The root
  always appears; a selected package that requires nothing may be omitted, and
  an absent requirer is the empty edge set, so the visibility that `'requires`
  masks is the package itself alone.
- The version selected for a name is never below a minimum recorded for that
  name. A lock that violates this is malformed.
- Entries in `'packages`, in `'requires`, and in each inner requirement map
  stand in ascending `cmp` order of their name keys.
- Optional `'store` is exactly the symbol `'vendor`. Absence selects the shared
  cache. No URL, absolute path, relative path, or environment variable may
  appear in this field.

The lock is machine-owned, so comments in it are not preserved and its layout
is canonical rather than free: a newline precedes each top-level key and each
entry of `'packages` and `'requires`, everything below an entry stays on one
line, every scalar is in `str`'s canonical spelling, and the text ends with a
newline because a lock is a file. A reader that ignores
whitespace paired with a writer that is layout-exact is what makes the round
trip a fixed point — reading a canonical lock and writing it back reproduces
its bytes — and it keeps one dependency change a one-line diff.

### Runtime lock tier

Ordinary CLI evaluation opts a Session into project discovery from the
process working directory. Embedders do so explicitly with the borrowed
`Host.project_start` capability; its default is absent, so a library Session
never reads ambient project state merely because its caller happens to run
inside an ECL project. With host filesystem access and a start path, Session
initialization walks upward once, stops at the first `ecl.pkg`, and reads only
the sibling `ecl.lock`. No marker, no sibling lock, no host filesystem access,
or no project-start capability means that the lock tier is absent.

The Session owns one immutable result of that discovery for the complete
lifetime of all its Units. A valid format-1 lock becomes an opaque observation
capability carried in inherited context. A malformed or unreadable sibling
lock is also remembered rather than reread: embedded modules remain usable,
and the first non-embedded lookup reports the invalid project lock as a
structured error before consulting `ECL_PATH`.

Cold module resolution has two modes:

1. With no discovered `ecl.pkg`, the embedded standard-library manifest is
   followed by legacy filename lookup on `ECL_PATH`.
2. With a discovered project, the embedded standard library is followed by
   exact lookup in the Session's derived package catalog. `ECL_PATH` is never
   consulted for a manifested project.

A locked selection names the immutable `<name>-<version>-<hex>` directory
below. A cache lock prefixes that key with the environment-selected shared
cache. A vendored lock prefixes it with the fixed `<project-root>/vendor`
directory and does not consult `ECL_CACHE`, `XDG_CACHE_HOME`, or `HOME`.
The catalog supplies the source candidate's exact relative path. A request for
`stats.regressions` may therefore load `src/stats/implementation.ecl`, and the
same artifact may also declare `stats.distributions`.

Catalog ownership is authoritative. A missing store directory reports the
package and tells the user to run `ecl pkg sync`; an unexported module or a
module hidden by the current package's direct-requirement mask is
`'undefined-word`. No failure falls through to `ECL_PATH`. Runtime resolution never
calls HTTP or TLS, fetches or installs an artifact, writes the lock, or admits
an `.eclmod` package candidate. Synchronization remains the only network and
package-mutation boundary.

Runtime lock-resolution diagnostics have exact stable message templates:

- absent selected entry: “locked package `<package>` is missing from the
  package store; run `ecl pkg sync`”;
- cache store unavailable: “locked package `<package>` has no package store;
  set ECL_CACHE, XDG_CACHE_HOME, or HOME before running `ecl pkg sync`”;
- failed selected-entry probe: “cannot inspect locked package `<package>` in
  the package store: `<host-error>`; run `ecl pkg sync`”;
- selected path is not a real directory: “locked package `<package>` is not a
  real package-store directory; run `ecl pkg sync`”;
- source absent within a present selected entry: “locked module `<module>` is
  absent from package `<package>`”.

The package and module placeholders are the canonical names from the validated
lock and the original qualified request. The first four are `'io`; the last
is `'undefined-word`. Invalid lock discovery is also `'io` and prefixes its
owned detail with “invalid project lock `<path>`:”. None falls through to
`ECL_PATH`.

The lock and catalog snapshot is immutable across concurrent Units. Visibility
is lexical: root and package code may resolve their own package plus only the
packages in that consumer's direct lock edges; loading a transitive module into
the shared registry does not grant access to it. `AutoLoadDriver` coordinates
by artifact identity, evaluates one source file once, verifies every cataloged
module registration and its package provenance, and marks the artifact
committed only after all declarations exist. Qualified resolution ignores all
registrations from an uncommitted artifact, so failure cannot expose a partial
multi-module file. Catalog lookup, candidate construction, transfer, and the
post-load registration walk remain poll-budgeted.

### Hashes and the store

A hash is the literal `sha256-` followed by exactly 64 lowercase hex digits.
The store entry for a selection is the directory named
`<name>-<version>-<hex>`, where `<hex>` is those digits without the prefix —
the same `name-version-hash` shape a content-addressed package cache
conventionally uses. A hash mismatch is a hard failure and never a warning: a
moved tag changes the content hash and fails rather than silently changing
what a build means.

The store root is selected from the Session's immutable environment snapshot,
never by reading the ambient process environment during evaluation:

1. a present, nonempty `ECL_CACHE` is the complete store root;
2. otherwise a present, nonempty `XDG_CACHE_HOME` selects
   `$XDG_CACHE_HOME/ecl/pkg`;
3. otherwise a present, nonempty `HOME` selects `$HOME/.cache/ecl/pkg`;
4. if all three are absent or empty, synchronization fails with `'io` before
   creating a path.

An empty variable is treated as absent; it never names the current directory.
Each canonical store-key path is immutable. `pkg.store.present?`
`( destination -- bool )` returns 0 only when the path is absent and 1 only
for a real directory. A symlink, non-directory node, access denial, or other
probe failure is `'io` carrying `'path`. A present entry is read locally and
is never re-fetched or overwritten by sync.

### Vendoring and cache collection

`ecl pkg vendor` requires a discovered project and a valid lock. For each
selection it derives the source root from that lock, streams and rehashes the
entry's reserved `.ecl-package.tgz`, and passes the resulting exact byte list
through the ordinary package installer at
`<project-root>/vendor/<store-key>`. An already-present vendor entry is
verified and never overwritten. Only after every selected vendor entry is
present does the command atomically rewrite the lock with `'store 'vendor`.
Failure preserves the prior lock; a partially completed run may leave valid
immutable vendor entries for the next run to reuse. Repeating the command is
idempotent. A vendored lock makes ordinary resolution and `ecl pkg verify`
independent of the network and shared cache.

`ecl pkg gc <lock-file> [lock-file ...]` requires at least one explicitly
named lock. It parses every file without evaluation, unions their canonical
selected store keys, and invokes `pkg.store.gc` with keys rather than a path.
The builtin derives the shared cache root from the same captured environment
precedence above. It preserves every retained key, symlink, non-directory, and
unknown child name. A real directory whose basename is a canonical store key
and is absent from the union is renamed within the cache to a private
`.ecl-gc-*` name, then walked and deleted one entry per bounded scheduler
advance without following links. Interrupted private names are recognized and
finished by the next collection. The reported count is the number of live
store entries detached during this invocation, not recovered private names.

### Package archives

A package artifact is one gzip-compressed tar byte list whose normalized
members obey M3's archive limits and hostile-input rules plus all of these
package rules:

- exactly one regular file named `ecl.pkg` occurs at the archive root;
- `ecl.pkg` is valid UTF-8 and parses as a format-1 manifest;
- directories and ordinary package-data files are permitted, but links and
  special nodes remain forbidden by the archive contract;
- a file ending in `.eclmod` anywhere is forbidden because v1 packages are
  source-only;
- source files may appear anywhere selected by an export glob; after staging,
  the installer derives the same inert catalog used at Session startup and
  refuses invalid globs, namespace declarations, duplicates, and parse errors
  before publication.

Thus package `foo` may place a module `foo.bar` in `src/internal/one.ecl`, and
one source artifact may declare several owned modules. Installation parses but
never evaluates either the manifest or package source.

`pkg.store.inspect` `( bytes package-name -- manifest-text )` performs the
complete bounded gzip/tar and package-layout scan without creating a
destination. It returns the sole root manifest's exact UTF-8 text. The caller
parses that text with `pkg.manifest.read` and checks its exact name/version
identity before any installation.

`pkg.store.install`
`( bytes package-name destination -- regular-file-paths )` repeats the same
archive and package-policy validation at the mutation sink, then extracts to a
unique sibling staging directory and publishes only by an absent-destination
rename. It returns normalized regular-file paths only after commit. The
destination is never overwritten or merged. Concurrent installers may both
stage, but at most one publishes. Both the pre-flight and commit conflict
return `'io` with `'destination-exists 1` in error data; a caller may re-run
`present?` and accept the immutable winner only for that condition. Cancellation,
allocation failure, malformed input, and filesystem failure remove private
staging and expose no partial destination.

`pkg.store.verify` `( destination package-name hash -- )` streams the reserved
archive seal and requires its SHA-256 to equal the lock hash.
`pkg.store.read-seal` `( destination package-name hash -- bytes )` performs
the identical package-named verification and then materializes the exact seal
as an ordinary integer byte list. It is the only filesystem-to-archive-byte
bridge and exists so vendoring can reuse `pkg.store.install`; it cannot read an
arbitrary file beneath the entry.

`pkg.store.write-lock` `( text path -- )` writes through a unique sibling
temporary file and replaces the named regular file with one same-parent atomic
rename. Encoding and writes are bounded scheduler work. On cancellation,
allocation failure, or filesystem failure the temporary is removed and an
existing lock remains byte-for-byte unchanged; when no lock existed, none is
published. A symlink or non-regular existing target is refused rather than
followed.

`pkg.store.write-new` `( text path -- )` uses the same bounded temporary-file
protocol but publishes with a non-replacing same-parent rename. It is the
manifest-creation boundary: a destination created after the initial probe wins
the race, the temporary is retired, and the existing bytes are untouched. Its
diagnostics name the supplied project-file path rather than assuming a
particular filename.

The eight `pkg.store` words documented here are the complete package
filesystem authority. ECL receives no generic recursive-delete, copy, rename,
or caller-rooted garbage-collection word as a side effect of package support.

### Synchronization

`pkg.sync.run` `( root-manifest project-root -- lock )` validates its root and
uses `project-root` only to place `ecl.lock`; walking upward to discover the
root belongs to the CLI layer. It executes two deterministic passes.

The discovery pass walks exact `(name, version)` requirements in canonical
order and builds the complete catalog required by `pkg.mvs.resolve`. For each
node it derives the store key from the declaration's name, version, and hash:

- when that exact entry is present, it reads `<entry>/ecl.pkg`, validates the
  manifest, and requires its name and version to equal the requested node;
- otherwise it calls `http.get-bytes`, requires status in `200..299`, computes
  `sha256-` plus `archive.sha256` of the returned body, and compares that value
  with the declaration **before** calling `pkg.store.inspect`;
- after a matching hash, it inspects and parses the archive manifest, requires
  exact name/version identity, inserts the exact node into the catalog, and
  traverses its requirements.

A non-success HTTP response is `'io` carrying `'package`, `'url`, and
`'status`. A hash mismatch is `'domain` carrying `'package`,
`'declared-hash`, and `'actual-hash`. A manifest identity mismatch is
`'domain` carrying the requested and actual names and versions. Archive-policy
errors additionally carry the package and offending member when one exists.
None of these discovery failures calls install or lock publication.

After `pkg.mvs.resolve` returns a validated lock, the installation pass visits
the selected package names in canonical order. It skips a present entry.
Every missing selection is fetched again, status-checked, hashed, inspected,
identity-checked, and passed to `pkg.store.install`; the repeated verification
keeps the publication sink independent of discovery state. A racing
destination-exists result is success only when `present?` immediately confirms
a real immutable directory.

The two passes are deliberate. MVS needs manifests from reachable exact
versions it may not select, while the store contains only selected versions.
Re-fetching a selected cold artifact bounds retained archive memory to one
body and avoids adding a temporary spool plus deletion authority. On a later
sync every exact node already present is read locally and never re-fetched,
but an absent reachable candidate that remains unselected may be fetched again
because its manifest can still contribute graph edges. Fully offline
resolution is the separate `sync --offline` contract.

Before discovery, sync reads only `<project-root>/ecl.lock`, where
`project-root` is its explicit argument. A valid vendored lock selects that
same project's fixed `vendor` store and retains `'store 'vendor` on the
resolved lock. An absent or invalid current lock selects cache mode, preserving
sync as the supported way to regenerate corrupt lock bytes. Ambient Session
project discovery never selects the synchronization target or its mode.

Only after every selected entry is present does sync render the lock once with
`pkg.lock.write` and call `pkg.store.write-lock` for
`<project-root>/ecl.lock`. It then returns the validated lock value. Deleting
that lock and running sync against unchanged inputs reproduces its bytes.
Failure preserves a prior lock and publishes no new lock. Verified immutable
entries successfully installed before a later failure may remain: the lock is
the project transaction boundary, while content-addressed cache population is
safe and reusable.

### Package CLI

`ecl pkg` is a fixed CLI dispatcher over the ordinary `pkg.*` modules. It does
not parse manifests, resolve graphs, hash archives, or render locks in Zig.
Every command other than `init` uses the same upward `ecl.pkg` discovery seam
as Session startup. `init` acts only on the working directory and refuses to
replace an existing manifest.

- `init [name]` derives the package name from the working-directory basename
  when omitted, accepts an explicit canonical override, and atomically creates
  a format-1 manifest at version `0.1.0` without replacing a racing file. An
  invalid name diagnostic carries both the attempted name and project path and
  explains the override form.
- `add <name> <version> <url>` downloads and validates that exact package,
  derives its `sha256-` declaration, and raises the root minimum to the given
  version through an atomic manifest replacement. The manifest dictionary's
  insertion order is retained. Comments cannot survive a rewrite because
  `pkg.manifest.read` deliberately returns inert values rather than a concrete
  syntax tree.
- `sync` performs ordinary synchronization. `sync --offline` discovers every
  exact manifest from immutable store entries and never opens a network
  request; an absent entry is an error naming the package.
- `tree` prints the lock root followed by dependency edges ordered first by
  requirer and then by required package. `why <module>` applies the same
  package-prefix ownership rule as runtime lookup and prints one deterministic
  root-to-owner path.
- `verify` streams the sealed archive retained inside every selected immutable
  store entry and compares its SHA-256 with the lock declaration. It never
  reaches the network. Missing seals and mismatches identify the package.

Successful command output is stable, line-oriented text. Usage failures are
ordinary CLI diagnostics; package and I/O failures remain structured ECL error
values rendered by the existing process boundary.

## The ecl command

```
ecl                      REPL on a terminal; otherwise read stdin as one unit
ecl -e <SOURCE> [ARGS…]  evaluate source, print the final stack
ecl <FILE> [ARGS…]       run a script file
ecl <SOURCE> [ARGS…]     evaluate source when the argument is not a readable
                         file (a missing file ending in .ecl is an error
                         instead), print the final stack
ecl - [ARGS…]            read stdin as one unit
ecl fmt <FILE|->         format source to stdout
ecl fmt -w <FILE>        format and atomically rewrite a regular file
ecl -h | --help          usage
ecl -V | --version       version
```

Trailing arguments are exposed to the program by `args`. Exit status: `0`
on success; the status passed to `exit`; `1` when the unit fails (the
error dict is printed to stderr); `2` on out-of-memory.

Environment variables: `ECL_PATH` is the module search path (see Modules).
`ECL_WORKERS` sets the worker count (a positive integer; default is the
CPU count). `ECL_NATIVE_DIAGNOSTICS`, when set, enables native-module
loading diagnostics.

The REPL reads one unit per logical line, continuing while a delimiter or
string is open. Ctrl-C discards the pending unit; Ctrl-D at an empty
prompt exits (and mid-continuation submits the pending unit, whose
incompleteness is then an error). Completion is available. History is kept
in `~/.ecl_history` — the last 100 single-line, valid-UTF-8 entries,
merged across concurrent sessions; history failures degrade to a warning,
never disable the editor.

## Source formatting

`ecl fmt` reads valid source without evaluating it and writes canonical
source. Formatting is idempotent, preserves program structure and every
ordinary literal value byte-for-byte, and never applies layout rules based
on a form's first word. `-w` formats completely before touching the source,
preserves its permissions, and publishes with a same-directory atomic replace;
it refuses standard input, symlinks, and non-regular files. Specifics:

- Space-separated items pack into locally grouped runs up to 100 columns;
  continuation lines begin immediately inside the opening delimiter.
  A closing delimiter on its own line aligns with its opener. Existing
  physical newlines remain hard boundaries. A comment or multiline child
  breaks only its local run. An indivisible token or preserved comment may
  exceed the target width.
- Comments are preserved and force physical line boundaries while staying
  attached to their neighboring forms.
- Strings are indivisible and byte-preserved, with one exception: the
  docstring of a structurally recognized definition annotation immediately
  preceding a body and `'name def`/`defp` is refilled paragraph-aware (semantics
  unchanged — `doc` canonicalization already ignores soft wrapping).
- Every structurally literal definition block is introduced by a navigation
  comment: `### def <name>` for `def`/`set`, and `### defp <name>` for
  `defp`/`setp`. It is preceded by exactly one empty line (omitted at the start
  of a file or container).
  Existing `# def`/`### def`/`# defp`/`### defp` comments are canonicalized
  from the structural terminator rather than trusted; recognition is purely
  structural — never evaluation — and is disabled for words directly
  contained by dict literals.
