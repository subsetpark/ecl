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

 ### def cache-root
 (-- store-root : "Select the package store from the Session's captured environment snapshot.")
 ("ECL_CACHE" env-or-empty
  dup empty?
  (pop "XDG_CACHE_HOME" env-or-empty xdg-cache-root)
  ()
  if)
 'cache-root def

 ### def store-key
 (package requirement -- key : "Derive the immutable name-version-hash store key.")
 (|package requirement|
  package "-" cat
  requirement 'version at cat
  "-" cat
  requirement 'hash at 7 drop cat)
 'store-key def

 ### def store-path
 (store package requirement -- path : "Derive one immutable package destination.")
 (|store package requirement| store "/" cat package requirement store-key cat)
 'store-path def

 ### def store-keys
 (lock -- keys : "Return the canonical immutable store keys selected by a lock.")
 (pkg.lock.validate 'packages at pkg.data.sorted-entries
  (|pair| pair first pair 1 at pkg.sync.store-key) each)
 'store-keys def

 ### def store-root
 (lock project-root -- store-root :
  "Select the shared cache or the fixed project-local vendor store named by a lock.")
 (|lock project|
  lock pkg.lock.validate pop
  project
  lock 'store has?
  ("/vendor" cat)
  (pop pkg.sync.cache-root)
  if)
 'store-root def

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

 ### def requirement
 (package version url -- requirement :
  "Fetch and validate one exact package archive, returning its derived hash declaration.")
 (|package version url|
  package pkg.name.valid?
  'domain error.new "pkg add expects a canonical package name" error.with-message assert
  version pkg.version.validate pop
  url pkg.name.url?
  'domain error.new "pkg add expects an https url" error.with-message assert
  url {} http.get-bytes package url success-response 'body at
  dup archive.sha256 "sha256-" swap cat
  package version url
  requirement-checked)
 'requirement def

 ### defp requirement-checked
 (body hash package version url -- requirement :
  "Validate fetched identity and construct one exact requirement declaration.")
 (|body hash package version url|
  body package inspect-checked pkg.manifest.read
  package version matching-manifest pop
  version wrap url append hash append
  (|version url hash| 'version version 'url url 'hash hash)
  infra
  dict-of
  pkg.manifest.validate-requirement)
 'requirement-checked defp

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

 ### defp load-stored-context
 (context -- state : "Invoke stored-node discovery from one packed context.")
 ((load-stored-discovery-node) with call)
 'load-stored-context defp

 ### defp load-fetched-context
 (context -- state : "Invoke fetched-node discovery from one packed context.")
 ((load-fetched-discovery-node) with call)
 'load-fetched-context defp

 ### defp offline-missing-context
 (context -- : "Raise an offline missing-entry error from one packed context.")
 ((offline-missing) with call)
 'offline-missing-context defp

 ### defp load-absent-discovery-node
 (state package requirement node destination -- state :
  "Reject an absent offline node or fetch it in the network-enabled mode.")
 (|state package requirement node destination|
  state 'offline at
  package destination 2 pack (offline-missing-context) partial
  state package requirement node 4 pack (load-fetched-context) partial
  if)
 'load-absent-discovery-node defp

 ### defp load-absent-context
 (context -- state : "Invoke absent-node handling from one packed context.")
 ((load-absent-discovery-node) with call)
 'load-absent-context defp

 ### defp load-discovery-node
 (state package requirement node destination -- state :
  "Load one present or fetched manifest, then record and traverse its exact node.")
 (|state package requirement node destination|
  destination pkg.store.present?
  state package requirement 'version at node destination 5 pack (load-stored-context) partial
  state package requirement node destination 5 pack (load-absent-context) partial
  if)
 'load-discovery-node defp

 ### defp offline-missing
 (package destination -- : "Raise when offline synchronization needs an absent exact store entry.")
 (|package destination|
  'io error.new "offline synchronization is missing a package store entry" error.with-message
  package destination pair
  (|package destination| 'package package 'path destination)
  infra
  dict-of
  error.with-data
  raise)
 'offline-missing defp

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
 (root store offline -- catalog :
  "Discover the complete exact manifest catalog, optionally refusing every network fetch.")
 (|root store offline|
  store offline pair
  (|store offline| 'catalog {} 'seen [] 'store store 'offline offline)
  infra
  dict-of
  root discover-manifest
  'catalog at)
 'discover defp

 ### defp finish-install
 (result destination -- : "Accept a racing immutable publication or re-raise its install failure.")
 (|result destination|
  result 'err at
  dup 'data at 'destination-exists 0 at-or
  destination wrap (pkg.store.present?) with @attempt
  dup 'ok has?
  ('ok at first)
  (pop 0)
  if
  and
  (pop)
  (raise)
  if)
 'finish-install defp

 ### def install-immutable
 (bytes package destination -- :
  "Install one immutable package, treating a concurrently published real directory as success.")
 (|bytes package destination|
  bytes package destination 3 pack (pkg.store.install pop) with @attempt
  dup 'ok has?
  (pop)
  destination (finish-install) partial
  if)
 'install-immutable def

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
    package destination install-immutable)
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

 ### defp verify-selection
 (pair store -- : "Stream and hash-check one selected package's retained archive seal.")
 (|pair store|
  store pair first pair 1 at store-path
  pair first
  pair 1 at 'hash at
  pkg.store.verify)
 'verify-selection defp

 ### def verify
 (lock project-root -- count :
  "Verify every immutable package selected by a lock at its cache or vendor root.")
 (|lock project|
  lock pkg.lock.validate pop
  lock 'packages at pkg.data.sorted-entries
  dup len swap
  lock project pkg.sync.store-root (verify-selection) partial
  for)
 'verify def

 ### def run
 (root-manifest project-root -- lock :
  "Discover and resolve transitive packages, install selected artifacts, atomically write ecl.lock,
   and return the validated lock.")
 (|root project|
  project str.str?
  {'kind 'type 'msg "pkg.sync.run expects a string project root"} assert
  root project 0 run-mode)
 'run def

 ### def run-offline
 (root-manifest project-root -- lock :
  "Resolve and atomically lock using immutable store entries without opening a network request.")
 (|root project| root project 1 run-mode)
 'run-offline def

 ### defp lock-mode
 (lock -- mode : "Return the closed store mode of one validated project lock.")
 (dup 'store has?
  ('store at)
  (pop 'cache)
  if)
 'lock-mode defp

 ### defp mode-result
 (result -- mode : "Return an explicit project's lock mode or cache when it can be regenerated.")
 (dup 'ok has?
  ('ok at first lock-mode)
  (pop 'cache)
  if)
 'mode-result defp

 ### defp project-mode
 (project-root -- mode : "Read store mode only from the explicit project being synchronized.")
 ("/ecl.lock" cat wrap (io.slurp pkg.lock.read) with @attempt mode-result)
 'project-mode defp

 ### defp run-mode
 (root-manifest project-root offline -- lock : "Validate explicit sync inputs and select its mode.")
 (|root project offline|
  project str.str?
  {'kind 'type 'msg "pkg.sync expects a string project root"} assert
  root pkg.manifest.validate
  project project-mode
  dup 'vendor match?
  project ("/vendor" cat) partial
  (cache-root)
  if
  project offline 5 pack
  (|root mode store project offline| root store project offline mode run-validated)
  with call)
 'run-mode defp

 ### defp run-validated
 (root store project-root offline mode -- lock : "Run synchronization after validating its inputs.")
 (|root store project offline mode|
  root store offline discover
  root swap pkg.mvs.resolve
  mode 'vendor match? (pkg.lock.vendor) when
  dup store install-selected
  dup pkg.lock.write
  project "/ecl.lock" cat
  pkg.store.write-lock)
 'run-validated defp
 ) 'pkg.sync @defm
