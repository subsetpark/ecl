### module pkg.solver
# Resolve reachable package manifests with minimal version selection.
(
 ### defp node-member?
 (nodes node -- bool : "Return 1 when an exact [name version] node occurs in a list.")
 ((match?) cons any?) `node-member? defp

 ### defp manifest-node
 (manifest -- node : "Return a manifest's [name version] identity.")
 ([name version] swap (swap at) cons each) `manifest-node defp

 ### defp node-named?
 (node name -- bool : "Return 1 when an exact node has the given package name.")
 (|node name| node first name match?) `node-named? defp

 ### defp malformed-version
 (package required-package version -- :
  "Raise a malformed-version error reporting the requirer, target, and spelling.")
 (|package required version|
  `domain error.new "a reachable package version is malformed" error.with-message
  package required version 3 pack
  (|package required version|
   `package package
   `required-package required
   `version version)
  infra
  dict.from-kvs
  error.with-data
  raise) `malformed-version defp

 ### defp resolve-version-checked
 (package required-package version -- parts :
  "Validate a reachable version or raise with requirement provenance.")
 (|package required version|
  version (pkg.version.validate) cons @attempt
  dup `ok has?
  (`ok at first)
  package required version 3 pack
  (|attempt-result package required version| package required version malformed-version)
  cat
  if) `resolve-version-checked defp

 ### defp precheck-requirement-value
 (requirement pair package -- : "Validate the version held by a requirement value.")
 (|requirement pair package|
  package requirement `package pair first dict.get requirement `version at
  resolve-version-checked pop) `precheck-requirement-value defp

 ### defp precheck-requirement
 (pair package -- : "Validate a requirement version before full manifest validation.")
 (|pair package| pair 1 at pair package precheck-present-requirement) `precheck-requirement defp

 ### defp precheck-present-requirement
 (requirement pair package -- : "Validate a requirement version when the field is present.")
 (|requirement pair package|
  requirement type `dict match?
  requirement `version has?
  and
  requirement pair package 3 pack (precheck-requirement-value) cat
  when) `precheck-present-requirement defp

 ### defp precheck-own-version
 (candidate package -- : "Validate one manifest's own version with package provenance.")
 (|candidate package|
  package package candidate `version at resolve-version-checked pop) `precheck-own-version defp

 ### defp precheck-requirements-dict
 (requirements package -- : "Validate every version in a requirements dict.")
 (|requirements package| requirements dict.pairs package (precheck-requirement) cons for)
 `precheck-requirements-dict defp

 ### defp precheck-requirements-value
 (requirements package -- : "Validate requirement versions when the field is a dict.")
 (|requirements package|
  requirements type `dict match?
  requirements package pair (precheck-requirements-dict) cat
  ()
  if) `precheck-requirements-value defp

 ### defp precheck-manifest-requirements
 (candidate package -- : "Validate the version spellings in one manifest's requirements.")
 (|candidate package| candidate `requires at package precheck-requirements-value)
 `precheck-manifest-requirements defp

 ### defp resolve-manifest-checked
 (candidate fallback-name -- manifest :
  "Validate a resolver input manifest after attaching package provenance to malformed versions.")
 (|candidate fallback|
  candidate type `dict match?
  `type error.new "a manifest is a dict" error.with-message assert
  candidate
  candidate `name fallback dict.get
  precheck-and-validate-manifest) `resolve-manifest-checked defp

 ### defp precheck-and-validate-manifest
 (candidate package -- manifest :
  "Attach provenance to version failures, then validate a manifest.")
 (|candidate package|
  candidate `version has?
  candidate package pair (precheck-own-version) cat
  when
  candidate `requires has?
  candidate package pair (precheck-manifest-requirements) cat
  when
  candidate pkg.manifest.validate) `precheck-and-validate-manifest defp

 ### defp missing-manifest
 (package required-package version -- :
  "Raise a missing-manifest error reporting the requirer and exact target.")
 (|package required version|
  `domain error.new "pkg.solver.resolve is missing a declared manifest" error.with-message
  package required version 3 pack
  (|package required version|
   `package package
   `required-package required
   `version version)
  infra
  dict.from-kvs
  error.with-data
  raise) `missing-manifest defp

 ### defp hash-conflict
 (name version left-package left-hash right-package right-hash -- :
  "Raise a canonical hash-conflict error for two declarations.")
 (|name version left-package left-hash right-package right-hash|
  name
  version
  left-package right-package cmp -1 =
  left-package left-hash right-package right-hash 4 pack (declaration-pairs) cat
  right-package right-hash left-package left-hash 4 pack (declaration-pairs) cat
  if
  raise-hash-conflict) `hash-conflict defp

 ### defp declaration-pairs
 (left-package left-hash right-package right-hash -- declarations :
  "Build two package/hash declarations in the supplied order.")
 (|left-package left-hash right-package right-hash|
  left-package left-hash pair right-package right-hash pair pair) `declaration-pairs defp

 ### defp raise-hash-conflict
 (name version declarations -- : "Raise a hash conflict from canonically ordered declarations.")
 (|name version declarations|
  `domain error.new "one package version has conflicting hashes" error.with-message
  name version declarations 3 pack
  (|name version declarations|
   `package name
   `version version
   `left-package declarations first first
   `left-hash declarations [0 1] at-path
   `right-package declarations [1 0] at-path
   `right-hash declarations [1 1] at-path)
  infra
  dict.from-kvs
  error.with-data
  raise) `raise-hash-conflict defp

 ### defp requirement-cycle
 (active node -- : "Raise a cycle error carrying its sorted distinct package names.")
 (|active node|
  active active node find drop
  node append
  (first) each
  distinct
  dup grade at
  raise-cycle-packages) `requirement-cycle defp

 ### defp raise-cycle-packages
 (packages -- : "Raise a requirement-cycle error from sorted package names.")
 (|packages|
  `domain error.new "the package requirement graph has a cycle" error.with-message
  `packages packages pair dict.from-kvs
  error.with-data
  raise) `raise-cycle-packages defp

 ### defp prefix-collision
 (names -- : "Raise a canonical prefix-collision error for a set of package names.")
 (|names|
  names
  dup ("." cat) each grade at
  2 windows
  (dup first swap 1 at colliding-names?) filter
  first
  dup grade at
  raise-prefix-collision) `prefix-collision defp

 ### defp raise-prefix-collision
 (pair -- : "Raise a prefix collision from one canonically ordered pair.")
 (|pair|
  `domain error.new "selected packages have overlapping prefixes" error.with-message
  pair wrap
  (|pair|
   `left-package pair first
   `right-package pair 1 at)
  infra
  dict.from-kvs
  error.with-data
  raise) `raise-prefix-collision defp

 ### defp colliding-names?
 (left right -- bool : "Return 1 when either package name owns the other.")
 ((pkg.name.owns?) (swap pkg.name.owns?) bi or) `colliding-names? defp

 ### defp source-record
 (requirement package -- record : "Attach declaring-package provenance to a requirement.")
 (|requirement package|
  requirement `requirer package put
  `git-commit requirement `source at `commit "" dict.get put) `source-record defp

 ### defp merge-source
 (prior name requirement package -- record :
  "Merge a same-hash mirror into a canonical source record or raise on a different hash.")
 (|prior name requirement package|
  prior requirement (`hash at) both match? not
  prior name requirement package 4 pack
  (|prior name requirement package|
   name requirement `version at
   prior (`requirer at) (`hash at) bi
   package requirement `hash at)
  infra
  (hash-conflict) cat
  when
  prior `git-commit prior `git-commit at requirement `source at `commit "" dict.get merge-commit put
  `source prior requirement canonical-source put
  `requirer prior `requirer at package lex-min put) `merge-source defp

 ### defp merge-commit
 (left right -- commit : "Retain Git identity even when an archive mirror sorts first.")
 (|left right|
  left empty? right empty? or left right match? or
  `domain error.new "one package version has conflicting Git commits" error.with-message assert
  left empty? right () cons left () cons if) `merge-commit defp

 ### defp canonical-source
 (prior requirement -- source : "Reject conflicting Git commits and order equivalent mirrors.")
 ((`source at) both canonical-source-pair) `canonical-source defp

 ### defp canonical-source-pair
 (left right -- source : "Choose a source by canonical encoding after checking Git identity.")
 (|left right|
  left pkg.manifest.write-source right pkg.manifest.write-source cmp 1 =
  right () cons left () cons if) `canonical-source-pair defp

 ### defp lex-min
 (left right -- minimum : "Return the lexicographically lesser of two strings.")
 (|left right|
  left right cmp 1 =
  right () cons left () cons if) `lex-min defp

 ### defp existing-source
 (sources node name requirement package -- record : "Merge a declaration into an existing node.")
 (|sources node name requirement package|
  sources node at name requirement package merge-source) `existing-source defp

 ### defp source-for
 (sources node name requirement package -- record :
  "Return the canonical source record after one declaration.")
 (|sources node name requirement package|
  sources node has?
  sources node name requirement package 5 pack (existing-source) cat
  requirement package pair (source-record) cat
  if) `source-for defp

 ### defp record-source
 (state package name requirement -- state :
  "Record one reached artifact source, merging mirrors and rejecting conflicting hashes.")
 (|state package name requirement|
  package name requirement `version at resolve-version-checked pop
  state package name requirement name requirement `version at pair record-source-node)
 `record-source defp

 ### defp record-source-node
 (state package name requirement node -- state : "Insert or merge one exact source node.")
 (|state package name requirement node|
  state
  `sources
  state `sources at
  node
  state `sources at node name requirement package source-for
  put
  put) `record-source-node defp

 ### defp manifest-for
 (state package version requirer -- manifest :
  "Return and validate the exact manifest specified by a reached requirement.")
 (|state package version requirer|
  package version pair
  state `root at manifest-node
  match?
  state (root-manifest) cons
  state package version requirer 4 pack (catalog-manifest) cat
  if
  package version matching-manifest) `manifest-for defp

 ### defp root-manifest
 (state -- manifest : "Return the resolver's validated root manifest.")
 (`root at) `root-manifest defp

 ### defp catalog-value
 (state package version -- manifest :
  "Return an exact manifest already known to exist in the catalog.")
 (|state package version| state `catalog package version 3 pack at-path) `catalog-value defp

 ### defp catalog-manifest
 (state package version requirer -- manifest :
  "Return an exact catalog manifest, or raise an error reporting the requiring package.")
 (|state package version requirer|
  state `catalog at package has?
  state `catalog at package {} dict.get type `dict match?
  and
  state `catalog at package {} dict.get version has?
  and
  state package version 3 pack (catalog-value) cat
  requirer package version 3 pack (missing-manifest) cat
  if) `catalog-manifest defp

 ### defp matching-manifest
 (candidate package version -- manifest :
  "Validate that a catalog manifest matches its catalog keys.")
 (|candidate package version|
  candidate package resolve-manifest-checked
  dup `name at package match?
  over `version at version match?
  and
  `domain error.new "a catalog manifest must match its name and version keys" error.with-message
  assert) `matching-manifest defp

 ### defp walk-manifest
 (state manifest -- state : "Visit every requirement of one manifest in canonical name order.")
 (|state manifest|
  manifest `requires at pkg.data.sorted-entries
  state manifest `name at (walk-edge) cons fold) `walk-manifest defp

 ### defp walk-edge
 (state pair requirer -- state :
  "Record and visit one exact requirement edge, detecting active-path cycles.")
 (|state pair requirer|
  state requirer pair 1 at `package at pair 1 at walk-requirement) `walk-edge defp

 ### defp walk-requirement
 (state requirer package requirement -- state : "Record and visit one unpacked requirement edge.")
 (|state requirer package requirement|
  state requirer package requirement record-source
  package requirement `version at pair
  requirer package requirement visit-node) `walk-requirement defp

 ### defp raise-cycle
 (state node -- : "Raise a requirement-cycle error for an active node.")
 (|state node| state `active at node requirement-cycle) `raise-cycle defp

 ### defp visit-node
 (state node requirer package requirement -- state :
  "Skip a visited node or visit a new exact node.")
 (|state node requirer package requirement|
  state `active at node node-member?
  state node pair (raise-cycle) cat
  when
  state `visited at node node-member?
  state () cons
  state node requirer package requirement 5 pack (visit-new-node) cat
  if) `visit-node defp

 ### defp visit-new-node
 (state node requirer package requirement -- state :
  "Load, enter, and traverse one new exact node.")
 (|state node requirer package requirement|
  state node
  state package requirement `version at requirer manifest-for
  enter-node) `visit-new-node defp

 ### defp enter-node
 (state node manifest -- state :
  "Record an active manifest, traverse it, and mark its node visited.")
 (|state node manifest|
  state `manifests
  state `manifests at node manifest put
  put
  `active
  state `active at node append
  put
  manifest
  walk-manifest
  node finish-node) `enter-node defp

 ### defp finish-node
 (state node -- state : "Remove a traversed node from the active path and mark it visited.")
 (|state node|
  state
  `active
  state `active at -1 drop
  put
  `visited
  state `visited at node append
  put) `finish-node defp

 ### defp selected-names
 (state -- names : "Return reached package names in canonical order.")
 (`sources at dict.keys (first) each distinct dup grade at) `selected-names defp

 ### defp selected-node
 (name state -- node : "Return the highest reached exact node for a package name.")
 (|name state|
  state `sources at dict.keys
  name (node-named?) cons filter
  dup (1 at) each pkg.version.max
  node-with-version) `selected-node defp

 ### defp node-has-version?
 (node version -- bool : "Return 1 when an exact node has the given version.")
 (|node version| node 1 at version match?) `node-has-version? defp

 ### defp node-with-version
 (nodes version -- node : "Return the exact node with a given version.")
 (|nodes version| nodes version (node-has-version?) cons filter first) `node-with-version defp

 ### defp selection-pair
 (name state -- pair : "Return one selected package entry.")
 (|name state|
  state `sources name state selected-node pair at-path `requirer del `git-commit del `package del
  name swap pair) `selection-pair defp

 ### defp selected-packages
 (state -- packages : "Build the selected package map from reached artifact sources.")
 (|state| state selected-names state (selection-pair) cons each raze dict.from-kvs)
 `selected-packages defp

 ### defp minimum-map
 (manifest -- minimums : "Return one manifest's alias-to-package minimum requirements.")
 (`requires at dup dict.keys swap dict.vals
  (|requirement|
   requirement wrap
   (|requirement| `package requirement `package at `version requirement `version at)
   infra
   dict.from-kvs)
  each
  dict.zip) `minimum-map defp

 ### defp requires-pair
 (name state -- pair : "Return one selected package's per-requirer minimum map.")
 (|name state|
  state `manifests name state selected-node pair at-path minimum-map
  name swap pair) `requires-pair defp

 ### defp resolved-requires
 (state -- requires : "Build the root-plus-selected per-requirer requirement table.")
 (|state|
  state ([root name] at-path) (`root at minimum-map) bi pair wrap
  state selected-names state (requires-pair) cons each
  cat raze dict.from-kvs) `resolved-requires defp

 ### defp resolved-lock
 (state -- lock : "Build and validate the portable lock for a completed graph traversal.")
 (|state|
  state [root name] at-path state selected-names cons
  dup pkg.name.collides? (prefix-collision) (pop) if
  state wrap
  (|state|
   `format 3
   `root-requires state [root requires] at-path
   `root state [root name] at-path
   `packages state selected-packages
   `requires state resolved-requires)
  infra
  dict.from-kvs
  prune pkg.resolution.validate) `resolved-lock defp

 ### defp reach-step
 (state -- state : "Traverse selected direct edges, retaining each package name once.")
 (dup `pending at first
  (|state name|
   state `pending state `pending at 1 drop put
   name reach-name) apply) `reach-step defp

 ### defp reach-name
 (state name -- state : "Skip already reached names before adding selected dependency edges.")
 (|state name|
  state `seen at name (match?) cons any?
  state () cons state name pair (reach-new) cat if) `reach-name defp

 ### defp reach-new
 (state name -- state : "Record one selected package and enqueue its direct dependencies.")
 (|state name|
  state `seen state `seen at name append put
  `pending state `pending at state `requires at name at dict.vals (`package at) each cat put)
 `reach-new defp

 ### defp prune
 (lock -- lock : "Drop dependencies reachable only through superseded minimum-version manifests.")
 (|lock|
  {seen []} `pending lock `root at wrap put `requires lock `requires at put
  (dup `pending at empty? not) (reach-step) while `seen at
  lock (prune-names) cons apply) `prune defp

 ### defp prune-names
 (names lock -- lock : "Keep the selected graph portable and entirely root-reachable.")
 (|names lock|
  lock `requires lock `requires at names dict.take put
  `packages lock `packages at names lock `root at (match? not) cons filter dict.take put)
 `prune-names defp

 ### def resolve
 (root-manifest manifests -- lock :
  "Resolve the reachable requirement graph by minimal version selection and return a validated
   lock.")
 (|root catalog|
  catalog type `dict match?
  `type error.new "pkg.solver.resolve expects a manifest catalog dict" error.with-message assert
  catalog
  root "root" resolve-manifest-checked
  resolve-validated) `resolve def

 ### defp resolve-validated
 (catalog root -- lock : "Traverse a validated root against a catalog and construct its lock.")
 (|catalog root|
  catalog root pair
  (|catalog root|
   `root root
   `catalog catalog
   `visited []
   `active root manifest-node wrap
   `sources {}
   `manifests {})
  infra
  dict.from-kvs
  root walk-manifest resolved-lock) `resolve-validated defp

 `pkg.test.support `t alias

 ### defp pinned-requirement
 (name version -- requirement : "Construct an exact inert fixture pin without network access.")
 (|name version|
  {hash "sha256-0000000000000000000000000000000000000000000000000000000000000000"}
  `package name put `version version put
  `source {kind archive} `url "https://fixture.invalid/" name cat "/" cat version cat put put)
 `pinned-requirement defp

 ### defp edge-manifest
 (name version requirements -- manifest :
  "Build a source-free fixture manifest with explicit edges.")
 (|name version requirements|
  {format 2 sources []} `name name put `version version put `requires requirements put)
 `edge-manifest defp

 ### defp superseding-catalog
 (-- catalog : "A higher selected version removes a dependency of its superseded minimum.")
 ({} "alpha" {} "1.0.0" "alpha" "1.0.0" {} "charlie" "charlie" "1.0.0" pinned-requirement put
  edge-manifest put
  "2.0.0" "alpha" "2.0.0" {} edge-manifest put put
  "bravo" {} "1.0.0" "bravo" "1.0.0" {} "alpha" "alpha" "2.0.0" pinned-requirement put edge-manifest
  put put
  "charlie" {} "1.0.0" "charlie" "1.0.0" {} edge-manifest put put) `superseding-catalog defp

 ### test selected-reachability
 (-- : "A superseded minimum does not retain an unreachable package in the portable lock.")
 ("project" "1.0.0" {} "alpha" "alpha" "1.0.0" pinned-requirement put
  "bravo" "bravo" "1.0.0" pinned-requirement put edge-manifest
  superseding-catalog pkg.solver.resolve
  dup `format at 3 t.equal
  dup `packages at dict.keys dup grade at ["alpha" "bravo"] t.equal
  dup `packages at "alpha" at `version at "2.0.0" t.equal
  dup `requires at dict.keys dup grade at ["alpha" "bravo" "project"] t.equal
  dup pkg.resolution.write pkg.resolution.read t.equal) `selected-reachability test

 ### defp requirement
 (package version url hash -- requirement : "Construct requirement fixture data.")
 (|package version url hash|
  {} `package package put `version version put `source {} `kind `archive put `url url put put `hash
  hash put) `requirement defp

 ### defp manifest
 (name version requires -- manifest : "Construct manifest fixture data.")
 (|name version requires|
  {} `format 2 put
  `name name put
  `version version put
  `sources ["**/*"] put
  `requires requires put)
 `manifest defp

 ### defp hash-a
 (-- hash : "Return the first valid fixture hash.")
 ("sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef") `hash-a defp

 ### defp hash-b
 (-- hash : "Return the second valid fixture hash.")
 ("sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789") `hash-b defp

 ### defp req-b
 (-- requirement : "Require b 1.0.0.")
 ("b" "1.0.0" "https://e.com/b.tgz" hash-a requirement) `req-b defp

 ### defp req-c-12
 (-- requirement : "Require c 1.2.0.")
 ("c" "1.2.0" "https://e.com/c12.tgz" hash-a requirement) `req-c-12 defp

 ### defp req-c-15
 (-- requirement : "Require c 1.5.0.")
 ("c" "1.5.0" "https://e.com/c15.tgz" hash-b requirement) `req-c-15 defp

 ### defp manifest-b
 (-- manifest : "Return b's transitive fixture manifest.")
 ("b" "1.0.0" {} "c" req-c-15 put manifest) `manifest-b defp

 ### defp manifest-c-12
 (-- manifest : "Return c 1.2.0's fixture manifest.")
 ("c" "1.2.0" {} manifest) `manifest-c-12 defp

 ### defp manifest-c-15
 (-- manifest : "Return c 1.5.0's fixture manifest.")
 ("c" "1.5.0" {} manifest) `manifest-c-15 defp

 ### defp root
 (-- manifest : "Return the root MVS fixture.")
 ("app" "0.1.0" {} "b" req-b put "c" req-c-12 put manifest) `root defp

 ### defp root-without-c
 (-- manifest : "Return the root fixture without its direct c requirement.")
 ("app" "0.1.0" {} "b" req-b put manifest) `root-without-c defp

 ### defp catalog
 (-- catalog : "Return the reachable MVS fixture catalog.")
 ({}
  "b" {} "1.0.0" manifest-b put put
  "c" {} "1.2.0" manifest-c-12 put "1.5.0" manifest-c-15 put put) `catalog defp

 ### defp git-requirement
 (commit -- requirement : "Require c 1.2.0 from one pinned Git source.")
 (|commit|
  req-c-12 `source {kind git url "https://e.com/c.git"} `commit commit put put)
 `git-requirement defp

 ### defp git-graph
 (left right -- root catalog : "Build two declarations of one Git package identity.")
 (|left right|
  root `requires root `requires at "c" left git-requirement put put
  catalog "b" {} "1.0.0"
  "b" "1.0.0" {} "c" right git-requirement put manifest put put)
 `git-graph defp

 ### test pinned-git
 (-- : "Preserve pinned sources and reject differing commits despite equal artifact hashes.")
 ("0123456789abcdef0123456789abcdef01234567"
  dup git-graph pkg.solver.resolve
  [packages "c" source commit] at-path
  "0123456789abcdef0123456789abcdef01234567" t.equal
  ("0123456789abcdef0123456789abcdef01234567"
   "1123456789abcdef0123456789abcdef01234567"
   git-graph pkg.solver.resolve)
  `domain "conflicting Git commits" t.raises-containing)
 `pinned-git test

 ### test resolution
 (-- : "Select every reachable maximum and record all declared minimums.")
 (root catalog pkg.solver.resolve
  dup `packages at dup dict.size 2 t.equal
  ["c" version] at-path "1.5.0" t.equal
  root catalog pkg.solver.resolve
  dup `requires at dict.vals (dict.pairs) each raze
  swap `packages at
  (|entry packages|
   packages entry 1 at `package at `version pair at-path
   entry 1 at `version at pkg.version.less? not)
  cons
  all?
  1 t.equal)
 `resolution test

 ### test deterministic-input-order
 (-- : "Ignore graph insertion order and unreachable catalog versions.")
 (root catalog pkg.solver.resolve pkg.resolution.write
  "app" "0.1.0" {} "c" req-c-12 put "b" req-b put manifest
  {}
  "c"
  {}
  "9.0.0" "c" "9.0.0" {} manifest put
  "1.5.0" manifest-c-15 put
  "1.2.0" manifest-c-12 put
  put
  "b" {} "1.0.0" manifest-b put put
  pkg.solver.resolve pkg.resolution.write
  match?
  1 t.equal
  root-without-c catalog pkg.solver.resolve `packages at
  root catalog pkg.solver.resolve
  (|packages lock|
   packages lock `packages at match? 1 t.equal
   lock [requires "app" "c"] at-path
   {package "c" version "1.2.0"} t.equal)
  apply)
 `deterministic-input-order test

 ### test conflicts
 (-- : "Report hash, prefix, and cycle conflicts with responsible packages.")
 (("app" "0.1.0"
   {}
   "b" req-b put
   "c" "c" "1.5.0" "https://mirror.example/c.tgz" hash-a requirement put
   manifest
   catalog
   pkg.solver.resolve)
  `domain
  "conflicting hashes"
  t.raises-containing
  ("app" "0.1.0"
   {}
   "a" "a" "1.0.0" "https://e.com/a.tgz" hash-a requirement put
   "b" "b" "1.0.0" "https://e.com/b.tgz" hash-b requirement put
   manifest
   {}
   "a"
   {} "1.0.0"
   "a" "1.0.0"
   {} "foo" "foo" "1.0.0" "https://e.com/foo.tgz" hash-a requirement put
   manifest
   put put
   "b"
   {} "1.0.0"
   "b" "1.0.0"
   {} "foo.bar"
   "foo.bar" "1.0.0" "https://e.com/foo-bar.tgz" hash-b requirement put
   manifest
   put put
   "foo" {} "1.0.0" "foo" "1.0.0" {} manifest put put
   "foo.bar" {} "1.0.0" "foo.bar" "1.0.0" {} manifest put put
   pkg.solver.resolve)
  `domain
  "overlapping prefixes"
  t.raises-containing
  "app" "0.1.0"
  {} "a" "a" "1.0.0" "https://e.com/a.tgz" hash-a requirement put
  manifest
  {}
  "a" {} "1.0.0"
  "a" "1.0.0"
  {} "b" "b" "1.0.0" "https://e.com/b.tgz" hash-b requirement put
  manifest put put
  "b" {} "1.0.0"
  "b" "1.0.0"
  {} "a" "a" "1.0.0" "https://e.com/a.tgz" hash-a requirement put
  manifest put put
  pair (pkg.solver.resolve) cat @attempt
  `err at
  dup `kind at `domain t.equal
  `data at `packages at ("a" "b") t.equal)
 `conflicts test

 ### test malformed-and-missing
 (-- : "Identify malformed requirements and absent exact manifests.")
 (("app" "0.1.0"
   {} "b" "b" "not-a-version" "https://e.com/b.tgz" hash-a requirement put
   manifest
   {}
   pkg.solver.resolve)
  `domain
  `version
  "not-a-version"
  t.raises-data
  (root-without-c {} pkg.solver.resolve)
  `domain
  `version
  "1.0.0"
  t.raises-data)
 `malformed-and-missing test

 ### test documentation
 (-- : "Require documentation for package resolution.")
 ((pkg.solver.resolve) t.documented)
 `documentation test
) `pkg.solver @defm
