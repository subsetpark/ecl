### module stdlib.test.pkg-manifest
[]
(
 'stdlib.test.support
 ('equal 'raises 'raises-containing 'raises-data 'documented)
 import

 ### defp manifest-text
 "{'format 1 'name \"my.proj\" 'version \"0.1.0\" 'exports {\"my.proj\" [\"**/*\"]} 'requires {\"foo\" {'package \"foo\" 'version \"1.2.0\" 'url \"https://e.com/f.tgz\" 'hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}}}"
 'manifest-text setp

 ### test read-and-validate
 (-- : "Read canonical manifests and enforce their declared schema.")
 (manifest-text pkg.manifest.read 'name at "my.proj" equal
  "# a comment\n{'format 1 'name \"a\" 'version \"0.1.0\" 'exports {} 'requires {}}"
  pkg.manifest.read 'requires at dict.size 0 equal
  manifest-text parse first dup pkg.manifest.validate match? 1 equal
  ("{'format 1" pkg.manifest.read) 'parse raises
  ("{} {}" pkg.manifest.read) 'shape "exactly one form" raises-containing
  ("" pkg.manifest.read) 'shape "exactly one form" raises-containing
  ("[1 2]" pkg.manifest.read) 'type "a manifest is a dict" raises-containing
  ("{'format 1 'name \"a\" 'version \"0.1.0\" 'exports {} 'requires {} 'require {}}"
   pkg.manifest.read)
  'domain
  "exactly the keys"
  raises-containing
  ("{'format 1 'name \"a\" 'version \"0.1.0\"}" pkg.manifest.read)
  'domain
  "exactly the keys"
  raises-containing
  ("{'format 2 'name \"a\" 'version \"0.1.0\" 'exports {} 'requires {}}"
   pkg.manifest.read)
  'domain
  "format is 1"
  raises-containing
  ("{'format 1 'name \"My.Proj\" 'version \"0.1.0\" 'exports {} 'requires {}}"
   pkg.manifest.read)
  'domain
  "lowercase segments"
  raises-containing)
 'read-and-validate test

 ### test exports-and-requirements
 (-- : "Validate export ownership, portable globs, URLs, hashes, and package collisions.")
 (("{'format 1 'name \"a\" 'version \"0.1.0\" 'exports {\"foreign\" [\"**/*\"]} 'requires {}}"
   pkg.manifest.read)
  'domain
  "owns every namespace"
  raises-containing
  ("{'format 1 'name \"a\" 'version \"0.1.0\" 'exports {\"a\" [\"src//*.ecl\"]} 'requires {}}"
   pkg.manifest.read)
  'domain
  "portable glob lists"
  raises-containing
  ("{'format 1 'name \"a\" 'version \"0.1.0\" 'exports {\"a\" [\"src/prefix**/*.ecl\"]} 'requires {}}"
   pkg.manifest.read)
  'domain
  "portable glob lists"
  raises-containing
  ("{'format 1 'name \"a\" 'version \"0.1.0\" 'exports {} 'requires {\"foo\" {'package \"foo\" 'version \"1.0.0\" 'url \"http://e.com/f.tgz\" 'hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}}}"
   pkg.manifest.read)
  'domain
  "https"
  raises-containing
  ("{'format 1 'name \"a\" 'version \"0.1.0\" 'exports {} 'requires {\"foo\" {'package \"foo\" 'version \"1.0.0\" 'url \"https://e.com/f.tgz\" 'hash \"sha256-ABC\"}}}"
   pkg.manifest.read)
  'domain
  "lowercase hex"
  raises-containing
  ("{'format 1 'name \"foo\" 'version \"0.1.0\" 'exports {} 'requires {\"foo\" {'package \"foo\" 'version \"1.0.0\" 'url \"https://e.com/f.tgz\" 'hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}}}"
   pkg.manifest.read)
  'domain
  "require itself"
  raises-containing
  ("{'format 1 'name \"a\" 'version \"0.1.0\" 'exports {} 'requires {\"foo\" {'package \"foo\" 'version \"1.0.0\" 'url \"https://e.com/f.tgz\" 'hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"} \"foo.bar\" {'package \"foo.bar\" 'version \"1.0.0\" 'url \"https://e.com/g.tgz\" 'hash \"sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\"}}}"
   pkg.manifest.read)
  'domain
  "require itself"
  raises-containing
  ("{'format 1 'name \"p\" 'version \"0.1.0\" 'exports {} 'requires {\"p-\" {'package \"p-\" 'version \"1.0.0\" 'url \"https://e.com/f.tgz\" 'hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"} \"p.a\" {'package \"p.a\" 'version \"1.0.0\" 'url \"https://e.com/g.tgz\" 'hash \"sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\"}}}"
   pkg.manifest.read)
  'domain
  "require itself"
  raises-containing
  ("{'format 1 'name \"p\" 'version \"0.1.0\" 'exports {} 'requires {\"p0\" {'package \"p0\" 'version \"1.0.0\" 'url \"https://e.com/f.tgz\" 'hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"} \"p.a\" {'package \"p.a\" 'version \"1.0.0\" 'url \"https://e.com/g.tgz\" 'hash \"sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\"}}}"
   pkg.manifest.read)
  'domain
  "require itself"
  raises-containing)
 'exports-and-requirements test

 ### test writing
 (-- : "Round-trip manifests while retaining requirement insertion order.")
 ({'format 1 'name "a" 'version "0.1.0" 'exports {"a" ["**/*"]}
   'requires
   {"z"
    {'package "z" 'version "2.0.0" 'url "https://e.com/z.tgz"
     'hash "sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}
    "b"
    {'package "b" 'version "1.0.0" 'url "https://e.com/b.tgz"
     'hash "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}}
  dup pkg.manifest.write pkg.manifest.read match? 1 equal
  {'format 1 'name "a" 'version "0.1.0" 'exports {"a" ["**/*"]}
   'requires
   {"z"
    {'package "z" 'version "2.0.0" 'url "https://e.com/z.tgz"
     'hash "sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}
    "b"
    {'package "b" 'version "1.0.0" 'url "https://e.com/b.tgz"
     'hash "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}}
  pkg.manifest.write
  "{'format 1 'name \"a\" 'version \"0.1.0\" 'exports {\"a\" (\"**/*\")} 'requires {\"z\" {'package \"z\" 'version \"2.0.0\" 'url \"https://e.com/z.tgz\" 'hash \"sha256-abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\"} \"b\" {'package \"b\" 'version \"1.0.0\" 'url \"https://e.com/b.tgz\" 'hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}}}\n"
  equal)
 'writing test

 ### test inert-data
 (-- : "Reject executable forms as data without evaluating them.")
 (("{'format 1 'name \"a\" 'version \"0.1.0\" 'requires ((\"pwned\" 'cwd \"pkg-pwned\" fs.create-text))}"
   pkg.manifest.read)
  'domain
  'key
  'requires
  raises-data
  ("{'format 1 'name \"a\" 'version \"0.1.0\" 'requires exit}"
   pkg.manifest.read)
  'domain
  'key
  'requires
  raises-data
  ("{'format 1 'name \"a\" 'version \"0.1.0\" 'requires {\"foo\" {'version \"1.0.0\" 'url \"https://e.com/f.tgz\" 'hash exit}}}"
   pkg.manifest.read)
  'domain
  'key
  'requires
  raises-data)
 'inert-data test

 ### test documentation
 (-- : "Require documentation for manifest and inert-data exports.")
 (('pkg.data.assert-inert-entry 'pkg.data.read-one 'pkg.data.sorted-entries
   'pkg.manifest.validate-requirement 'pkg.manifest.validate
   'pkg.manifest.read 'pkg.manifest.write)
  documented)
 'documentation test
) 'stdlib.test.pkg-manifest @defm
