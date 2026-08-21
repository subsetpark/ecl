# Workstream: First-Party Package Manager

## Vision

`ecl` gains first-party dependency management: a project declares its
dependencies in an inert data manifest, a resolver derives a lock from that
manifest by minimal version selection, and the interpreter resolves module
names through the lock before it ever touches a search path. Importing stays
by name — `use foo.bar` never mentions a file, a URL, or a version — and a
checkout plus a lock reproduces the same module images on any machine. The
resolver is written in ECL and ships embedded in the binary, so the language's
first substantial first-party program is written in itself and there is no
second tool to install.

## Current State

Verified in the checkout (2026-08-21, `0.1.0` tagged 2026-08-19, the v1
workstream terminal).

- **There is no package manager, no manifest, no lock, and no notion of a
  version anywhere in `src/`.** `design/workstream-v1.md` follow-up 12 scopes
  one as post-v1 work and the 2026-08-21 Decisions Made entry records the MVS
  and lock-table rulings this workstream implements.
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
  Constraint verified at `src/stdlib.zig:73`: **embedded module names are
  comptime-rejected if they contain a dot or whitespace**, so every embedded
  module is a single atom. Dotted names have only ever come from `ECL_PATH`,
  where `core.utils` names the file `core.utils.ecl` in a search directory —
  flat, no directory nesting (`src/machine.zig:2580`–`2620`).
- **`ecl_path` and `host_io` ride on `unit.inherited`** (`src/machine.zig:1088`,
  threaded from `src/session.zig:52` and owned at `:276`). A lock table
  attaches at exactly the same place, and the existing
  `host_io == null or ecl_path == null` bail already establishes the pattern
  for "this tier is unavailable, skip it."
- **A subcommand precedent exists.** `src/main.zig:56` dispatches `ecl fmt`
  ahead of the flag handling; `ecl pkg …` slots into the same position.
- **The client's raw materials are already embedded.** `http` supplies
  `get`/`post` over TLS with transparent gzip/zstd decoding
  (`src/stdlib/http.zig`), `io` supplies `slurp`/`spit`
  (`src/stdlib/io.zig`), `parse` reifies the reader as a value, and `json`
  and `csv` demonstrate both the builtin-words and native-descriptor arms.
- **Missing from `src/` and required: SHA-256, tar, and gzip *decompression as
  an exposed operation*.** No `std.crypto.hash` use exists anywhere;
  `src/stdlib/http.zig:321`–`333` uses `std.compress.flate` only internally
  for response bodies. All three are available in Zig 0.16 std
  (`std.crypto.hash.sha2.Sha256`, `std.tar`, `std.compress.flate`).
- **`test/http_fixture_server.zig` already exists**, so fetcher acceptance
  runs against a local server with no CI network access.
- **The target design is already in the repo.** `build.zig.zon` pins each
  dependency as a tarball URL plus a content hash with no registry, and
  `zig-pkg/` is a content-addressed store keyed `name-version-hash`. This
  workstream mirrors that shape for ECL modules.

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
- **Embedded names cannot be dotted.** `src/stdlib.zig:73` forbids it, so the
  resolver module is the single atom `pkg` and host primitives cannot live at
  `pkg.host`. Either they take their own single-atom module name or the
  comptime check is relaxed. This workstream takes the former.

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
- A new embedded stdlib module `pkg` (single atom, per `src/stdlib.zig:73`)
  registered in `src/stdlib.zig` with the `source` arm, exporting pure
  functions: `pkg.read-manifest`, `pkg.read-lock`, `pkg.write-lock`,
  `pkg.version<`, `pkg.version-max`, `pkg.validate-manifest`,
  `pkg.owns-prefix?`. No network, no filesystem.
- **The lock is structurally per-package from this first version**: its
  entries key requirements by the *requiring* package, even though MVS makes
  every map identical today. This is the recorded retrofit door for admitting
  two versions of one name later without a breaking format change.
- Round-trip property tests: `write-lock` of `read-lock` is byte-identical;
  `version<` is a total order over a generated version corpus.

