### module stdlib.test.pkg-mvs
[]
(
 'stdlib.test.support
 ('equal 'raises-containing 'raises-data 'documented)
 import

 ### defp requirement
 (package version url hash -- requirement : "Construct requirement fixture data.")
 (|package version url hash|
  {} 'package package put 'version version put 'url url put 'hash hash put)
 'requirement defp

 ### defp manifest
 (name version requires -- manifest : "Construct manifest fixture data.")
 (|name version requires|
  {} 'format 1 put
  'name name put
  'version version put
  'exports {} name ["**/*"] put put
  'requires requires put)
 'manifest defp

 ### defp hash-a
 (-- hash : "Return the first valid fixture hash.")
 ("sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
 'hash-a defp

 ### defp hash-b
 (-- hash : "Return the second valid fixture hash.")
 ("sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
 'hash-b defp

 ### defp req-b
 (-- requirement : "Require b 1.0.0.")
 ("b" "1.0.0" "https://e.com/b.tgz" hash-a requirement)
 'req-b defp

 ### defp req-c-12
 (-- requirement : "Require c 1.2.0.")
 ("c" "1.2.0" "https://e.com/c12.tgz" hash-a requirement)
 'req-c-12 defp

 ### defp req-c-15
 (-- requirement : "Require c 1.5.0.")
 ("c" "1.5.0" "https://e.com/c15.tgz" hash-b requirement)
 'req-c-15 defp

 ### defp manifest-b
 (-- manifest : "Return b's transitive fixture manifest.")
 ("b" "1.0.0" {} "c" req-c-15 put manifest)
 'manifest-b defp

 ### defp manifest-c-12
 (-- manifest : "Return c 1.2.0's fixture manifest.")
 ("c" "1.2.0" {} manifest)
 'manifest-c-12 defp

 ### defp manifest-c-15
 (-- manifest : "Return c 1.5.0's fixture manifest.")
 ("c" "1.5.0" {} manifest)
 'manifest-c-15 defp

 ### defp root
 (-- manifest : "Return the root MVS fixture.")
 ("app" "0.1.0" {} "b" req-b put "c" req-c-12 put manifest)
 'root defp

 ### defp root-without-c
 (-- manifest : "Return the root fixture without its direct c requirement.")
 ("app" "0.1.0" {} "b" req-b put manifest)
 'root-without-c defp

 ### defp catalog
 (-- catalog : "Return the reachable MVS fixture catalog.")
 ({}
  "b" {} "1.0.0" manifest-b put put
  "c" {} "1.2.0" manifest-c-12 put "1.5.0" manifest-c-15 put put)
 'catalog defp

 ### test resolution
 (-- : "Select every reachable maximum and record all declared minimums.")
 (root catalog pkg.mvs.resolve
  dup 'packages at dup dict.size 2 equal
  ["c" 'version] at-path "1.5.0" equal
  root catalog pkg.mvs.resolve
  dup 'requires at dict.vals (dict.pairs) each raze
  swap 'packages at
  (|entry packages|
   packages entry 1 at 'package at 'version pair at-path
   entry 1 at 'version at pkg.version.less? not)
  partial
  all?
  1 equal)
 'resolution test

 ### test deterministic-input-order
 (-- : "Ignore graph insertion order and unreachable catalog versions.")
 (root catalog pkg.mvs.resolve pkg.lock.write
  "app" "0.1.0" {} "c" req-c-12 put "b" req-b put manifest
  {}
  "c"
  {}
  "9.0.0" "c" "9.0.0" {} manifest put
  "1.5.0" manifest-c-15 put
  "1.2.0" manifest-c-12 put
  put
  "b" {} "1.0.0" manifest-b put put
  pkg.mvs.resolve pkg.lock.write
  match?
  1 equal
  root-without-c catalog pkg.mvs.resolve 'packages at
  root catalog pkg.mvs.resolve
  (|packages lock|
   packages lock 'packages at match? 1 equal
   lock ['requires "app" "c"] at-path
   {'package "c" 'version "1.2.0"} equal)
  call)
 'deterministic-input-order test

 ### test conflicts
 (-- : "Report hash, prefix, and cycle conflicts with responsible packages.")
 (("app" "0.1.0"
   {}
   "b" req-b put
   "c" "c" "1.5.0" "https://mirror.example/c.tgz" hash-a requirement put
   manifest
   catalog
   pkg.mvs.resolve)
  'domain
  "conflicting hashes"
  raises-containing
  ("app" "0.1.0"
   {}
   "a" "a" "1.0.0" "https://e.com/a.tgz" hash-a requirement put
   "b" "b" "1.0.0" "https://e.com/b.tgz" hash-b requirement put
   manifest
   {}
   "a"
   {} "1.0.0"
   "a" "1.0.0"
   {} "foo" "foo" "1.0.0" "https://e.com/foo.tgz" hash-a requirement put
   manifest
   put put
   "b"
   {} "1.0.0"
   "b" "1.0.0"
   {} "foo.bar"
   "foo.bar" "1.0.0" "https://e.com/foo-bar.tgz" hash-b requirement put
   manifest
   put put
   "foo" {} "1.0.0" "foo" "1.0.0" {} manifest put put
   "foo.bar" {} "1.0.0" "foo.bar" "1.0.0" {} manifest put put
   pkg.mvs.resolve)
  'domain
  "overlapping prefixes"
  raises-containing
  "app" "0.1.0"
  {} "a" "a" "1.0.0" "https://e.com/a.tgz" hash-a requirement put
  manifest
  {}
  "a" {} "1.0.0"
  "a" "1.0.0"
  {} "b" "b" "1.0.0" "https://e.com/b.tgz" hash-b requirement put
  manifest put put
  "b" {} "1.0.0"
  "b" "1.0.0"
  {} "a" "a" "1.0.0" "https://e.com/a.tgz" hash-a requirement put
  manifest put put
  2 pack (pkg.mvs.resolve) @attempt
  'err at
  dup 'kind at 'domain equal
  'data at 'packages at ("a" "b") equal)
 'conflicts test

 ### test malformed-and-missing
 (-- : "Identify malformed requirements and absent exact manifests.")
 (("app" "0.1.0"
   {} "b" "b" "not-a-version" "https://e.com/b.tgz" hash-a requirement put
   manifest
   {}
   pkg.mvs.resolve)
  'domain
  'version
  "not-a-version"
  raises-data
  (root-without-c {} pkg.mvs.resolve)
  'domain
  'version
  "1.0.0"
  raises-data)
 'malformed-and-missing test

 ### test documentation
 (-- : "Require documentation for package resolution.")
 (('pkg.mvs.resolve) documented)
 'documentation test
) 'stdlib.test.pkg-mvs @defm
