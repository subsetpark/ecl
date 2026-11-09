### module cli.test.installed-apps
# Exercise installation-only dispatch through a relocated executable.
(
 `cli.test.support
 (expect expect-contains expect-absent absolute install invocation succeeds write) import

 ### defp descriptor
 (-- dict : "A valid installed application descriptor.")
 ({format 1 entry "main.ecl" module_map "ecl.modules"}) `descriptor defp

 ### defp app
 (prefix -- path : "The fixture application's directory beneath an installation prefix.")
 ("share/ecl/apps/fixture" pair path.join) `app defp

 ### defp in-caller
 (binary arguments -- spec : "Describe the installed binary running from the caller directory.")
 ("installed-apps/caller" invocation) `in-caller defp

 ### defp entry
 (source prefix -- : "Replace the fixture application's entry program.")
 (app "main.ecl" pair path.join write) `entry defp

 ### defp copy-into
 (source-directory destination-directory name -- : "Copy one file between test directories.")
 (|from to name| `cwd from name pair path.join `cwd to name pair path.join fs.copy) `copy-into defp

 ### test 'installed applications dispatch from the installation'
 (-- : "Resolve installed applications from the executable's own prefix, never the caller's.")
 ("installed-apps/distribution" install
  `cwd "installed-apps/distribution" app fs.mkdirs
  descriptor json.emit "installed-apps/distribution" app "application.json" pair path.join write
  "{format 1 local \"app\" scopes {\"app\" {root \".\" visible [] sources [\"*.ecl\"] artifacts []}}}"
  "installed-apps/distribution" app "ecl.modules" pair path.join write
  "((42) `answer def) `appfixture @defm"
  "installed-apps/distribution" app "library.ecl" pair path.join write
  "appfixture.answer str io.prin args str io.prin `cwd \"sentinel\" fs.read-text io.prin"
  "installed-apps/distribution" entry
  `cwd "installed-apps/caller" fs.mkdirs
  "caller directory" "installed-apps/caller/sentinel" write
  "broken project map" "installed-apps/caller/ecl.modules" write
  "((999) `answer def) `appfixture @defm" "installed-apps/caller/appfixture.ecl" write
  dup ["fixture" "one" "two"] in-caller "application dispatch" succeeds
  "42(\"one\" \"two\")caller directory" "application output" expect
  # An explicit caller map also cannot replace the application's own map.
  dup ["--module-map" "missing" "fixture" "three"] in-caller "explicit caller map" succeeds
  "42(\"three\")" "explicit caller map output" expect-contains
  # Standard input stays available as program data.
  "io.stdin io.prin" "installed-apps/distribution" entry
  dup ["fixture"] in-caller `stdin "input bytes" bytes put "standard input" succeeds
  "input bytes" "standard input output" expect
  pop
  # The installation is relocatable as one directory.
  `cwd "installed-apps/distribution" "installed-apps/moved" fs.rename
  "installed-apps/moved/bin/ecl" absolute
  dup ["fixture"] in-caller `stdin "moved" bytes put "relocated installation" succeeds
  "moved" "relocated output" expect
  "\"APP_FIXTURE_TOKEN\" getenv io.prin" "installed-apps/moved" entry
  dup ["fixture"] in-caller `env {"APP_FIXTURE_TOKEN" "passed"} put "environment" succeeds
  "passed" "environment output" expect
  # Installed names are not discovered in the caller's project or PATH. The
  # PATH candidate is a real executable, so running it would exit 0.
  `cwd "installed-apps/caller/ecl.modules" fs.remove-file
  `cwd "installed-apps/caller/share/ecl/apps/unregistered" fs.mkdirs
  "installed-apps/moved" app "installed-apps/caller/share/ecl/apps/unregistered" "application.json"
  copy-into
  `cwd "installed-apps/caller/path-bin" fs.mkdirs
  "installed-apps/moved/bin" "installed-apps/caller/path-bin" "ecl" copy-into
  `cwd "installed-apps/caller/path-bin/ecl" "installed-apps/caller/path-bin/unregistered" fs.rename
  dup ["unregistered"] in-caller `env {} "PATH" "installed-apps/caller/path-bin" absolute put put
  proc.run `term at `code at 0 match? not 1 "unregistered name is not dispatched" expect
  # Every invalid descriptor is refused before the application runs.
  dup [{format 2} {entry "../escape.ecl"} {module_map "/outside"} {extra 1}] swap
  (swap descriptor swap dict.merge json.emit
   "installed-apps/moved" app "application.json" pair path.join write
   ["fixture"] in-caller proc.run dup `term at `code at 0 match? not 1
   "invalid descriptor is refused" expect
   `stderr at chars "invalid installed application descriptor" "invalid descriptor message"
   expect-contains 0) cons each pop
  # Built-in commands retain precedence over installed application names.
  `cwd "installed-apps/moved/share/ecl/apps/test" fs.mkdirs
  ["application.json" "ecl.modules" "library.ecl" "main.ecl"]
  ("installed-apps/moved" app "installed-apps/moved/share/ecl/apps/test" rolldown copy-into 0) each
  pop
  ["test"] in-caller proc.run `stderr at chars "invalid installed application descriptor"
  "builtin test precedence" expect-absent) `'installed applications dispatch from the installation'
 test
) `cli.test.installed-apps @defm
