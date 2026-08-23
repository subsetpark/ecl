# Workstream: First-Party Package Manager

## Vision

`ecl` gains first-party dependency management: a project declares its
dependencies in an inert data manifest, a resolver derives a lock from that
manifest by minimal version selection, and the interpreter resolves module
names through the lock before it ever touches a search path. Importing stays
by name — `'foo.bar.word 'word import` never mentions a file, a URL, or a version — and a
checkout plus a lock reproduces the same module images on any machine. The
resolver is written in ECL and ships embedded in the binary, so the language's
first substantial first-party program is written in itself and there is no
second tool to install.

## Current State

Verified in the checkout (2026-08-23, `0.1.0` tagged 2026-08-19, the v1
workstream terminal).

- **The format, resolution, binary archive, and package-sync layers now exist,
  but no runtime lock tier does.** M1 added inert manifest/lock values and
  version ordering; M2 added the pure MVS resolver; M3 added exact byte lists,
  SHA-256, and hostile-input-safe atomic tgz extraction; M4 added exact-byte
  HTTPS fetching, immutable package-store publication, and canonical atomic
  lock writes. Project-file discovery, CLI mutation, and runtime module lookup
  remain later milestones.
- **Module resolution today is embedded manifest, then `ECL_PATH`.**
  `AutoLoadDriver` (`src/machine.zig:2366`) is a poll-budgeted state machine
  with phases `begin → registered → filename → component_start →
  component_end → candidate → access → path_value → transfer`. At
  `src/machine.zig:2565` — after the loading lease is granted and after the
  recheck for a racing winner — it calls `stdlib.find` and only then falls
  through to `beginFilename`. That fall-through is the single insertion point
  for a lock tier; no other resolution path exists.
- **`src/stdlib.zig` is already the table shape the lock needs.** It is a
  comptime array of `{name, entry}` with `find(name) ?Entry` and three
  transport arms — `source` (embedded text plus a provenance name), `native`
  (`*const abi.Descriptor`), `builtin` (`[]const env.BuiltinWord`).
  Embedded module names are validated segment by segment at comptime, so
  ordinary dotted modules such as `pkg.version` and `pkg.mvs` use the same
  flat registry as path-loaded modules. `ECL_PATH` still maps `core.utils` to
  the flat filename `core.utils.ecl`; it does not imply directory nesting.
- **`ecl_path` and `host_io` ride on `unit.inherited`** (`src/machine.zig:1088`,
  threaded from `src/session.zig:52` and owned at `:276`). A lock table
  attaches at exactly the same place, and the existing
  `host_io == null or ecl_path == null` bail already establishes the pattern
  for "this tier is unavailable, skip it."
- **A subcommand precedent exists.** `src/main.zig:56` dispatches `ecl fmt`
  ahead of the flag handling; `ecl pkg …` slots into the same position.
- **The client's remaining raw materials are embedded.** `http` supplies
  `get`/`post` over TLS with transparent gzip/zstd decoding but materializes
  every response body as text (`src/stdlib/http.zig`); M4 needs a parallel
  exact-byte body word. `io` supplies `slurp`/`spit` (`src/stdlib/io.zig`),
  `parse` reifies the reader as a value, and `json` and `csv` demonstrate both
  the builtin-words and native-descriptor arms.
- **M3 now supplies the binary host boundary.** `archive.sha256` consumes the
  exact integer byte list, while `archive.unpack-tgz` performs bounded hostile-
  input validation, staging, rollback, and absent-destination publication.
  M4 must extend that scanner with package policy at the publication sink;
  validating returned paths after `unpack-tgz` would be too late.
- **`test/http_fixture_server.zig` is plaintext and cannot prove M4's HTTPS
  contract.** M4 adds `test/pkg_https_fixture.py`, a loopback TLS fixture with
  checked-in test trust and deterministic package graph generation. CI still
  uses no public network.
- **The target design is already in the repo.** `build.zig.zon` pins each
  dependency as a tarball URL plus a content hash with no registry, and
  `zig-pkg/` is a content-addressed store keyed `name-version-hash`. This
  workstream mirrors that shape for ECL modules.
- **Two reader facts constrain the version format, verified against
  `./zig-out/bin/ecl` during M1 planning (2026-08-21).** `"1.2.3" parse first
  type` is `'word`: a bare dotted version reads as an *executable reference*,
  so a version is always a **string** and an unquoted version is malformed by
  construction rather than by rule. And `"01" parse first` is `1`: a
  `parse`-based field reader silently admits the leading zeros semver §9
  forbids, giving one version two spellings and breaking the total order, so
  numeric fields must be classified digit by digit. Both facts bind M2's
  resolver and M6's `add` as much as M1.

## Key Challenges

- **The lock tier lands in the hot resolution path.** `AutoLoadDriver` is
  budgeted (`kernel_poll_quantum`), allocates through `heap.Owned`, and
  interacts with the registry's loading-lease and contention protocol. A new
  tier must not introduce blocking IO, must preserve the racing-winner
  recheck, and must leave behavior byte-identical when no lock is present.
  Module-load timing changes are exactly the class of change that only
  ThreadSanitizer catches.
- **Longest-prefix match over dotted names is new work.** Package `foo` owns
  `foo.*`, so the lock maps a *prefix* to a store root and the tier must
  select the longest matching prefix for a requested dotted name. The
  existing search-path code does whole-name filename construction and has no
  prefix logic to reuse.
- **Writing the resolver in ECL is the workstream's real bet.** MVS is graph
  work over data literals and is well within the language, but this is the
  first program of its size written in ECL and it will surface missing
  vocabulary. That discovery is a deliverable, not an accident — but it means
  milestone estimates for the ECL-side milestones are softer than the Zig ones.
- **Error quality.** A resolver written in ECL reports failures through ECL's
  error vocabulary. "No version of `foo` satisfies both `bar`'s `>= 1.2` and
  `baz`'s `>= 2.0`" has to be constructed deliberately; nothing produces it
  for free.
- **Version ordering is a specification, not a detail.** MVS needs a total
  order on versions to take a maximum. Semver's prerelease ordering rules are
  subtle and must be pinned in SPEC.md before the resolver is written.
