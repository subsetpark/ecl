### module pkg.gc
# Cache collection is explicit and never reclaims project generations.
[]
(
 ### defp lock-file
 (path -- lock : "Read a portable retained-resolution input through an explicit directory.")
 (pkg.project.absolute dup path.dirname fs.open-dir
  (|path directory|
   directory path path.basename fs.read-text pkg.resolution.read directory port.close) call)
 'lock-file defp

 ### defp retain
 (hashes path -- hashes : "Retain every exact archive selected by one explicit lockfile.")
 (|hashes path|
  path lock-file 'packages at dict.vals ('hash at) each hashes cat distinct) 'retain defp

 ### defp archive-name?
 (name -- bool : "Recognize only the application's flat exact-hash cache filenames.")
 (dup ".tgz" str.ends?
  (dup len 4 - take "sha256-" swap cat pkg.name.hash?) (pop 0) if) 'archive-name? defp

 ### defp removed
 (result -- count :
  "Count only this collector's removal and tolerate another collector winning first.")
 (dup result.ok? (pop 1)
  ('err at dup 'data {} at-or 'reason 'none at-or 'not-found match? (pop 0) (raise) if) if) 'removed
 defp

 ### defp remove
 (state name -- state : "Remove an unretained regular cache file without following links.")
 (|state name|
  state 'directory at name pair (fs.remove-file) @attempt removed state count-removed) 'remove defp

 ### defp count-removed
 (count state -- state : "Accumulate successful namespace removals.")
 (|count state| state 'removed state 'removed at count + put) 'count-removed defp

 ### defp entry
 (state entry -- state :
  "Keep unrecognized entries and all explicitly retained archive identities.")
 (|state entry|
  entry 'kind at 'file match? entry 'name at archive-name? and
  state 'retained at entry 'name at (match?) partial any? not and
  state entry 'name at pair (remove) with state () partial if) 'entry defp

 ### def collect-at
 (directory hashes -- count :
  "Collect an explicitly opened cache; the caller retains its directory resource.")
 (|directory hashes|
  hashes (pkg.name.hash?) all?
  'domain error.new "invalid retained archive hash" error.with-message assert
  directory "." fs.open-list
  (|cursor directory hashes|
   {'removed 0} 'directory directory put 'cursor cursor put
   'retained hashes (pkg.cache.filename) each put cursor fs.next-entry
   (dup dict.size 0 >) (entry dup 'cursor at fs.next-entry) while pop
   'removed at cursor port.close)
  directory hashes pair swap with call) 'collect-at def

 ### defp collect
 (path hashes -- count : "Join the cache directory after incremental collection.")
 (|path hashes|
  path wrap (fs.open-dir) @attempt hashes collect-result) 'collect defp

 ### defp collect-result
 (result hashes -- count : "An absent cache is empty; other host failures remain visible.")
 (|result hashes|
  result result.ok?
  result hashes pair (|result hashes| result 'ok at first dup hashes collect-at swap port.close)
  with
  result (missing-cache) partial if) 'collect-result defp

 ### defp missing-cache
 (result -- count : "Accept only the documented absent-directory case.")
 ('err at dup 'kind at 'io match? over 'data {} at-or 'reason 'none at-or 'not-found match? and
  (pop 0) (raise) if) 'missing-cache defp

 ### def run
 (paths -- count : "Collect the download cache using only explicitly retained resolution inputs.")
 (dup empty? not
  'domain error.new "pkg gc requires retained ecl.lock paths" error.with-message assert
  [] (retain) fold pkg.project.cache-path
  dup empty? (pop pop 0) (swap collect) if) 'run def
) 'pkg.gc @defm
