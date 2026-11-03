### module cli.test.module-maps
# Validate maps through the public CLI, without constructing a project Session.
[]
(
 `cli.test.support
 (expect expect-contains install invocation succeeds fails write exists?) import

 ### defp complete
 (-- text : "A complete local map whose sources live beside it.")
 ("{format 1 local \"local\" scopes {\"local\" {root \".\" visible [] sources [\"src/*.ecl\"] artifacts []}}}")
 `complete defp

 ### defp check
 (binary arguments -- spec : "Describe check-map in the test root.")
 (["check-map"] swap cat "module-maps" invocation) `check defp

 ### defp document
 (binary path text -- spec : "Describe validation of an unpublished document read from stdin.")
 (|binary path text|
  binary "--document" path "-" 3 pack check `stdin text bytes put) `document defp

 ### defp invalid?
 (spec label -- stderr : "Require check-map to reject a map and return its diagnostic.")
 (|spec label| spec label fails dup "invalid module map" label expect-contains) `invalid? defp

 ### defp invalid
 (spec label -- : "Require check-map to reject a map.")
 (invalid? pop) `invalid defp

 ### defp diagnoses
 (spec fragment label -- : "Require check-map to reject a map with a diagnostic naming the fix.")
 (|spec fragment label| spec label invalid? fragment label expect-contains) `diagnoses defp

 ### defp rejects
 (binary text detail -- :
  "Require a candidate document to be rejected with a diagnostic naming the fix.")
 (|binary text detail|
  binary "maps/candidate" text document detail "rejection detail" diagnoses) `rejects defp

 ### defp usage
 (spec label -- : "Require check-map to reject its arguments.")
 (|spec label| spec label fails "usage:" label expect-contains) `usage defp

 ### test 'validation never executes or publishes'
 (-- : "Validate published, unpublished, and relocated maps without executing sources.")
 ("module-maps" install
  # Neither a corrupt caller map nor a broken lock enters validation.
  "broken" "module-maps/ecl.modules" write
  "broken" "module-maps/ecl.pkg" write
  "broken" "module-maps/ecl.lock" write
  `cwd "module-maps/maps/src" fs.mkdirs
  complete "module-maps/maps/complete" write
  # A source with observable side effects is inspected, never executed.
  "`cwd \"executed\" \"bad\" fs.create-text [] () `localmod @defm"
  "module-maps/maps/src/entry.ecl" write
  "{format 1 map \"complete\"}" "module-maps/maps/reference" write
  dup ["maps/complete"] check "complete map" succeeds "" "complete map stdout" expect
  dup ["maps/reference"] check "reference map" succeeds "" "reference map stdout" expect
  "module-maps/executed" exists? 0 "sources are not executed" expect
  # A not-yet-published document uses its eventual path as the relative base.
  dup "maps/future/ecl.modules" complete "root \".\"" "root \"..\"" str.replace document
  "future document" succeeds pop
  "module-maps/maps/future" exists? 0 "future document is not published" expect
  "module-maps/executed" exists? 0 "future sources are not executed" expect
  dup "maps/future/ecl.modules" "broken" document "broken document" invalid
  dup "maps/unpublished" "{format 1 map \"complete\"}" document "unpublished reference" succeeds
  pop
  dup "maps/unpublished" "{format 1 map \"reference\"}" document "chained reference" invalid
  # Each rejection names what to fix rather than only that the map is invalid.
  dup "broken" "must contain exactly one dict" rejects
  dup "{format 2 map \"complete\"}" "must declare `format 1`" rejects
  dup complete "local \"local\"" "local \"other\"" str.replace
  "local scope `other` is not declared" rejects
  dup complete "visible []" "visible [\"ghost\"]" str.replace "lists undeclared scope `ghost`"
  rejects
  dup complete "[\"src/*.ecl\"]" "[\"../*.ecl\"]" str.replace "invalid source pattern `../*.ecl`"
  rejects
  dup "maps/unpublished" "{format 1 map \"chain\"}" document
  "cannot read module map" "unpublished reference" diagnoses
  dup "maps/unpublished" " " 16777217 str.repeat document "oversized document" fails
  "bounded module map input" "oversized document" expect-contains
  # Validation discovers new sources with the same rules as startup.
  "[] () `localmod @defm" "module-maps/maps/src/duplicate.ecl" write
  dup ["maps/complete"] check "duplicate module" invalid
  # The diagnostic names the module and both declaring files.
  dup ["module `localmod`" "`src/duplicate.ecl`" "`src/entry.ecl`" "scope `local`"] swap
  (|fragment binary| binary ["maps/complete"] check fragment "duplicate diagnostic" diagnoses 0)
  partial each pop
  `cwd "module-maps/maps/src/duplicate.ecl" fs.remove-file
  "{format 1 map \"reference\"}" "module-maps/maps/chain" write
  dup ["maps/chain"] check "chained map" invalid
  dup ["ecl.modules"] check "corrupt caller map" invalid
  dup ["missing"] check "missing map" invalid
  dup [] check "no arguments" usage
  dup ["maps/complete" "extra"] check "extra argument" usage
  dup ["-"] check "bare stdin" usage
  dup ["--document" "maps/new"] check "document without stdin marker" usage
  # Builtin precedence and explicit-map independence also apply here.
  `cwd "module-maps/share/ecl/apps/check-map" fs.mkdirs
  "{\"format\":999}" "module-maps/share/ecl/apps/check-map/application.json" write
  dup ["--module-map" "missing" "check-map" "maps/complete"] "module-maps" invocation
  "explicit map ignored" succeeds pop
  # Relative source roots survive relocation of the containing document.
  `cwd "module-maps/maps" "module-maps/moved" fs.rename
  ["moved/reference"] check "relocated reference" succeeds pop)
 `'validation never executes or publishes' test
) `cli.test.module-maps @defm