- **Package code must retain ordinary module semantics.** M2 relaxed the old
  single-atom embedded-name check and split the pure vocabulary into dotted
  `pkg.*` modules. Later host-backed capabilities may use their own modules,
  but the host must not concatenate ECL fragments, synthesize a facade, or
  grant private cross-module access.

## Established Precedents

- **[algorithm] Minimal Version Selection** — https://research.swtch.com/vgo-mvs
  Russ Cox's algorithm as shipped in Go modules. Each requirement declares a
  *minimum*; the build list is the maximum of the minimums reached over the
  module graph. No backtracking, no SAT, no NP-hard tail, and the result is a
  pure function of the graph — recomputable rather than merely replayable.
  Read the "algorithm 1/2/3" progression: this workstream implements
  algorithm 1 (construct the build list) plus `ecl pkg add` as algorithm 3
  (upgrade one module). Its central property — resolution never consults a
  list of *available* versions, only *declared* ones — is what makes a
  registry unnecessary rather than merely deferred.

- **[documentation] Go modules reference: go.mod and go.sum** — https://go.dev/ref/mod
  The separation this workstream copies: the manifest records requirements,
  the lock records the resolved graph, and a third artifact records content
  hashes for integrity. Also the source of the `-mod=readonly` default —
  ordinary evaluation never mutates the lock or reaches the network.

- **[rfc-spec] Semantic Versioning 2.0.0** — https://semver.org
  The version grammar and, specifically, §11's precedence rules including
  prerelease ordering. MVS requires a total order; this is the total order.
  Build metadata is excluded from the grammar rather than parsed-and-ignored.

- **[documentation] Zig `build.zig.zon` package management** — https://ziglang.org/documentation/0.16.0/#Package-Management
  Already in use in this repo. The shape being mirrored: dependency = tarball
  URL + content hash, no registry, a content-addressed store keyed
  `name-version-hash`, and a hash mismatch as a hard failure. `zig-pkg/` in
  this checkout is the working reference for the store layout.

- **[pattern] Write-then-rename atomic publication** — stage a complete value
  under a unique sibling name, close and validate it, then expose it with one
  same-parent rename. M3 applies this to archive extraction so no store
  destination is partly visible; M4 retains the absent-destination and
  immutable-entry rule when several fetches race for one content key.

- **[pattern] Janet's `bundle/` and `spork/pm` layering** — https://janet-lang.org/api/bundle.html
  Janet's core `bundle/` module is explicitly "a package manager without
  networking, letting package managers built on top handle user workflows."
  The core binary owns install, manifest, and uninstall; a separate library
  (`spork/pm`) owns fetching, git/tarball transports, transitive recursion,
  and the lockfile. This workstream adopts the same layer boundary — the
  runtime consumes a lock and does nothing else; resolution and fetching live
  above it — while collapsing the *distribution* split, because Janet's
  four-tool ecosystem is the cautionary half (see Decisions Made).

- **[pattern] Inert data manifest, separate build program** — https://articles.inqk.net/2025/09/15/janet-bundles.html
  Janet's modern bundles split `info.jdn` (parsed, never evaluated) from
  `bundle/init.janet` (a program with install hooks), after finding a purely
  declarative `project.janet` could not express Rust/Zig/custom-compiler
  builds. The split is the lesson: keep the dependency manifest inert so
  resolution can never execute code, and give build logic its own explicitly
  trusted file if and when native packages land.

- **[documentation] JSR: scopes, provenance, no install scripts** — https://jsr.io/docs
  The two properties adopted here without the registry: a package may only
  publish under a namespace it owns, and installing a package never executes
  code from it. Prefix ownership (`foo` owns `foo.*`) is how the first
  property is enforced with no registry to police it.

## Milestones

### Milestone 1: pkg-manifest-and-lock-format

**Definition of Done**:
- SPEC.md gains a Packages section specifying: the `ecl.pkg` manifest grammar,
  the `ecl.lock` grammar, the version grammar and total order (semver 2.0.0
  precedence, build metadata excluded from the grammar), the canonical module
  name prefix rule (package `foo` owns exactly `foo` and `foo.*`), and the
  hash spelling (`sha256-` prefix, lowercase hex).
- Both files are ECL data literals — nested dicts and lists of scalars — read
  with `parse` and **never evaluated**. A manifest containing a quotation, a
  word reference, or any non-literal form is rejected by validation, not run.
- Five ordinary embedded stdlib modules under `src/stdlib/pkg/` are registered
  separately through the `source` arm: `pkg.version`, `pkg.name`, `pkg.data`,
  `pkg.manifest`, and `pkg.lock`. They export pure format and validation words,
  including `pkg.manifest.read`, `pkg.lock.read`, `pkg.lock.write`,
  `pkg.version.less?`, `pkg.version.max`, `pkg.manifest.validate`, and
  `pkg.name.owns?`. There is no synthetic root `pkg` facade. No word reaches
  the network or filesystem.
  **The three reading and writing words take and return text, not paths** —
  slurping a file and discovering it belong to M6 — and the lock validator
  they share is `pkg.lock.validate`; cross-module helpers are ordinary public
  ECL words because the modules have no privileged friendship relation.
- **The lock is structurally per-package from this first version**: its
  entries key requirements by the *requiring* package, even though MVS makes
  every map identical today. This is the recorded retrofit door for admitting
  two versions of one name later without a breaking format change.
- Round-trip property tests: `pkg.lock.write` of `pkg.lock.read` is
  byte-identical; `pkg.version.less?` is a total order over a generated
  version corpus.
- **The canonical lock layout is pinned in SPEC.md**, because it is what
  byte-identical means: a newline before each top-level key and before each
  `'packages` / `'requires` entry, entries in ascending `cmp` order of their
  name keys, every scalar in `str`'s canonical spelling. A layout-insensitive
  reader (`parse` ignores whitespace) plus a layout-exact writer is what makes
  the round trip a fixed point, and it keeps one dependency change a one-line
  diff.
- **Two clauses pulled forward from later milestones, deliberately.** SPEC.md
  also pins the **store-key derivation** (`<name>-<version>-<64 lowercase hex
  digits>`, mirroring `zig-pkg/`), because M4 creates those directories and M5
  resolves through them *in parallel* and would otherwise each invent a
  spelling. And `pkg.lock.read` enforces the lock's **internal consistency** —
  no selection below a minimum recorded for it — so M5's tier can trust the
  file it reads.

