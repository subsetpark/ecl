### module pkg.test.cache
[]
(
 ### defp equal
 (actual expected -- : "Compare observable download-cache behavior.")
 (match? {'kind 'user 'msg "download cache assertion failed"} assert) 'equal defp

 ### setp digest
 "sha256-a12871fee210fb8619291eaea194581cbd2531e4b23759d225f6806923f63222"
 'digest setp

 ### test exact-byte-cache
 (-- :
  "A cache miss or damaged entry is harmless; valid bytes publish atomically under their hash.")
 ('cwd "apps/pkg/test/fixtures/cache-unused" fs.stage-dir
  (|directory|
   directory digest pkg.cache.read-at [] equal
   directory digest [1 2] pkg.cache.write-at
   directory digest pkg.cache.read-at [1 2] equal
   [9] directory digest pkg.cache.filename fs.publish-bytes
   directory digest pkg.cache.read-at [] equal
   directory digest [1 2] pkg.cache.write-at
   directory digest pkg.cache.read-at [1 2] equal
   directory digest [3] 3 pack (pkg.cache.write-at) @attempt result.err? 1 equal
   directory digest pkg.cache.read-at [1 2] equal
   directory port.close)
  call)
 'exact-byte-cache test

 ### test disabled-cache
 (-- : "An absent cache configuration does not write or prevent synchronization.")
 ("" digest pkg.cache.read [] equal
  "" digest [1 2] pkg.cache.write)
 'disabled-cache test
) 'pkg.test.cache @defm
