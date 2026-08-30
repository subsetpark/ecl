### module stdlib.test.pkg-name
(
 'stdlib.test.support ('equal 'raises-containing 'documented) import

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

 ### test documentation
 (-- : "Require documentation for every package-name export.")
 (('pkg.name.valid? 'pkg.name.hash? 'pkg.name.url?
   'pkg.name.owns? 'pkg.name.collides?)
  documented)
 'documentation test
) 'stdlib.test.pkg-name @defm