**Why this is a safe pause point**: The focused `pkg.*` modules manipulate
data through ordinary ECL module semantics; no resolution path, CLI surface,
or IO behavior is touched.
The binary behaves identically for every program that does not reference or
import a `pkg` word.

**Unlocks**: The resolver (M2) and the lock tier (M5) can both be written
against a fixed format, in parallel.

**Open Questions**: None. Manifest discovery was settled during planning —
walk up from the working directory (see Decisions Made).

**Status**: Executed, 2026-08-21. Four patches landed in the planned order:
`36e662f` pins the format, `9c60195` registers the selected proof surface,
`42b7b83` adds the embedded module and version ordering, and `176736f` adds
manifest/lock validation and canonical lock writing. The later checkpointed-
guard and explicit-import migrations preserve those contracts and keep every
checked-in pkg predicate and example on the current vocabulary. The complete
plan and proof ledger are in `gameplans/pkg-manifest-and-lock-format.json`.

---

### Milestone 2: pkg-mvs-resolver

**Definition of Done**:
- `pkg.mvs.resolve` in `src/stdlib/pkg/mvs.ecl`: a pure function from a root manifest
  plus a dict of already-read dependency manifests to either a lock value or
  a structured error. No IO of any kind.
- Implements MVS algorithm 1: walk the requirement graph, take the maximum of
  declared minimums per canonical package name, one selected version per name.
- Structured, specific failures — each carrying the packages responsible:
  **hash conflict** (two manifests declare the same name and version with
  different hashes), **prefix collision** (two distinct packages claim
  overlapping module prefixes), **requirement cycle**, **malformed version**,
  **missing manifest** for a declared requirement.
- Property tests: resolution is deterministic and order-independent over
  shuffled graph inputs; the selected version for every name is `>=` every
  declared minimum for that name; adding a requirement already satisfied
  changes nothing.

**Why this is a safe pause point**: `pkg.mvs.resolve` is a pure function over
data. It is callable and testable from an ordinary script, and nothing in the
interpreter consults it yet.

**Unlocks**: The fetcher (M4), which needs a resolution before it knows what
to download.

**Established Precedents** (milestone-scoped):
- **[algorithm] Minimal Version Selection** — https://research.swtch.com/vgo-mvs — This milestone *is* the algorithm; the workstream-level entry applies here in full and the "algorithm 1" section is the direct implementation reference.

**Status**: Executed on `zax--pkg-mvs-resolver`, 2026-08-22. Commits
`4243885`, `6c585c9`, and `de3ceaf` pinned the resolver contract, added its
pending public cases, then implemented `pkg.mvs.resolve` while splitting the
package vocabulary into six ordinary dotted ECL modules. The final working
tree passed `zig build precommit` and the Linux/x86_64 TSan gate locally;
SourceHut build 1869043 then passed the complete CI matrix. M2 required no
operator action before M3.

---

### Milestone 3: pkg-host-primitives

**Definition of Done**:
- A new embedded builtin module `archive` in `src/stdlib.zig` (single atom,
  `builtin` arm, modelled on `src/stdlib/io.zig`) exporting:
  `archive.sha256` (`byte-list -- lowercase-hex`) and
  `archive.unpack-tgz` (`byte-list destination -- regular-file-paths`). A
  byte list is an ordinary ECL list whose items are integers in `0..255`;
  strings are not accepted or coerced because Unicode string ingress cannot
  preserve every possible archive byte spelling. All-byte integer lists use a
  packed one-byte leaf automatically, without introducing a distinct ECL value
  kind; widening remains transparent when a later mutation adds another int.
- `unpack-tgz` **fails closed on hostile archives**: absolute member paths,
  `..` traversal, duplicate members, symlinks, hardlinks, character/block
  devices, FIFOs, malformed gzip/tar/PAX data, invalid UTF-8 member names, and
  members resolving outside the destination root are rejected with a precise
  error. Extraction accepts at most 1 GiB (1,073,741,824 bytes) of total
  uncompressed tar data and 100,000 regular-file/directory members.
- The destination must be absent. Extraction creates a unique sibling
  `.ecl-unpack-*` staging directory, writes and rolls back through bounded
  scheduler phases, and publishes the complete tree with one same-parent
  rename. It never calls whole-input `std.tar.extract` or recursive
  `std.Io.Dir.deleteTree` from a scheduler turn. Failure or cancellation never
  exposes a partial destination; concurrent calls can have at most one
  successful commit. Success returns normalized regular-file paths in archive
  order.
- Every word carries nonempty reflective documentation including its stack
  shape, matching the builtin-module contract enforced in `src/stdlib.zig`.
  The driver-backed words omit an enforceable binding effect: builtin effect
  checks run when the primitive returns, before a scheduled driver has
  produced its output.
- Tests include known-answer vectors for SHA-256 and a checked-in corpus of
  valid and malicious tarballs. Public Session cases cover byte fidelity,
  exact failures, filesystem containment, absent/existing destinations,
  concurrent commit, cancellation, host-IO refusal, reflection, and
  initialized-Session allocation failure.

**Why this is a safe pause point**: Two new words in a new embedded module,
depended on by nothing. Existing programs are unaffected.

**Unlocks**: The fetcher (M4). Independent of M1 and M2, so it can run in
parallel with them.

**Status**: Implemented, 2026-08-22. Commits `879f425`, `e73a8e7`, and
`e7ebc59` froze the contract, added the pending fixture-backed proof surface,
then added the invisible U8 leaf, representation-independent byte view,
builtin archive module, bounded hashing/extraction/rollback drivers, and
activated public cases. `zig build precommit` and the Linux/x86_64 Alpine TSan
gate pass locally. SourceHut builds 1869270 (`e7ebc59`) and 1869282 (`754c62b`)
exposed a stale differential assertion that compared the invisible
`.leaf_i64`/`.leaf_u8` storage choice. Commit `808f92b` made that proof
representation-independent, and SourceHut build 1869313 passed the complete
matrix. M3's execution prerequisite for M4 is satisfied.

---

### Milestone 4: pkg-fetch-and-store

