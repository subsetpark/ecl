### module stdlib.test.host-surfaces
(
 'stdlib.test.support ('documented) import

 ### test documentation
 (-- : "Require documentation for host-authority standard-library exports.")
 (('io.pp 'io.prin 'io.print 'io.inspect 'io.debug 'io.stack 'io.stdin
   'io.slurp 'io.spit 'io.lines 'http.get 'http.get-bytes 'http.post
   'pkg.store.inspect 'pkg.store.install 'pkg.store.present?
   'pkg.store.verify 'pkg.store.read-seal 'pkg.store.write-lock
   'pkg.store.write-new 'pkg.store.gc)
  documented)
 'documentation test

) 'stdlib.test.host-surfaces @defm
