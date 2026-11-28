### module pkg.verify
# Read-only verification of installed packages against the lock and the exact
# archives kept beside them.
(
 ### defp require
 (condition -- : "Reject a modified or incomplete installation.")
 (`domain error.new "package installation verification failed" error.with-message assert) `require
 defp

 ### defp check-member
 (state member -- state : "Compare one regular installed file with its sealed source archive.")
 (|state member|
  member `kind at `file match?
  state member pair (file) cat state () cons if) `check-member defp

 ### defp file
 (state member -- state : "Require a regular file and compare its exact bytes.")
 (|state member|
  state `directory at member `path at fs.lstat
  dup `kind at `file match? require `size at member `bytes at len match? require
  state `directory at member `path at fs.read-bytes
  member `bytes at match? require
  state `files state `files at member `path at append put) `file defp

 ### defp archived-files
 (bytes directory -- paths : "Check every archived file against the installed tree.")
 (|bytes directory|
  bytes gzip.decompress tar.read {files []} `directory directory put (check-member) fold `files at)
 `archived-files defp

 ### defp entry
 (state entry -- state : "Reject links and special objects while enumerating the installed tree.")
 (|state entry|
  entry `kind at `file match? entry `kind at `directory match? or require
  state `count at 100000 < require
  state `count state `count at 1 + put
  state `current at entry `name at pair path.join path.normalize
  entry `kind at `file match? (`files) (`pending) if append-path) `entry defp

 ### defp append-path
 (state path key -- state : "Append one discovered file or pending directory.")
 (|state path key| state key state key at path append put) `append-path defp

 ### defp directory
 (state -- state : "Enumerate one directory through a joined incremental cursor.")
 (dup `pending at first
  (|state path|
   state `current path put `pending state `pending at 1 drop put
   state `directory at path fs.open-list scan-directory) apply) `directory defp

 ### defp scan-directory
 (state cursor -- state : "Read each child without following links or retaining a bulk listing.")
 (|state cursor|
  state `cursor cursor put cursor fs.next-entry
  (dup dict.size 0 >) (entry dup `cursor at fs.next-entry) while pop
  `cursor del cursor port.close) `scan-directory defp

 ### defp installed-files
 (directory -- paths : "Enumerate all installed regular files and reject unexpected object kinds.")
 ({files [] pending ["."] count 0} swap `directory swap put
  (dup `pending at empty? not) (directory) while `files at) `installed-files defp

 ### def package
 (bytes directory -- bundle : "Verify an installed package against its exact sealed source bytes.")
 (|bytes directory|
  bytes pkg.bundle.inspect
  bytes directory archived-files dup grade at directory installed-files dup grade at match? require)
 `package def

 ### defp selected
 (state name -- state : "Verify one selected archive, identity, and installed contents.")
 (|state name|
  state `lock at `packages at name at `hash at
  state name pair (selected-hash) cat apply) `selected defp

 ### defp selected-hash
 (hash state name -- state : "Use the kept archive copy, never the download cache.")
 (|hash state name|
  state `directory at ".ecl/archives/" hash pkg.cache.filename cat fs.read-bytes hash
  pkg.fetch.checked
  state `directory at ".ecl/packages/" name cat fs.child-dir
  (|bytes directory| bytes directory package directory port.close) apply
  `manifest at state `lock at swap pkg.resolution.check-manifest state) `selected-hash defp

 ### defp child
 (state entry -- state : "Require exactly the expected immediate child name and object kind.")
 (|state entry|
  state `expected at entry `name at has? require
  state `expected at entry `name at at entry `kind at match? require
  state `expected state `expected at entry `name at del put) `child defp

 ### defp children
 (directory path expected -- : "Reject missing, extra, linked, or special entries.")
 (|directory path expected|
  directory path fs.open-list
  (|cursor expected|
   {} `cursor cursor put `expected expected put cursor fs.next-entry
   (dup dict.size 0 >) (child dup `cursor at fs.next-entry) while pop
   `expected at dict.size 0 = require cursor port.close)
  expected swap cons apply) `children defp

 ### def installation
 (directory lock -- :
  "Require exactly the selected packages and archives, each installed as its archive holds it,
   without repair or network.")
 (|directory lock|
  directory ".ecl/packages" lock `packages at dict.keys (`directory pair) each dict.from-pairs
  children
  directory ".ecl/archives" lock `packages at dict.vals
  (`hash at pkg.cache.filename `file pair) each dict.from-pairs children
  lock `packages at dict.keys dup grade at
  {} `lock lock put `directory directory put (selected) fold pop) `installation def
) `pkg.verify @defm