**Definition of Done**:
- `pkg.sync.run` in `src/stdlib/pkg/sync.ecl` has effect
  `(root-manifest project-root -- lock)`: read transitive manifests, resolve via
  `pkg.mvs.resolve`, fetch every selected package that is not already in the
  store, atomically write `<project-root>/ecl.lock`, and return the validated
  lock value. M6 owns walking upward to discover the root manifest and passes
  the already-known project root here.
- Fetch is tarball-over-HTTPS only, via the existing `http` module. Each
  downloaded archive is hashed with `archive.sha256` and compared against the
  declared hash **before** it is unpacked; a mismatch aborts the whole sync
  and writes no new lock while preserving an existing lock.
- M4 adds a raw HTTP response-body surface that materializes received octets
  directly as M3's integer byte list. The existing textual `http.get` body
  remains a string for compatibility; a tarball must never pass through that
  Unicode conversion before hashing or unpacking. The word is
  `http.get-bytes (url headers -- response)`: status, headers, redirects, and
  content decoding match `http.get`, while only `'body` changes to the exact
  integer byte list.
- `Session.Host` gains an optional nominal TLS trust override containing an
  absolute CA-file path and fixed verification timestamp. Tests use it with a
  checked-in fixture CA so HTTPS acceptance reads neither the public network
  nor the wall clock; a null override preserves production system trust and
  current-time verification.
- The store is content-addressed at `$ECL_CACHE` (default
  `$XDG_CACHE_HOME/ecl/pkg`, then `~/.cache/ecl/pkg`), one directory per
  entry keyed `<name>-<version>-<hash>`, mirroring `zig-pkg/`. Store entries
  are treated as immutable: an existing directory whose name matches is used
  as-is and never re-fetched, but its root manifest is parsed and checked
  against the requested exact name/version.
- A package's manifest is read from its own tarball, so transitive
  requirements are discovered during the fetch walk rather than declared by
  the root.
- Discovery and installation are deliberately two passes. The first pass
  fetches, hashes, and inspects one exact reachable archive at a time to build
  the complete MVS catalog without publishing it. After resolution, the
  second pass re-fetches and installs only selected missing archives. The
  duplicate cold download keeps retained memory to one archive, requires no
  temporary-spool deletion authority, and ensures unselected candidates never
  become store entries.
- A narrow builtin `pkg.store` capability owns `inspect`, `install`,
  `present?`, and `write-lock`. `inspect` and `install` both require exactly
  one root `ecl.pkg`, regular source-only flat files, and package-prefix
  ownership. `pkg.sync` parses the inspected manifest through the existing
  `pkg.manifest` authority and checks exact name/version identity before
  install. `install` repeats archive-layout and prefix validation at the
  mutation sink and publishes an absent immutable entry atomically;
  `write-lock` uses atomic sibling replacement and preserves a prior lock on
  failure. Generic recursive deletion or rename authority is not exposed to
  ECL.
- **Prefix ownership is enforced before publication**: a package `foo` whose
  tarball contains a module file outside `foo.ecl` / `foo.*.ecl` fails the
  sync and retains no `foo` entry or new lock.
- Acceptance runs against `test/pkg_https_fixture.py`, a loopback Python TLS
  server using checked-in fixture-only credentials and deterministic tarballs
  generated after binding its dynamic port. Python 3 is installed by the
  SourceHut build; no CI test reaches the public network.

**Why this is a safe pause point**: `pkg.sync.run` is callable from a script and
produces a real store and a real lock, but nothing reads the lock yet — the
interpreter still resolves through the embedded manifest and `ECL_PATH`
exactly as before. A user who runs it has downloaded files and gained a lock
file, and lost nothing.

**Unlocks**: Real end-to-end verification of the lock tier (M5) against
genuinely fetched packages.

**Status**: Executed, 2026-08-23. The five planned patches landed as
`e964616`, `be50981`, `12f9814`, `afac073`, and `a9318d5`; SourceHut build
1869377 passed the complete matrix, including acceptance and TSan. The plan,
formal per-patch specifications, dependency graph, exact public-test ledger,
and reachability proofs remain in `gameplans/pkg-fetch-and-store.json`.

The live-network operator acceptance passed on 2026-08-23 against the public
source-only package at
`https://github.com/subsetpark/ecl-pkg-smoke/releases/download/v1.0.0/smoke-1.0.0.tgz`
(`sha256-315c772a16778673e205ae556185d25b4109ad40641e60e6b5d96d1f7db99745`).
Production system trust and current-time verification followed GitHub's 302
redirect to its release-asset host. A cold `pkg.sync.run` published exactly
`smoke-1.0.0-315c772a16778673e205ae556185d25b4109ad40641e60e6b5d96d1f7db99745`
and a canonical lock; a warm run produced byte-identical output without
changing the immutable entry. The downloaded bytes independently matched the
declared hash. No TLS, redirect, or content-encoding fixture gap surfaced, so
M5 is unblocked.

---

### Milestone 5: pkg-lock-tier

**Definition of Done**:
- `AutoLoadDriver` consults a lock table between the `stdlib.find` check
  (`src/machine.zig:2565`) and `beginFilename`. Tier order is embedded
  manifest → lock → `ECL_PATH`.
- Lookup is **longest-prefix match** on the requested dotted module name
  against the lock's package prefixes; the winning entry names a store
  directory, and the module file within it is the requested module's full
  canonical name plus `.ecl`. This matches M4's root-level archive contract:
  package `foo` publishes `foo.bar.ecl`, never `bar.ecl`.
- The lock is read once at session initialization from the `ecl.lock` beside
  the discovered `ecl.pkg` — **not** from the working directory; the discovery
  walk settled in M1 means initialization pays O(directory depth) stats rather
  than one. It is carried on `unit.inherited` alongside `ecl_path`, following
  the same optional-and-skippable pattern (`src/machine.zig:1088`,
  `src/session.zig:52`). No `ecl.pkg` anywhere up the chain, no lock file, or
  no `host_io` means the tier is absent and resolution is byte-identical to
  today.
- Resolution **never reaches the network and never mutates the lock**. A
  module named in the lock whose store directory is missing is a precise
  error naming the package and telling the user to run `ecl pkg sync` — it is
  not an implicit fetch.
- The racing-winner recheck, the loading lease, the cycle detection, and the
  poll budget are all preserved; the new phase allocates through `heap.Owned`
  like its neighbours.
- `zig build test-tsan` is green, and the existing module-load and
  stateful-module suites are extended to cover the new tier.

