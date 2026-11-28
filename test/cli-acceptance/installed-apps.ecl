### module cli.test.installed-apps
# Exercise installation-only dispatch through a relocated executable.
(
 `cli.test.support
 (expect expect-contains expect-absent absolute install invocation succeeds write) import

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
  "((42) `answer def) `appfixture @defm"
  "installed-apps/distribution" app "library.ecl" pair path.join write
  "appfixture.answer str io.prin args str io.prin `cwd \"sentinel\" fs.read-text io.prin"
  "installed-apps/distribution" entry
  `cwd "installed-apps/caller" fs.mkdirs
  "caller directory" "installed-apps/caller/sentinel" write
  # Neither the caller's project nor ECL_PATH supplies the application's
  # modules: a caller file declaring the same module is never found.
  "broken manifest" "installed-apps/caller/ecl.pkg" write
  "((999) `answer def) `appfixture @defm" "installed-apps/caller/appfixture.ecl" write
  dup ["fixture" "one" "two"] in-caller `env {} "ECL_PATH" "installed-apps/caller" absolute put put
  "application dispatch" succeeds
  "42(\"one\" \"two\")caller directory" "application output" expect
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
  `cwd "installed-apps/caller/ecl.pkg" fs.remove-file
  `cwd "installed-apps/caller/share/ecl/apps/unregistered" fs.mkdirs
  "installed-apps/moved" app "installed-apps/caller/share/ecl/apps/unregistered" "main.ecl"
  copy-into
  `cwd "installed-apps/caller/path-bin" fs.mkdirs
  "installed-apps/moved/bin" "installed-apps/caller/path-bin" "ecl" copy-into
  `cwd "installed-apps/caller/path-bin/ecl" "installed-apps/caller/path-bin/unregistered" fs.rename
  dup ["unregistered"] in-caller `env {} "PATH" "installed-apps/caller/path-bin" absolute put put
  proc.run `term at `code at 0 match? not 1 "unregistered name is not dispatched" expect
  # Built-in commands retain precedence over installed application names.
  `cwd "installed-apps/moved/share/ecl/apps/test" fs.mkdirs
  "installed-apps/moved" app "installed-apps/moved/share/ecl/apps/test" "library.ecl" copy-into
  "\"installed test application ran\" io.prin"
  "installed-apps/moved/share/ecl/apps/test/main.ecl" write
  ["test"] in-caller proc.run `stdout at chars "installed test application ran"
  "builtin test precedence" expect-absent) `'installed applications dispatch from the installation'
 test
) `cli.test.installed-apps @defm
