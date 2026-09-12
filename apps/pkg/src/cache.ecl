### module pkg.cache
# A disposable shared download cache. Project generations never depend on it.
[]
(
 ### def filename
 (hash -- filename : "Name one exact archive in the flat download cache.")
 (dup pkg.name.hash? 'domain error.new "invalid archive cache hash" error.with-message assert
  7 drop ".tgz" cat) 'filename def

 ### defp optional
 (result -- values :
  "Ignore unavailable cache I/O while preserving cancellation and other failures.")
 (dup result.ok? ('ok at)
  ('err at dup 'kind at 'io match? (pop []) (raise) if) if) 'optional defp

 ### defp read-file
 (path hash -- bytes :
  "Read an owned byte snapshot and release the cache directory before returning.")
 (|path hash|
  path fs.open-dir dup hash read-at swap port.close) 'read-file defp

 ### defp read-known
 (directory hash -- bytes : "Read one candidate cache file through an already opened directory.")
 (filename fs.read-bytes) 'read-known defp

 ### def read-at
 (directory hash -- bytes :
  "Read and hash-check a cache entry through an explicit directory resource.")
 (|directory hash|
  directory hash pair (read-known) @attempt optional
  dup empty? (pop []) (first) if hash checked-read) 'read-at def

 ### defp checked-read
 (bytes hash -- bytes : "Treat corrupted cache contents as a miss without trusting their filename.")
 (|bytes hash|
  bytes pkg.fetch.hash hash match? bytes () partial ([]) if) 'checked-read defp

 ### defp read-present
 (path hash -- bytes :
  "Read a cache entry without making cache availability a synchronization requirement.")
 (|path hash|
  path hash pair (read-file) @attempt optional
  dup empty? (pop []) (first) if) 'read-present defp

 ### def read
 (path hash -- bytes :
  "Return exact cached bytes, or [] when the optional cache cannot supply them.")
 (over empty? (pop pop []) (read-present) if) 'read def

 ### defp write-file
 (path hash bytes -- :
  "Atomically publish valid cache bytes, allowing initial creation and replacement.")
 (|path hash bytes|
  path pkg.project.open-created hash bytes
  (|directory hash bytes| directory hash bytes write-at directory port.close) call) 'write-file defp

 ### def write-at
 (directory hash bytes -- :
  "Publish only the bytes named by this cache key through an explicit directory.")
 (|directory hash bytes|
  bytes hash pkg.fetch.checked directory hash filename fs.publish-bytes) 'write-at def

 ### def write
 (path hash bytes -- : "Populate the cache opportunistically; cancellation still propagates.")
 (|path hash bytes|
  path hash bytes 3 pack path empty?
  (pop) ((write-file) @attempt optional pop) if) 'write def
) 'pkg.cache @defm