**Status**: Executed, 2026-08-23. The atomic three-patch implementation plan,
formal per-patch specifications, exact ten-test ledger, dependency graph, and
runtime reachability proofs are in `gameplans/pkg-lock-tier.json`. All ten
public behavior cases were proven fail-first and enabled. `zig build
precommit`, `test-e2e`, `test-workers`, and the CI-matching Linux/x86_64
`test-tsan` gate pass. The exhaustive allocation sweep found and fixed an M5
snapshot leak; it then reached the checkout's two existing release-candidate
OOM failures, both reproduced from untouched `HEAD`, so they are not recorded
as M5 regressions or successes.

**Why this is a safe pause point**: The tier is inert without a lock file, so
every existing program, test, and CLI transcript behaves exactly as before.
With a lock file it resolves locked modules by name. Either state is
coherent.

**Unlocks**: The CLI (M6) — with the tier in place, `ecl pkg sync` followed by
an ordinary `ecl script.ecl` is the whole user story.

**Operator Actions Before Next Milestone**: None. The required Linux/x86_64
TSan acceptance is green; no loading-lease or registry-publication finding
blocks M6.

---

### Milestone 6: pkg-cli

**Definition of Done**:
- `ecl pkg <subcommand>` dispatched at `src/main.zig:56` alongside `ecl fmt`,
  delegating to the ordinary `pkg.*` modules rather than reimplementing logic
  in Zig. Subcommands: `init`, `add <name> <version> <url>`, `sync`, `tree`,
  `why <module>`, `verify`.
- `add` performs MVS algorithm 3 — raise one requirement to a new minimum,
  leave every other selection alone — and rewrites `ecl.pkg` preserving the
  author's ordering and comments where the format permits.
- `verify` rehashes every store entry named by the lock and reports any
  mismatch without touching the network.
- `sync --offline` resolves and writes a lock from the store alone, failing if
  any selected package is absent rather than fetching.
- **There is deliberately no `upgrade` subcommand.** Under MVS with no
  registry there is no enumeration source for "newer versions," and upgrades
  are manifest edits by construction. `ecl pkg add` at a higher version is the
  upgrade path.
- CLI behavior is covered by the `ohsnap` transcript gate in `test/e2e.zig`
  with exact exit status, stdout, and stderr.

**Why this is a safe pause point**: This is the complete user-facing tool. A
user can initialize a project, add a dependency, sync, and run code that
imports it by name.

**Unlocks**: Dogfooding, and the documentation and hardening pass.

**Operator Actions Before Next Milestone**:
1. Convert one real ECL project to `ecl.pkg`/`ecl.lock` and use it for at
   least a week of ordinary work. Watch for: resolution errors that fail to
   name the responsible package, store entries that grow without bound,
   lock churn on unrelated commits.
2. **Decision, with criteria**: M7's error-catalogue scope is set by what this
   soak actually produced. Every resolution failure encountered during the
   week that did not name both the responsible package and the conflicting
   requirement becomes a required M7 fix.

---

### Milestone 7: pkg-integrity-and-documentation

**Definition of Done**:
- SPEC.md documents the complete `pkg` and `archive` vocabularies, the tier
  order, and every resolution error with its exact spelling.
- `design/workstream-v1.md` follow-up 12 is updated to record what shipped and
  what remains deferred (native packages, target selection).
- `ecl pkg vendor` copies the resolved store entries into a project-local
  directory and rewrites the lock to reference it, so a repository can be made
  network-independent.
- Store garbage collection: `ecl pkg gc` removes store entries not referenced
  by a named set of lock files.
- Every error identified by the M6 soak names both the responsible package and
  the conflicting requirement.

**Why this is a safe pause point**: Terminal. The workstream's promised
capability is complete and documented.

**Unlocks**: A future native-package workstream, which inherits the lock
format's per-package structure and the tier's insertion point unchanged.

## Dependency Graph

```text
1 (pkg-manifest-and-lock-format) → []
2 (pkg-mvs-resolver)             → [1]
3 (pkg-host-primitives)          → []
4 (pkg-fetch-and-store)          → [2, 3]
5 (pkg-lock-tier)                → [1]
6 (pkg-cli)                      → [4, 5]
7 (pkg-integrity-and-documentation) → [6]
```

M1 and M3 are independent in the dependency graph. M5 needs only the format, so
the Zig-side lock tier proceeds in parallel with the ECL-side resolver and
fetcher. M6 is the join.

## Open Questions

- **Store sharing and lifetime across projects.** The store is a shared cache
  keyed by content, so two projects on one machine share entries. Whether `gc`
  needs a reference-tracking file, or whether pointing it at a set of lock
  files is sufficient, is unresolved and deferred to M7.

## Decisions Made

- **`ecl.pkg` is discovered by walking up from the working directory** (user
  ruling, 2026-08-21, settled while planning M1). The first `ecl.pkg` found
  walking from the process working directory toward the filesystem root is the
  project root, and `ecl.lock` is read from beside it — never from a different
  directory. No repo-boundary stop and no environment override. The
  working-directory-only rule was rejected because it fails the common case
  *silently*: a script run from a subdirectory simply has no lock and falls
  back to `ECL_PATH`, which is the worst available failure shape. The cost is
  real and lands on M5: session initialization walks O(directory depth) stats
  instead of one.
- **Implicit prerelease selection is vacuous, not prohibited** (settled while
  planning M1, 2026-08-21). Go needs a rule against selecting a prerelease
  because it enumerates available versions from a registry. MVS here takes the
  maximum of *declared* minimums and never enumerates, so every selection is a
  version some manifest wrote down and there is nothing implicit to prevent.
  SPEC records that reasoning rather than a rule: a rule no code can violate
  is a claim no test can prove. A future registry or tag-discovery proposal is
  exactly what would re-open this.
- **MVS, not a constraint solver** (user ruling, 2026-08-21; recorded in
  `design/workstream-v1.md`). Cheapest correct thing, and the only resolution
  strategy that does not require enumerating available versions. If
  expressiveness later proves insufficient, PubGrub replaces the resolution
  step alone.
