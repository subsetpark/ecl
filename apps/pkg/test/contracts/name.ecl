### module pkg.test.name
[]
(
 'pkg.test.support ('equal 'raises-containing 'documented) import

 ### test ownership
 (-- : "Recognize only a package's own name and dotted descendants.")
 ("foo" "foo" pkg.name.owns? 1 equal
  "foo" "foo.bar" pkg.name.owns? 1 equal
  "foo" "foo.bar.baz" pkg.name.owns? 1 equal
  "foo" "foobar" pkg.name.owns? 0 equal
  "foo.bar" "foo" pkg.name.owns? 0 equal
  "a.b" "a.b.c" pkg.name.owns? 1 equal
  "a.b" "a.c" pkg.name.owns? 0 equal
  (5 "foo" pkg.name.owns?) 'type "two package names" raises-containing
  ("foo" "Foo.Bar" pkg.name.owns?)
  'domain
  "lowercase segments"
  raises-containing
  ("foo" "foo..bar" pkg.name.owns?)
  'domain
  "lowercase segments"
  raises-containing)
 'ownership test

 ### test url-hostnames
 (-- : "Reject empty URL hosts while retaining ports, queries, and IPv6 literals.")
 (("https://?query" "https://:443/path" "https:///path" "https://[]/path"
   "https://[::1/path")
  (pkg.name.url? 0 equal) for
  ("https://example.com/path" "https://example.com:443/path"
   "https://example.com?query" "https://[::1]/path" "https://[::1]:443/path")
  (pkg.name.url? 1 equal) for
  ({'kind 'archive 'url "https://?query"} pkg.manifest.validate-source)
  'domain "HTTPS" raises-containing
  ("https://:443/path" pkg.fetch.archive) 'domain "HTTPS" raises-containing)
 'url-hostnames test

 ### test documentation
 (-- : "Require documentation for every package-name export.")
 (('pkg.name.valid? 'pkg.name.hash? 'pkg.name.url?
   'pkg.name.owns? 'pkg.name.collides?)
  documented)
 'documentation test
) 'pkg.test.name @defm
