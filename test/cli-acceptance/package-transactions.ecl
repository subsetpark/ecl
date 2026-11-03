### module cli.test.package-transactions
# Separate processes observe immutable generations across publication
# boundaries. Policy and conflict assertions belong to
# apps/pkg/test/transaction.ecl.
[]
(
 `cli.test.support (expect absolute invocation succeeds write) import

 ### defp generation
 (-- identifier : "The generation a transaction publishes.")
 ("a" 64 str.repeat) `generation defp

 ### defp previous-generation
 (-- identifier : "The generation active before publication.")
 ("b" 64 str.repeat) `previous-generation defp

 ### defp old-lock
 (-- text : "The lock before publication.")
 ("{format 2 root \"project\" packages {} requires {\"project\" {}}}\n") `old-lock defp

 ### defp new-lock
 (-- text : "The lock a transaction publishes.")
 ("{format 2 root \"project\" packages {} requires {}}\n") `new-lock defp

 ### defp generation-map
 (identifier -- text : "A project map referencing one generation.")
 (wrap "{{format 1 map \".ecl/generations/{}/ecl.modules\"}}\n" str.format) `generation-map defp

 ### defp app-map
 (-- path : "The package application's module map in this repository.")
 (*file* path.dirname path.dirname path.dirname "apps/pkg/ecl.modules" pair path.join)
 `app-map defp

 ### defp invoke
 (directory body -- : "Run a package-application program holding the project mutation lock.")
 (|directory body|
  directory absolute json.emit body pair
  "{} fs.open-dir `project set project \".ecl/mutation.lock\" fs.lock {} port.close" str.format
  host.executable swap "--module-map" app-map rolldown 3 pack directory invocation
  "transaction program" succeeds pop) `invoke defp

 ### defp runnable
 (directory expected -- : "Require the project's active generation to supply the expected value.")
 (|directory expected|
  host.executable ["fixture.value str io.prin"] directory invocation "active generation" succeeds
  expected str "active generation value" expect) `runnable defp

 ### defp initialize
 (directory -- : "Create a project whose lock and map select the previous generation.")
 (|directory|
  previous-generation old-lock 7 3 pack generation new-lock 9 3 pack pair
  directory
  (|entry directory|
   directory ".ecl/generations" entry first 3 pack path.join
   `cwd over fs.mkdirs
   entry 1 at over "ecl.lock" pair path.join write
   "{format 1 local \"local\" scopes {\"local\" {root \".\" visible [] sources [\"*.ecl\"] artifacts []}}}\n"
   over "ecl.modules" pair path.join write
   entry 2 at wrap "[] (({}) `value def) `fixture @defm" str.format
   swap "fixture.ecl" pair path.join write 0) partial each pop
  "{format 2 name \"project\" version \"0.1.0\" requires {}}\n" directory "ecl.pkg" pair path.join
  write
  old-lock directory "ecl.lock" pair path.join write
  previous-generation generation-map directory "ecl.modules" pair path.join write) `initialize defp

 ### test 'recovery completes publication from every boundary'
 (-- : "Recover an interrupted publication at each boundary, observing it from fresh processes.")
 ([{name "prepared" lock 0 map 0 retired 0 before 7}
   {name "lock" lock 1 map 0 retired 0 before 7}
   {name "map" lock 1 map 1 retired 0 before 9}
   {name "retired" lock 1 map 1 retired 1 before 9}]
  (|case|
   "package-transactions" case `name at pair path.join
   dup initialize
   dup
   "project {} {} (pop pop) pkg.transaction.prepare"
   ".ecl/generations" generation pair path.join json.emit new-lock json.emit pair swap str.format
   invoke
   new-lock over "ecl.lock" pair path.join case `lock at (write) (pop pop) if
   generation generation-map over "ecl.modules" pair path.join case `map at (write) (pop pop) if
   `cwd over ".ecl/publication.ecl" pair path.join case `retired at (fs.remove-file) (pop pop) if
   dup case `before at runnable
   dup "project (pop pop) pkg.transaction.recover" invoke
   dup "project (pop pop) pkg.transaction.recover" invoke
   9 runnable 0) each pop) `'recovery completes publication from every boundary' test
) `cli.test.package-transactions @defm
