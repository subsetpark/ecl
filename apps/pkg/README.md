# Package application contract

The maintained package application owns project discovery, manifests, lockfiles,
source selection, fetching, installation, and verification. The interpreter
reads none of its files: it finds installed packages by module search beneath
`.ecl/packages`, and uses `ecl.pkg` only to locate the project root.

See [manifest and source conventions](FORMATS.md) and the
[pure data API reference](API.md). Verification evidence and separate core/complete
distribution measurements are recorded in [VALIDATION.md](VALIDATION.md).

## Portable project state

`ecl.pkg` remains the project manifest. The root `ecl.lock` is portable project
data intended for version control. It pins the complete resolved graph: exact
versions, source identities, full Git commits, archive hashes, and dependency
edges. It contains no machine-specific cache or installation paths.
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

Changing the root's version or local source patterns does not itself
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
sealed-manifest checks. `zig build test-pkg-app` runs ECL's built-in test
command with the application directory as the project. Unit tests live in the
modules whose logic they test, sharing the assertions in `pkg.test.support`;
tests that need repository fixtures or write to the working directory stay
under `test/`. Acceptance under `test/acceptance/` declares no tests: each file
exports a `run` word that a build step selects as the runner.
Separate-process orchestration and controlled external services remain host
integration fixtures.

## Commands and installation

The distribution ships the entry script `main.ecl`, ECL module sources, and
`git.eclmod` together beneath `share/ecl/apps/pkg/`. The entry passes ordinary
process arguments to `pkg.command.main`. The application searches only its own
directory, so project-local modules cannot replace package application modules
and broken project state does not prevent startup.

- `init [name]` creates `src/`, `ecl.pkg`, and an empty portable `ecl.lock`.
  Existing project state is not overwritten.
- `add <name> <version> <https-url>` validates an archive and records its exact
  source and hash in the manifest. `add <https-git-url> --tag|--commit <revision>`
  obtains the package identity from its source manifest and records the resolved
  full commit and archive hash. A dependency edit requires `update` to select
  the new graph.
- `sync [--offline]` honors an existing lock and installs it. `update [--offline]`
  explicitly reruns dependency selection.
- `verify` checks the installed packages without repair. `tree` shows
  sorted direct selected edges; `why <module>` shows one canonical shortest
  root-to-owner path, using a search bounded by the selected graph.
- `gc <retained-lock>...` collects only unretained regular files in the shared
  download cache. Inputs may be absolute or caller-relative portable lock paths.
  Unrecognized entries are preserved; installed packages are never collected.

`zig build test-pkg-application` owns a temporary caller directory and cache,
then invokes the built-in ECL test runner for command assertions. The host
fixture supplies process isolation and does not duplicate package policy tests.

`zig build test-pkg-git` launches the installed application in isolated caller
processes against a controlled HTTPS Git server. ECL phases cover mixed archive
and Git sources, moved tags, unavailable commits, corrupt project state,
explicit updates, portable-lock reproduction in fresh checkouts, and
reinstallation after relocation and removal of the shared cache. The host fixture only creates repositories,
serves Git, copies checkout inputs, and launches test phases.

## Source package archives

`pkg.bundle` applies package rules to the member values `gzip.decompress
tar.read` returns and to `source.declarations`. The shared archive parser owns
path safety, duplicate-member checks, and rejection of links and special files.
The application requires one regular root `ecl.pkg`, rejects `.eclmod` payloads
and reserved `.ecl-package.tgz` / `.ecl-package.catalog` control files, and limits
the package to 100,000 members and 64 MiB of member contents.

Manifest patterns select at most 4,096 source artifacts, each at most 16 MiB.
`*` and `?` match bytes within a path component; `**` matches zero or more whole
components. The application matcher uses dynamic programming through ordinary
ECL evaluation, so pattern processing remains cancellable without exponential
backtracking. Selected files are parsed without execution. Every literal
top-level module declaration is an export; each must be package-owned and occur
exactly once. Installation keeps every regular file, so module search also
reads unselected `.ecl` files; a module they declare matters only if
requested.

## Application orchestration

`pkg.project` searches upward from the captured startup directory for `ecl.pkg`.
Discovery reads no project lock. All subsequent project
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

`pkg.obtain` retains each verified artifact in a private download directory
before releasing its bytes or populating the shared cache. It tries those
private pins, the project's kept archives, the optional download cache, and
finally the exact network source. Offline mode omits that last step. Cache
collection cannot remove a private pin needed by an in-progress installation.

## Installation

All application mutations hold the project's advisory mutation lock.
`pkg.install` validates each selected manifest against the lock, unpacks the
package into a staged sibling of `.ecl/packages`, and keeps its exact archive
in a staged sibling of `.ecl/archives`. Once every package is in place it
replaces the installed trees with the staged ones and then publishes
`ecl.lock` with a same-directory atomic rename. A failure before that point
leaves the previous installation and lock untouched. The two trees and the lock
are not replaced as one transaction; an interrupted replacement is repaired by
running `sync` again, which needs no network when the archives are kept or
cached. `pkg.verify` checks that `.ecl/packages` and `.ecl/archives` hold
exactly the locked packages and archives, each archive's hash, and every
installed regular file against its archive, rejecting links, special objects,
missing files, and extra files without repair.

`zig build test-pkg-install` runs offline installation, exact lock
preservation, explicit-update refusal, reinstallation from kept archives,
module search over the installed package from a new interpreter, and
verification of a damaged installation. It is included in the full test suite;
the fast precommit tier retains the smaller policy cases in `test-pkg-app`.

## Required acceptance

Acceptance must reproduce a fresh checkout from its manifest and root lock,
preserve pinned commits after tags move, and prove that ordinary sync leaves
the locked graph unchanged. Explicit updates must produce a new portable lock.
A failed command must leave the installed packages and lock unchanged.
