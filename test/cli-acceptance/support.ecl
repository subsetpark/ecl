### module cli.test.support
# Shared helpers for CLI acceptance. Every test works beneath its own directory
# inside the build-owned working directory and launches the binary under test
# with an explicit, otherwise empty environment.
[]
(
 ### def fail-unless
 (condition values template -- : "Fail with a formatted message when condition is false.")
 (str.format {kind user} `msg rolldown put assert) `fail-unless def

 ### def expect
 (actual expected label -- : "Fail with both values when actual differs from expected.")
 (|actual expected label|
  actual expected match? label expected actual 3 pack "{}: expected {} but got {}" fail-unless)
 `expect def

 ### def expect-contains
 (text fragment label -- : "Fail unless text contains fragment.")
 (|text fragment label|
  text fragment str.contains? label fragment text 3 pack "{}: expected {} in {}" fail-unless)
 `expect-contains def

 ### def expect-absent
 (text fragment label -- : "Fail when text contains fragment.")
 (|text fragment label|
  text fragment str.contains? not label fragment text 3 pack "{}: unexpected {} in {}"
  fail-unless) `expect-absent def

 ### def absolute
 (path -- path : "Resolve a working-directory-relative path to an absolute host path.")
 (host.cwd swap pair path.join) `absolute def

 ### def write
 (text path -- : "Create or replace a working-directory-relative text file.")
 (|text path|
  `cwd path text `cwd path fs.exists? (fs.replace-text) (fs.create-text) if) `write def

 ### def exists?
 (path -- bool : "Report whether a working-directory-relative entry exists.")
 (`cwd swap fs.exists?) `exists? def

 ### def install
 (directory -- binary :
  "Copy the binary under test to directory/bin/ecl, keeping its permissions, and return its absolute
   path.")
 (|directory|
  `cwd directory "bin" pair path.join fs.mkdirs
  host.executable path.dirname fs.open-dir dup host.executable path.basename
  `cwd directory "bin/ecl" pair path.join fs.copy port.close
  directory "bin/ecl" pair path.join absolute) `install def

 ### def invocation
 (binary arguments directory -- spec :
  "Describe a bounded run of binary in a working-directory-relative directory with an empty
   environment.")
 (|binary arguments directory|
  {env {} timeout-ms 60000 stdout-limit 1048576 stderr-limit 1048576}
  `executable binary put `args arguments put `cwd directory absolute put) `invocation def

 ### def outcome
 (result -- code stdout stderr : "Split a process result into exit code and decoded streams.")
 (dup `term at `code at over `stdout at chars rolldown `stderr at chars) `outcome def

 ### def expect-status
 (code stdout stderr status label -- stdout stderr :
  "Require an exit status, reporting the child's stderr when it differs.")
 (|code stdout stderr status label|
  code status label stderr pair "{} (stderr: {})" str.format expect stdout stderr)
 `expect-status def

 ### def succeeds
 (spec label -- stdout : "Run spec, require exit status 0, and return its stdout.")
 (|spec label| spec proc.run outcome 0 label expect-status pop) `succeeds def

 ### def fails
 (spec label -- stderr : "Run spec, require exit status 1, and return its stderr.")
 (|spec label| spec proc.run outcome 1 label expect-status nip) `fails def
) `cli.test.support @defm
