### module pkg.test.fetch
[]
(
 ### defp equal
 (actual expected -- : "Compare public application fetch results.")
 (match? {'kind 'user 'msg "application fetch assertion failed"} assert) 'equal defp

 ### defp pin
 (snapshot -- requirement : "Build an exact source pin from an observed snapshot.")
 (|snapshot|
  {'package "unused" 'version "1.0.0"}
  'source {'kind 'git} 'url args first put 'commit snapshot first put put
  'hash snapshot 1 at pkg.fetch.hash put) 'pin defp

 ### defp check-snapshot
 (snapshot -- : "Fetch the pinned commit again and reject a mismatched archive hash.")
 (|snapshot|
  snapshot first args 1 at equal
  snapshot pin pkg.fetch.requirement snapshot 1 at equal
  snapshot pin 'hash "sha256-0000000000000000000000000000000000000000000000000000000000000000" put
  wrap (pkg.fetch.requirement) @attempt 'err at 'kind at 'domain equal
  snapshot 1 at wrap (pkg.bundle.inspect) @attempt result.err? 1 equal) 'check-snapshot defp

 ### test exact-fetch
 (-- : "Use a tag only for explicit selection, then fetch and hash-check the pinned commit.")
 (args first 'tag "release" pkg.fetch.git check-snapshot)
 'exact-fetch test

 ### def run
 (-- : "Require the acceptance registration and invoke the standard ECL test runner.")
 (tests len 1 = {'kind 'user 'msg "fetch acceptance test was not registered"} assert
  test.default.run) 'run def
) 'pkg.test.fetch @defm
