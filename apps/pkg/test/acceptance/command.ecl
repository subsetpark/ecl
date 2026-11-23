### module pkg.test.command
(
 ### defp equal
 (actual expected -- : "Compare public command behavior.")
 (match? {kind user msg "package command assertion failed"} assert) `equal defp

 ### test command-workflow
 (-- :
  "Initialize, synchronize, verify, and vendor a project through the application command entry. The
   host designates `cache` as the download cache; an offline workflow must leave it empty.")
 (`cwd "cache" fs.mkdir
  ["init" "demo"] pkg.command.main
  `cwd "ecl.pkg" fs.read-text pkg.manifest.read `name at "demo" equal
  `cwd "ecl.lock" fs.read-text
  ["sync" "--offline"] pkg.command.main
  ["verify"] pkg.command.main
  ["tree"] pkg.command.main
  ["vendor" "--offline"] pkg.command.main
  ["verify"] pkg.command.main
  `cwd "ecl.lock" fs.read-text equal
  `cwd "ecl.modules" fs.read-text pkg.layout.from-reference "vendor/" str.starts? 1 equal
  `cwd "cache" fs.remove-dir
  ["gc" "ecl.lock"] pkg.command.main) `command-workflow test

 ### def run
 (-- : "Run only the command acceptance test; package modules carry their own tests.")
 (`pkg.test.command pkg.test.support.run-module) `run def
) `pkg.test.command @defm
