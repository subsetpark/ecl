### module pkg.verify
# Read-only verification against each generation's own resolution snapshot.
[]
(
 ### defp require
 (condition -- : "Reject a modified or incomplete immutable generation.")
 ('domain error.new "package generation verification failed" error.with-message assert) 'require
 defp

 ### defp member
 (state metadata -- state : "Compare one regular installed file with its sealed source archive.")
 (|state metadata|
  metadata 'kind at 'file match?
  state metadata pair (file) with state () partial if) 'member defp

 ### defp file
 (state metadata -- state : "Require a regular file and compare its exact bytes.")
 (|state metadata|
  state 'directory at metadata 'path at fs.lstat
  dup 'kind at 'file match? require 'size at metadata 'size at match? require
  state 'directory at metadata 'path at fs.read-bytes
  state 'archive at 67108864 pkg.bundle.member-bytes match? require
  state 'files state 'files at metadata 'path at append put) 'file defp

 ### defp archived-files
 (bytes directory -- paths :
  "Check all archived files while reading member contents incrementally.")
 (|bytes directory|
  bytes archive.open-tgz
  (|archive directory|
   {'files []} 'archive archive put 'directory directory put
   archive archive.next-member
   (dup dict.size 0 >) (member dup 'archive at archive.next-member) while pop
   'files at archive port.close)
  directory swap partial call) 'archived-files defp

 ### defp entry
 (state entry -- state : "Reject links and special objects while enumerating the installed tree.")
 (|state entry|
  entry 'kind at 'file match? entry 'kind at 'directory match? or require
  state 'count at 100000 < require
  state 'count state 'count at 1 + put
  state 'current at entry 'name at pair path.join path.normalize
  entry 'kind at 'file match? ('files) ('pending) if append-path) 'entry defp

 ### defp append-path
 (state path key -- state : "Append one discovered file or pending directory.")
 (|state path key| state key state key at path append put) 'append-path defp

 ### defp directory
 (state -- state : "Enumerate one directory through a joined incremental cursor.")
 (dup 'pending at first
  (|state path|
   state 'current path put 'pending state 'pending at 1 drop put
   state 'directory at path fs.open-list scan-directory) call) 'directory defp

 ### defp scan-directory
 (state cursor -- state : "Read each child without following links or retaining a bulk listing.")
 (|state cursor|
  state 'cursor cursor put cursor fs.next-entry
  (dup dict.size 0 >) (entry dup 'cursor at fs.next-entry) while pop
  'cursor del cursor port.close) 'scan-directory defp

 ### defp installed-files
 (directory -- paths : "Enumerate all installed regular files and reject unexpected object kinds.")
 ({'files [] 'pending ["."] 'count 0} swap 'directory swap put
  (dup 'pending at empty? not) (directory) while 'files at) 'installed-files defp

 ### def package
 (bytes directory -- bundle : "Verify an installed package against its exact sealed source bytes.")
 (|bytes directory|
  bytes pkg.bundle.inspect
  bytes directory archived-files sort directory installed-files sort match? require) 'package def

 ### defp selected
 (state name -- state :
  "Verify one selected seal, identity, contents, and exported artifact mapping.")
 (|state name|
  state 'lock at 'packages at name at 'hash at
  state name pair (selected-hash) with call) 'selected defp

 ### defp selected-hash
 (hash state name -- state :
  "Use the immutable generation's archive copy, never its download cache.")
 (|hash state name|
  state 'directory at "archives/" hash pkg.cache.filename cat fs.read-bytes hash pkg.fetch.checked
  state 'directory at "packages/" name cat fs.child-dir
  (|bytes directory| bytes directory package directory port.close) call
  state name pair (record-bundle) with call) 'selected-hash defp

 ### defp record-bundle
 (bundle state name -- state : "Require the locked manifest and retain only inspected metadata.")
 (|bundle state name|
  state 'lock at bundle 'manifest at pkg.resolution.check-manifest
  state 'bundles state 'bundles at name bundle put put) 'record-bundle defp

 ### def generation
 (project location -- :
  "Validate a complete generation without repair, network, or root-lock interpretation.")
 (|project location|
  location pkg.layout.generation? require
  project 'directory at location fs.child-dir
  project location pair (opened) with call) 'generation def

 ### defp opened
 (directory project location -- :
  "Validate snapshots and reconstruct the expected complete runtime map.")
 (|directory project location|
  directory "ecl.pkg" fs.read-text pkg.manifest.read
  directory "ecl.lock" fs.read-text pkg.resolution.read
  directory project location 3 pack (snapshots) with call
  directory port.close) 'opened defp

 ### defp child
 (state entry -- state : "Require exactly the expected immediate child name and object kind.")
 (|state entry|
  state 'expected at entry 'name at dict.has? require
  state 'expected at entry 'name at at entry 'kind at match? require
  state 'expected state 'expected at entry 'name at del put) 'child defp

 ### defp children
 (directory path expected -- :
  "Reject missing, extra, linked, or special generation control entries.")
 (|directory path expected|
  directory path fs.open-list
  (|cursor expected|
   {} 'cursor cursor put 'expected expected put cursor fs.next-entry
   (dup dict.size 0 >) (child dup 'cursor at fs.next-entry) while pop
   'expected at dict.size 0 = require cursor port.close)
  expected swap partial call) 'children defp

 ### defp layout
 (directory lock -- : "Require the closed immutable generation layout and every selected seal.")
 (|directory lock|
  directory "."
  {"ecl.pkg" 'file "ecl.lock" 'file "ecl.modules" 'file "packages" 'directory "archives" 'directory}
  children
  directory "packages" lock 'packages at dict.keys ('directory pair) each dict.from-pairs children
  directory "archives" lock 'packages at dict.vals
  ('hash at pkg.cache.filename 'file pair) each dict.from-pairs children) 'layout defp

 ### defp snapshots
 (manifest lock directory project location -- :
  "Verify dependencies and map against the generation's own inputs.")
 (|manifest lock directory project location|
  lock manifest pkg.resolution.compatible pop
  directory lock layout
  lock 'packages at dict.keys sort
  {'bundles {}} 'lock lock put 'directory directory put (selected) fold 'bundles at
  manifest lock location 3 pack (expected-map) with call
  dup directory "ecl.modules" fs.read-text pkg.data.read-one match? require
  project 'path at location "/ecl.modules" cat pair path.join pkg.map.validate) 'snapshots defp

 ### defp expected-map
 (bundles manifest lock location -- map :
  "Rebuild exactly the app-owned artifact and visibility metadata.")
 (|bundles manifest lock location|
  manifest lock bundles location pkg.layout.local-root pkg.map.build) 'expected-map defp

 ### def publication
 (directory location project-path -- :
  "Validate a candidate and require the root manifest it was built from.")
 (|directory location project-path|
  directory location "/ecl.pkg" cat fs.read-text directory "ecl.pkg" fs.read-text match? require
  {} 'directory directory put 'path project-path put location generation) 'publication def
) 'pkg.verify @defm
