### module pkg.sync
# Discover, resolve, install, and atomically lock source packages.
(
 ### defp env-or-empty
 (name -- text : "Read one captured environment value, returning an empty string when absent.")
 (wrap (getenv) with @attempt
  dup 'ok has?
  ('ok at first)
  (pop "")
  if)
 'env-or-empty defp

 ### defp missing-cache-root
 (value -- : "Raise when no captured environment value selects a package cache.")
 (pop
  {'kind 'io
   'msg "pkg.sync.run needs ECL_CACHE, XDG_CACHE_HOME, or HOME to select a package store"}
  raise)
 'missing-cache-root defp

 ### defp home-cache-root
 (home -- store-root : "Derive the default package cache from a captured HOME value.")
 (dup empty?
  (missing-cache-root)
  ("/.cache/ecl/pkg" cat)
  if)
 'home-cache-root defp

 ### defp xdg-cache-root
 (xdg -- store-root : "Use XDG_CACHE_HOME when nonempty, otherwise derive the cache from HOME.")
 (dup empty?
  (pop "HOME" env-or-empty home-cache-root)
  ("/ecl/pkg" cat)
  if)
 'xdg-cache-root defp

 ### defp cache-root
 (-- store-root : "Select the package store from the Session's captured environment snapshot.")
 ("ECL_CACHE" env-or-empty
  dup empty?
  (pop "XDG_CACHE_HOME" env-or-empty xdg-cache-root)
  ()
  if)
 'cache-root defp

 ### defp store-key
 (package requirement -- key : "Derive the immutable name-version-hash store key.")
 (|package requirement|
  package "-" cat
  requirement 'version at cat
  "-" cat
  requirement 'hash at 7 drop cat)
 'store-key defp

 ### defp store-path
 (store package requirement -- path : "Derive one immutable package destination.")
 (|store package requirement| store "/" cat package requirement store-key cat)
 'store-path defp

 ### defp success-response
 (response package url -- response : "Require a successful HTTP status with package provenance.")
 (|response package url|
  response 'status at dup 200 >= swap 300 < and
  {'kind 'io 'msg "package download returned a non-success HTTP status"}
  'data
  {}
  'package package put
  'url url put
  'status response 'status at put
  put
  assert
  response)
 'success-response defp

 ### defp hash-checked
 (body package declared-hash -- body : "Require the exact declared archive hash with provenance.")
 (|body package declared|
  body archive.sha256 "sha256-" swap cat
  body package declared 4 pack
  (|actual body package declared|
   actual declared match?
   {'kind 'domain 'msg "downloaded package hash does not match its declaration"}
   'data
   {}
   'package package put
   'declared-hash declared put
   'actual-hash actual put
   put
   assert
   body)
  with call)
 'hash-checked defp

 ### defp fetch-body
 (package requirement -- body : "Fetch and hash-check one exact package archive.")
 (|package requirement|
  requirement 'url at {} http.get-bytes
  package requirement 'url at success-response
  'body at
  package requirement 'hash at hash-checked)
 'fetch-body defp

 ### defp raise-package-error
 (error package -- : "Attach package provenance to a store-policy error and re-raise it.")
 (|error package|
  error 'data error 'data at 'package package put put raise)
 'raise-package-error defp

 ### defp inspect-checked
 (body package -- manifest-text : "Inspect an archive and preserve package provenance on failure.")
 (|body package|
  body package 2 pack (pkg.store.inspect) with @attempt
  dup 'ok has?
  ('ok at first)
  ('err at) package (raise-package-error) partial compose
  if)
 'inspect-checked defp

 ### defp matching-manifest
 (candidate package version -- manifest : "Require a manifest to match its requested identity.")
 (|candidate package version|
  candidate pkg.manifest.validate
  dup 'name at package match?
  over 'version at version match?
  and
  {'kind 'domain 'msg "package manifest identity does not match its request"}
  'data
  {}
  'requested-name package put
  'requested-version version put
  'actual-name candidate 'name at put
  'actual-version candidate 'version at put
  put
  assert)
 'matching-manifest defp

 ### defp fetched-manifest
 (package requirement -- manifest :
  "Fetch, verify, inspect, parse, and identity-check one manifest.")
 (|package requirement|
  package requirement fetch-body
  dup package inspect-checked
  pkg.manifest.read
  package requirement 'version at matching-manifest
  nip)
 'fetched-manifest defp

 ### defp stored-manifest
 (destination package version -- manifest : "Read and identity-check a present store manifest.")
 (|destination package version|
  destination "/ecl.pkg" cat io.slurp pkg.manifest.read
  package version matching-manifest)
 'stored-manifest defp

 ### defp seen-node?
 (nodes node -- bool : "Return 1 when an exact package/version node has already been discovered.")
 ((match?) partial any?)
 'seen-node? defp

 ### defp catalog-insert
 (state package version manifest -- state : "Insert one exact manifest into the discovery catalog.")
 (|state package version manifest|
  state
  'catalog
  state 'catalog at
  package
  state 'catalog at package {} at-or
  version manifest put
  put
  put)
 'catalog-insert defp

 ### defp discover-edge
 (state pair -- state : "Discover one canonically ordered requirement edge.")
 (|state pair| state pair first pair 1 at discover-node)
 'discover-edge defp

 ### defp discover-manifest
 (state manifest -- state : "Discover every exact requirement reachable from one manifest.")
 (|state manifest|
  manifest 'requires at pkg.data.sorted-entries
  state
  (discover-edge)
  fold)
 'discover-manifest defp

 ### defp finish-discovery-node
 (state node manifest -- state : "Mark one exact node seen before traversing its requirements.")
 (|state node manifest|
  state 'seen state 'seen at node append put
  manifest discover-manifest)
 'finish-discovery-node defp

 ### defp record-discovery-node
 (state package version node manifest -- state : "Record and traverse one newly loaded manifest.")
 (|state package version node manifest|
  state package version manifest catalog-insert
  node manifest finish-discovery-node)
 'record-discovery-node defp

 ### defp load-stored-discovery-node
 (state package version node destination -- state : "Read and record one present immutable entry.")
 (|state package version node destination|
  state package version node
  destination package version stored-manifest
  record-discovery-node)
 'load-stored-discovery-node defp

 ### defp load-fetched-discovery-node
 (state package requirement node -- state : "Fetch and record one absent exact entry.")
 (|state package requirement node|
  state package requirement 'version at node
  package requirement fetched-manifest
  record-discovery-node)
 'load-fetched-discovery-node defp

 ### defp load-discovery-node
 (state package requirement node destination -- state :
  "Load one present or fetched manifest, then record and traverse its exact node.")
 (|state package requirement node destination|
  destination pkg.store.present?
  state package requirement 'version at node destination 5 pack
  (load-stored-discovery-node) with
  state package requirement node 4 pack
  (load-fetched-discovery-node) with
  if)
 'load-discovery-node defp

 ### defp discover-new-node
 (state package requirement node -- state : "Derive and load one previously unseen exact node.")
 (|state package requirement node|
  state package requirement node
  state 'store at package requirement store-path
  load-discovery-node)
 'discover-new-node defp

 ### defp discover-node
 (state package requirement -- state : "Skip a seen exact node or discover a new one.")
 (|state package requirement|
  package requirement 'version at pair
  state 'seen at over seen-node?
  (pop) state () partial compose
  state package requirement 3 pack
  (|node state package requirement| state package requirement node discover-new-node)
  with
  if)
 'discover-node defp

 ### defp discover
 (root store -- catalog : "Discover the complete exact manifest catalog reachable from the root.")
 (|root store|
  store wrap
  (|store| 'catalog {} 'seen [] 'store store)
  infra
  dict-of
  root discover-manifest
  'catalog at)
 'discover defp

 ### defp install-selection
 (pair store -- : "Install one missing selected package after repeating every verification.")
 (|pair store|
  pair first
  pair 1 at
  store 3 pack
  (|package requirement store|
   store package requirement store-path
   dup pkg.store.present?
   (pop)
   package requirement 2 pack
   (|destination package requirement|
    package requirement fetch-body
    dup package inspect-checked pkg.manifest.read
    package requirement 'version at matching-manifest pop
    package destination pkg.store.install pop)
   with
   if)
  with
  call)
 'install-selection defp

 ### defp install-selected
 (lock store -- : "Install missing selected packages in canonical package-name order.")
 (|lock store|
  lock 'packages at pkg.data.sorted-entries
  store (install-selection) partial
  for)
 'install-selected defp

 ### def run
 (root-manifest project-root -- lock :
  "Discover and resolve transitive packages, install selected artifacts, atomically write ecl.lock,
   and return the validated lock.")
 (|root project|
  project str.str?
  {'kind 'type 'msg "pkg.sync.run expects a string project root"} assert
  root pkg.manifest.validate
  cache-root
  project
  run-validated)
 'run def

 ### defp run-validated
 (root store project-root -- lock : "Run synchronization after validating its explicit inputs.")
 (|root store project|
  root store discover
  root swap pkg.mvs.resolve
  dup store install-selected
  dup pkg.lock.write
  project "/ecl.lock" cat
  pkg.store.write-lock)
 'run-validated defp
 ) 'pkg.sync @defm
