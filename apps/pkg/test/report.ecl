### module pkg.test.report
[]
(
 ### defp equal
 (actual expected -- : "Compare user-visible dependency reports with explicit expected text.")
 (match? {'kind 'user 'msg "package report assertion failed"} assert) 'equal defp

 ### defp selection
 (-- selection : "Supply an inert exact source identity for report fixtures.")
 ({'version "1.0.0" 'source {'kind 'archive 'url "https://fixture.invalid/source.tgz"}
   'hash "sha256-0000000000000000000000000000000000000000000000000000000000000000"}) 'selection defp

 ### defp lock
 (-- lock : "Author a diamond graph with two possible paths to the same selected dependency.")
 ({'format 3 'root "demo" 'requires
   {"demo" {"alpha" {'package "alpha" 'version "1.0.0"} "bravo" {'package "bravo" 'version "1.0.0"}}
    "alpha" {"charlie" {'package "charlie" 'version "1.0.0"}}
    "bravo" {"charlie" {'package "charlie" 'version "1.0.0"}} "charlie" {}}}
  'packages {} "alpha" selection put "bravo" selection put "charlie" selection put put
  'root-requires {} "alpha" selection 'package "alpha" put put
  "bravo" selection 'package "bravo" put put put) 'lock defp

 ### test canonical-reports
 (-- : "Render sorted direct edges and one canonical shortest path through a shared dependency.")
 (lock pkg.report.tree
  "demo\nalpha -> charlie 1.0.0\nbravo -> charlie 1.0.0\ndemo -> alpha 1.0.0\ndemo -> bravo 1.0.0\n"
  equal
  lock "charlie.api" pkg.report.why "charlie.api: demo -> alpha 1.0.0 -> charlie 1.0.0\n" equal
  lock "missing.api" pair (pkg.report.why) @attempt result.err? 1 equal) 'canonical-reports test
) 'pkg.test.report @defm
