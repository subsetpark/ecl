### module pkg.mvs
# Resolve reachable package manifests with minimal version selection.
(
 ### defp node-member?
 (nodes node -- bool : "Return 1 when an exact [name version] node occurs in a list.")
 ((match?) partial any?)
 'node-member? defp

 ### defp manifest-node
 (manifest -- node : "Return a manifest's [name version] identity.")
 (['name 'version] swap (swap at) partial each)
 'manifest-node defp

 ### defp node-named?
 (node name -- bool : "Return 1 when an exact node has the given package name.")
 (|node name| node first name match?)
 'node-named? defp

 ### defp malformed-version
 (package required-package version -- :
  "Raise a malformed-version error naming the requirer, target, and spelling.")
 (|package required version|
  'domain error.new "a reachable package version is malformed" error.with-message
  package required version 3 pack
  (|package required version|
   'package package
   'required-package required
   'version version)
  infra
  dict.from-flat
  error.with-data
  raise)
 'malformed-version defp

 ### defp resolve-version-checked
 (package required-package version -- parts :
  "Validate a reachable version or raise with requirement provenance.")
 (|package required version|
  version wrap (pkg.version.validate) seed @attempt
  dup 'ok dict.has?
  ('ok at first)
  package required version 3 pack
  (|attempt-result package required version| package required version malformed-version)
  with
  if)
 'resolve-version-checked defp

 ### defp precheck-requirement-value
 (requirement pair package -- : "Validate the version held by a requirement value.")
 (|requirement pair package|
  package pair first requirement 'version at resolve-version-checked pop)
 'precheck-requirement-value defp

 ### defp precheck-requirement
 (pair package -- : "Validate a requirement version before full manifest validation.")
 (|pair package| pair 1 at pair package precheck-present-requirement)
 'precheck-requirement defp

 ### defp precheck-present-requirement
 (requirement pair package -- : "Validate a requirement version when the field is present.")
 (|requirement pair package|
  requirement type 'dict match?
  requirement 'version dict.has?
  and
  requirement pair package 3 pack (precheck-requirement-value) with
  when)
 'precheck-present-requirement defp

 ### defp precheck-own-version
 (candidate package -- : "Validate one manifest's own version with package provenance.")
 (|candidate package|
  package package candidate 'version at resolve-version-checked pop)
 'precheck-own-version defp

 ### defp precheck-requirements-dict
 (requirements package -- : "Validate every version in a requirements dict.")
 (|requirements package| requirements dict.pairs package (precheck-requirement) partial for)
 'precheck-requirements-dict defp

 ### defp precheck-requirements-value
 (requirements package -- : "Validate requirement versions when the field is a dict.")
 (|requirements package|
  requirements type 'dict match?
  requirements package pair (precheck-requirements-dict) with
  ()
  if)
 'precheck-requirements-value defp

 ### defp precheck-manifest-requirements
 (candidate package -- : "Validate the version spellings in one manifest's requirements.")
 (|candidate package| candidate 'requires at package precheck-requirements-value)
 'precheck-manifest-requirements defp

 ### defp resolve-manifest-checked
 (candidate fallback-name -- manifest :
  "Validate a resolver input manifest after attaching package provenance to malformed versions.")
 (|candidate fallback|
  candidate type 'dict match?
  'type error.new "a manifest is a dict" error.with-message assert
  candidate
  candidate 'name fallback at-or
  precheck-and-validate-manifest)
 'resolve-manifest-checked defp

 ### defp precheck-and-validate-manifest
 (candidate package -- manifest :
  "Attach provenance to version failures, then validate a manifest.")
 (|candidate package|
  candidate 'version dict.has?
  candidate package pair (precheck-own-version) with
  when
  candidate 'requires dict.has?
  candidate package pair (precheck-manifest-requirements) with
  when
  candidate pkg.manifest.validate)
 'precheck-and-validate-manifest defp

 ### defp missing-manifest
 (package required-package version -- :
  "Raise a missing-manifest error naming the requirer and exact target.")
 (|package required version|
  'domain error.new "pkg.mvs.resolve is missing a declared manifest" error.with-message
  package required version 3 pack
  (|package required version|
   'package package
   'required-package required
   'version version)
  infra
  dict.from-flat
  error.with-data
  raise)
 'missing-manifest defp

 ### defp hash-conflict
 (name version left-package left-hash right-package right-hash -- :
  "Raise a canonical hash-conflict error for two declarations.")
 (|name version left-package left-hash right-package right-hash|
  name
  version
  left-package right-package cmp -1 =
  left-package left-hash right-package right-hash 4 pack (declaration-pairs) with
  right-package right-hash left-package left-hash 4 pack (declaration-pairs) with
  if
  raise-hash-conflict)
 'hash-conflict defp

 ### defp declaration-pairs
 (left-package left-hash right-package right-hash -- declarations :
  "Build two package/hash declarations in the supplied order.")
 (|left-package left-hash right-package right-hash|
  left-package left-hash pair right-package right-hash pair pair)
 'declaration-pairs defp

 ### defp raise-hash-conflict
 (name version declarations -- : "Raise a hash conflict from canonically ordered declarations.")
 (|name version declarations|
  'domain error.new "one package version has conflicting hashes" error.with-message
  name version declarations 3 pack
  (|name version declarations|
   'package name
   'version version
   'left-package declarations first first
   'left-hash declarations [0 1] at-path
   'right-package declarations [1 0] at-path
   'right-hash declarations [1 1] at-path)
  infra
  dict.from-flat
  error.with-data
  raise)
 'raise-hash-conflict defp

 ### defp requirement-cycle
 (active node -- : "Raise a cycle error carrying its sorted distinct package names.")
 (|active node|
  active active node find drop
  node append
  (first) each
  distinct
  sort
  raise-cycle-packages)
 'requirement-cycle defp

 ### defp raise-cycle-packages
 (packages -- : "Raise a requirement-cycle error from sorted package names.")
 (|packages|
  'domain error.new "the package requirement graph has a cycle" error.with-message
  'packages packages pair dict.from-flat
  error.with-data
  raise)
 'raise-cycle-packages defp

 ### defp prefix-collision
 (names -- : "Raise a canonical prefix-collision error for a set of package names.")
 (|names|
  names
  dup ("." cat) each grade at
  2 windows
  (dup first swap 1 at colliding-names?) filter
  first
  sort
  raise-prefix-collision)
 'prefix-collision defp

 ### defp raise-prefix-collision
 (pair -- : "Raise a prefix collision from one canonically ordered pair.")
 (|pair|
  'domain error.new "selected packages have overlapping prefixes" error.with-message
  pair wrap
  (|pair|
   'left-package pair first
   'right-package pair 1 at)
  infra
  dict.from-flat
  error.with-data
  raise)
 'raise-prefix-collision defp

 ### defp colliding-names?
 (left right -- bool : "Return 1 when either package name owns the other.")
 ((pkg.name.owns?) (swap pkg.name.owns?) bi2 or)
 'colliding-names? defp

 ### defp source-record
 (requirement package -- record : "Attach declaring-package provenance to a requirement.")
 (|requirement package| requirement 'package package put)
 'source-record defp

 ### defp merge-source
 (prior name requirement package -- record :
  "Merge a same-hash mirror into a canonical source record or raise on a different hash.")
 (|prior name requirement package|
  prior requirement ('hash at) both match? not
  prior name requirement package 4 pack
  (|prior name requirement package|
   name requirement 'version at
   prior ('package at) ('hash at) bi
   package requirement 'hash at)
  infra
  (hash-conflict) with
  when
  prior 'url prior requirement ('url at) both lex-min put
  'package prior 'package at package lex-min put)
 'merge-source defp

 ### defp lex-min
 (left right -- minimum : "Return the lexicographically lesser of two strings.")
 (|left right|
  left right cmp 1 =
  right () partial left () partial if)
 'lex-min defp

 ### defp existing-source
 (sources node name requirement package -- record : "Merge a declaration into an existing node.")
 (|sources node name requirement package|
  sources node at name requirement package merge-source)
 'existing-source defp

 ### defp source-for
 (sources node name requirement package -- record :
  "Return the canonical source record after one declaration.")
 (|sources node name requirement package|
  sources node dict.has?
  sources node name requirement package 5 pack (existing-source) with
  requirement package pair (source-record) with
  if)
 'source-for defp

 ### defp record-source
 (state package name requirement -- state :
  "Record one reached artifact source, merging mirrors and rejecting conflicting hashes.")
 (|state package name requirement|
  package name requirement 'version at resolve-version-checked pop
  state package name requirement name requirement 'version at pair record-source-node)
 'record-source defp

 ### defp record-source-node
 (state package name requirement node -- state : "Insert or merge one exact source node.")
 (|state package name requirement node|
  state
  'sources
  state 'sources at
  node
  state 'sources at node name requirement package source-for
  put
  put)
 'record-source-node defp

 ### defp manifest-for
 (state package version requirer -- manifest :
  "Return and validate the exact manifest named by a reached requirement.")
 (|state package version requirer|
  package version pair
  state 'root at manifest-node
  match?
  state (root-manifest) partial
  state package version requirer 4 pack (catalog-manifest) with
  if
  package version matching-manifest)
 'manifest-for defp

 ### defp root-manifest
 (state -- manifest : "Return the resolver's validated root manifest.")
 ('root at)
 'root-manifest defp

 ### defp catalog-value
 (state package version -- manifest :
  "Return an exact manifest already known to exist in the catalog.")
 (|state package version| state 'catalog package version 3 pack at-path)
 'catalog-value defp

 ### defp catalog-manifest
 (state package version requirer -- manifest :
  "Return an exact catalog manifest, or raise an error naming the requiring package.")
 (|state package version requirer|
  state 'catalog at package dict.has?
  state 'catalog at package {} at-or type 'dict match?
  and
  state 'catalog at package {} at-or version dict.has?
  and
  state package version 3 pack (catalog-value) with
  requirer package version 3 pack (missing-manifest) with
  if)
 'catalog-manifest defp

 ### defp matching-manifest
 (candidate package version -- manifest :
  "Validate that a catalog manifest matches its catalog keys.")
 (|candidate package version|
  candidate package resolve-manifest-checked
  dup 'name at package match?
  over 'version at version match?
  and
  'domain error.new "a catalog manifest must match its name and version keys" error.with-message
  assert)
 'matching-manifest defp

 ### defp walk-manifest
 (state manifest -- state : "Visit every requirement of one manifest in canonical name order.")
 (|state manifest|
  manifest 'requires at pkg.data.sorted-entries
  state manifest 'name at (walk-edge) partial fold)
 'walk-manifest defp

 ### defp walk-edge
 (state pair requirer -- state :
  "Record and visit one exact requirement edge, detecting active-path cycles.")
 (|state pair requirer|
  state requirer pair first pair 1 at walk-requirement)
 'walk-edge defp

 ### defp walk-requirement
 (state requirer package requirement -- state : "Record and visit one unpacked requirement edge.")
 (|state requirer package requirement|
  state requirer package requirement record-source
  package requirement 'version at pair
  requirer package requirement visit-node)
 'walk-requirement defp

 ### defp raise-cycle
 (state node -- : "Raise a requirement-cycle error for an active node.")
 (|state node| state 'active at node requirement-cycle)
 'raise-cycle defp

 ### defp visit-node
 (state node requirer package requirement -- state :
  "Skip a visited node or visit a new exact node.")
 (|state node requirer package requirement|
  state 'active at node node-member?
  state node pair (raise-cycle) with
  when
  state 'visited at node node-member?
  state () partial
  state node requirer package requirement 5 pack (visit-new-node) with
  if)
 'visit-node defp

 ### defp visit-new-node
 (state node requirer package requirement -- state :
  "Load, enter, and traverse one new exact node.")
 (|state node requirer package requirement|
  state node
  state package requirement 'version at requirer manifest-for
  enter-node)
 'visit-new-node defp

 ### defp enter-node
 (state node manifest -- state :
  "Record an active manifest, traverse it, and mark its node visited.")
 (|state node manifest|
  state 'manifests
  state 'manifests at node manifest put
  put
  'active
  state 'active at node append
  put
  manifest
  walk-manifest
  node finish-node)
 'enter-node defp

 ### defp finish-node
 (state node -- state : "Remove a traversed node from the active path and mark it visited.")
 (|state node|
  state
  'active
  state 'active at -1 drop
  put
  'visited
  state 'visited at node append
  put)
 'finish-node defp

 ### defp selected-names
 (state -- names : "Return reached package names in canonical order.")
 ('sources at dict.keys (first) each distinct sort)
 'selected-names defp

 ### defp selected-node
 (name state -- node : "Return the highest reached exact node for a package name.")
 (|name state|
  state 'sources at dict.keys
  name (node-named?) partial filter
  dup (1 at) each pkg.version.max
  node-with-version)
 'selected-node defp

 ### defp node-has-version?
 (node version -- bool : "Return 1 when an exact node has the given version.")
 (|node version| node 1 at version match?)
 'node-has-version? defp

 ### defp node-with-version
 (nodes version -- node : "Return the exact node with a given version.")
 (|nodes version| nodes version (node-has-version?) partial filter first)
 'node-with-version defp

 ### defp selection-pair
 (name state -- pair : "Return one selected package entry.")
 (|name state|
  state 'sources name state selected-node pair at-path 'package del
  name swap pair)
 'selection-pair defp

 ### defp selected-packages
 (state -- packages : "Build the selected package map from reached artifact sources.")
 (|state| state selected-names state (selection-pair) partial each raze dict.from-flat)
 'selected-packages defp

 ### defp minimum-map
 (manifest -- minimums : "Return one manifest's required names and minimum versions.")
 ('requires at dup dict.keys swap dict.vals ('version at) each dict.from-lists)
 'minimum-map defp

 ### defp requires-pair
 (name state -- pair : "Return one selected package's per-requirer minimum map.")
 (|name state|
  state 'manifests name state selected-node pair at-path minimum-map
  name swap pair)
 'requires-pair defp

 ### defp resolved-requires
 (state -- requires : "Build the root-plus-selected per-requirer requirement table.")
 (|state|
  state (['root 'name] at-path) ('root at minimum-map) bi pair wrap
  state selected-names state (requires-pair) partial each
  cat raze dict.from-flat)
 'resolved-requires defp

 ### defp resolved-lock
 (state -- lock : "Build and validate the format-1 lock for a completed graph traversal.")
 (|state|
  state ['root 'name] at-path state selected-names cons
  dup pkg.name.collides? (prefix-collision) (pop) if
  state wrap
  (|state|
   'format 1
   'root state ['root 'name] at-path
   'packages state selected-packages
   'requires state resolved-requires)
  infra
  dict.from-flat
  pkg.lock.validate)
 'resolved-lock defp

 ### def resolve
 (root-manifest manifests -- lock :
  "Resolve the reachable requirement graph by minimal version selection and return a validated
   lock.")
 (|root catalog|
  catalog type 'dict match?
  'type error.new "pkg.mvs.resolve expects a manifest catalog dict" error.with-message assert
  catalog
  root "root" resolve-manifest-checked
  resolve-validated)
 'resolve def

 ### defp resolve-validated
 (catalog root -- lock : "Traverse a validated root against a catalog and construct its lock.")
 (|catalog root|
  catalog root pair
  (|catalog root|
   'root root
   'catalog catalog
   'visited []
   'active root manifest-node wrap
   'sources {}
   'manifests {})
  infra
  dict.from-flat
  root walk-manifest resolved-lock)
 'resolve-validated defp
 ) 'pkg.mvs @defm
