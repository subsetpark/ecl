### module pkg.lock
# Validate, read, and canonically render package locks.
(
 ### defp lock-keys
 # Required lock keys.
 ['format 'root 'packages 'requires]
 'lock-keys setp

 ### defp minimums-checked
 (minimums -- minimums : "Validate and return one package's minimum-version requirements.")
 (|minimums|
  minimums type 'dict match?
  {'kind 'type 'msg "a lock's requirements are a dict from package name to version"} assert
  minimums keys (pkg.name.valid?) all?
  {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
  minimums vals (pkg.version.validate pop) for
  minimums)
 'minimums-checked defp

 ### defp known?
 (pair packages -- bool : "Test whether a required package has a locked selection.")
 (|pair packages| packages pair first has?)
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
 'validate def

 ### def read
 (text -- lock : "Parse and validate a lock without evaluating it.")
 (pkg.data.read-one pkg.lock.validate)
 'read def

 ### defp render-requirement
 (requirement -- text : "Render one selection in the canonical field order.")
 (('version at) ('url at) ('hash at) tri
  3 pack (str) each
  "{{'version {} 'url {} 'hash {}}}" format)
 'render-requirement defp

 ### defp render-selection
 (pair -- text : "Render one `packages` entry.")
 ((first str) (1 at render-requirement) bi
  2 pack "{} {}" format)
 'render-selection defp

 ### defp render-minimum
 (pair -- text : "Render one package name and minimum version.")
 ((str) each "{} {}" format)
 'render-minimum defp

 ### defp render-minimums
 (minimums -- text : "Render one package's minimum versions on a single line.")
 (pkg.data.sorted-entries (render-minimum) each " " join
  wrap "{{{}}}" format)
 'render-minimums defp

 ### defp render-requirer
 (pair -- text : "Render one `requires` entry.")
 ((first str) (1 at render-minimums) bi
  2 pack "{} {}" format)
 'render-requirer defp

 ### defp render-block
 (holder renderer -- text : "Render a dict as an indented block.")
 (|holder renderer|
  holder pkg.data.sorted-entries renderer each "\n  " join
  wrap "{{{}}}" format)
 'render-block defp

 ### def write
 (lock -- text :
  "Validate a lock and render canonical text. Keys are sorted and the output ends with a newline.")
 (pkg.lock.validate render-validated)
 'write def

 ### defp render-validated
 (lock -- text : "Render an already validated lock in canonical layout.")
 (wrap
  (('root at str)
   ('packages at (render-selection) render-block)
   ('requires at (render-requirer) render-block)
   tri)
  infra
  "{{'format 1\n 'root {}\n 'packages\n {}\n 'requires\n {}}}\n" format)
 'render-validated defp
 ) 'pkg.lock @defm
