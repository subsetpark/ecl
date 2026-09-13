### module pkg.test.resolution
[]
(
 ### defp equal
 (actual expected -- : "Compare observable resolution data.")
 (match? {'kind 'user 'msg "resolution assertion failed"} assert) 'equal defp

 ### defp rejected
 (quotation -- : "Require malformed or incompatible metadata to fail.")
 ([] swap @attempt result.err? 1 equal) 'rejected defp

 ### setp empty-lock
 {'format 3 'root "project" 'root-requires {} 'packages {} 'requires {"project" {}}}
 'empty-lock setp

 ### setp selection
 {'version "1.0.0" 'source {'kind 'archive 'url "https://example.com/foo.tgz"}
  'hash "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
 'selection setp

 ### defp requirement
 (-- requirement : "Build the declared exact source input.")
 (selection 'package "foo" put) 'requirement defp

 ### defp manifest
 (-- manifest : "Build the project manifest independently of its resolution.")
 ({'format 2 'name "project" 'version "0.1.0" 'sources ["src/**/*.ecl"] 'exports []}
  'requires {} "api" requirement put put) 'manifest defp

 ### defp locked
 (-- lock : "Build one complete portable lock with a consumer-local alias.")
 (empty-lock 'root-requires {} "api" requirement put put
  'packages {} "foo" selection put put
  'requires {"project" {"api" {'package "foo" 'version "1.0.0"}} "foo" {}} put)
 'locked defp

 ### test round-trip
 (-- : "Portable locks preserve exact pins and canonicalize all dictionary ordering.")
 (locked pkg.resolution.write pkg.resolution.read locked equal
  locked pkg.resolution.write "\n" str.ends? 1 equal
  locked 'packages at "foo" at 'source at 'url at "https://example.com/foo.tgz" equal
  empty-lock pkg.resolution.validate empty-lock equal
  locked 'root-requires locked 'root-requires at dict.pairs reverse dict.from-pairs put
  pkg.resolution.write locked pkg.resolution.write equal)
 'round-trip test

 ### test compatibility
 (-- : "Normal synchronization keeps the locked graph and refuses changed dependency inputs.")
 (locked manifest pkg.resolution.compatible locked equal
  locked manifest 'version "2.0.0" put pkg.resolution.compatible locked equal
  (locked manifest 'requires {} put pkg.resolution.compatible) rejected
  (locked manifest 'name "another" put pkg.resolution.compatible) rejected
  (locked manifest 'requires {} "api" requirement 'source
   {'kind 'git 'url "https://example.com/repo.git" 'commit
    "0123456789abcdef0123456789abcdef01234567"}
   put put put pkg.resolution.compatible) rejected)
 'compatibility test

 ### test exact-source-pins
 (-- : "Exact minima retain source identities, full Git commits, and archive hashes.")
 (locked 'packages {} "foo" selection 'source
  {'kind 'git 'url "https://example.com/repo.git"
   'commit "0123456789abcdef0123456789abcdef01234567"} put put put
  (|git-lock| git-lock 'root-requires
   {} "api" git-lock 'packages at "foo" at 'package "foo" put put put)
  call dup pkg.resolution.write pkg.resolution.read equal
  (locked 'packages {} "foo" selection 'source
   {'kind 'archive 'url "https://example.com/different.tgz"} put put put
   pkg.resolution.validate) rejected
  (locked 'packages {} "foo" selection
   'hash "sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
   put put put pkg.resolution.validate) rejected)
 'exact-source-pins test

 ### test selected-manifest
 (-- : "A higher locked selection is allowed, but its own dependency edges must match.")
 (locked 'packages {} "foo" selection 'version "1.1.0" put put put
  dup manifest pkg.resolution.compatible equal
  locked {'format 2 'name "foo" 'version "1.0.0" 'sources [] 'exports [] 'requires {}}
  pkg.resolution.check-manifest
  (locked {'format 2 'name "foo" 'version "9.0.0" 'sources [] 'exports [] 'requires {}}
   pkg.resolution.check-manifest) rejected
  (locked manifest 'requires {} put pkg.resolution.check-manifest) rejected)
 'selected-manifest test

 ### test graph-validation
 (-- : "Reject missing, extra, cyclic, unreachable, or unsatisfied resolution edges.")
 ((locked 'requires {"project" {"api" {'package "foo" 'version "1.0.0"}}} put
   pkg.resolution.validate) rejected
  (locked 'requires {"project" {} "foo" {}} put pkg.resolution.validate) rejected
  (locked 'packages {} put pkg.resolution.validate) rejected
  (empty-lock 'packages {} "foo" selection put put 'requires {"project" {} "foo" {}} put
   pkg.resolution.validate) rejected
  (locked 'requires
   {"project" {"api" {'package "foo" 'version "1.0.0"}}
    "foo" {"self" {'package "foo" 'version "1.0.0"}}} put pkg.resolution.validate) rejected
  (locked 'packages {} "foo" selection 'version "0.9.0" put put put
   pkg.resolution.validate) rejected)
 'graph-validation test

 ### test closed-portable-schema
 (-- : "Installation locations, generation identifiers, and unpinned sources cannot enter a lock.")
 ((locked 'store 'vendor put pkg.resolution.validate) rejected
  (locked 'generation "local" put pkg.resolution.validate) rejected
  (locked 'format 2 put pkg.resolution.validate) rejected
  (locked 'packages {} "foo" selection 'hash "sha256-bad" put put put
   pkg.resolution.validate) rejected
  (locked 'packages {} "foo" selection 'source
   {'kind 'git 'url "https://example.com/repo.git" 'commit "main"} put put put
   pkg.resolution.validate) rejected
  ("{'format 3 'root host.cwd}" pkg.resolution.read) rejected)
 'closed-portable-schema test
) 'pkg.test.resolution @defm
