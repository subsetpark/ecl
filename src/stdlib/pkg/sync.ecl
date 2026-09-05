### module pkg.sync
# Discover, resolve, install, and atomically lock source packages. Stores are
# named `'cache` or `'vendor` and reached only through the Session's package
# authority; project files are reached through the `'project` filesystem root.
[]
(
 ### def store-key
 (package requirement -- key : "Derive the immutable name-version-hash store key.")
 (|package requirement|
  package "-" cat
  requirement 'version at cat
  "-" cat
  requirement 'hash at 7 drop cat)
 'store-key def

 ### def store-keys
 (lock -- keys : "Return the canonical immutable store keys selected by a lock.")
 (pkg.lock.validate 'packages at pkg.data.sorted-entries
  (|pair| pair first pair 1 at pkg.sync.store-key) each)
 'store-keys def

 ### def store-root
 (lock -- store :
  "Return the store a validated lock selects: 'vendor for a vendored lock, otherwise 'cache.")
 (pkg.lock.validate 'store dict.has? ('vendor) ('cache) if)
 'store-root def

 ### def write-project-file
 (text path -- :
  "Publish one project data file beneath 'project: create it when absent, otherwise strictly replace
   the existing regular file.")
 ('project swap over over fs.exists? (fs.replace-text) (fs.create-text) if)
 'write-project-file def

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
  'target requirement 'url at pair dict.from-flat http.get-bytes
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
  'target url pair dict.from-flat http.get-bytes package url success-response 'body at
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
  package version url hash 4 pack
  (|package version url hash| 'package package 'version version 'url url 'hash hash)
  infra
  dict.from-flat
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
  body package 2 pack (pkg.store.inspect) @attempt
  dup 'ok dict.has?
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
 (store key package version -- manifest : "Read and identity-check a present store manifest.")
 (|store key package version|
  store key pkg.store.manifest pkg.manifest.read
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
 (|state pair| state pair 1 at 'package at pair 1 at discover-node)
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
 (state package version node key -- state : "Read and record one present immutable entry.")
 (|state package version node key|
  state package version node
  state 'store at key package version stored-manifest
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
 (state package requirement node key -- state :
  "Reject an absent offline node or fetch it in the network-enabled mode.")
 (|state package requirement node key|
  state 'offline at
  package state 'store at key 3 pack (offline-missing-context) partial
  state package requirement node 4 pack (load-fetched-context) partial
  if)
 'load-absent-discovery-node defp

 ### defp load-absent-context
 (context -- state : "Invoke absent-node handling from one packed context.")
 ((load-absent-discovery-node) with call)
 'load-absent-context defp

 ### defp load-discovery-node
 (state package requirement node key -- state :
  "Load one present or fetched manifest, then record and traverse its exact node.")
 (|state package requirement node key|
  state 'store at key pkg.store.present?
  state package requirement 'version at node key 5 pack (load-stored-context) partial
  state package requirement node key 5 pack (load-absent-context) partial
  if)
 'load-discovery-node defp

 ### defp offline-missing
 (package store key -- : "Raise when offline synchronization needs an absent exact store entry.")
 (|package store key|
  'io error.new "offline synchronization is missing a package store entry" error.with-message
  package store key 3 pack
  (|package store key| 'package package 'store store 'key key)
  infra
  dict.from-flat
  error.with-data
  raise)
 'offline-missing defp

 ### defp discover-new-node
 (state package requirement node -- state : "Derive and load one previously unseen exact node.")
 (|state package requirement node|
  state package requirement node
  package requirement store-key
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
  dict.from-flat
  root discover-manifest
  'catalog at)
 'discover defp

 ### defp finish-install
 (result store key -- : "Accept a racing immutable publication or re-raise its install failure.")
 (|result store key|
  result 'err at
  dup 'data at 'destination-exists 0 at-or
  store key 2 pack (pkg.store.present?) @attempt
  dup 'ok dict.has?
  ('ok at first)
  (pop 0)
  if
  and
  (pop)
  (raise)
  if)
 'finish-install defp

 ### def install-immutable
 (bytes package store key -- :
  "Install one immutable package, treating a concurrently published real directory as success.")
 (|bytes package store key|
  bytes package store key 4 pack (pkg.store.install pop) @attempt
  dup 'ok dict.has?
  (pop)
  store key 2 pack (finish-install) with
  if)
 'install-immutable def

 ### defp install-fetched
 (key package requirement store -- : "Fetch, verify, and install one absent selection.")
 (|key package requirement store|
  package requirement fetch-body
  dup package inspect-checked pkg.manifest.read
  package requirement 'version at matching-manifest pop
  package store key install-immutable)
 'install-fetched defp

 ### defp install-selection
 (pair store -- : "Install one missing selected package after repeating every verification.")
 (|pair store|
  pair first pair 1 at store 3 pack
  (|package requirement store|
   package requirement store-key
   store over pkg.store.present?
   (pop)
   package requirement store 3 pack (install-fetched) with
   if)
  with call)
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
  store pair first pair 1 at store-key
  pair first
  pair 1 at 'hash at
  pkg.store.verify)
 'verify-selection defp

 ### def verify
 (lock -- count : "Verify every immutable package selected by a lock at its cache or vendor store.")
 (|lock|
  lock pkg.lock.validate pop
  lock 'packages at pkg.data.sorted-entries
  dup len swap
  lock store-root (verify-selection) partial
  for)
 'verify def

 ### def run
 (root-manifest -- lock :
  "Discover and resolve transitive packages, install selected artifacts, atomically write the
   project's ecl.lock, and return the validated lock.")
 (0 run-mode)
 'run def

 ### def run-offline
 (root-manifest -- lock :
  "Resolve and atomically lock using immutable store entries without opening a network request.")
 (1 run-mode)
 'run-offline def

 ### defp lock-mode
 (lock -- mode : "Return the closed store mode of one validated project lock.")
 (dup 'store dict.has?
  ('store at)
  (pop 'cache)
  if)
 'lock-mode defp

 ### defp mode-result
 (result -- mode : "Return an explicit project's lock mode or cache when it can be regenerated.")
 (dup 'ok dict.has?
  ('ok at first lock-mode)
  (pop 'cache)
  if)
 'mode-result defp

 ### defp project-mode
 (-- mode : "Read store mode only from the explicit project being synchronized.")
 ([] ('project "ecl.lock" fs.read-text pkg.lock.read) @attempt mode-result)
 'project-mode defp

 ### defp run-mode
 (root-manifest offline -- lock : "Validate explicit sync inputs and select its store.")
 (|root offline|
  root pkg.manifest.validate
  project-mode
  offline 3 pack
  (|root store offline| root store offline run-validated)
  with call)
 'run-mode defp

 ### defp run-validated
 (root store offline -- lock : "Run synchronization after validating its inputs.")
 (|root store offline|
  root store offline discover
  root swap pkg.mvs.resolve
  store 'vendor match? (pkg.lock.vendor) when
  dup store install-selected
  dup pkg.lock.write "ecl.lock" write-project-file)
 'run-validated defp
) 'pkg.sync @defm
