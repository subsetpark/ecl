### module test.default
(: "The bundled runner is ordinary ECL policy over the closed `tests` / `@test` substrate. Projects
    may replace it with any public qualified runner word. The host supplies only catalog discovery,
    protected invocation, and root dispatch.")
(
 ### defp report
 (descriptor -- failed :
  "Run one descriptor, print its total result, and return 1 exactly on failure.")
 (|descriptor|
  descriptor @test descriptor pair
  dup first `ok has?
  (1 at
   dup `module at swap `name at pair (chars) each
   "ok {}.{}" str.format io.eprint
   0)
  (dup 1 at
   dup `module at swap `name at pair (chars) each
   "{}.{}" str.format
   swap first pair "FAIL {}: {}" str.format io.eprint
   1)
  if) `report defp

 ### def run
 (-- :
  "Discover every module's tests and invoke them sequentially, printing one `ok` or `FAIL` line to
   stderr for every result. Exit with status code 1 if any test failed.")
 (tests (report) each sum
  dup 0 >
  (pop 1 exit)
  (pop)
  if) `run def
) `test.default @defm
