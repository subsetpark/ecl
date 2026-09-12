### module pkg.test.map
[]
(
 ### defp equal
 (actual expected -- : "Compare public runtime-map data.")
 (match? {'kind 'user 'msg "package map assertion failed"} assert) 'equal defp

 ### setp manifest
 {'format 2 'name "project" 'version "0.1.0" 'sources ["src/**/*.ecl"] 'exports [] 'requires {}}
 'manifest setp

 ### setp graph
 {'packages {"alpha" {} "beta" {}}
  'requires {"project" {"a" {'package "alpha"}} "alpha" {"b" {'package "beta"}} "beta" {}}}
 'graph setp

 ### setp bundles
 {"alpha" {'artifacts [{'kind 'ecl 'path "src/a.ecl" 'exports ["alpha.api"]}]}
  "beta" {'artifacts [{'kind 'ecl 'path "src/b.ecl" 'exports ["beta.api"]}]}}
 'bundles setp

 ### test direct-visibility
 (-- : "Keep live local source patterns and only direct dependency edges in the runtime map.")
 (manifest graph bundles "../../.." pkg.map.build
  dup 'format at 1 equal
  dup 'local at "project" equal
  'scopes at
  dup "project" at
  {'root "../../.." 'visible ["alpha"] 'sources ["src/**/*.ecl"] 'artifacts []} equal
  dup "alpha" at
  {'root "packages/alpha" 'visible ["beta"] 'sources []
   'artifacts [{'kind 'ecl 'path "src/a.ecl" 'exports ["alpha.api"]}]} equal
  "beta" at 'visible at [] equal)
 'direct-visibility test

 ### test validates-before-publication
 (-- : "Validate from stdin against a future generation path without publishing it.")
 (manifest graph bundles "../../.." pkg.map.build
  host.cwd "apps/pkg/test/fixtures/project/.ecl/generations/unpublished/ecl.modules" pair path.join
  pkg.map.validate
  'cwd "apps/pkg/test/fixtures/project/.ecl" fs.exists? 0 equal)
 'validates-before-publication test
) 'pkg.test.map @defm
