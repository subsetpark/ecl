### module pkg.cli
# User-facing package command orchestration over the ordinary package modules.
# Project files are the fixed names `ecl.pkg` and `ecl.lock` beneath the
# `'project` filesystem root the command line grants; no absolute path enters
# evaluated code.
[]
(
 ### defp read-manifest
 (-- manifest : "Read and parse the discovered project's root manifest.")
 ('project "ecl.pkg" fs.read-text pkg.manifest.read)
 'read-manifest defp

 ### defp read-lock
 (-- lock : "Read and parse the discovered project's lock.")
 ('project "ecl.lock" fs.read-text pkg.lock.read)
 'read-lock defp

 ### def init
 (arguments -- :
  "Create one default root manifest in the working directory and report its canonical package
   name.")
 (first
  (|name|
   name pkg.name.valid?
   'domain error.new
   "pkg init needs a canonical package name; pass one as `ecl pkg init <name>`"
   error.with-message
   name wrap (|name| 'name name) infra dict.from-flat
   error.with-data
   assert
   name wrap
   (|name| 'format 1 'name name 'version "0.1.0" 'exports {} 'requires {})
   infra
   dict.from-flat
   pkg.manifest.write
   'cwd "ecl.pkg" fs.create-text
   name wrap "initialized ecl.pkg for {}" str.format io.print)
  call)
 'init def

 ### defp record-requirement
 (manifest requirement package -- : "Rewrite one validated root requirement.")
 (|manifest requirement package|
  manifest 'requires
  manifest 'requires at package requirement put
  put
  pkg.manifest.write
  'project "ecl.pkg" fs.replace-text)
 'record-requirement defp

 ### def add
 (arguments -- : "Fetch, validate, and record one exact root requirement.")
 (|arguments|
  arguments first
  arguments 1 at
  arguments 2 at
  (|package version url|
   read-manifest
   package version url pkg.sync.requirement
   package record-requirement
   package version pair "added {} {}" str.format io.print)
  call)
 'add def

 ### defp sync-result
 (operation -- : "Run one synchronization mode and report its selected package count.")
 (read-manifest swap call
  'packages at dict.size
  wrap "synced {} packages" str.format io.print)
 'sync-result defp

 ### def sync
 (arguments -- : "Synchronize the discovered project with network fetching enabled.")
 (pop (pkg.sync.run) sync-result)
 'sync def

 ### def sync-offline
 (arguments -- : "Synchronize the discovered project using only immutable store entries.")
 (pop (pkg.sync.run-offline) sync-result)
 'sync-offline def

 ### def tree
 (arguments -- : "Print the deterministic dependency edge projection of the project lock.")
 (pop read-lock pkg.lock.tree io.prin)
 'tree def

 ### def why
 (arguments -- : "Print one deterministic root-to-owner path for a module name.")
 (first read-lock swap pkg.lock.why io.prin)
 'why def

 ### def verify
 (arguments -- : "Verify every sealed package archive selected by the project lock.")
 (pop read-lock pkg.sync.verify wrap "verified {} packages" str.format io.print)
 'verify def

 ### defp verify-vendor-entry
 (key package requirement -- : "Verify one already-present project vendor entry.")
 (|key package requirement| 'vendor key package requirement 'hash at pkg.store.verify)
 'verify-vendor-entry defp

 ### defp install-vendor-entry
 (key package requirement -- : "Read, verify, and install one absent project vendor entry.")
 (|key package requirement|
  'cache key package requirement 'hash at pkg.store.read-seal
  package 'vendor key pkg.sync.install-immutable)
 'install-vendor-entry defp

 ### defp vendor-selection
 (pair -- : "Copy or verify one selected immutable package in the project vendor store.")
 (|pair|
  pair first pair 1 at
  (|package requirement|
   package requirement pkg.sync.store-key
   'vendor over pkg.store.present?
   package requirement 2 pack (verify-vendor-entry) with
   package requirement 2 pack (install-vendor-entry) with
   if)
  call)
 'vendor-selection defp

 ### def vendor
 (arguments -- : "Copy every locked package into the fixed project-local vendor store.")
 (pop read-lock
  (|lock|
   lock 'packages at pkg.data.sorted-entries (vendor-selection) for
   lock pkg.lock.vendor
   dup pkg.lock.write 'project "ecl.lock" fs.replace-text
   'packages at dict.size
   wrap "vendored {} packages" str.format io.print)
  call)
 'vendor def

 ### defp lock-text-at
 (path -- text : "Read one lock file by canonical relative path beneath the working directory.")
 (dup path.valid-relative?
  'domain error.new
  "ecl pkg gc expects canonical relative lock paths beneath the working directory"
  error.with-message
  assert
  'cwd swap fs.read-text)
 'lock-text-at defp

 ### def gc
 (lock-paths -- : "Remove shared-cache entries absent from every named lock file.")
 ((lock-text-at pkg.lock.read pkg.sync.store-keys) each raze distinct
  pkg.store.gc
  wrap "removed {} packages" str.format io.print)
 'gc def
) 'pkg.cli @defm
