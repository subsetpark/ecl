### module pkg.cli
# User-facing package command orchestration over the ordinary package modules.
(
 ### defp manifest-path
 (root -- path : "Return the root manifest path for a discovered project.")
 ("/ecl.pkg" cat)
 'manifest-path defp

 ### defp lock-path
 (root -- path : "Return the lock path for a discovered project.")
 ("/ecl.lock" cat)
 'lock-path defp

 ### def init
 (arguments -- : "Create one default root manifest and report its canonical package name.")
 (|arguments|
  arguments first
  arguments 1 at
  (|root name|
   name pkg.name.valid?
   'domain error.new
   "pkg init needs a canonical package name; pass one as `ecl pkg init <name>`"
   error.with-message
   name root 2 pack
   (|name root| 'name name 'path root)
   infra
   dict-of
   error.with-data
   assert
   name wrap
   (|name| 'format 1 'name name 'version "0.1.0" 'requires {})
   infra
   dict-of
   pkg.manifest.write
   root manifest-path
   pkg.store.write-new
   name wrap "initialized ecl.pkg for {}" format io.print)
  call)
 'init def

 ### defp record-requirement
 (manifest requirement root package -- : "Rewrite one validated root requirement.")
 (|manifest requirement root package|
  manifest 'requires
  manifest 'requires at package requirement put
  put
  pkg.manifest.write
  root manifest-path
  pkg.store.write-lock)
 'record-requirement defp

 ### def add
 (arguments -- : "Fetch, validate, and record one exact root requirement.")
 (|arguments|
  arguments first
  arguments 1 at
  arguments 2 at
  arguments 3 at
  (|root package version url|
   root manifest-path io.slurp pkg.manifest.read
   package version url pkg.sync.requirement
   root package record-requirement
   package version pair "added {} {}" format io.print)
  call)
 'add def

 ### defp sync-result
 (root operation -- : "Run one synchronization mode and report its selected package count.")
 (|root operation|
  root manifest-path io.slurp pkg.manifest.read
  root
  operation call
  'packages at keys len
  wrap "synced {} packages" format io.print)
 'sync-result defp

 ### def sync
 (arguments -- : "Synchronize the discovered project with network fetching enabled.")
 (first (pkg.sync.run) sync-result)
 'sync def

 ### def sync-offline
 (arguments -- : "Synchronize the discovered project using only immutable store entries.")
 (first (pkg.sync.run-offline) sync-result)
 'sync-offline def

 ### def tree
 (arguments -- : "Print the deterministic dependency edge projection of the project lock.")
 (first lock-path io.slurp pkg.lock.read pkg.lock.tree io.prin)
 'tree def

 ### def why
 (arguments -- : "Print one deterministic root-to-owner path for a module name.")
 ((first lock-path io.slurp pkg.lock.read) (1 at) bi pkg.lock.why io.prin)
 'why def

 ### def verify
 (arguments -- : "Verify every sealed package archive selected by the project lock.")
 (first
  (|root| root lock-path io.slurp pkg.lock.read root pkg.sync.verify
   wrap "verified {} packages" format io.print)
  call)
 'verify def

 ### defp verify-vendor-context
 (context -- : "Verify one already-present project vendor entry.")
 ((|source destination package requirement|
   source pop
   destination package requirement 'hash at pkg.store.verify)
  with call)
 'verify-vendor-context defp

 ### defp install-vendor-context
 (context -- : "Read, verify, and install one absent project vendor entry.")
 ((|source destination package requirement|
   source package requirement 'hash at pkg.store.read-seal
   package destination pkg.sync.install-immutable)
  with call)
 'install-vendor-context defp

 ### defp vendor-selection
 (pair roots -- : "Copy or verify one selected immutable package in the project vendor store.")
 (|pair roots|
  pair first
  pair 1 at
  roots first
  roots 1 at
  4 pack
  (|package requirement source-root destination-root|
   source-root package requirement pkg.sync.store-path
   destination-root package requirement pkg.sync.store-path
   package requirement 4 pack
   dup 1 at pkg.store.present?
   (verify-vendor-context)
   (install-vendor-context)
   if)
  with call)
 'vendor-selection defp

 ### def vendor
 (arguments -- : "Copy every locked package into the fixed project-local vendor store.")
 (first dup lock-path io.slurp pkg.lock.read pair
  (|root lock|
   lock root pkg.sync.store-root
   root "/vendor" cat
   pair
   lock 'packages at pkg.data.sorted-entries
   swap (vendor-selection) partial
   for
   lock pkg.lock.vendor
   dup pkg.lock.write root lock-path pkg.store.write-lock
   'packages at keys len
   wrap "vendored {} packages" format io.print)
  with call)
 'vendor def

 ### def gc
 (lock-paths -- : "Remove shared-cache entries absent from every named lock file.")
 ((io.slurp pkg.lock.read pkg.sync.store-keys) each raze distinct
  pkg.store.gc
  wrap "removed {} packages" format io.print)
 'gc def
 ) 'pkg.cli @defm
