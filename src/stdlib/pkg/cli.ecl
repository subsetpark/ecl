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
   name wrap
   (|name| 'format 1 'name name 'version "0.1.0" 'requires {})
   infra
   dict-of
   pkg.manifest.write
   root manifest-path
   io.spit
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
 (first lock-path io.slurp pkg.lock.read pkg.sync.verify
  wrap "verified {} packages" format io.print)
 'verify def
 ) 'pkg.cli @defm
