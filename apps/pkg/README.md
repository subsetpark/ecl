# Package application contract

The maintained package application owns project discovery, manifests, lockfiles,
source selection, fetching, installation, verification, and publication. The
interpreter consumes only `ecl.modules`; it never discovers or interprets
`ecl.pkg`, `ecl.lock`, or application recovery records.

See [manifest and source conventions](FORMATS.md) and the
[pure data API reference](API.md).

## Portable project state

`ecl.pkg` remains the project manifest. The root `ecl.lock` is portable project
data intended for version control. It pins the complete resolved graph: exact
versions, source identities, full Git commits, archive hashes, and dependency
edges. It contains no machine-specific cache paths or generation identifiers.
A fresh checkout containing these two files must reproduce the locked graph.

Ordinary `sync` uses the existing lock without reselecting dependencies or
resolving tags again. A lock incompatible with the manifest is an error;
dependency updates require an explicit update operation. An initial sync may
resolve a graph when no lock exists. Offline sync applies the same selection
rules and fails when the exact pinned artifacts are unavailable.

The portable lock uses format 3 with exactly `format`, `root`, `root-requires`,
`packages`, and `requires`. `root-requires` retains the manifest's complete
dependency declarations, including local aliases and exact source pins.
`packages` records each selected version, tagged source identity, and archive
hash. `requires` records the direct alias-to-package minimum-version edges for
the root and every selected package, including packages with no dependencies.
Every selection is reachable from the root, and the graph is acyclic. Sources
remain HTTPS archives or Git repositories pinned to full commits.

Changing the root's version, exports, or local source patterns does not itself
update dependencies. Changing its name or dependency declarations makes the
lock incompatible and requires `pkg update`. When minimal version selection
raises a dependency above a declared minimum, ordinary sync fetches the selected
pin; it does not need to fetch superseded minimum artifacts. If the selected
version equals a declaration's minimum, its source and hash must match that
declaration exactly. Every selected manifest must match its locked identity and
direct edges.

Initial resolution and explicit updates inspect the reachable declared minimum
artifacts and select the highest reached version of each package. The resulting
lock retains only packages reachable through the selected manifests; dependencies
used solely by superseded minima are removed. Normal locked synchronization
bypasses this discovery and selection entirely.

`pkg.resolution` owns validation, canonical serialization, compatibility, and
sealed-manifest checks. `zig build test-pkg-app` invokes ECL's built-in test
runner against the application's test map; package policy assertions live in
ECL. The larger manifest, SemVer, and solver corpora run under
`zig build test-pkg-contracts` in the full suite. Separate-process orchestration and controlled external services remain
host integration fixtures.

## Commands and installation

The distribution ships the entry script, inert application descriptor, module
map, ECL module sources, and `git.eclmod` together beneath `share/ecl/apps/pkg/`.
The entry passes ordinary process arguments to `pkg.command.main`. Application
loading uses its own map, so project-local modules cannot replace package
application modules and broken project runtime state does not prevent startup.

- `init [name]` creates `src/`, `ecl.pkg`, an empty portable `ecl.lock`, and a
  usable local-source `ecl.modules`. Existing project state is not overwritten.
- `add <name> <version> <https-url>` validates an archive and records its exact
  source and hash in the manifest. `add <https-git-url> --tag|--commit <revision>`
  obtains the package identity from its source manifest and records the resolved
  full commit and archive hash. A dependency edit requires `update` to select
  the new graph.
- `sync [--offline]` honors an existing lock. `update [--offline]` explicitly
  reruns dependency selection. `vendor [--offline]` requires a lock and activates
  an equivalent generation beneath `vendor/`, preserving the portable lock.
- `verify` reads the active generation without recovery or repair. `tree` shows
  sorted direct selected edges; `why <module>` shows one canonical shortest
  root-to-owner path, using a search bounded by the selected graph.
- `gc <retained-lock>...` collects only unretained regular files in the shared
  download cache. Inputs may be absolute or caller-relative portable lock paths.
  Unrecognized entries are preserved; project generations are never collected.

`zig build test-pkg-application` owns a temporary caller directory and cache,
then invokes the built-in ECL test runner for command assertions. The host
fixture supplies process isolation and does not duplicate package policy tests.

## Source package archives

`pkg.bundle` applies package rules through `archive.open-tgz`, member metadata,
bounded member reads, and `source.declarations`. The shared archive parser owns
path safety, duplicate-member checks, and rejection of links and special files.
The application requires one regular root `ecl.pkg`, rejects `.eclmod` payloads
and reserved `.ecl-package.tgz` / `.ecl-package.catalog` control files, and limits
the package to 100,000 members and 64 MiB of member contents.

Manifest patterns select at most 4,096 source artifacts, each at most 16 MiB.
`*` and `?` match bytes within a path component; `**` matches zero or more whole
components. The application matcher uses dynamic programming through ordinary
ECL evaluation, so pattern processing remains cancellable without exponential
backtracking. Selected files are parsed without execution. Only literal
top-level module declarations named by the manifest's exports enter the
artifact map; all declared exports must occur exactly once. Other registrations
remain file-private, including duplicate private names in different artifacts.
Unselected regular data files are retained by installation.

## Application orchestration

`pkg.project` searches upward from the captured startup directory for `ecl.pkg`.
Discovery reads neither a project lock nor a runtime map. All subsequent project
access uses an explicitly opened directory resource. Mutations coordinate with
the advisory lock at `.ecl/mutation.lock`.

Download-cache selection belongs to the application: nonempty `ECL_CACHE`, then
`XDG_CACHE_HOME/ecl/pkg`, then `HOME/.cache/ecl/pkg`. Relative settings resolve
against the captured startup directory; absence of all settings disables the
cache optimization. Git trust uses optional `ECL_GIT_CA_FILE`, and scratch uses
`TMPDIR` or `/tmp`. These are application choices passed explicitly to the
independent native port; the extension does not read package configuration.

