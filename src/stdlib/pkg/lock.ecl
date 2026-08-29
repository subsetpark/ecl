### module pkg.lock
# Validate, read, and canonically render package locks.
(
 ### defp lock-keys
 # Required cache-lock keys.
 ['format 'root 'packages 'requires]
 'lock-keys setp

 ### defp vendor-lock-keys
 # Required project-vendor lock keys.
 ['format 'root 'store 'packages 'requires]
 'vendor-lock-keys setp

 ### defp minimums-checked
 (minimums -- minimums : "Validate and return one package's minimum-version requirements.")
 (|minimums|
  minimums type 'dict match?
  'type error.new "a lock's requirements are a dict from package name to version" error.with-message
  assert
  minimums dict.keys (pkg.name.valid?) all?
  'domain error.new "a package name is dot-joined lowercase segments" error.with-message assert
  minimums dict.vals (pkg.version.validate pop) for
  minimums)
 'minimums-checked defp

 ### defp known?
 (pair packages -- bool : "Test whether a required package has a locked selection.")
 (|pair packages| packages pair first dict.has?)
 'known? defp

 ### defp satisfied?
 (entry packages -- bool : "Test whether a locked version meets a minimum version.")
 (|entry packages|
  packages entry first 'version pair at-path entry 1 at pkg.version.less? not)
 'satisfied? defp

 ### def validate
 (candidate -- lock :
  "Validate and return a lock. Each required package must have a selection that meets every recorded
   minimum version.")
 (|candidate|
  candidate type 'dict match?
  'type error.new "a lock is a dict" error.with-message assert
  candidate dict.pairs (pkg.data.assert-inert-entry) for
  candidate lock-keys dict.keys-exactly?
  candidate vendor-lock-keys dict.keys-exactly?
  or
  'domain error.new "a lock has exactly the keys 'format 'root 'packages 'requires, or adds 'store"
  error.with-message
  assert
  candidate 'format at 1 match?
  'domain error.new "the only lock format is 1" error.with-message assert
  candidate 'root at pkg.name.valid?
  'domain error.new "a package name is dot-joined lowercase segments" error.with-message assert
  candidate
  candidate 'store dict.has?
  ('store at 'vendor match?
   'domain error.new "a lock's only project-local store mode is 'vendor" error.with-message assert)
  (pop)
  if
  candidate 'packages at type 'dict match?
  'type error.new "a lock's packages are a dict from package name to selection" error.with-message
  assert
  candidate 'packages at dict.keys (pkg.name.valid?) all?
  'domain error.new "a package name is dot-joined lowercase segments" error.with-message assert
  candidate 'packages at dict.vals (pkg.manifest.validate-requirement pop) for
  candidate 'requires at type 'dict match?
  'type error.new "a lock's requirements are keyed by the requiring package" error.with-message
  assert
  candidate 'requires at dict.keys (pkg.name.valid?) all?
  'domain error.new "a package name is dot-joined lowercase segments" error.with-message assert
  candidate 'requires at dict.vals (minimums-checked pop) for
  candidate 'requires at candidate 'root at dict.has?
  'domain error.new "a lock records the root's own requirements under its name" error.with-message
  assert
  candidate 'requires at dict.vals (dict.pairs) each raze
  dup candidate 'packages at (known?) partial all?
  'domain error.new "every required package has a selection in the lock" error.with-message assert
  candidate 'packages at (satisfied?) partial all?
  'domain error.new "a selected version is never below a minimum recorded for it" error.with-message
  assert
  candidate)
 'validate def

 ### def read
 (text -- lock : "Parse and validate a lock without evaluating it.")
 (pkg.data.read-one pkg.lock.validate)
 'read def

 ### def vendor
 (lock -- lock : "Return a validated lock selecting the fixed project-local vendor store.")
 (pkg.lock.validate 'store 'vendor put pkg.lock.validate)
 'vendor def

 ### defp render-requirement
 (requirement -- text : "Render one selection in the canonical field order.")
 (('version at) ('url at) ('hash at) tri
  3 pack (str) each
  "{{'version {} 'url {} 'hash {}}}" str.format)
 'render-requirement defp

 ### defp render-selection
 (pair -- text : "Render one `packages` entry.")
 ((first str) (1 at render-requirement) bi
  2 pack "{} {}" str.format)
 'render-selection defp

 ### defp render-minimum
 (pair -- text : "Render one package name and minimum version.")
 ((str) each "{} {}" str.format)
 'render-minimum defp

 ### defp render-minimums
 (minimums -- text : "Render one package's minimum versions on a single line.")
 (pkg.data.sorted-entries (render-minimum) each " " join
  wrap "{{{}}}" str.format)
 'render-minimums defp

 ### defp render-requirer
 (pair -- text : "Render one `requires` entry.")
 ((first str) (1 at render-minimums) bi
  2 pack "{} {}" str.format)
 'render-requirer defp

 ### defp render-block
 (holder renderer -- text : "Render a dict as an indented block.")
 (|holder renderer|
  holder pkg.data.sorted-entries renderer each "\n  " join
  wrap "{{{}}}" str.format)
 'render-block defp

 ### def write
 (lock -- text :
  "Validate a lock and render canonical text. Keys are sorted and the output ends with a newline.")
 (pkg.lock.validate render-validated)
 'write def

 ### defp render-validated
 (lock -- text : "Render an already validated lock in canonical layout.")
 (|lock|
  lock 'root at str
  lock 'store dict.has? ("\n 'store 'vendor") ("") if
  lock 'packages at (render-selection) render-block
  lock 'requires at (render-requirer) render-block
  4 pack
  "{{'format 1\n 'root {}{}\n 'packages\n {}\n 'requires\n {}}}\n" str.format)
 'render-validated defp

 ### defp append-tree-line
 (line state -- state : "Append one rendered tree line to the edge accumulator.")
 (|line state| state 'lines state 'lines at line append put)
 'append-tree-line defp

 ### defp tree-edge
 (state entry -- state : "Append one deterministic selected dependency edge.")
 (|state entry|
  state entry pair
  (|state entry|
   state 'requirer at
   entry first
   state 'lock at 'packages at entry first 'version pair at-path)
  infra
  "{} -> {} {}" str.format
  state append-tree-line)
 'tree-edge defp

 ### defp tree-requirer
 (state pair -- state : "Append every edge for one requiring package.")
 (|state pair|
  state 'requirer pair first put
  pair 1 at pkg.data.sorted-entries
  swap (tree-edge) fold
 )
 'tree-requirer defp

 ### def tree
 (lock -- text :
  "Render the root and canonical dependency edges, ordered by requirer then requirement.")
 (pkg.lock.validate
  (|lock|
   lock wrap
   (|lock| 'lock lock 'lines [])
   infra
   dict.from-flat
   lock 'requires at pkg.data.sorted-entries
   swap (tree-requirer) fold
   'lines at
   lock 'root at swap cons
   "\n" join "\n" cat)
  call)
 'tree def

 ### defp path-has?
 (path package -- bool : "Return 1 when a path already contains a package.")
 ((match?) partial any?)
 'path-has? defp

 ### defp path-child
 (child state -- state : "Collect paths through one not-yet-visited child.")
 (|child state|
  state 'lock at
  state 'target at
  state 'path at
  child
  paths-from
  state
  (|paths state| state 'results state 'results at paths cat put)
  call)
 'path-child defp

 ### defp path-edge
 (state entry -- state : "Skip a visited child or collect its paths.")
 (|state entry|
  entry first
  state
  state 'path at entry first path-has?
  (swap pop)
  (path-child)
  if)
 'path-edge defp

 ### defp expand-path
 (path context -- paths : "Expand one path from its packed lock, target, and current node.")
 (|path context|
  path context cons
  (|path lock target current|
   lock target path 3 pack
   (|lock target path| 'lock lock 'target target 'path path 'results [])
   infra
   dict.from-flat
   lock 'requires at current {} at-or pkg.data.sorted-entries
   swap (path-edge) fold
   'results at)
  with call)
 'expand-path defp

 ### defp paths-from
 (lock target path current -- paths : "Collect deterministic acyclic paths to one package.")
 (|lock target path current|
  path current append
  lock target current 3 pack
  current target match?
  (pop wrap)
  (expand-path)
  if)
 'paths-from defp

 ### defp path-node
 (name lock -- text : "Render a root path node with its selected version when applicable.")
 (|name lock|
  name " " cat lock 'packages at name {} at-or 'version "" at-or cat
  name pair
  name lock 'root at match? at)
 'path-node defp

 ### defp append-path-text
 (text state -- state : "Append one rendered node to the path accumulator.")
 (|text state| state 'nodes state 'nodes at text append put)
 'append-path-text defp

 ### defp render-path-node
 (state name -- state : "Append one rendered package to a dependency path.")
 (|state name|
  name state 'lock at path-node
  state append-path-text)
 'render-path-node defp

 ### defp render-path
 (path lock -- text : "Render one dependency path with selected versions.")
 (|path lock|
  lock wrap
  (|lock| 'lock lock 'nodes [])
  infra
  dict.from-flat
  path swap (render-path-node) fold
  'nodes at
  " -> " join)
 'render-path defp

 ### defp longer-owner
 (left right -- owner : "Return the longer of two candidate package-prefix owners.")
 (|left right|
  left len right len <
  right () partial
  left () partial
  if)
 'longer-owner defp

 ### def why
 (lock module -- text : "Render one deterministic root-to-owner explanation for a module name.")
 (|lock module|
  lock pkg.lock.validate pop
  module pkg.name.valid?
  'domain error.new "pkg why expects a canonical module name" error.with-message assert
  lock 'packages at dict.keys module (pkg.name.owns?) partial filter
  dup empty? not
  'domain error.new "no locked package owns the requested module" error.with-message
  'data 'module module pair dict.from-flat put
  assert
  "" (longer-owner) fold
  lock swap [] lock 'root at paths-from
  dup empty? not
  'domain error.new "the locked package is not reachable from the project root" error.with-message
  assert
  first
  lock render-path
  module ": " cat swap cat "\n" cat)
 'why def
) 'pkg.lock @defm