- **No registry; tarball URL plus content hash** (user ruling, 2026-08-21).
  This composes with MVS rather than merely coexisting: MVS takes the maximum
  of *declared* minimums, and each declaration carries its own URL and hash,
  so the candidate set is exactly the union of what the graph declares. No
  enumeration source is needed. It also dissolves the immutable-publish
  problem a registry would have created — a moved tag changes the content
  hash and hard-fails rather than silently changing a build.
- **Tarball transport only; no git protocol client.** A git dependency is a
  codeload tarball URL. Zig supports both and this repo's own
  `build.zig.zon` uses tarballs exclusively. One fetch path, one hash, no
  embedded git client. Version discovery from tags is not needed because MVS
  never enumerates.
- **The resolver is written in ECL and ships embedded** (user ruling,
  2026-08-21). Makes "the runtime gains no dependency solver" literally true
  of the Zig side, and makes the package manager the language's first
  substantial self-hosted program. Zig's share is confined to host primitives
  the language cannot express (SHA-256, tar, gzip) and the lock tier.
- **`format` splices strings and renders other values canonically** (user
  ruling, 2026-08-22). Rendered text is already text, so interpolating it must
  not add source quotes. A caller that wants a string's quoted source spelling
  applies `str` explicitly. This makes `str` an independent bounded core
  primitive rather than a prelude definition in terms of `format`.
- **Definition annotations precede bodies and constant values** (user ruling,
  2026-08-22). The canonical forms are `annotation? body 'name def` and
  `annotation? value 'name set`, with the same private variants. The adjacent
  operand is unconditionally the body or value; only the quotation beneath it
  is shape-tested as optional metadata. `see` and the formatter emit that
  order.
- **Archive payloads are integer byte lists, not strings or a new runtime
  value kind** (settled while planning M3, 2026-08-22). ECL strings are
  Unicode values: valid UTF-8 ingress decodes scalars, while invalid bytes map
  one-to-one to characters, so no later string encoder can distinguish the
  original spellings for all binary inputs. Integers in `0..255` preserve the
  octets using ordinary inert ECL data and avoid expanding the Value layout or
  native ABI. The heap may represent an all-byte integer list as a packed
  `leaf_u8`; ordinary ECL construction selects it automatically, all language
  operations still expose integers, and an out-of-range mutation widens it to
  `leaf_i64`. This is an invisible storage choice, not a native-only value.
  M4 must produce this list directly from the HTTP byte stream.
- **Archive extraction is absent-destination atomic and resource-bounded**
  (user ruling while planning M3, 2026-08-22). `archive.unpack-tgz` stages
  beside an absent destination, commits with one rename, refuses to overwrite
  or merge an existing tree, and returns only regular-file paths. It rejects
  more than 1 GiB of uncompressed data or 100,000 members. These fixed limits
  bound expansion and metadata floods without adding an options argument to
  the v1 word.
- **M4 uses an explicit custom-trust Host seam for hermetic HTTPS** (user
  ruling while planning M4, 2026-08-22). Production's null override keeps
  system certificate roots and current-time verification. Tests supply an
  absolute checked-in CA path plus a fixed verification timestamp to the
  Session, so the production HTTP client reaches a real loopback TLS server
  without consulting the public network or ambient wall clock. Python serves
  the fixture because Zig 0.16 has a standard TLS client but no standard TLS
  server.
- **M4 discovers first and installs selected artifacts second** (settled while
  planning M4, 2026-08-22). MVS needs manifests from exact reachable
  candidates that it may not select. Discovery therefore fetches, hashes, and
  inspects one archive at a time without publishing it; after resolution, a
  second fetch installs only missing selected artifacts. The duplicate cold
  transfer is preferred to retaining the whole graph or granting temporary-
  spool deletion authority, and it makes the store contain no unselected
  versions.
- **Package publication is a narrow builtin authority** (settled while
  planning M4, 2026-08-22). `pkg.sync` remains ordinary ECL orchestration;
  builtin `pkg.store` owns archive inspection, repeated layout/prefix
  validation at install, immutable absent-destination publication, presence
  checks, and atomic lock replacement. The existing ECL manifest reader owns
  semantic parsing and `pkg.sync` checks exact identity before install. ECL
  does not gain generic recursive deletion or rename merely to implement a
  package cache.
- **`pkg.sync.run` takes an explicit project root** (settled while planning
  M4, 2026-08-22). Its effect is `(root-manifest project-root -- lock)`.
  Upward manifest discovery belongs to M6, which passes the discovered root;
  scripts and M4 tests remain deterministic without duplicating discovery.
- **Manifest and lock are inert data, parsed and never evaluated.** Resolution
  cannot execute code from a dependency, which is npm's standing wound and
  what JSR and Go both deliberately designed out. Janet reached the same split
  from the opposite direction — its modern bundles separate `info.jdn`
  (parsed) from a build script (a program) after finding declarative config
  could not express complex native builds. If native packages ever land here,
  their build logic gets its own explicitly trusted file; it is never
  smuggled into the manifest.
- **A package owns a dotted name prefix** (user ruling, 2026-08-21). Package
  `foo` may publish `foo` and `foo.*` and nothing else, enforced at unpack.
  This is how namespace ownership is policed with no registry to police it,
  and it keeps the lock table small enough for prefix matching to be cheap.
- **Source-only packages in v1** (user ruling, 2026-08-21). Native `.eclmod`
  distribution — and with it target selection, per-platform artifacts, and a
  binary supply-chain trust story — is deferred. Follow-up 12's "target
  selection" clause is explicitly *not* delivered by this workstream.
- **Evaluation never fetches and never writes the lock.** Resolution reads the
  lock; the network is reached only under `ecl pkg sync`. This is Go's
  `-mod=readonly` default. A missing store entry is an error naming the
  package, not an implicit download.
- **No `upgrade` subcommand.** There is no enumeration source without a
  registry, and under MVS upgrades are manifest edits by design.
- **The distribution split Janet made is deliberately *not* copied.** Janet's
  layering is right and adopted — core owns the lock-consuming half and does
  no networking, the resolver lives above it. But Janet shipped that layering
  as *separate artifacts* and paid for it: `jpm` (declarative
  `project.janet`), then `bundle/` in core (1.35.0, 2024-06-15), then
  `janet-pm` in the third-party `spork` contrib library, then `jeep` — four
  tools, two coexisting bundle formats, a package that may legally be both,
  `janet-pm` development stalled, and `jpm` still "used by the vast majority
  of projects" two years after its replacement landed. The
  2026 discussion janet-lang/janet#1748 is a user asking which of these is
  real and the maintainer answering with a decision tree. ECL's `pkg` module
  ships *inside the binary*: same layer boundary, one artifact, nothing to
  install, and no second format to migrate away from. The lesson taken is that
  the migration cost, not the design, is what damages an ecosystem — so the
  format is specified once in M1 and a future break is planned as a break, not
  as coexistence.

