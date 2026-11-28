### module pkg.install
# Resolution and installation: each selected package is unpacked beneath
# `.ecl/packages/<name>`, where module search finds it, and its exact archive
# is kept in `.ecl/archives`.
(
 ### defp existing-lock
 (directory manifest -- text :
  "Preserve the portable lock's exact bytes during ordinary synchronization.")
 (|directory manifest|
  directory "ecl.lock" fs.read-text
  dup pkg.resolution.read manifest pkg.resolution.compatible pop) `existing-lock defp

 ### defp resolve
 (context manifest -- text :
  "Select dependencies only for initial synchronization or an explicit update.")
 (|context manifest|
  manifest context manifest pkg.discover.catalog pkg.solver.resolve pkg.resolution.write)
 `resolve defp

 ### def selection
 (context manifest update -- text :
  "Honor an existing lock unless dependency selection was explicitly requested.")
 (|context manifest update|
  context `project at "ecl.lock" fs.exists? update not and
  context `project at manifest pair (existing-lock) cat
  context manifest pair (resolve) cat if) `selection def

 ### def start
 (project offline -- context :
  "Stage the package and archive trees beside the installed ones, and a private download pin
   directory that is never published.")
 (|project offline|
  project `directory at ".ecl" fs.mkdirs
  {} `project project `directory at put `offline offline put `cache pkg.project.cache-path put
  `downloads project `directory at ".ecl/downloads" fs.stage-dir put
  `packages project `directory at ".ecl/packages" fs.stage-dir put
  `archives project `directory at ".ecl/archives" fs.stage-dir put) `start def

 ### defp install
 (state name -- state : "Obtain, check, and unpack one selected package.")
 (|state name|
  state `context at state `lock at `packages at name at pkg.obtain.requirement
  state name pair (install-bytes) cat apply) `install defp

 ### defp install-bytes
 (bytes state name -- state : "Keep the exact archive and unpack only a validated package.")
 (|bytes state name|
  state `lock at bytes pkg.bundle.inspect `manifest at pkg.resolution.check-manifest
  state [context archives] at-path state `lock at `packages at name at `hash at pkg.cache.filename
  bytes fs.create-bytes
  state [context packages] at-path name bytes gzip.decompress tar.unpack pop
  state) `install-bytes defp

 ### defp replace
 (directory path -- : "Remove an installed tree, if there is one.")
 (dup2 fs.exists? (fs.remove-tree) (pop pop) if) `replace defp

 ### def finish
 (context manifest-text lock-text -- :
  "Install every selected package, then publish the staged trees in place of the installed ones and
   the lock after them. A failure or cancellation after the trees are replaced and before the lock
   is published leaves the new packages beside the old lock; `verify` reports the mismatch, and
   rerunning `sync` is the only recovery.")
 (|context manifest-text lock-text|
  lock-text pkg.resolution.read manifest-text pkg.manifest.read pkg.resolution.compatible
  {} swap `lock swap put `context context put
  dup `lock at `packages at dict.keys dup grade at swap (install) fold pop
  context `downloads at port.close
  context `project at ".ecl/packages" replace
  context `project at ".ecl/archives" replace
  context `packages at fs.commit-dir
  context `archives at fs.commit-dir
  context `project at "ecl.lock" lock-text fs.publish-text) `finish def

 ### defp publish
 (context manifest-text update -- : "Build against one observed manifest and one lock selection.")
 (|context manifest-text update|
  context manifest-text pkg.manifest.read update selection
  context manifest-text rolldown finish) `publish defp

 ### def synchronize
 (project update offline -- :
  "Synchronize under cancellable application-level project coordination.")
 (|project update offline|
  project pkg.project.lock
  project offline start project `directory at "ecl.pkg" fs.read-text update publish
  port.close) `synchronize def

 ### def verify
 (project -- : "Verify the installed packages against the root lock and their kept archives.")
 (|project|
  project `directory at "ecl.lock" fs.read-text pkg.resolution.read
  project pkg.project.manifest pkg.resolution.compatible
  project `directory at swap pkg.verify.installation) `verify def
) `pkg.install @defm
