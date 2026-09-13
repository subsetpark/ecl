### module pkg.test.solver
[]
(
 ### defp equal
 (actual expected -- : "Compare deterministic selected graphs against independent expectations.")
 (match? {'kind 'user 'msg "solver assertion failed"} assert) 'equal defp

 ### defp requirement
 (name version -- requirement : "Construct an exact inert fixture pin without network access.")
 (|name version|
  {'hash "sha256-0000000000000000000000000000000000000000000000000000000000000000"}
  'package name put 'version version put
  'source {'kind 'archive} 'url "https://fixture.invalid/" name cat "/" cat version cat put put)
 'requirement defp

 ### defp manifest
 (name version requirements -- manifest :
  "Build a source-free fixture manifest with explicit edges.")
 (|name version requirements|
  {'format 2 'sources [] 'exports []} 'name name put 'version version put 'requires requirements put)
 'manifest defp

 ### defp catalog
 (-- catalog : "A higher selected version removes a dependency of its superseded minimum.")
 ({} "alpha" {} "1.0.0" "alpha" "1.0.0" {} "charlie" "charlie" "1.0.0" requirement put manifest put
  "2.0.0" "alpha" "2.0.0" {} manifest put put
  "bravo" {} "1.0.0" "bravo" "1.0.0" {} "alpha" "alpha" "2.0.0" requirement put manifest put put
  "charlie" {} "1.0.0" "charlie" "1.0.0" {} manifest put put) 'catalog defp

 ### test selected-reachability
 (-- : "A superseded minimum does not retain an unreachable package in the portable lock.")
 ("project" "1.0.0" {} "alpha" "alpha" "1.0.0" requirement put
  "bravo" "bravo" "1.0.0" requirement put manifest
  catalog pkg.solver.resolve
  dup 'format at 3 equal
  dup 'packages at dict.keys sort ["alpha" "bravo"] equal
  dup 'packages at "alpha" at 'version at "2.0.0" equal
  dup 'requires at dict.keys sort ["alpha" "bravo" "project"] equal
  dup pkg.resolution.write pkg.resolution.read equal) 'selected-reachability test
) 'pkg.test.solver @defm
