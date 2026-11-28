### module pkg.test.command
# The command workflow, run by `pkg.test.command.run` in a fresh working
# directory whose download cache is `cache`.
(
 ### defp equal
 (actual expected -- : "Compare public command behavior.")
 (match? {kind user msg "package command assertion failed"} assert) `equal defp

 ### def run
 (-- :
  "Initialize, synchronize, and verify a project through the application command entry. An offline
   workflow must leave the cache empty.")
 (`cwd "cache" fs.mkdir
  ["init" "demo"] pkg.command.main
  `cwd "ecl.pkg" fs.read-text pkg.manifest.read `name at "demo" equal
  `cwd "ecl.lock" fs.read-text
  ["sync" "--offline"] pkg.command.main
  ["verify"] pkg.command.main
  ["tree"] pkg.command.main
  ["sync" "--offline"] pkg.command.main
  ["verify"] pkg.command.main
  `cwd "ecl.lock" fs.read-text equal
  `cwd "cache" fs.remove-dir
  ["gc" "ecl.lock"] pkg.command.main) `run def
) `pkg.test.command @defm
