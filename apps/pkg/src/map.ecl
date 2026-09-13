### module pkg.map
# Construct runtime metadata from an application-owned resolved graph.
[]
(
 ### defp direct
 (lock name -- visible : "Project only a consumer's direct dependency visibility.")
 (|lock name| lock 'requires at name at dict.vals ('package at) each sort) 'direct defp

 ### defp dependency
 (name lock bundles -- scope : "Map the inspected ECL artifacts of one installed package.")
 (|name lock bundles|
  {'sources []} 'root "packages/" name cat put 'visible lock name direct put
  'artifacts bundles name at 'artifacts at put) 'dependency defp

 ### defp insert
 (state name -- state : "Append one deterministic dependency scope.")
 (|state name|
  state 'scopes state 'scopes at name
  name state 'lock at state 'bundles at dependency put put) 'insert defp

 ### def build
 (manifest lock bundles local-root -- map :
  "Build an inert map with live local sources and explicit dependencies.")
 (|manifest lock bundles local-root|
  lock 'packages at dict.keys sort
  {} 'lock lock put 'bundles bundles put 'scopes {} put (insert) fold 'scopes at
  manifest 'name at
  {'artifacts []} 'root local-root put 'visible lock manifest 'name at direct put
  'sources manifest 'sources at put put
  {'format 1} 'local manifest 'name at put swap 'scopes swap put) 'build def

 ### def validate
 (map document -- : "Validate a candidate at its final location before publishing any directory.")
 (|map document|
  {} 'executable host.executable put
  'args "check-map" "--document" document "-" 4 pack put
  'stdin map str bytes put 'timeout-ms 30000 put 'stdout-limit 4096 put 'stderr-limit 65536 put
  proc.run
  dup 'term at {'kind 'exited 'code 0} match?
  swap 'stderr at chars 'io error.new swap error.with-message assert) 'validate def
) 'pkg.map @defm
