### module pkg.test.manifest
[]
(
 `pkg.test.support
 (equal raises raises-containing raises-data documented)
 import

 ### setp manifest-text
 "{format 2 name \"my.proj\" version \"0.1.0\" sources [\"**/*\"] exports [\"my.proj\"] requires {\"foo\" {package \"foo\" version \"1.2.0\" source {kind archive url \"https://e.com/f.tgz\"} hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}}}"
 `manifest-text setp

 ### test read-and-validate
 (-- : "Read canonical manifests and enforce their declared schema.")
 (manifest-text pkg.manifest.read `name at "my.proj" equal
  "# a comment\n{format 2 name \"a\" version \"0.1.0\" sources [] exports [] requires {}}"
  pkg.manifest.read `requires at dict.size 0 equal
  manifest-text parse first dup pkg.manifest.validate match? 1 equal
  ("{format 2" pkg.manifest.read) `parse raises
  ("{} {}" pkg.manifest.read) `shape "exactly one form" raises-containing
  ("" pkg.manifest.read) `shape "exactly one form" raises-containing
  ("[1 2]" pkg.manifest.read) `type "a manifest is a dict" raises-containing
  ("{format 2 name \"a\" version \"0.1.0\" sources [] exports [] requires {} require {}}"
   pkg.manifest.read)
  `domain
  "exactly the keys"
  raises-containing
  ("{format 2 name \"a\" version \"0.1.0\"}" pkg.manifest.read)
  `domain
  "exactly the keys"
  raises-containing
  ("{format 1 name \"a\" version \"0.1.0\" sources [] exports [] requires {}}"
   pkg.manifest.read)
  `domain
  "migrate format 1"
  raises-containing
  ("{format 2 name \"My.Proj\" version \"0.1.0\" sources [] exports [] requires {}}"
   pkg.manifest.read)
  `domain
  "lowercase segments"
  raises-containing)
 `read-and-validate test

 ### test exports-and-requirements
 (-- : "Validate export ownership, portable globs, URLs, hashes, and package collisions.")
 (("{format 2 name \"a\" version \"0.1.0\" sources [\"**/*\"] exports [\"foreign\"] requires {}}"
   pkg.manifest.read)
  `domain
  "owns every module"
  raises-containing
  ("{format 2 name \"a\" version \"0.1.0\" sources [\"src//*.ecl\"] exports [\"a\"] requires {}}"
   pkg.manifest.read)
  `domain
  "portable glob strings"
  raises-containing
  ("{format 2 name \"a\" version \"0.1.0\" sources [\"src/prefix**/*.ecl\"] exports [\"a\"] requires {}}"
   pkg.manifest.read)
  `domain
  "portable glob strings"
  raises-containing
  ("{format 2 name \"a\" version \"0.1.0\" sources [] exports [] requires {\"foo\" {package \"foo\" version \"1.0.0\" source {kind archive url \"http://e.com/f.tgz\"} hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}}}"
   pkg.manifest.read)
  `domain
  "HTTPS"
  raises-containing
  ("{format 2 name \"a\" version \"0.1.0\" sources [] exports [] requires {\"foo\" {package \"foo\" version \"1.0.0\" source {kind archive url \"https://e.com/f.tgz\"} hash \"sha256-ABC\"}}}"
   pkg.manifest.read)
  `domain
  "lowercase hex"
  raises-containing
  ("{format 2 name \"foo\" version \"0.1.0\" sources [] exports [] requires {\"foo\" {package \"foo\" version \"1.0.0\" source {kind archive url \"https://e.com/f.tgz\"} hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}}}"
   pkg.manifest.read)
  `domain
  "require itself"
  raises-containing
  ("{format 2 name \"a\" version \"0.1.0\" sources [] exports [] requires {\"foo\" {package \"foo\" version \"1.0.0\" source {kind archive url \"https://e.com/f.tgz\"} hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"} \"foo.bar\" {package \"foo.bar\" version \"1.0.0\" source {kind archive url \"https://e.com/g.tgz\"} hash \"sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\"}}}"
   pkg.manifest.read)
  `domain
  "require itself"
  raises-containing
  ("{format 2 name \"p\" version \"0.1.0\" sources [] exports [] requires {\"p-\" {package \"p-\" version \"1.0.0\" source {kind archive url \"https://e.com/f.tgz\"} hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"} \"p.a\" {package \"p.a\" version \"1.0.0\" source {kind archive url \"https://e.com/g.tgz\"} hash \"sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\"}}}"
   pkg.manifest.read)
  `domain
  "require itself"
  raises-containing
  ("{format 2 name \"p\" version \"0.1.0\" sources [] exports [] requires {\"p0\" {package \"p0\" version \"1.0.0\" source {kind archive url \"https://e.com/f.tgz\"} hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"} \"p.a\" {package \"p.a\" version \"1.0.0\" source {kind archive url \"https://e.com/g.tgz\"} hash \"sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\"}}}"
   pkg.manifest.read)
  `domain
  "require itself"
  raises-containing)
 `exports-and-requirements test

 ### test writing
 (-- : "Round-trip manifests while retaining requirement insertion order.")
 ({format 2 name "a" version "0.1.0" sources ["**/*"] exports ["a"]
   requires
   {"z"
    {package "z" version "2.0.0" source {kind archive url "https://e.com/z.tgz"}
     hash "sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}
    "b"
    {package "b" version "1.0.0" source {kind archive url "https://e.com/b.tgz"}
     hash "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}}
  dup pkg.manifest.write pkg.manifest.read match? 1 equal
  {format 2 name "a" version "0.1.0" sources ["**/*"] exports ["a"]
   requires
   {"z"
    {package "z" version "2.0.0" source {kind archive url "https://e.com/z.tgz"}
     hash "sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}
    "b"
    {package "b" version "1.0.0" source {kind archive url "https://e.com/b.tgz"}
     hash "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}}
  pkg.manifest.write
  "{format 2 name \"a\" version \"0.1.0\" sources (\"**/*\") exports (\"a\") requires {\"z\" {package \"z\" version \"2.0.0\" source {kind archive url \"https://e.com/z.tgz\"} hash \"sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\"} \"b\" {package \"b\" version \"1.0.0\" source {kind archive url \"https://e.com/b.tgz\"} hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}}}\n"
  equal)
 `writing test
) `pkg.test.manifest @defm
