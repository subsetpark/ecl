### module stdlib.test.pkg-lock
[]
(
 'stdlib.test.support ('equal 'raises-containing 'documented) import

 ### defp canonical-lock
 "{'format 1\n 'root \"my.proj\"\n 'packages\n {\"bar\" {'version \"0.3.0\" 'url \"https://e.com/b.tgz\" 'hash \"sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\"}\n  \"foo\" {'version \"1.2.0\" 'url \"https://e.com/f.tgz\" 'hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}}\n 'requires\n {\"foo\" {\"bar\" {'package \"bar\" 'version \"0.3.0\"}}\n  \"my.proj\" {\"foo\" {'package \"foo\" 'version \"1.2.0\"}}}}\n"
 'canonical-lock setp

 ### defp vendor-lock
 "{'format 1\n 'root \"my.proj\"\n 'store 'vendor\n 'packages\n {\"bar\" {'version \"0.3.0\" 'url \"https://e.com/b.tgz\" 'hash \"sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\"}\n  \"foo\" {'version \"1.2.0\" 'url \"https://e.com/f.tgz\" 'hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}}\n 'requires\n {\"foo\" {\"bar\" {'package \"bar\" 'version \"0.3.0\"}}\n  \"my.proj\" {\"foo\" {'package \"foo\" 'version \"1.2.0\"}}}}\n"
 'vendor-lock setp

 ### defp unsorted-lock
 {'format 1 'root "my.proj"
  'packages
  {"foo"
   {'version "1.2.0" 'url "https://e.com/f.tgz"
    'hash "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
   "bar"
   {'version "0.3.0" 'url "https://e.com/b.tgz"
    'hash "sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}}
  'requires
  {"my.proj" {"foo" {'package "foo" 'version "1.2.0"}}
   "foo" {"bar" {'package "bar" 'version "0.3.0"}}}}
 'unsorted-lock setp

 ### test round-trips
 (-- : "Read, write, canonicalize, and vendor lock data.")
 (canonical-lock dup pkg.lock.read pkg.lock.write match? 1 equal
  unsorted-lock dup pkg.lock.write pkg.lock.read match? 1 equal
  unsorted-lock pkg.lock.write "\n" str.ends? 1 equal
  unsorted-lock pkg.lock.write canonical-lock equal
  canonical-lock pkg.lock.read pkg.lock.vendor pkg.lock.write vendor-lock equal
  vendor-lock dup pkg.lock.read pkg.lock.write match? 1 equal
  (canonical-lock pkg.lock.read 'store "../../elsewhere" put pkg.lock.write)
  'domain
  "store mode is 'vendor"
  raises-containing
  ({'format 1 'root "a"} pkg.lock.write)
  'domain
  "exactly the keys"
  raises-containing
  (5 pkg.lock.write) 'type "a lock is a dict" raises-containing)
 'round-trips test

 ### test paths
 (-- : "Render deterministic dependency trees and longest-owner explanations.")
 (unsorted-lock pkg.lock.tree
  "my.proj\nfoo -> bar 0.3.0\nmy.proj -> foo 1.2.0\n"
  equal
  unsorted-lock "bar.worker" pkg.lock.why
  "bar.worker: my.proj -> foo 1.2.0 -> bar 0.3.0\n"
  equal
  {'format 1 'root "root"
   'packages
   {"foo"
    {'version "1.0.0" 'url "https://e.com/foo.tgz"
     'hash "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
    "foo.bar"
    {'version "1.0.0" 'url "https://e.com/foo-bar.tgz"
     'hash "sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}}
   'requires
   {"foo" {} "foo.bar" {}
    "root" {"foo.bar" {'package "foo.bar" 'version "1.0.0"}}}}
  pkg.lock.validate
  "foo.bar.worker"
  pkg.lock.why
  "foo.bar.worker: root -> foo.bar 1.0.0\n"
  equal)
 'paths test

 ### test requirement-table
 (-- : "Key requirements by requirer and reject inconsistent selections.")
 (canonical-lock pkg.lock.read dup 'requires at dict.keys sort
  ("foo" "my.proj") equal
  dup 'root at "my.proj" equal
  dup 'requires at "my.proj" at dict.keys ("foo") equal
  pop
  ({'format 1 'root "a"
    'packages
    {"foo"
     {'version "1.0.0" 'url "https://e.com/f.tgz"
      'hash "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}
    'requires
    {"a" {"foo" {'package "foo" 'version "1.2.0"}} "foo" {}}}
   pkg.lock.write)
  'domain
  "never below a minimum"
  raises-containing
  ({'format 1 'root "a" 'packages {}
    'requires {"a" {"foo" {'package "foo" 'version "1.2.0"}}}}
   pkg.lock.write)
  'domain
  "has a selection"
  raises-containing
  ({'format 1 'root "a" 'packages {} 'requires {}} pkg.lock.write)
  'domain
  "root's own requirements"
  raises-containing)
 'requirement-table test

 ### test documentation
 (-- : "Require documentation for every package-lock export.")
 (('pkg.lock.validate 'pkg.lock.read 'pkg.lock.write 'pkg.lock.vendor
   'pkg.lock.tree 'pkg.lock.why)
  documented)
 'documentation test
) 'stdlib.test.pkg-lock @defm
