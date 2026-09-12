### module pkg.test.generation
[]
(
 ### defp equal
 (actual expected -- : "Compare immutable generation behavior through public resources.")
 (match? {'kind 'user 'msg "generation assertion failed"} assert) 'equal defp

 ### defp fixture-bytes
 (-- bytes : "Decode the source package fixture independently of generation construction.")
 ('cwd "apps/pkg/test/fixtures/valid.tgz.hex" fs.read-text str.trim
  ("0123456789abcdef" swap find) each
  dup len 2 div 2 pair reshape (|pair| pair first 16 * pair 1 at +) each) 'fixture-bytes defp

 ### defp manifest
 (-- manifest : "Describe a project with one exact archive dependency.")
 ({'format 2 'name "project" 'version "1.0.0" 'sources [] 'exports []}
  'requires {} "sample"
  {'package "sample" 'version "1.0.0" 'source
   {'kind 'archive 'url "https://fixture.invalid/sample.tgz"}}
  'hash fixture-bytes pkg.fetch.hash put put put) 'manifest defp

 ### defp lock
 (-- lock : "Supply an independently authored portable selected graph.")
 ({'format 3 'root "project" 'requires
   {"project" {"sample" {'package "sample" 'version "1.0.0"}} "sample" {}}}
  'root-requires manifest 'requires at put
  'packages {} "sample" manifest 'requires at "sample" at 'package del put put
  pkg.resolution.validate) 'lock defp

 ### defp started
 (project -- work : "Start offline from deliberately malformed project runtime state.")
 (pkg.project.generation-id pkg.layout.project-generation 1 pkg.generation.start
  dup 'context at 'cache "" put 'context swap put) 'started defp

 ### defp exercise
 (project -- : "Pin privately, publish without activation, and retain exact portable snapshots.")
 (|project|
  manifest str project 'directory at "ecl.pkg" fs.create-text
  "broken" project 'directory at "ecl.modules" fs.create-text
  project pkg.project.lock
  project started project pair (build) with call port.close) 'exercise defp

 ### defp build
 (work project -- : "Install one exact dependency without any network or shared cache.")
 (|work project|
  work ['context 'downloads] at-path fixture-bytes pkg.fetch.hash fixture-bytes pkg.cache.write-at
  work 'context at manifest 'requires at "sample" at pkg.obtain.requirement fixture-bytes equal
  work manifest 0 pkg.install.selection pkg.resolution.read lock equal
  work manifest str lock pkg.resolution.write pkg.generation.finish
  project work 'location at pkg.verify.generation
  project 'directory at work 'location at "/ecl.lock" cat fs.read-text lock pkg.resolution.write
  equal
  project 'directory at "ecl.modules" fs.read-text "broken" equal
  project 'directory at work 'location at "/downloads" cat fs.exists? 0 equal
  project 'directory at work 'location at "/packages/sample/README.md" cat fs.read-bytes
  "ordinary data" bytes [0 255] cat equal
  project 'directory at work 'location at "/ecl.modules" cat fs.read-text pkg.data.read-one
  'scopes at "sample" at 'artifacts at
  [{'kind 'ecl 'path "src/api.ecl" 'exports ["sample.api"]}] equal
  work lock pkg.resolution.write pkg.install.activate
  project pkg.install.verify
  project started project pair (reproduce) with call
  project rejected-map
  project recover-publication
  project work 'location at check-damage) 'build defp

 ### defp reproduce
 (work project -- :
  "Honor the root lock and reuse a captured generation after the cache is unavailable.")
 (|work project|
  work manifest 0 pkg.install.selection lock pkg.resolution.write equal
  work manifest 'requires {} put 0 3 pack (pkg.install.selection) @attempt result.err? 1 equal
  work manifest 'requires {} put 1 pkg.install.selection pkg.resolution.read 'packages at {} equal
  project 'directory at "ecl.lock" fs.read-text lock pkg.resolution.write equal
  work manifest str lock pkg.resolution.write pkg.generation.finish
  work lock pkg.resolution.write pkg.install.activate
  project pkg.install.verify) 'reproduce defp

 ### defp rejected-map
 (project -- : "Reject a conflicting local declaration before publishing a candidate generation.")
 (|project|
  "[] () 'sample.api @defm" project 'directory at "collision.ecl" fs.publish-text
  project started project pair (reject-work) with call) 'rejected-map defp

 ### defp reject-work
 (work project -- : "Join failed staging and retain both active root files exactly.")
 (|work project|
  project 'directory at "ecl.modules" fs.read-text
  project 'directory at "ecl.lock" fs.read-text
  work manifest 'sources ["collision.ecl"] put str lock pkg.resolution.write
  3 pack (pkg.generation.finish) @attempt result.err? 1 equal
  work 'stage at port.close
  project 'directory at work 'location at fs.exists? 0 equal
  project 'directory at "ecl.lock" fs.read-text equal
  project 'directory at "ecl.modules" fs.read-text equal
  project pkg.install.verify) 'reject-work defp

 ### defp recover-publication
 (project -- : "Prepare a different valid graph and interrupt after publishing its root lock.")
 (|project|
  project started project pair (recover-work) with call) 'recover-publication defp

 ### defp recover-work
 (work project -- :
  "An existing generation remains consistent while recovery completes activation.")
 (|work project|
  project 'directory at "ecl.modules" fs.read-text
  work manifest 'requires {} put 1 pkg.install.selection
  work project 3 pack (interrupt-work) with call) 'recover-work defp

 ### defp interrupt-work
 (previous-map next-lock work project -- :
  "Replay the real generation validator across the two root writes.")
 (|previous-map next-lock work project|
  manifest 'requires {} put pkg.manifest.write
  dup project 'directory at "ecl.pkg" fs.publish-text
  work swap next-lock pkg.generation.finish
  project 'directory at work 'location at next-lock
  project 'path at (pkg.verify.publication) partial pkg.transaction.prepare
  next-lock project 'directory at "ecl.lock" fs.publish-text
  project wrap (pkg.install.verify) @attempt result.err? 1 equal
  project 'directory at "ecl.modules" fs.read-text previous-map equal
  project previous-map pkg.layout.from-reference pkg.verify.generation
  project 'directory at previous-map pkg.layout.from-reference "/ecl.lock" cat fs.read-text
  lock pkg.resolution.write equal
  project pkg.install.recover project pkg.install.verify
  project 'directory at "ecl.modules" fs.read-text work 'location at pkg.layout.reference equal
  project 'directory at "ecl.lock" fs.read-text next-lock equal
  project 'directory at ".ecl/publication.ecl" fs.exists? 0 equal
  project pkg.install.recover project pkg.install.verify) 'interrupt-work defp

 ### defp check-damage
 (project location -- :
  "Verification checks old generations independently and never repairs changed bytes.")
 (|project location|
  "changed" project 'directory at location "/packages/sample/README.md" cat fs.publish-text
  project location pair (pkg.verify.generation) @attempt result.err? 1 equal
  project 'directory at location "/packages/sample/README.md" cat fs.read-text "changed" equal
  project pkg.install.verify) 'check-damage defp

 ### defp run-at
 (path -- : "Join owned resources and remove the test project before propagating an assertion.")
 (|path|
  'cwd path fs.mkdir
  {} 'path path pkg.project.absolute put 'directory path pkg.project.absolute fs.open-dir put
  path pair (run-project) with call) 'run-at defp

 ### defp run-project
 (project path -- : "Clean up both successful and failed test invocations.")
 (|project path|
  project wrap (exercise) @attempt
  project 'directory at port.close 'cwd path fs.remove-tree
  result.or-raise pop) 'run-project defp

 ### test sealed-offline-generation
 (-- : "A private exact pin produces a complete generation without changing the active root map.")
 ("apps/pkg/test/fixtures/project-" pkg.project.generation-id cat run-at) 'sealed-offline-generation
 test

 ### def run
 (-- : "Require the generation acceptance registration before invoking the built-in test runner.")
 (tests len 1 = {'kind 'user 'msg "generation acceptance test was not registered"} assert
  test.default.run) 'run def
) 'pkg.test.generation @defm
