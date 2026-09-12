### module pkg.test.gc
[]
(
 ### defp equal
 (actual expected -- : "Compare cache collection through public directory operations.")
 (match? {'kind 'user 'msg "cache collection assertion failed"} assert) 'equal defp

 ### test explicit-retention
 (-- : "Collect only unretained regular cache archives and preserve unrelated entries.")
 ('cwd "apps/pkg/test/fixtures/gc-unused" fs.stage-dir
  (|directory|
   directory [1 2] pkg.fetch.hash [1 2] pkg.cache.write-at
   directory [3 4] pkg.fetch.hash [3 4] pkg.cache.write-at
   "unrelated" directory "keep.txt" fs.create-text
   directory [5 6] pkg.fetch.hash pkg.cache.filename fs.mkdir
   directory [1 2] pkg.fetch.hash wrap pkg.gc.collect-at 1 equal
   directory [1 2] pkg.fetch.hash pkg.cache.read-at [1 2] equal
   directory [3 4] pkg.fetch.hash pkg.cache.filename fs.exists? 0 equal
   directory "keep.txt" fs.read-text "unrelated" equal
   directory [5 6] pkg.fetch.hash pkg.cache.filename fs.lstat 'kind at 'directory equal
   directory [1 2] pkg.fetch.hash wrap pkg.gc.collect-at 0 equal
   directory port.close) call) 'explicit-retention test
) 'pkg.test.gc @defm