**Why this is a safe pause point**: Nothing outside `src/stdlib.zig` and
`src/stdlib/pkg.ecl` changes. `pkg` is an ordinary embedded module that
manipulates data; no resolution path, CLI surface, or IO behavior is touched.
The binary behaves identically for every program that does not `use pkg`.

**Unlocks**: The resolver (M2) and the lock tier (M5) can both be written
against a fixed format, in parallel.

**Open Questions**: Whether `ecl.pkg` is discovered by walking up from the
process working directory (git-style) or named explicitly. Resolve during
this milestone and record in SPEC.md; M6 depends on the answer.

---

### Milestone 2: pkg-mvs-resolver

**Definition of Done**:
- `pkg.resolve` in `src/stdlib/pkg.ecl`: a pure function from a root manifest
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

**Why this is a safe pause point**: `pkg.resolve` is a pure function over
data. It is callable and testable from an ordinary script, and nothing in the
interpreter consults it yet.

**Unlocks**: The fetcher (M4), which needs a resolution before it knows what
to download.

**Established Precedents** (milestone-scoped):
- **[algorithm] Minimal Version Selection** — https://research.swtch.com/vgo-mvs — This milestone *is* the algorithm; the workstream-level entry applies here in full and the "algorithm 1" section is the direct implementation reference.

---

### Milestone 3: pkg-host-primitives

**Definition of Done**:
- A new embedded builtin module `archive` in `src/stdlib.zig` (single atom,
  `builtin` arm, modelled on `src/stdlib/io.zig`) exporting:
  `archive.sha256` (bytes → lowercase hex string) and `archive.unpack-tgz`
  (archive bytes plus a destination path → the list of extracted relative
  paths).
- `unpack-tgz` **fails closed on hostile archives**: absolute member paths,
  `..` traversal, symlinks, hardlinks, device nodes, and members resolving
  outside the destination root are rejected with a precise error and leave
  nothing extracted. Extraction is atomic — unpack to a temporary directory
  and rename, so an interrupted unpack never yields a half-populated store
  entry.
- Every word carries documentation and a declared effect, matching the
  existing builtin-module contract enforced at `src/stdlib.zig:88`.
- Tests include known-answer vectors for SHA-256 and a checked-in corpus of
  malicious tarballs, each asserted to be rejected.

**Why this is a safe pause point**: Two new words in a new embedded module,
depended on by nothing. Existing programs are unaffected.

**Unlocks**: The fetcher (M4). Independent of M1 and M2, so it can run in
parallel with them.

---

### Milestone 4: pkg-fetch-and-store

**Definition of Done**:
- `pkg.sync` in `src/stdlib/pkg.ecl`: given a root manifest, read transitive
  manifests, resolve via `pkg.resolve`, fetch every selected package that is
  not already in the store, and write `ecl.lock`.
- Fetch is tarball-over-HTTPS only, via the existing `http` module. Each
  downloaded archive is hashed with `archive.sha256` and compared against the
  declared hash **before** it is unpacked; a mismatch aborts the whole sync
  and writes no lock.
- The store is content-addressed at `$ECL_CACHE` (default
  `$XDG_CACHE_HOME/ecl/pkg`, then `~/.cache/ecl/pkg`), one directory per
  entry keyed `<name>-<version>-<hash>`, mirroring `zig-pkg/`. Store entries
  are treated as immutable: an existing directory whose name matches is used
  as-is and never re-fetched.
- A package's manifest is read from its own tarball, so transitive
  requirements are discovered during the fetch walk rather than declared by
  the root.
- **Prefix ownership is enforced at unpack**: a package `foo` whose tarball
  contains a module file outside `foo.ecl` / `foo.*.ecl` fails the sync.
- Acceptance runs against `test/http_fixture_server.zig` with checked-in
  fixture tarballs. No CI network access.

**Why this is a safe pause point**: `pkg.sync` is callable from a script and
produces a real store and a real lock, but nothing reads the lock yet — the
interpreter still resolves through the embedded manifest and `ECL_PATH`
exactly as before. A user who runs it has downloaded files and gained a lock
file, and lost nothing.

**Unlocks**: Real end-to-end verification of the lock tier (M5) against
genuinely fetched packages.

