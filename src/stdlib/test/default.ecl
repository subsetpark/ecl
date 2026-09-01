### module test.default
# The bundled test runner deliberately owns policy in ordinary ECL. The host
# supplies only catalog discovery, protected invocation, and root dispatch.
[]
(
 ### defp report
 (descriptor -- failed :
  "Run one descriptor, print its total result, and return 1 exactly on failure.")
 (|descriptor|
  descriptor @test descriptor pair
  dup first 'ok dict.has?
  (1 at
   dup 'module at swap 'name at pair (str 1 drop) each
   "ok {}.{}" str.format io.print
   0)
  (dup 1 at swap first pair "FAIL {}: {}" str.format io.print
   1)
  if)
 'report defp

 ### def run
 (-- : "Discover and run canonical tests sequentially, exiting 1 after any failure.")
 (tests (report) each sum
  dup 0 >
  (pop 1 exit)
  (pop)
  if)
 'run def
) 'test.default @defm