## Definition of Done (Acceptance Suite)

- **DoD-1 — Import by name resolves through the lock**
  - **Assert**: With a synced project, a script that says
    `'foo.bar.answer 'answer import` runs
    successfully without naming any file, path, URL, or version, and with
    `ECL_PATH` unset.
  - **Verify by** `cmd`: In a fixture project synced against the fixture
    server, run `env -u ECL_PATH ecl script.ecl` where `script.ecl` contains
    `'foo.bar.answer 'answer import` and calls `answer`.
  - **Expected**: Exit status 0 and the word's output on stdout.
  - **Traces to**: Milestone 5 — the lock tier in `AutoLoadDriver`
    (`src/machine.zig`).

- **DoD-2 — No lock file means byte-identical behavior**
  - **Assert**: With no `ecl.lock` present, resolution behaves exactly as it
    did at `0.1.0`.
  - **Verify by** `cmd`: `zig build test-e2e` in a directory containing no
    `ecl.lock`.
  - **Expected**: The full `ohsnap` transcript gate passes with no diffs
    against the transcripts recorded before this workstream.
  - **Traces to**: Milestone 5 — the tier's absent-lock skip on
    `unit.inherited`.

- **DoD-3 — The embedded stdlib still wins over the lock**
  - **Assert**: A locked package that publishes a module named `json` cannot
    shadow the embedded `json`.
  - **Verify by** `cmd`: Sync a fixture package declaring prefix `json`, then
    run `ecl -e "'json.parse doc"` and inspect the resolved documentation.
  - **Expected**: The embedded module's word. The tier order embedded →
    lock → `ECL_PATH` holds.
  - **Traces to**: Milestone 5 — the tier inserted *after* `stdlib.find` at
    `src/machine.zig:2565`.

- **DoD-4 — MVS selects the maximum of declared minimums**
  - **Assert**: Given a root requiring `a >= 1.0.0` and `b >= 1.0.0`, where
    `a` requires `c >= 1.2.0` and `b` requires `c >= 1.5.0`, the resolution
    selects `c` at exactly `1.5.0`.
  - **Verify by** `cmd`: `ecl pkg sync` in that fixture, then
    `ecl pkg tree`.
  - **Expected**: `c 1.5.0` appears exactly once; no other version of `c` is
    present in the lock or the store.
  - **Traces to**: Milestone 2 — `pkg.mvs.resolve` in
    `src/stdlib/pkg/mvs.ecl` owns the selected lock version; Milestone 4 — the
    two-pass selected-only install in `pkg.sync.run` owns the assertion that
    no unselected `c` version is present in the store.

- **DoD-5 — A newer available version is not selected**
  - **Assert**: If `c 2.0.0` exists at a reachable URL but nothing in the graph
    declares it, resolution still selects `c 1.5.0`.
  - **Verify by** `cmd`: Serve `c 2.0.0` from the fixture server, re-run
    `ecl pkg sync` against the DoD-4 fixture unchanged, and read `ecl.lock`.
  - **Expected**: `c 1.5.0`. MVS never upgrades without a manifest edit.
  - **Traces to**: Milestone 2 — `pkg.mvs.resolve`.

- **DoD-6 — Resolution is deterministic and recomputable**
  - **Assert**: Deleting `ecl.lock` and re-syncing reproduces it byte for
    byte.
  - **Verify by** `cmd`: `cp ecl.lock ecl.lock.bak && rm ecl.lock &&
    ecl pkg sync && diff ecl.lock ecl.lock.bak`.
  - **Expected**: `diff` exits 0. The lock is derived, not a transcript.
  - **Traces to**: Milestone 2 — `pkg.mvs.resolve`; Milestone 4 — `pkg.sync.run`.

- **DoD-7 — A hash mismatch aborts before unpacking**
  - **Assert**: A tarball whose content does not match its declared hash is
    never unpacked and never produces a lock.
  - **Verify by** `cmd`: Point a fixture manifest at a served tarball with a
    deliberately wrong hash and run `ecl pkg sync`.
  - **Expected**: Nonzero exit, an error naming the package and both hashes,
    no new store directory, and no `ecl.lock` written.
  - **Traces to**: Milestone 4 — the hash check in `pkg.sync.run`.

- **DoD-8 — Conflicting hashes for one name and version are a hard error**
  - **Assert**: Two manifests declaring `c 1.5` with different hashes fail
    resolution rather than picking one.
  - **Verify by** `cmd`: `ecl pkg sync` against that fixture.
  - **Expected**: Nonzero exit and an error naming both declaring packages and
    both hashes.
  - **Traces to**: Milestone 2 — the hash-conflict arm of `pkg.mvs.resolve`.

- **DoD-9 — A package cannot publish outside its prefix**
  - **Assert**: A package `foo` whose tarball contains `bar.ecl` fails the
    sync.
  - **Verify by** `cmd`: Serve such a tarball and run `ecl pkg sync`.
  - **Expected**: Nonzero exit, an error naming `foo` and the offending
    module name, and no store entry retained.
  - **Traces to**: Milestone 4 — prefix enforcement at unpack.

- **DoD-10 — Hostile archives are rejected without publication**
  - **Assert**: A malformed, over-limit, absolute/parent-traversing,
    duplicate, linked, or special-node tarball publishes no destination and
    changes nothing outside its staging root.
  - **Verify by** `cmd`: Run the checked-in malicious-tarball corpus through
    `archive.unpack-tgz` in `src/tests/archive_test.zig`, including its outside
    sentinel, existing-destination, concurrent-commit, and cancellation
    cases.
  - **Expected**: Every hostile case produces its classified error; the
    destination is absent or byte-for-byte unchanged, the outside sentinel is
    unchanged, and concurrent valid attempts expose exactly one complete
    tree.
  - **Traces to**: Milestone 3 — `archive.unpack-tgz` and its bounded staging
    driver in `src/stdlib/archive.zig`.