**Operator Actions Before Next Milestone**:
1. Publish one real source-only package tarball to a durable URL (a GitHub
   release or `archive/refs/tags/*.tar.gz` is sufficient) and record its
   SHA-256.
2. Run `pkg.sync` against a manifest naming it, on a machine with network
   access, outside CI. Confirm the store directory, the lock contents, and the
   hash all match.
3. **Decision, with criteria**: if the live fetch surfaces TLS, redirect, or
   content-encoding behavior the fixture server does not model, extend the
   fixture server to model it *before* M5 begins rather than discovering it
   during lock-tier work. Abort condition: if `http` cannot fetch GitHub
   release tarballs at all, M4 is not done and M5 must not start.

---

### Milestone 5: pkg-lock-tier

**Definition of Done**:
- `AutoLoadDriver` consults a lock table between the `stdlib.find` check
  (`src/machine.zig:2565`) and `beginFilename`. Tier order is embedded
  manifest → lock → `ECL_PATH`.
- Lookup is **longest-prefix match** on the requested dotted module name
  against the lock's package prefixes; the winning entry names a store
  directory, and the module file within it is derived from the remainder of
  the dotted name.
- The lock is read once at session initialization from `ecl.lock` and carried
  on `unit.inherited` alongside `ecl_path`, following the same
  optional-and-skippable pattern (`src/machine.zig:1088`, `src/session.zig:52`).
  No lock file, or no `host_io`, means the tier is absent and resolution is
  byte-identical to today.
- Resolution **never reaches the network and never mutates the lock**. A
  module named in the lock whose store directory is missing is a precise
  error naming the package and telling the user to run `ecl pkg sync` — it is
  not an implicit fetch.
- The racing-winner recheck, the loading lease, the cycle detection, and the
  poll budget are all preserved; the new phase allocates through `heap.Owned`
  like its neighbours.
- `zig build test-tsan` is green, and the existing module-load and
  stateful-module suites are extended to cover the new tier.

**Why this is a safe pause point**: The tier is inert without a lock file, so
every existing program, test, and CLI transcript behaves exactly as before.
With a lock file it resolves locked modules by name. Either state is
coherent.

**Unlocks**: The CLI (M6) — with the tier in place, `ecl pkg sync` followed by
an ordinary `ecl script.ecl` is the whole user story.

**Operator Actions Before Next Milestone**:
1. Run `zig build test-tsan` on Linux and confirm green. This milestone
   changes module-load timing, which is the specific class of bug only TSan
   catches; a green precommit is not sufficient evidence here.
2. Abort condition: any TSan finding in the loading-lease or registry
   publication path blocks M6 until resolved.

---

### Milestone 6: pkg-cli

**Definition of Done**:
- `ecl pkg <subcommand>` dispatched at `src/main.zig:56` alongside `ecl fmt`,
  delegating to the embedded `pkg` module rather than reimplementing logic in
  Zig. Subcommands: `init`, `add <name> <version> <url>`, `sync`, `tree`,
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

M1 and M3 are independent and start together. M5 needs only the format, so
the Zig-side lock tier proceeds in parallel with the ECL-side resolver and
fetcher. M6 is the join.

## Open Questions

- **Prerelease selection.** Semver orders prereleases below their release, but
  should MVS ever *select* one implicitly? Go says no — a prerelease is chosen
  only when explicitly required. Adopting that rule is likely correct but the
  interaction with "maximum of declared minimums" needs to be written out
  before M2.
- **Store sharing and lifetime across projects.** The store is a shared cache
  keyed by content, so two projects on one machine share entries. Whether `gc`
  needs a reference-tracking file, or whether pointing it at a set of lock
  files is sufficient, is unresolved and deferred to M7.
- **Manifest discovery.** Walk up from the working directory, or require the
  manifest in the working directory? Affects M1's spec text and M6's
  behavior. To be settled inside M1.

