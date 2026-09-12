### module pkg.test.runner
[]
(
 ### def run
 (-- : "Run one explicitly selected application test module through the public test interface.")
 (tests ('module at chars args first match?) filter
  dup empty? not {'kind 'user 'msg "no matching application tests"} assert
  (|descriptor|
   descriptor @test result.or-raise pop
   descriptor 'module at chars descriptor 'name at chars pair "ok {}.{}" str.format io.print)
  for) 'run def
) 'pkg.test.runner @defm
