### module pkg.test.install
# Offline installation through public resources, run by `pkg.test.install.run`
# in a fresh working directory.
(
 ### defp equal
 (actual expected -- : "Compare installation behavior through public resources.")
 (match? {kind user msg "installation assertion failed"} assert) `equal defp

 ### defp fixture-bytes
 (-- bytes : "Decode the source package fixture independently of installation.")
 (*file* path.dirname path.dirname "fixtures" pair path.join fs.open-dir
  dup "valid.tgz.hex" fs.read-text swap port.close str.trim
  ("0123456789abcdef" swap find) each
  dup len 2 div 2 pair reshape (|pair| pair first 16 * pair 1 at +) each) `fixture-bytes defp

 ### defp manifest
 (-- manifest : "Describe a project with one exact archive dependency.")
 ({format 2 name "project" version "1.0.0" sources []}
  `requires {} "sample"
  {package "sample" version "1.0.0" source
   {kind archive url "https://fixture.invalid/sample.tgz"}}
  `hash fixture-bytes pkg.fetch.hash put put put) `manifest defp

 ### defp lock
 (-- lock : "Supply an independently authored portable selected graph.")
 ({format 3 root "project" requires
   {"project" {"sample" {package "sample" version "1.0.0"}} "sample" {}}}
  `root-requires manifest `requires at put
  `packages {} "sample" manifest `requires at "sample" at `package del put put
  pkg.resolution.validate) `lock defp

 ### defp started
 (project -- context : "Start offline with no shared cache.")
 (1 pkg.install.start `cache "" put) `started defp

 ### defp install
 (project -- : "Pin privately, install, and keep the exact archive.")
 (|project|
  project started
  dup `downloads at fixture-bytes pkg.fetch.hash fixture-bytes pkg.cache.write-at
  dup manifest `requires at "sample" at pkg.obtain.requirement fixture-bytes equal
  dup manifest 0 pkg.install.selection pkg.resolution.read lock equal
  manifest str lock pkg.resolution.write pkg.install.finish
  project pkg.install.verify
  project `directory at "ecl.lock" fs.read-text lock pkg.resolution.write equal
  project `directory at ".ecl/downloads" fs.exists? 0 equal
  project `directory at ".ecl/packages/sample/README.md" fs.read-bytes
  "ordinary data" bytes [0 255] cat equal) `install defp

 ### defp search
 (project -- : "Module search finds an installed package with nothing written for it.")
 (|project|
  {timeout-ms 60000 stdout-limit 4096 stderr-limit 65536} `executable host.executable put
  `args ["-e" "sample.api.value"] put `cwd project `path at put proc.run
  dup dup `term at {kind exited code 0} match? swap str `user error.new swap error.with-message
  assert
  `stdout at chars str.trim "7" equal) `search defp

 ### defp reinstall
 (project -- : "Honor the root lock and reuse the kept archive with no pin or cache.")
 (|project|
  project started
  dup manifest 0 pkg.install.selection lock pkg.resolution.write equal
  dup manifest `requires {} put 0 3 pack (pkg.install.selection) cat @attempt result.err? 1 equal
  manifest str lock pkg.resolution.write pkg.install.finish
  project pkg.install.verify) `reinstall defp

 ### defp damage
 (project -- : "Verification never repairs a changed installed file.")
 (|project|
  project `directory at ".ecl/packages/sample/README.md" "changed" fs.publish-text
  project (pkg.install.verify) cons @attempt result.err? 1 equal
  project `directory at ".ecl/packages/sample/README.md" fs.read-text "changed" equal)
 `damage defp

 ### defp exercise
 (project -- : "Install, find, reinstall, and damage one project under its mutation lock.")
 (|project|
  project `directory at "ecl.pkg" manifest str fs.create-text
  project pkg.project.lock
  project install project search project reinstall project damage
  port.close) `exercise defp

 ### def run
 (-- : "Run the offline installation acceptance in a fresh project directory.")
 (`cwd "project" fs.mkdir
  {} `path "project" pkg.project.absolute put `directory "project" pkg.project.absolute fs.open-dir
  put
  (|project| project (exercise) cons @attempt project `directory at port.close result.or-raise pop)
  apply) `run def
) `pkg.test.install @defm