## Decisions Made

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
  - **Assert**: With a synced project, a script that says `use foo.bar` runs
    successfully without naming any file, path, URL, or version, and with
    `ECL_PATH` unset.
  - **Verify by** `cmd`: In a fixture project synced against the fixture
    server, run `env -u ECL_PATH ecl script.ecl` where `script.ecl` contains
    `use foo.bar` and calls an exported word.
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
    run `ecl -e 'use json'` and inspect which words are present.
  - **Expected**: The embedded module's words. The tier order embedded →
    lock → `ECL_PATH` holds.
  - **Traces to**: Milestone 5 — the tier inserted *after* `stdlib.find` at
    `src/machine.zig:2565`.

- **DoD-4 — MVS selects the maximum of declared minimums**
  - **Assert**: Given a root requiring `a >= 1.0` and `b >= 1.0`, where `a`
    requires `c >= 1.2` and `b` requires `c >= 1.5`, the resolution selects
    `c` at exactly `1.5`.
  - **Verify by** `cmd`: `ecl pkg sync` in that fixture, then
    `ecl pkg tree`.
  - **Expected**: `c 1.5` appears exactly once; no other version of `c` is
    present in the lock or the store.
  - **Traces to**: Milestone 2 — `pkg.resolve` in `src/stdlib/pkg.ecl`.

- **DoD-5 — A newer available version is not selected**
  - **Assert**: If `c 2.0` exists at a reachable URL but nothing in the graph
    declares it, resolution still selects `c 1.5`.
  - **Verify by** `cmd`: Serve `c 2.0` from the fixture server, re-run
    `ecl pkg sync` against the DoD-4 fixture unchanged, and read `ecl.lock`.
  - **Expected**: `c 1.5`. MVS never upgrades without a manifest edit.
  - **Traces to**: Milestone 2 — `pkg.resolve`.

- **DoD-6 — Resolution is deterministic and recomputable**
  - **Assert**: Deleting `ecl.lock` and re-syncing reproduces it byte for
    byte.
  - **Verify by** `cmd`: `cp ecl.lock ecl.lock.bak && rm ecl.lock &&
    ecl pkg sync && diff ecl.lock ecl.lock.bak`.
  - **Expected**: `diff` exits 0. The lock is derived, not a transcript.
  - **Traces to**: Milestone 2 — `pkg.resolve`; Milestone 4 — `pkg.sync`.

- **DoD-7 — A hash mismatch aborts before unpacking**
  - **Assert**: A tarball whose content does not match its declared hash is
    never unpacked and never produces a lock.
  - **Verify by** `cmd`: Point a fixture manifest at a served tarball with a
    deliberately wrong hash and run `ecl pkg sync`.
  - **Expected**: Nonzero exit, an error naming the package and both hashes,
    no new store directory, and no `ecl.lock` written.
  - **Traces to**: Milestone 4 — the hash check in `pkg.sync`.

- **DoD-8 — Conflicting hashes for one name and version are a hard error**
  - **Assert**: Two manifests declaring `c 1.5` with different hashes fail
    resolution rather than picking one.
  - **Verify by** `cmd`: `ecl pkg sync` against that fixture.
  - **Expected**: Nonzero exit and an error naming both declaring packages and
    both hashes.
  - **Traces to**: Milestone 2 — the hash-conflict arm of `pkg.resolve`.

- **DoD-9 — A package cannot publish outside its prefix**
  - **Assert**: A package `foo` whose tarball contains `bar.ecl` fails the
    sync.
  - **Verify by** `cmd`: Serve such a tarball and run `ecl pkg sync`.
  - **Expected**: Nonzero exit, an error naming `foo` and the offending
    module name, and no store entry retained.
  - **Traces to**: Milestone 4 — prefix enforcement at unpack.

- **DoD-10 — Path traversal in an archive is rejected**
  - **Assert**: A tarball containing a member resolving outside the
    destination root extracts nothing.
  - **Verify by** `cmd`: Run the checked-in malicious-tarball corpus through
    `archive.unpack-tgz`.
  - **Expected**: Every case errors, and no file exists outside the
    destination root afterwards.
  - **Traces to**: Milestone 3 — `archive.unpack-tgz` in `src/stdlib.zig`'s
    `archive` module.

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
  - **Traces to**: Milestone 1 — `pkg.validate-manifest`.

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