The download cache is flat, with `<archive-sha256>.tgz` entries. Reads verify
contents against the requested hash; missing, unavailable, or corrupt entries
are cache misses. Writes atomically publish verified bytes. Cache availability
never determines package selection, and cancellation is not treated as a miss.

`pkg.fetch` drains bounded Git byte output before observing its resolved commit,
joins the exchange and resource, and verifies a selected artifact's exact hash.
Only explicit tag selection requests a tag. A locked requirement always requests
its full commit. Archive requests use the public bounded HTTP facility.
`zig build test-pkg-fetch` provides a controlled HTTPS service and runs the
application's fetch assertions with `ecl test`.

`pkg.map` projects direct dependency edges and inspected artifact exports into a
general module map. It keeps the project's source patterns live. Before any
directory publication, it sends the candidate map to the current executable's
public validator, with the eventual document path and a bounded subprocess
deadline. Neither project state nor executable search through `PATH` participates
in that validation.

Each immutable generation contains its own complete resolution snapshot,
installed dependencies, sealed artifacts, and a complete relative module map.
The snapshot supplements the root lock: a running generation always uses its own
snapshot, even while the root lock is being updated. Neither synchronization nor
recovery deletes previous project generations.

Application generation references use `.ecl/generations/<64 lowercase hex>` or
`vendor/<64 lowercase hex>`. Both locations use the same publication protocol;
the complete map locates live project sources relative to its own document.
The root lock contains neither location.

`pkg.obtain` retains each verified artifact in the private generation before
releasing its bytes or populating the shared cache. It tries private pins, the
captured active generation's seals, the optional download cache, and finally
the exact network source. Offline mode omits that last step. Cache collection
cannot remove a private pin needed by an in-progress installation.

`pkg.generation` validates selected manifests, extracts source packages, records
their exact archives under `archives/`, and writes `ecl.pkg`, `ecl.lock`, and
the complete map before publishing the staged directory. `pkg.verify` checks
the closed generation layout, every seal, installed regular-file contents, and
the reconstructed map against that generation's own inputs. It rejects links,
special objects, missing files, and extra installed files without repair.
Publication validation additionally requires the root manifest to match the
generation's manifest snapshot. `pkg.install` coordinates recovery, lock
selection, construction, and activation under the project mutation lock.

`zig build test-pkg-generation` runs this full acceptance through ECL's test
runner, including initial resolution, exact lock preservation, explicit update
selection, offline reproduction, activation, and independent verification of
older generations. It is included in the full test suite; the fast precommit
tier retains the smaller policy cases in `test-pkg-app`.

## Publication and recovery

All application mutations hold the project's advisory mutation lock. Publication
uses this order:

1. Materialize and validate a private generation against the proposed project
   lock. Publish the complete generation to its absent immutable destination.
2. Atomically create an application recovery record beneath `.ecl/`. It records
   the manifest observed for this operation, the previous root lock and map
   states (including absence), the proposed lock, and the new generation map
   reference. The generation's resolution snapshot must match that proposed
   lock exactly. No root file has changed yet.
3. Atomically publish the root `ecl.lock`.
4. Atomically publish the root `ecl.modules` reference. This is activation.
5. Remove the recovery record.

The two root files cannot be atomically replaced together. Interruption after
step 3 can leave a newer project lock beside the previous active generation.
That generation remains runnable and internally consistent because its map and
resolution snapshot are immutable. A fresh checkout of the newer root lock
reproduces the newer locked graph independently of local recovery state.

Before another mutation, the application validates any recovery record and its
generation, then completes the publication idempotently. It requires the
manifest to match the recorded observation and each root file to match either
its recorded previous state or its proposed state. Unexpected edits, malformed
records, or invalid generations cause an explicit recovery conflict; recovery
must not overwrite unrelated user edits or resolve a different graph. A valid
pending transaction is completed before selecting work for the new command.

Failure before activation leaves the previous runnable generation available.
Cancellation after activation never rolls it back; a surviving recovery record
is completed or removed by the next mutating command. Read-only startup and
verification do not recover, repair, fetch, or write package state. Verification
checks the active generation against its own snapshot and reports any pending
publication or root-lock mismatch separately.

Namespace operations promise atomic visibility under process interruption.
Filesystem or machine crash durability is limited by the host filesystem APIs;
the protocol must not claim a multi-file durable transaction.

The `pkg.transaction` module implements record preparation and idempotent replay
through public filesystem resources. Its caller holds the project mutation lock
and supplies a generation validator with stack effect `(project path --)`.
That validator checks the complete generation, including its runtime map and
artifact seals, without repairing or resolving sources. The transaction module
also independently checks the generation's exact resolution-snapshot bytes.
Records contain data only; recovery never executes their contents. The ordinary
coordination guarantee covers writers participating in the application lock.
The ECL test suite checks initial publication, every root-write boundary,
idempotent replay, and conflicting edits through public directory resources.
The host fixture checks separate interpreter processes loading the old or new
generation at those boundaries.

## Required publication acceptance

Acceptance must reproduce a fresh checkout from its manifest and root lock,
preserve pinned commits after tags move, and prove that ordinary sync leaves
the locked graph unchanged. Explicit updates must produce a new portable lock.
Interruption at every boundary above must preserve an internally consistent
active generation and allow idempotent recovery without network resolution.
Recovery must reject intervening root or manifest edits, damaged generation
snapshots, and malformed records. Repeated recovery and cancellation after
activation must preserve the committed generation. Vendoring must retain an
equivalent resolution snapshot without making the root lock machine-specific.
