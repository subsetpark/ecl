### module stdlib.test.host-surfaces
[]
(
 'stdlib.test.support ('documented) import

 ### test documentation
 (-- : "Require documentation for host-authority standard-library exports.")
 (('io.pp 'io.prin 'io.print 'io.inspect 'io.debug 'io.stack 'io.stdin
   'fs.read-bytes 'fs.read-text 'fs.create-bytes 'fs.create-text
   'fs.replace-bytes 'fs.replace-text 'fs.stat 'fs.lstat 'fs.exists? 'fs.list
   'fs.mkdir 'fs.copy 'fs.rename 'fs.remove-file 'fs.remove-dir
   'path.join 'path.normalize 'path.dirname 'path.basename 'path.extension
   'path.absolute? 'path.relative? 'path.components 'path.valid-relative?
   'http.get 'http.get-bytes 'http.post
   'pkg.store.inspect 'pkg.store.install 'pkg.store.present?
   'pkg.store.verify 'pkg.store.read-seal 'pkg.store.manifest 'pkg.store.gc)
  documented)
 'documentation test

) 'stdlib.test.host-surfaces @defm
