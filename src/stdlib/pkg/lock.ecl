### module pkg.lock
# Validate, read, and canonically render package locks.
(
 ### defp lock-keys
 # Required lock keys.
 ['format 'root 'packages 'requires]
 'lock-keys setp

 ### defp minimums-checked
 (|minimums|
  minimums type 'dict match?
  {'kind 'type 'msg "a lock's requirements are a dict from package name to version"} assert
  minimums keys (pkg.name.valid?) all?
  {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
  minimums vals (pkg.version.validate pop) for
  minimums)
 (minimums -- minimums : "Validate and return one package's minimum-version requirements.")
 'minimums-checked defp

 ### defp known?
 (|pair packages| packages pair first has?)
 (pair packages -- bool : "Test whether a required package has a locked selection.")
 'known? defp

 ### defp satisfied?
 (|entry packages|
  packages entry first 'version pair at-path entry 1 at pkg.version.less? not)
 (entry packages -- bool : "Test whether a locked version meets a minimum version.")
 'satisfied? defp

 ### def validate
 (|candidate|
  candidate type 'dict match?
  {'kind 'type 'msg "a lock is a dict"} assert
  candidate pairs (pkg.data.assert-inert-entry) for
  candidate lock-keys keys-exactly?
  {'kind 'domain
   'msg "a lock has exactly the keys 'format 'root 'packages 'requires"}
  assert
  candidate 'format at 1 match?
  {'kind 'domain 'msg "the only lock format is 1"} assert
  candidate 'root at pkg.name.valid?
  {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
  candidate 'packages at type 'dict match?
  {'kind 'type 'msg "a lock's packages are a dict from package name to selection"} assert
  candidate 'packages at keys (pkg.name.valid?) all?
  {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
  candidate 'packages at vals (pkg.manifest.validate-requirement pop) for
  candidate 'requires at type 'dict match?
  {'kind 'type 'msg "a lock's requirements are keyed by the requiring package"} assert
  candidate 'requires at keys (pkg.name.valid?) all?
  {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
  candidate 'requires at vals (minimums-checked pop) for
  candidate 'requires at candidate 'root at has?
  {'kind 'domain 'msg "a lock records the root's own requirements under its name"} assert
  candidate 'requires at vals (pairs) each raze
  dup candidate 'packages at (known?) partial all?
  {'kind 'domain 'msg "every required package has a selection in the lock"} assert
  candidate 'packages at (satisfied?) partial all?
  {'kind 'domain 'msg "a selected version is never below a minimum recorded for it"} assert
  candidate)
 (candidate -- lock :
  "Validate and return a lock. Each required package must have a selection that meets every recorded
   minimum version.")
 'validate def

 ### def read
 (pkg.data.read-one pkg.lock.validate)
 (text -- lock : "Parse and validate a lock without evaluating it.")
 'read def

 ### defp render-requirement
 (|requirement|
  requirement 'version at
  requirement 'url at
  requirement 'hash at
  3 pack "{{'version {} 'url {} 'hash {}}}" format)
 (requirement -- text : "Render one selection in the canonical field order.")
 'render-requirement defp

 ### defp render-selection
 (|pair| pair first str " " pair 1 at render-requirement 3 pack raze)
 (pair -- text : "Render one `packages` entry.")
 'render-selection defp

 ### defp render-minimum
 (|pair| pair first pair 1 at 2 pack "{} {}" format)
 (pair -- text : "Render one package name and minimum version.")
 'render-minimum defp

 ### defp render-minimums
 (|minimums| "{" minimums pkg.data.sorted-entries (render-minimum) each " " join "}" 3 pack raze)
 (minimums -- text : "Render one package's minimum versions on a single line.")
 'render-minimums defp

 ### defp render-requirer
 (|pair| pair first str " " pair 1 at render-minimums 3 pack raze)
 (pair -- text : "Render one `requires` entry.")
 'render-requirer defp

 ### defp render-block
 (|holder renderer| "{" holder pkg.data.sorted-entries renderer each "\n  " join "}" 3 pack raze)
 (holder renderer -- text : "Render a dict as an indented block.")
 'render-block defp

 ### def write
 (pkg.lock.validate render-validated)
 (lock -- text :
  "Validate a lock and render canonical text. Keys are sorted and the output ends with a newline.")
 'write def

 ### defp render-validated
 (|lock|
  "{'format 1\n 'root "
  lock 'root at str
  "\n 'packages\n "
  lock 'packages at (render-selection) render-block
  "\n 'requires\n "
  lock 'requires at (render-requirer) render-block
  "}\n"
  7 pack raze)
 (lock -- text : "Render an already validated lock in canonical layout.")
 'render-validated defp
 )
'pkg.lock
@defm
