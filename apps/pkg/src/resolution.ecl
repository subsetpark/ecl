### module pkg.resolution
# Portable project locks. Generations retain these same resolution bytes.
(
 ### defp require
 (condition -- : "Reject inconsistent portable resolution data.")
 (`domain error.new "invalid portable package lock" error.with-message assert) `require defp

 ### defp dict?
 (value -- bool : "Recognize a dictionary.")
 (type `dict match?) `dict? defp

 ### def minimums
 (requirements -- edges : "Project exact manifest requirements into dependency edges.")
 (dict.pairs (|entry| entry first entry 1 at [package version] dict.take pair) each
  dict.from-pairs) `minimums def

 ### defp check-selection
 (selection -- : "Validate one exact resolved source, version, and archive hash.")
 (|selection|
  selection dict? require
  selection [version source hash] dict.keys-exactly? require
  selection `version at pkg.version.validate pop
  selection `source at pkg.manifest.validate-source pop
  selection `hash at pkg.name.hash? require) `check-selection defp

 ### defp check-edge
 (edge selections -- : "Require a known selection meeting an exact recorded minimum.")
 (|edge selections|
  edge dict? require
  edge [package version] dict.keys-exactly? require
  edge `package at pkg.name.valid? require
  edge `version at pkg.version.validate pop
  selections edge `package at has? require
  selections edge `package at `version pair at-path
  edge `version at pkg.version.less? not require) `check-edge defp

 ### defp check-edges
 (edges selections -- : "Validate one consumer's direct dependency edges.")
 (|edges selections|
  edges dict? require
  edges dict.keys (pkg.name.valid?) all? require
  edges dict.vals (`package at) each dup distinct len swap len = require
  edges dict.vals selections (check-edge) cons for) `check-edges defp

 ### defp visit-edge
 (state child -- state : "Visit a selected dependency with the current ancestor path.")
 (|state child|
  state `lock at child state `path at state `seen at visit
  state swap `seen swap put) `visit-edge defp

 ### defp descend
 (lock name path seen -- seen : "Traverse a previously unseen package and reject cycles.")
 (|lock name path seen|
  {} `lock lock put `path path name append put `seen seen name append put
  lock `requires at name at dict.vals (`package at) each
  swap (visit-edge) fold `seen at) `descend defp

 ### defp visit
 (lock name path seen -- seen : "Check acyclic reachability without fetching any sources.")
 (|lock name path seen|
  path name (match?) cons any? not require
  seen name (match?) cons any?
  seen () cons
  lock name path seen 4 pack (descend) cat
  if) `visit defp

 ### defp root-manifest
 (lock -- manifest : "Validate the exact root requirements retained as the lock's input.")
 (|lock|
  {format 2 version "0.0.0" sources []}
  `name lock `root at put `requires lock `root-requires at put pkg.manifest.validate)
 `root-manifest defp

 ### def validate
 (candidate -- lock : "Validate the complete portable graph without network or installation state.")
 (|lock|
  lock dict? require
  lock [format root root-requires packages requires] dict.keys-exactly? require
  lock `format at 3 match? require
  lock root-manifest pop
  lock `packages at dict? require
  lock `packages at dict.keys (pkg.name.valid?) all? require
  lock `packages at dict.vals (check-selection) for
  lock `root at wrap lock `packages at dict.keys cat
  dup pkg.name.collides? not require
  dup grade at lock `requires at dict.keys dup grade at match? require
  lock `requires at dict.vals lock `packages at (check-edges) cons for
  lock `root-requires at minimums lock `requires at lock `root at at match? require
  lock lock `root at [] [] visit len lock `packages at dict.size 1 + = require
  lock root-manifest lock swap check-manifest
  lock) `validate def

 ### defp check-pin
 (requirement lock -- : "An exact selected minimum retains its declared source and archive hash.")
 (|requirement lock|
  lock `packages at requirement `package at at
  requirement `package del
  (|selection declared|
   selection `version at declared `version at match?
   selection declared pair (match? require) cat when)
  apply) `check-pin defp

 ### def check-manifest
 (lock manifest -- : "Check a manifest against a validated lock's identity, edges, and exact pins.")
 (|lock manifest|
  manifest pkg.manifest.validate pop
  lock manifest lock `root at manifest `name at match?
  (pop pop) (check-identity) if
  manifest `requires at minimums lock `requires at manifest `name at at match? require
  manifest `requires at dict.vals lock (check-pin) cons for) `check-manifest def

 ### defp check-identity
 (lock manifest -- : "A selected artifact must declare its exact locked package version.")
 (|lock manifest|
  lock `packages at manifest `name at `version pair at-path
  manifest `version at match? require) `check-identity defp

 ### def compatible
 (lock manifest -- lock :
  "Honor an existing lock only when its root dependency inputs still match.")
 (|lock manifest|
  lock validate pop manifest pkg.manifest.validate pop
  lock `root at manifest `name at match?
  lock `root-requires at manifest `requires at match? and
  `domain error.new "ecl.lock does not match ecl.pkg; dependency updates require pkg update"
  error.with-message assert
  lock) `compatible def

 ### def read
 (text -- lock : "Read exactly one inert portable project lock.")
 (pkg.data.read-one validate) `read def

 ### defp canonical-entry
 (key holder -- pair : "Canonicalize one nested dictionary entry.")
 (|key holder| key holder key at canonical pair) `canonical-entry defp

 ### defp canonical
 (value -- value : "Sort all metadata dictionary keys while preserving list order.")
 (dup dict?
  (|holder| holder dict.keys dup (str) each grade at
   holder (canonical-entry) cons each dict.from-pairs)
  (dup type `list match? ((canonical) each) () if)
  if) `canonical defp

 ### def write
 (lock -- text : "Write deterministic portable resolution data ending in a newline.")
 (validate canonical str "\n" cat) `write def

 `pkg.test.support `t alias

 ### defp rejected
 (quotation -- : "Require malformed or incompatible metadata to fail.")
 (@attempt result.err? 1 t.equal) `rejected defp

 ### setp empty-lock
 {format 3 root "project" root-requires {} packages {} requires {"project" {}}}
 `empty-lock setp

 ### setp selection
 {version "1.0.0" source {kind archive url "https://example.com/foo.tgz"}
  hash "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
 `selection setp

 ### defp requirement
 (-- requirement : "Build the declared exact source input.")
 (selection `package "foo" put) `requirement defp

 ### defp manifest
 (-- manifest : "Build the project manifest independently of its resolution.")
 ({format 2 name "project" version "0.1.0" sources ["src/**/*.ecl"]}
  `requires {} "api" requirement put put) `manifest defp

 ### defp locked
 (-- lock : "Build one complete portable lock with a consumer-local alias.")
 (empty-lock `root-requires {} "api" requirement put put
  `packages {} "foo" selection put put
  `requires {"project" {"api" {package "foo" version "1.0.0"}} "foo" {}} put)
 `locked defp

 ### test round-trip
 (-- : "Portable locks preserve exact pins and canonicalize all dictionary ordering.")
 (locked pkg.resolution.write pkg.resolution.read locked t.equal
  locked pkg.resolution.write "\n" str.ends? 1 t.equal
  locked `packages at "foo" at `source at `url at "https://example.com/foo.tgz" t.equal
  empty-lock pkg.resolution.validate empty-lock t.equal
  locked `root-requires locked `root-requires at dict.pairs reverse dict.from-pairs put
  pkg.resolution.write locked pkg.resolution.write t.equal)
 `round-trip test

 ### test compatibility
 (-- : "Normal synchronization keeps the locked graph and refuses changed dependency inputs.")
 (locked manifest pkg.resolution.compatible locked t.equal
  locked manifest `version "2.0.0" put pkg.resolution.compatible locked t.equal
  (locked manifest `requires {} put pkg.resolution.compatible) rejected
  (locked manifest `name "another" put pkg.resolution.compatible) rejected
  (locked manifest `requires {} "api" requirement `source
   {kind git url "https://example.com/repo.git" commit
    "0123456789abcdef0123456789abcdef01234567"}
   put put put pkg.resolution.compatible) rejected)
 `compatibility test

 ### test exact-source-pins
 (-- : "Exact minima retain source identities, full Git commits, and archive hashes.")
 (locked `packages {} "foo" selection `source
  {kind git url "https://example.com/repo.git"
   commit "0123456789abcdef0123456789abcdef01234567"} put put put
  (|git-lock| git-lock `root-requires
   {} "api" git-lock `packages at "foo" at `package "foo" put put put)
  apply dup pkg.resolution.write pkg.resolution.read t.equal
  (locked `packages {} "foo" selection `source
   {kind archive url "https://example.com/different.tgz"} put put put
   pkg.resolution.validate) rejected
  (locked `packages {} "foo" selection
   `hash "sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
   put put put pkg.resolution.validate) rejected)
 `exact-source-pins test

 ### test selected-manifest
 (-- : "A higher locked selection is allowed, but its own dependency edges must match.")
 (locked `packages {} "foo" selection `version "1.1.0" put put put
  dup manifest pkg.resolution.compatible t.equal
  locked {format 2 name "foo" version "1.0.0" sources [] requires {}}
  pkg.resolution.check-manifest
  (locked {format 2 name "foo" version "9.0.0" sources [] requires {}}
   pkg.resolution.check-manifest) rejected
  (locked manifest `requires {} put pkg.resolution.check-manifest) rejected)
 `selected-manifest test

 ### test graph-validation
 (-- : "Reject missing, extra, cyclic, unreachable, or unsatisfied resolution edges.")
 ((locked `requires {"project" {"api" {package "foo" version "1.0.0"}}} put
   pkg.resolution.validate) rejected
  (locked `requires {"project" {} "foo" {}} put pkg.resolution.validate) rejected
  (locked `packages {} put pkg.resolution.validate) rejected
  (empty-lock `packages {} "foo" selection put put `requires {"project" {} "foo" {}} put
   pkg.resolution.validate) rejected
  (locked `requires
   {"project" {"api" {package "foo" version "1.0.0"}}
    "foo" {"self" {package "foo" version "1.0.0"}}} put pkg.resolution.validate) rejected
  (locked `packages {} "foo" selection `version "0.9.0" put put put
   pkg.resolution.validate) rejected)
 `graph-validation test

 ### test closed-portable-schema
 (-- : "Installation locations, generation identifiers, and unpinned sources cannot enter a lock.")
 ((locked `store `vendor put pkg.resolution.validate) rejected
  (locked `generation "local" put pkg.resolution.validate) rejected
  (locked `format 2 put pkg.resolution.validate) rejected
  (locked `packages {} "foo" selection `hash "sha256-bad" put put put
   pkg.resolution.validate) rejected
  (locked `packages {} "foo" selection `source
   {kind git url "https://example.com/repo.git" commit "main"} put put put
   pkg.resolution.validate) rejected
  ("{format 3 root host.cwd}" pkg.resolution.read) rejected)
 `closed-portable-schema test
) `pkg.resolution @defm
