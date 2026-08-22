### module pkg.mvs
# Resolve reachable package manifests with minimal version selection.
(
 ### defp node-member?
 (|nodes node| nodes node (match?) partial any?)
 (nodes node -- bool : "Return 1 when an exact [name version] node occurs in a list.")
 'node-member? defp

 ### defp manifest-node
 (['name 'version] swap (swap at) partial each)
 (manifest -- node : "Return a manifest's [name version] identity.")
 'manifest-node defp

 ### defp node-named?
 (|node name| node first name match?)
 (node name -- bool : "Return 1 when an exact node has the given package name.")
 'node-named? defp

 ### defp malformed-version
 (|package required version|
  {'kind 'domain 'msg "a reachable package version is malformed"}
  'data
  package required version 3 pack
  (|package required version|
   'package package
   'required-package required
   'version version)
  infra
  dict-of
  put
  raise)
 (package required-package version -- :
  "Raise a malformed-version error naming the requirer, target, and spelling.")
 'malformed-version defp

 ### defp malformed-result
 (|result package required version| result pop package required version malformed-version)
 (result package required-package version -- :
  "Discard a captured validation result and raise its provenance-rich replacement.")
 'malformed-result defp

 ### defp resolve-version-checked
 (|package required version|
  version wrap (pkg.version.validate) with @attempt
  dup 'ok has?
  ('ok at first)
  package required version 3 pack (malformed-result) with
  if)
 (package required-package version -- parts :
  "Validate a reachable version or raise with requirement provenance.")
 'resolve-version-checked defp

 ### defp precheck-requirement-value
 (|requirement pair package|
  package pair first requirement 'version at resolve-version-checked pop)
 (requirement pair package -- : "Validate the version held by a requirement value.")
 'precheck-requirement-value defp

 ### defp precheck-requirement
 (|pair package| pair 1 at pair package precheck-present-requirement)
 (pair package -- : "Validate a requirement version before full manifest validation.")
 'precheck-requirement defp

 ### defp precheck-present-requirement
 (|requirement pair package|
  requirement type 'dict match?
  requirement 'version has?
  and
  requirement pair package 3 pack (precheck-requirement-value) with
  when)
 (requirement pair package -- : "Validate a requirement version when the field is present.")
 'precheck-present-requirement defp

 ### defp precheck-own-version
 (|candidate package|
  package package candidate 'version at resolve-version-checked pop)
 (candidate package -- : "Validate one manifest's own version with package provenance.")
 'precheck-own-version defp

 ### defp precheck-requirements-dict
 (|requirements package| requirements pairs package (precheck-requirement) partial for)
 (requirements package -- : "Validate every version in a requirements dict.")
 'precheck-requirements-dict defp

 ### defp precheck-requirements-value
 (|requirements package|
  requirements type 'dict match?
  requirements package pair (precheck-requirements-dict) with
  ()
  if)
 (requirements package -- : "Validate requirement versions when the field is a dict.")
 'precheck-requirements-value defp

 ### defp precheck-manifest-requirements
 (|candidate package| candidate 'requires at package precheck-requirements-value)
 (candidate package -- : "Validate the version spellings in one manifest's requirements.")
 'precheck-manifest-requirements defp

 ### defp resolve-manifest-checked
 (|candidate fallback|
  candidate type 'dict match?
  {'kind 'type 'msg "a manifest is a dict"} assert
  candidate
  candidate 'name fallback at-or
  precheck-and-validate-manifest)
 (candidate fallback-name -- manifest :
  "Validate a resolver input manifest after attaching package provenance to malformed versions.")
 'resolve-manifest-checked defp

 ### defp precheck-and-validate-manifest
 (|candidate package|
  candidate 'version has?
  candidate package pair (precheck-own-version) with
  when
  candidate 'requires has?
  candidate package pair (precheck-manifest-requirements) with
  when
  candidate pkg.manifest.validate)
 (candidate package -- manifest :
  "Attach provenance to version failures, then validate a manifest.")
 'precheck-and-validate-manifest defp

 ### defp missing-manifest
 (|package required version|
  {'kind 'domain 'msg "pkg.mvs.resolve is missing a declared manifest"}
  'data
  package required version 3 pack
  (|package required version|
   'package package
   'required-package required
   'version version)
  infra
  dict-of
  put
  raise)
 (package required-package version -- :
  "Raise a missing-manifest error naming the requirer and exact target.")
 'missing-manifest defp

 ### defp hash-conflict
 (|name version left-package left-hash right-package right-hash|
  name
  version
  left-package right-package cmp -1 =
  left-package left-hash right-package right-hash 4 pack (declaration-pairs) with
  right-package right-hash left-package left-hash 4 pack (declaration-pairs) with
  if
  raise-hash-conflict)
 (name version left-package left-hash right-package right-hash -- :
  "Raise a canonical hash-conflict error for two declarations.")
 'hash-conflict defp

 ### defp declaration-pairs
 (|left-package left-hash right-package right-hash|
  left-package left-hash pair right-package right-hash pair pair)
 (left-package left-hash right-package right-hash -- declarations :
  "Build two package/hash declarations in the supplied order.")
 'declaration-pairs defp

 ### defp raise-hash-conflict
 (|name version declarations|
  {'kind 'domain 'msg "one package version has conflicting hashes"}
  'data
  name version declarations 3 pack
  (|name version declarations|
   'package name
   'version version
   'left-package declarations first first
   'left-hash declarations [0 1] at-path
   'right-package declarations [1 0] at-path
   'right-hash declarations [1 1] at-path)
  infra
  dict-of
  put
  raise)
 (name version declarations -- : "Raise a hash conflict from canonically ordered declarations.")
 'raise-hash-conflict defp

 ### defp requirement-cycle
 (|active node|
  active active node find drop
  node append
  (first) each
  distinct
  sort
  raise-cycle-packages)
 (active node -- : "Raise a cycle error carrying its sorted distinct package names.")
 'requirement-cycle defp

 ### defp raise-cycle-packages
 (|packages|
  {'kind 'domain 'msg "the package requirement graph has a cycle"}
  'data
  'packages packages pair dict-of
  put
  raise)
 (packages -- : "Raise a requirement-cycle error from sorted package names.")
 'raise-cycle-packages defp

 ### defp prefix-collision
 (|names|
  names
  dup ("." cat) each grade at
  2 windows
  (dup first swap 1 at colliding-names?) filter
  first
  sort
  raise-prefix-collision)
 (names -- : "Raise a canonical prefix-collision error for a set of package names.")
 'prefix-collision defp

 ### defp raise-prefix-collision
 (|pair|
  {'kind 'domain 'msg "selected packages have overlapping prefixes"}
  'data
  pair wrap
  (|pair|
   'left-package pair first
   'right-package pair 1 at)
  infra
  dict-of
  put
  raise)
 (pair -- : "Raise a prefix collision from one canonically ordered pair.")
 'raise-prefix-collision defp

 ### defp colliding-names?
 (|left right| left right (pkg.name.owns?) (swap pkg.name.owns?) bi2 or)
 (left right -- bool : "Return 1 when either package name owns the other.")
 'colliding-names? defp

 ### defp source-record
 (|requirement package| requirement 'package package put)
 (requirement package -- record : "Attach declaring-package provenance to a requirement.")
 'source-record defp

 ### defp merge-source
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
 (prior name requirement package -- record :
  "Merge a same-hash mirror into a canonical source record or raise on a different hash.")
 'merge-source defp

 ### defp lex-min
 (|left right|
  left right cmp 1 =
  right () partial left () partial if)
 (left right -- minimum : "Return the lexicographically lesser of two strings.")
 'lex-min defp

 ### defp existing-source
 (|sources node name requirement package|
  sources node at name requirement package merge-source)
 (sources node name requirement package -- record : "Merge a declaration into an existing node.")
 'existing-source defp

 ### defp source-for
 (|sources node name requirement package|
  sources node has?
  sources node name requirement package 5 pack (existing-source) with
  requirement package pair (source-record) with
  if)
 (sources node name requirement package -- record :
  "Return the canonical source record after one declaration.")
 'source-for defp

 ### defp record-source
 (|state package name requirement|
  package name requirement 'version at resolve-version-checked pop
  state package name requirement name requirement 'version at pair record-source-node)
 (state package name requirement -- state :
  "Record one reached artifact source, merging mirrors and rejecting conflicting hashes.")
 'record-source defp

 ### defp record-source-node
 (|state package name requirement node|
  state
  'sources
  state 'sources at
  node
  state 'sources at node name requirement package source-for
  put
  put)
 (state package name requirement node -- state : "Insert or merge one exact source node.")
 'record-source-node defp

 ### defp manifest-for
 (|state package version requirer|
  package version pair
  state 'root at manifest-node
  match?
  state (root-manifest) partial
  state package version requirer 4 pack (catalog-manifest) with
  if
  package version matching-manifest)
 (state package version requirer -- manifest :
  "Return and validate the exact manifest named by a reached requirement.")
 'manifest-for defp

 ### defp root-manifest
 ('root at)
 (state -- manifest : "Return the resolver's validated root manifest.")
 'root-manifest defp

 ### defp catalog-value
 (|state package version| state 'catalog package version 3 pack at-path)
 (state package version -- manifest :
  "Return an exact manifest already known to exist in the catalog.")
 'catalog-value defp

 ### defp catalog-manifest
 (|state package version requirer|
  state 'catalog at package has?
  state 'catalog at package {} at-or type 'dict match?
  and
  state 'catalog at package {} at-or version has?
  and
  state package version 3 pack (catalog-value) with
  requirer package version 3 pack (missing-manifest) with
  if)
 (state package version requirer -- manifest :
  "Return an exact catalog manifest, or raise an error naming the requiring package.")
 'catalog-manifest defp

 ### defp matching-manifest
 (|candidate package version|
  candidate package resolve-manifest-checked
  dup 'name at package match?
  over 'version at version match?
  and
  {'kind 'domain 'msg "a catalog manifest must match its name and version keys"} assert)
 (candidate package version -- manifest :
  "Validate that a catalog manifest matches its catalog keys.")
 'matching-manifest defp

 ### defp walk-manifest
 (|state manifest|
  manifest 'requires at pkg.data.sorted-entries
  state manifest 'name at (walk-edge) partial fold)
 (state manifest -- state : "Visit every requirement of one manifest in canonical name order.")
 'walk-manifest defp

 ### defp walk-edge
 (|state pair requirer|
  state requirer pair first pair 1 at walk-requirement)
 (state pair requirer -- state :
  "Record and visit one exact requirement edge, detecting active-path cycles.")
 'walk-edge defp

 ### defp walk-requirement
 (|state requirer package requirement|
  state requirer package requirement record-source
  package requirement 'version at pair
  requirer package requirement visit-node)
 (state requirer package requirement -- state : "Record and visit one unpacked requirement edge.")
 'walk-requirement defp

 ### defp raise-cycle
 (|state node| state 'active at node requirement-cycle)
 (state node -- : "Raise a requirement-cycle error for an active node.")
 'raise-cycle defp

 ### defp visit-node
 (|state node requirer package requirement|
  state 'active at node node-member?
  state node pair (raise-cycle) with
  when
  state 'visited at node node-member?
  state () partial
  state node requirer package requirement 5 pack (visit-new-node) with
  if)
 (state node requirer package requirement -- state :
  "Skip a visited node or visit a new exact node.")
 'visit-node defp

 ### defp visit-new-node
 (|state node requirer package requirement|
  state node
  state package requirement 'version at requirer manifest-for
  enter-node)
 (state node requirer package requirement -- state :
  "Load, enter, and traverse one new exact node.")
 'visit-new-node defp

 ### defp enter-node
 (|state node manifest|
  state
  'manifests
  state 'manifests at node manifest put
  put
  'active
  state 'active at node append
  put
  manifest
  walk-manifest
  node finish-node)
 (state node manifest -- state :
  "Record an active manifest, traverse it, and mark its node visited.")
 'enter-node defp

 ### defp finish-node
 (|state node|
  state
  'active
  state 'active at -1 drop
  put
  'visited
  state 'visited at node append
  put)
 (state node -- state : "Remove a traversed node from the active path and mark it visited.")
 'finish-node defp

 ### defp selected-names
 ('sources at keys (first) each distinct sort)
 (state -- names : "Return reached package names in canonical order.")
 'selected-names defp

 ### defp selected-node
 (|name state|
  state 'sources at keys
  name (node-named?) partial filter
  dup (1 at) each pkg.version.max
  node-with-version)
 (name state -- node : "Return the highest reached exact node for a package name.")
 'selected-node defp

 ### defp node-has-version?
 (|node version| node 1 at version match?)
 (node version -- bool : "Return 1 when an exact node has the given version.")
 'node-has-version? defp

 ### defp node-with-version
 (|nodes version| nodes version (node-has-version?) partial filter first)
 (nodes version -- node : "Return the exact node with a given version.")
 'node-with-version defp

 ### defp selection-pair
 (|name state|
  state 'sources name state selected-node pair at-path 'package del
  name swap pair)
 (name state -- pair : "Return one selected package entry.")
 'selection-pair defp

 ### defp selected-packages
 (|state| state selected-names state (selection-pair) partial each raze dict-of)
 (state -- packages : "Build the selected package map from reached artifact sources.")
 'selected-packages defp

 ### defp minimum-map
 ('requires at dup keys swap vals ('version at) each to-dict)
 (manifest -- minimums : "Return one manifest's required names and minimum versions.")
 'minimum-map defp

 ### defp requires-pair
 (|name state|
  state 'manifests name state selected-node pair at-path minimum-map
  name swap pair)
 (name state -- pair : "Return one selected package's per-requirer minimum map.")
 'requires-pair defp

 ### defp resolved-requires
 (|state|
  state (['root 'name] at-path) ('root at minimum-map) bi pair wrap
  state selected-names state (requires-pair) partial each
  cat raze dict-of)
 (state -- requires : "Build the root-plus-selected per-requirer requirement table.")
 'resolved-requires defp

 ### defp resolved-lock
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
  dict-of
  pkg.lock.validate)
 (state -- lock : "Build and validate the format-1 lock for a completed graph traversal.")
 'resolved-lock defp

 ### def resolve
 (|root catalog|
  catalog type 'dict match?
  {'kind 'type 'msg "pkg.mvs.resolve expects a manifest catalog dict"} assert
  catalog
  root "root" resolve-manifest-checked
  resolve-validated)
 (root-manifest manifests -- lock :
  "Resolve the reachable requirement graph by minimal version selection and return a validated
   lock.")
 'resolve def

 ### defp resolve-validated
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
  dict-of
  root walk-manifest resolved-lock)
 (catalog root -- lock : "Traverse a validated root against a catalog and construct its lock.")
 'resolve-validated defp
 )
'pkg.mvs
@defm
