### module stdlib.test.pkg-version
[]
(
 'stdlib.test.support
 ('equal 'raises 'raises-containing 'documented)
 import

 ### defp trichotomy
 (a b -- count : "Count the less-than and equality relations holding for a pair.")
 (|a b|
  a b pkg.version.less?
  b a pkg.version.less? +
  a b match? +)
 'trichotomy defp

 ### defp row-of
 (element corpus -- pairs : "Pair one element with a corpus.")
 (|element corpus| corpus element (pair) partial each)
 'row-of defp

 ### defp pairs-of
 (corpus -- pairs : "Build the Cartesian square of a corpus.")
 (|corpus| corpus corpus (row-of) partial each raze)
 'pairs-of defp

 ### defp ascending-row
 (index reference -- flags : "Compare one item to every later reference item.")
 (|index reference|
  reference index 1 + drop
  reference index at
  (swap pkg.version.less?) partial each)
 'ascending-row defp

 ### defp ascending-flags
 (reference -- flags : "Compare every earlier version with every later one.")
 (|reference|
  reference len range
  reference (ascending-row) partial each raze)
 'ascending-flags defp

 ### test ordering-laws
 (-- : "Prove strict total ordering over generated and SemVer reference corpora.")
 (7 rng.seed
  24 4 rng.ints [8 3] reshape ((str) each "." join) each
  dup ("-alpha.1" cat) each cat
  dup distinct len 16 equal
  dup pairs-of (call trichotomy) each (1 =) all? 1 equal
  (dup pkg.version.less?) each (0 =) all? 1 equal
  ["1.0.0-alpha" "1.0.0-alpha.1" "1.0.0-alpha.beta"
   "1.0.0-beta" "1.0.0-beta.2" "1.0.0-beta.11" "1.0.0-rc.1"
   "1.0.0" "1.0.1" "1.1.0" "2.0.0"]
  ascending-flags (1 =) all? 1 equal
  ["1.0.0" "1.0.0-alpha"] ascending-flags (1 =) all? 0 equal)
 'ordering-laws test

 ### test grammar
 (-- : "Accept canonical SemVer spellings and reject ambiguous or unsupported forms.")
 (("1.0.0+build" "1.0.1" pkg.version.less?)
  'domain
  "build metadata"
  raises-containing
  ("1.01.0" "1.2.0" pkg.version.less?) 'domain "leading zero" raises-containing
  ("1.0.0-01" "1.2.0" pkg.version.less?)
  'domain
  "leading zero"
  raises-containing
  ("1.0" "1.2.0" pkg.version.less?)
  'domain
  "major.minor.patch"
  raises-containing
  ("1.0.0.0" "1.2.0" pkg.version.less?)
  'domain
  "major.minor.patch"
  raises-containing
  ("1.0.0-" "1.2.0" pkg.version.less?)
  'domain
  "prerelease identifier"
  raises-containing
  ("1.0.0-a..b" "1.2.0" pkg.version.less?)
  'domain
  "prerelease identifier"
  raises-containing
  ("1.0.0-a_b" "1.2.0" pkg.version.less?)
  'domain
  "prerelease identifier"
  raises-containing
  "1.0.0-a-b" "1.0.0-a-c" pkg.version.less? 1 equal)
 'grammar test

 ### test malformed-operands
 (-- : "Classify malformed comparison operands rather than returning an ordering.")
 ((5 "1.2.0" pkg.version.less?)
  'type
  "a package version is a string"
  raises-containing
  ("1.2.0" 5 pkg.version.less?)
  'type
  "a package version is a string"
  raises-containing
  ("1.2.0" "nope" pkg.version.less?) 'domain raises)
 'malformed-operands test

 ### test maximum
 (-- : "Return an input member that no other version exceeds.")
 (["1.2.0" "1.5.0" "1.10.0" "1.5.0"] pkg.version.max "1.10.0" equal
  ["1.0.0-rc.1" "1.0.0" "1.0.0-alpha"] pkg.version.max "1.0.0" equal
  ["0.1.0"] pkg.version.max "0.1.0" equal
  ["2.0.0" "1.9.9" "2.0.0-rc.1"] dup pkg.version.max
  (|corpus max|
   corpus max (swap pkg.version.less?) partial each (1 =) any? not 1 equal
   corpus max (match?) partial each (1 =) any? 1 equal)
  call
  ([] pkg.version.max) 'shape "at least one version" raises-containing
  (5 pkg.version.max) 'type "list of version strings" raises-containing
  (["9.0.0" "1.0"] pkg.version.max) 'domain raises)
 'maximum test

 ### test documentation
 (-- : "Require documentation for every package-version export.")
 (('pkg.version.validate 'pkg.version.less? 'pkg.version.max) documented)
 'documentation test
) 'stdlib.test.pkg-version @defm
