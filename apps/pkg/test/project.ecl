### module pkg.test.project
[]
(
 ### defp equal
 (actual expected -- : "Assert application project discovery behavior.")
 (match? {'kind 'user 'msg "project discovery assertion failed"} assert) 'equal defp

 ### test discovers-nearest-manifest
 (-- : "Find the nearest manifest without reading corrupt lockfiles or maps.")
 ("apps/pkg/test/fixtures/project/nested" pkg.project.find-at
  dup pkg.project.manifest 'name at "fixture" equal
  dup 'path at host.cwd "apps/pkg/test/fixtures/project" pair path.join equal
  'directory at port.close)
 'discovers-nearest-manifest test

 ### test local-paths
 (-- : "Resolve application paths against the captured cwd rather than environment spelling.")
 ("." pkg.project.absolute host.cwd equal
  "/one/two/../three" pkg.project.absolute "/one/three" equal)
 'local-paths test
) 'pkg.test.project @defm
