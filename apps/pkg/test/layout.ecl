### module pkg.test.layout
[]
(
 ### defp equal
 (actual expected -- : "Compare closed application generation locations.")
 (match? {'kind 'user 'msg "generation layout assertion failed"} assert) 'equal defp

 ### setp identifier
 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
 'identifier setp

 ### test generation-locations
 (-- : "Project and vendor references are portable and confined to their closed namespaces.")
 (identifier pkg.layout.project-generation dup pkg.layout.generation? 1 equal
  dup pkg.layout.local-root "../../.." equal
  dup pkg.layout.reference pkg.layout.from-reference equal
  identifier pkg.layout.vendor-generation dup pkg.layout.generation? 1 equal
  dup pkg.layout.local-root "../.." equal
  dup pkg.layout.reference pkg.layout.from-reference equal
  [".ecl/generations/../escape" "vendor/../../outside" "/absolute" "vendor/short" "bare"]
  (pkg.layout.generation? 0 equal) for)
 'generation-locations test
) 'pkg.test.layout @defm
