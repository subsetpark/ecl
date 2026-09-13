### module pkg.resolution
# Portable project locks. Generations retain these same resolution bytes.
[]
(
 ### defp require
 (condition -- : "Reject inconsistent portable resolution data.")
 ('domain error.new "invalid portable package lock" error.with-message assert) 'require defp

 ### defp dict?
 (value -- bool : "Recognize a dictionary.")
 (type 'dict match?) 'dict? defp

 ### def minimums
 (requirements -- edges : "Project exact manifest requirements into dependency edges.")
 (dict.pairs (|entry| entry first entry 1 at ['package 'version] dict.take pair) each
  dict.from-pairs) 'minimums def

 ### defp check-selection
 (selection -- : "Validate one exact resolved source, version, and archive hash.")
 (|selection|
  selection dict? require
  selection ['version 'source 'hash] dict.keys-exactly? require
  selection 'version at pkg.version.validate pop
  selection 'source at pkg.manifest.validate-source pop
  selection 'hash at pkg.name.hash? require) 'check-selection defp

 ### defp check-edge
 (edge selections -- : "Require a known selection meeting an exact recorded minimum.")
 (|edge selections|
  edge dict? require
  edge ['package 'version] dict.keys-exactly? require
  edge 'package at pkg.name.valid? require
  edge 'version at pkg.version.validate pop
  selections edge 'package at dict.has? require
  selections edge 'package at 'version pair at-path
  edge 'version at pkg.version.less? not require) 'check-edge defp

 ### defp check-edges
 (edges selections -- : "Validate one consumer's direct dependency edges.")
 (|edges selections|
  edges dict? require
  edges dict.keys (pkg.name.valid?) all? require
  edges dict.vals ('package at) each dup distinct len swap len = require
  edges dict.vals selections (check-edge) partial for) 'check-edges defp

 ### defp visit-edge
 (state child -- state : "Visit a selected dependency with the current ancestor path.")
 (|state child|
  state 'lock at child state 'path at state 'seen at visit
  state swap 'seen swap put) 'visit-edge defp

 ### defp descend
 (lock name path seen -- seen : "Traverse a previously unseen package and reject cycles.")
 (|lock name path seen|
  {} 'lock lock put 'path path name append put 'seen seen name append put
  lock 'requires at name at dict.vals ('package at) each
  swap (visit-edge) fold 'seen at) 'descend defp

 ### defp visit
 (lock name path seen -- seen : "Check acyclic reachability without fetching any sources.")
 (|lock name path seen|
  path name (match?) partial any? not require
  seen name (match?) partial any?
  seen () partial
  lock name path seen 4 pack (descend) with
  if) 'visit defp

 ### defp root-manifest
 (lock -- manifest : "Validate the exact root requirements retained as the lock's input.")
 (|lock|
  {'format 2 'version "0.0.0" 'sources [] 'exports []}
  'name lock 'root at put 'requires lock 'root-requires at put pkg.manifest.validate)
 'root-manifest defp

 ### def validate
 (candidate -- lock : "Validate the complete portable graph without network or installation state.")
 (|lock|
  lock dict? require
  lock dict.pairs (pkg.data.assert-inert-entry) for
  lock ['format 'root 'root-requires 'packages 'requires] dict.keys-exactly? require
  lock 'format at 3 match? require
  lock root-manifest pop
  lock 'packages at dict? require
  lock 'packages at dict.keys (pkg.name.valid?) all? require
  lock 'packages at dict.vals (check-selection) for
  lock 'root at wrap lock 'packages at dict.keys cat
  dup pkg.name.collides? not require
  sort lock 'requires at dict.keys sort match? require
  lock 'requires at dict.vals lock 'packages at (check-edges) partial for
  lock 'root-requires at minimums lock 'requires at lock 'root at at match? require
  lock lock 'root at [] [] visit len lock 'packages at dict.size 1 + = require
  lock root-manifest lock swap check-manifest
  lock) 'validate def

 ### defp check-pin
 (requirement lock -- : "An exact selected minimum retains its declared source and archive hash.")
 (|requirement lock|
  lock 'packages at requirement 'package at at
  requirement 'package del
  (|selection declared|
   selection 'version at declared 'version at match?
   selection declared pair (match? require) with when)
  call) 'check-pin defp

 ### def check-manifest
 (lock manifest -- : "Check a manifest against a validated lock's identity, edges, and exact pins.")
 (|lock manifest|
  manifest pkg.manifest.validate pop
  lock manifest lock 'root at manifest 'name at match?
  (pop pop) (check-identity) if
  manifest 'requires at minimums lock 'requires at manifest 'name at at match? require
  manifest 'requires at dict.vals lock (check-pin) partial for) 'check-manifest def

 ### defp check-identity
 (lock manifest -- : "A selected artifact must declare its exact locked package version.")
 (|lock manifest|
  lock 'packages at manifest 'name at 'version pair at-path
  manifest 'version at match? require) 'check-identity defp

 ### def compatible
 (lock manifest -- lock :
  "Honor an existing lock only when its root dependency inputs still match.")
 (|lock manifest|
  lock validate pop manifest pkg.manifest.validate pop
  lock 'root at manifest 'name at match?
  lock 'root-requires at manifest 'requires at match? and
  'domain error.new "ecl.lock does not match ecl.pkg; dependency updates require pkg update"
  error.with-message assert
  lock) 'compatible def

 ### def read
 (text -- lock : "Read exactly one inert portable project lock.")
 (pkg.data.read-one validate) 'read def

 ### defp canonical-entry
 (key holder -- pair : "Canonicalize one nested dictionary entry.")
 (|key holder| key holder key at canonical pair) 'canonical-entry defp

 ### defp canonical
 (value -- value : "Sort all metadata dictionary keys while preserving list order.")
 (dup dict?
  (|holder| holder dict.keys dup (str) each grade at
   holder (canonical-entry) partial each dict.from-pairs)
  (dup type 'list match? ((canonical) each) () if)
  if) 'canonical defp

 ### def write
 (lock -- text : "Write deterministic portable resolution data ending in a newline.")
 (validate canonical str "\n" cat) 'write def
) 'pkg.resolution @defm
