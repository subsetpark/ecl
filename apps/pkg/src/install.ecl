### module pkg.install
# Resolution and publication policy for project-local immutable generations.
[]
(
 ### defp existing-lock
 (project manifest -- text :
  "Preserve the portable lock's exact bytes during ordinary synchronization.")
 (|project manifest|
  project 'directory at "ecl.lock" fs.read-text
  dup pkg.resolution.read manifest pkg.resolution.compatible pop) 'existing-lock defp

 ### defp resolve
 (work manifest -- text :
  "Select dependencies only for initial synchronization or an explicit update.")
 (|work manifest|
  manifest work 'context at manifest pkg.discover.catalog pkg.solver.resolve pkg.resolution.write)
 'resolve defp

 ### def selection
 (work manifest update -- text :
  "Honor an existing lock unless dependency selection was explicitly requested.")
 (|work manifest update|
  work 'project at 'directory at "ecl.lock" fs.exists? update not and
  work 'project at manifest pair (existing-lock) with
  work manifest pair (resolve) with if) 'selection def

 ### def recover
 (project -- : "Complete a validated pending publication under the caller's mutation lock.")
 (|project|
  project 'directory at project 'path at (pkg.verify.publication) partial pkg.transaction.recover)
 'recover def

 ### def activate
 (work lock-text -- :
  "Journal the published candidate and activate it through the recovery protocol.")
 (|work lock-text|
  work 'project at 'directory at work 'location at lock-text
  work 'project at 'path at (pkg.verify.publication) partial pkg.transaction.prepare
  work 'project at recover) 'activate def

 ### defp location
 (vendor -- path :
  "Choose a fresh immutable destination without putting its identity into the lock.")
 (pkg.project.generation-id swap
  (pkg.layout.vendor-generation) (pkg.layout.project-generation) if) 'location defp

 ### defp synchronize-held
 (project update offline vendor -- : "Recover before reading the manifest or selecting new work.")
 (|project update offline vendor|
  project recover
  project 'directory at "ecl.pkg" fs.read-text
  project vendor location offline pkg.generation.start
  update (synchronize-work) partial call) 'synchronize-held defp

 ### defp synchronize-work
 (manifest-text work update -- :
  "Build against one observed manifest and one portable lock selection.")
 (|manifest-text work update|
  work manifest-text pkg.manifest.read update selection
  manifest-text work pair (publish) with call) 'synchronize-work defp

 ### defp publish
 (lock-text manifest-text work -- :
  "Complete the private installation before either root-file publication.")
 (|lock-text manifest-text work|
  work manifest-text lock-text pkg.generation.finish work lock-text activate) 'publish defp

 ### def synchronize
 (project update offline vendor -- :
  "Synchronize under cancellable application-level project coordination.")
 (|project update offline vendor|
  project pkg.project.lock
  project update offline vendor synchronize-held
  port.close) 'synchronize def

 ### def verify
 (project -- : "Verify the captured active generation and report unsettled root publication state.")
 (|project|
  project 'directory at "ecl.modules" fs.read-text pkg.layout.from-reference
  project swap verify-active) 'verify def

 ### defp verify-active
 (project location -- :
  "Check an immutable snapshot before diagnosing a pending or divergent root lock.")
 (|project location|
  project location pkg.verify.generation
  project 'directory at ".ecl/publication.ecl" fs.exists? not
  'domain error.new "package publication is pending; run pkg sync to recover" error.with-message
  assert
  project 'directory at location "/ecl.lock" cat fs.read-text pkg.resolution.read
  project 'directory at "ecl.lock" fs.read-text pkg.resolution.read match?
  'domain error.new "root ecl.lock differs from the active generation" error.with-message assert)
 'verify-active defp
) 'pkg.install @defm