- **DoD-11 — Evaluation never reaches the network**
  - **Assert**: Running a locked project with the store deleted fails with a
    resolution error rather than downloading anything.
  - **Verify by** `cmd`: Delete the store directory, stop the fixture server,
    and run `ecl script.ecl`.
  - **Expected**: Nonzero exit and an error naming the missing package and
    directing the user to `ecl pkg sync`. No network syscall is attempted.
  - **Traces to**: Milestone 5 — the missing-store-entry arm of the lock tier.

- **DoD-12 — Manifests are never evaluated**
  - **Assert**: A manifest containing an executable form is rejected as
    malformed rather than run.
  - **Verify by** `cmd`: Write an `ecl.pkg` whose value includes a quotation
    that would write a file if evaluated, then run `ecl pkg sync`.
  - **Expected**: Nonzero exit, a validation error naming the offending key,
    and the file the quotation would have written does not exist.
  - **Traces to**: Milestone 1 — `pkg.manifest.validate` in
    `src/stdlib/pkg/manifest.ecl`. The terminal form of this assertion needs M6's
    `ecl pkg sync` to run; M1 lands its unit-level half as
    `pkg: a manifest holding an executable form is rejected, not evaluated`
    in `src/tests/pkg_test.zig`, which asserts the `'domain` rejection and
    that the error names the offending key. Inertness is decided by one
    grounded fact: `type` reports `'word` for an executable reference, while
    a quotation is an ordinary `'list`, so "no word value anywhere" is the
    whole test.

- **DoD-13 — `verify` detects a mutated store entry**
  - **Assert**: Editing a file inside a store entry is detected without
    network access.
  - **Verify by** `cmd`: Append a byte to a file in a store entry, stop the
    fixture server, run `ecl pkg verify`.
  - **Expected**: Nonzero exit and an error naming the package and the
    mismatched hash.
  - **Traces to**: Milestone 6 — `ecl pkg verify`.

- **DoD-14 — `add` raises one requirement and disturbs nothing else**
  - **Assert**: `ecl pkg add c 1.6 <url>` changes only `c`'s selection.
  - **Verify by** `cmd`: Run it against the DoD-4 fixture and diff the lock
    before and after.
  - **Expected**: The only changed entries concern `c`; every other package's
    selected version and hash is unchanged.
  - **Traces to**: Milestone 6 — `ecl pkg add` (MVS algorithm 3).

- **DoD-15 — Module-load concurrency is clean under the new tier**
  - **Assert**: Concurrent auto-loads through the lock tier are free of data
    races.
  - **Verify by** `cmd`: `zig build test-tsan` on Linux with the module-load
    and stateful-module suites extended to cover lock-tier resolution.
  - **Expected**: Exit 0 with no ThreadSanitizer reports.
  - **Traces to**: Milestone 5 — the lock tier's interaction with the
    registry loading lease in `src/modules.zig`.

- **DoD-16 — The full local gate is green**
  - **Assert**: The repository's standard precommit gate passes with the
    workstream complete.
  - **Verify by** `cmd`: `zig build precommit`.
  - **Expected**: Exit 0, including the `ohsnap` CLI transcript gate, the
    source audit, and lint.
  - **Traces to**: Milestone 7 — terminal state across all milestones.

- **DoD-17 — Version precedence matches semver 2.0.0 §11**
  - **Assert**: `pkg.version.less?` is a strict total order agreeing with §11 over
    the prerelease corpus, and a spelling outside the grammar is an error
    rather than a false answer.
  - **Verify by** `cmd`: adjacent pairs of the ascending corpus, then two
    rejections. The pair plumbing was verified against `0.1.0`:
    `ecl -e '[…corpus…] dup unappend pop swap 1 drop zip (call pkg.version.less?) each'`,
    with the corpus `["1.0.0-alpha" "1.0.0-alpha.1" "1.0.0-alpha.beta"
    "1.0.0-beta.2" "1.0.0-beta.11" "1.0.0-rc.1" "1.0.0"]`; then
    `ecl -e '"1.0.0+build" "1.0.1" pkg.version.less?'` and
    `ecl -e '"1.01.0" "1.2.0" pkg.version.less?'`.
  - **Expected**: `[1 1 1 1 1 1]` for the corpus; nonzero exit and a
    `'domain` error for each of the two malformed spellings.
  - **Traces to**: Milestone 1 — `pkg.version.less?` in `src/stdlib/pkg/version.ecl`,
    proved by `pkg: version ordering is a strict total order over a generated
    corpus` in `src/tests/pkg_test.zig`.

- **DoD-18 — The lock is a fixed point of its own writer**
  - **Assert**: Reading a canonical `ecl.lock` and writing it back reproduces
    the bytes, and writing a lock value then reading it reproduces the value.
  - **Verify by** `cmd`: `ecl -e '"ecl.lock" io.slurp pkg.lock.read
    pkg.lock.write io.prin' > round-tripped && diff ecl.lock round-tripped`.
    `io.prin` rather than the final-stack print: `-e` renders the stack as a
    quoted, escaped value, which is not the file's bytes (verified against
    `0.1.0`).
  - **Expected**: `diff` exits 0. Distinct from DoD-6, which asserts the lock
    is *recomputable* from the manifests; this asserts the format's spelling
    is canonical, which is what makes DoD-6's `diff` meaningful.
  - **Traces to**: Milestone 1 — `pkg.lock.write` in `src/stdlib/pkg/lock.ecl`,
    proved by `pkg: read-lock and write-lock round-trip a canonical lock byte
    for byte` in `src/tests/pkg_test.zig`.

- **DoD-19 — SHA-256 hashes exact archive octets**
  - **Assert**: `archive.sha256` hashes integer byte-list items one-for-one,
    including values above 127, with no Unicode normalization or UTF-8
    re-encoding.
  - **Verify by** `cmd`: Run
    `archive: sha256 matches known-answer vectors and preserves high bytes` in
    `src/tests/archive_test.zig` against the empty, `abc`, multi-block, and
    high-byte vectors.
  - **Expected**: Every lowercase 64-digit digest matches the independent
    known answer; changing one byte changes the result.
  - **Traces to**: Milestone 3 — `archive.sha256` and
    `kernel_storage.ByteVectorEncoder`.
