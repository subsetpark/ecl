### module pkg.version
# Validate and compare package versions using the supported SemVer subset.
(
 ### setp digit-chars
 # Decimal digits.
 "0123456789"
 `digit-chars setp

 ### setp identifier-chars
 # Characters allowed in prerelease identifiers.
 "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
 `identifier-chars setp

 ### defp chars-in?
 (string characters -- bool :
  "Return 1 when a string is nonempty and contains only characters from the given set.")
 (|string characters|
  string empty? not
  string characters (in?) cons all?
  and) `chars-in? defp

 ### defp digits?
 (string -- bool : "Return 1 for a nonempty string of decimal digits.")
 (digit-chars chars-in?) `digits? defp

 ### defp numeric-field?
 (string -- bool : "Return 1 for a decimal field with no leading zero except 0.")
 ([(digits? not) (pop 0)
   (len 1 =) (pop 1)
   (first \0 not=)]
  cond) `numeric-field? defp

 ### defp identifier?
 (string -- bool : "Return 1 for a nonempty prerelease identifier.")
 (identifier-chars chars-in?) `identifier? defp

 ### defp prerelease-identifier?
 (string -- bool :
  "Return 1 for a valid prerelease identifier. Numeric identifiers may not have leading zeros.")
 ([(identifier? not) (pop 0)
   (digits?) (numeric-field?)
   (pop 1)]
  cond) `prerelease-identifier? defp

 ### defp hyphen-parts
 (candidate -- parts :
  "Split a version at hyphens. The first item is the core; later items make up the prerelease.")
 ("-" str.split) `hyphen-parts defp

 ### defp core-fields
 (candidate -- fields : "Return the dot-separated fields before the first hyphen.")
 (hyphen-parts first "." str.split) `core-fields defp

 ### defp identifiers
 (candidate -- identifiers :
  "Return the dot-separated prerelease identifiers, or an empty list when none are present.")
 (hyphen-parts dup len 1 = (pop []) (rest "-" str.join "." str.split) if) `identifiers defp

 ### def validate
 (candidate -- parts : "Validate a version and return [core-fields prerelease-identifiers].")
 (dup str.str?
  `type error.new "a package version is a string" error.with-message assert
  dup "+" str.split len 1 =
  `domain error.new "build metadata is not part of a package version" error.with-message assert
  dup core-fields
  dup len 3 =
  `domain error.new "a package version core is major.minor.patch" error.with-message assert
  dup (numeric-field?) all?
  `domain error.new "a package version field is digits with no leading zero" error.with-message
  assert
  swap identifiers
  dup (prerelease-identifier?) all?
  `domain error.new
  "a prerelease identifier is alphanumeric or hyphen, with no leading zero when numeric"
  error.with-message
  assert
  pair) `validate def

 ### defp field-cmp
 (left right -- order : "Compare two validated decimal fields by numeric value.")
 (over len over len = (cmp) (swap len swap len cmp) if) `field-cmp defp

 ### defp core-cmp
 (left right -- order : "Compare validated major, minor, and patch fields in order.")
 ((field-cmp) lex-cmp-with) `core-cmp defp

 ### defp identifier-cmp
 (left right -- order :
  "Compare two prerelease identifiers. Numeric identifiers sort before nonnumeric identifiers.")
 ([(digits? swap digits? =) (over digits? (field-cmp) (cmp) if)
   (over digits? (pop pop -1) (pop pop 1) if)]
  cond) `identifier-cmp defp

 ### defp prerelease-cmp
 (left right -- order :
  "Compare prereleases. A release version sorts after a version with the same core and a
   prerelease.")
 ([(empty? swap empty? and) (pop pop 0)
   (pop empty?) (pop pop 1)
   (nip empty?) (pop pop -1)
   ((identifier-cmp) lex-cmp-with)]
  cond) `prerelease-cmp defp

 ### defp version-cmp
 (left right -- order : "Compare validated versions by core, then prerelease.")
 (over first over first core-cmp
  dup 0 = (pop swap 1 at swap 1 at prerelease-cmp) (nip nip) if) `version-cmp defp

 ### def less?
 (left right -- bool :
  "Return 1 when the left version has lower SemVer 2.0.0 precedence. Validate both versions.")
 (validate swap validate swap version-cmp -1 =) `less? def

 ### defp keep-larger
 (accumulated candidate -- accumulated : "Return the entry with higher version precedence.")
 (over 1 at over 1 at version-cmp -1 = (nip) (pop) if) `keep-larger defp

 ### def max
 (versions -- version :
  "Return the highest version in a nonempty list. Validate every item before comparing.")
 (dup type `list match?
  `type error.new "pkg.version.max expects a list of version strings" error.with-message assert
  dup empty? not
  `shape error.new "pkg.version.max needs at least one version" error.with-message assert
  dup (str.str?) all?
  `type error.new "pkg.version.max expects a list of version strings" error.with-message assert
  (dup validate pair) each
  (keep-larger) fold1
  first) `max def

 `pkg.test.support `t alias

 ### defp trichotomy
 (a b -- count : "Count the less-than and equality relations holding for a pair.")
 (|a b|
  a b pkg.version.less?
  b a pkg.version.less? +
  a b match? +) `trichotomy defp

 ### defp row-of
 (element corpus -- pairs : "Pair one element with a corpus.")
 (|element corpus| corpus element (pair) cons each) `row-of defp

 ### defp pairs-of
 (corpus -- pairs : "Build the Cartesian square of a corpus.")
 (|corpus| corpus corpus (row-of) cons each raze) `pairs-of defp

 ### defp ascending-row
 (index reference -- flags : "Compare one item to every later reference item.")
 (|index reference|
  reference index 1 + drop
  reference index at
  (swap pkg.version.less?) cons each) `ascending-row defp

 ### defp ascending-flags
 (reference -- flags : "Compare every earlier version with every later one.")
 (|reference|
  reference len range
  reference (ascending-row) cons each raze) `ascending-flags defp

 ### test ordering-laws
 (-- : "Prove strict total ordering over generated and SemVer reference corpora.")
 ([7 0] 24 4 rand.ints nip [8 3] reshape ((str) each "." str.join) each
  dup ("-alpha.1" cat) each cat
  dup distinct len 16 t.equal
  dup pairs-of (apply trichotomy) each (1 =) all? 1 t.equal
  (dup pkg.version.less?) each (0 =) all? 1 t.equal
  ["1.0.0-alpha" "1.0.0-alpha.1" "1.0.0-alpha.beta"
   "1.0.0-beta" "1.0.0-beta.2" "1.0.0-beta.11" "1.0.0-rc.1"
   "1.0.0" "1.0.1" "1.1.0" "2.0.0"]
  ascending-flags (1 =) all? 1 t.equal
  ["1.0.0" "1.0.0-alpha"] ascending-flags (1 =) all? 0 t.equal)
 `ordering-laws test

 ### test grammar
 (-- : "Accept canonical SemVer spellings and reject ambiguous or unsupported forms.")
 (("1.0.0+build" "1.0.1" pkg.version.less?)
  `domain
  "build metadata"
  t.raises-containing
  ("1.01.0" "1.2.0" pkg.version.less?) `domain "leading zero" t.raises-containing
  ("1.0.0-01" "1.2.0" pkg.version.less?)
  `domain
  "leading zero"
  t.raises-containing
  ("1.0" "1.2.0" pkg.version.less?)
  `domain
  "major.minor.patch"
  t.raises-containing
  ("1.0.0.0" "1.2.0" pkg.version.less?)
  `domain
  "major.minor.patch"
  t.raises-containing
  ("1.0.0-" "1.2.0" pkg.version.less?)
  `domain
  "prerelease identifier"
  t.raises-containing
  ("1.0.0-a..b" "1.2.0" pkg.version.less?)
  `domain
  "prerelease identifier"
  t.raises-containing
  ("1.0.0-a_b" "1.2.0" pkg.version.less?)
  `domain
  "prerelease identifier"
  t.raises-containing
  "1.0.0-a-b" "1.0.0-a-c" pkg.version.less? 1 t.equal)
 `grammar test

 ### test malformed-operands
 (-- : "Classify malformed comparison operands rather than returning an ordering.")
 ((5 "1.2.0" pkg.version.less?)
  `type
  "a package version is a string"
  t.raises-containing
  ("1.2.0" 5 pkg.version.less?)
  `type
  "a package version is a string"
  t.raises-containing
  ("1.2.0" "nope" pkg.version.less?) `domain t.raises)
 `malformed-operands test

 ### test maximum
 (-- : "Return an input member that no other version exceeds.")
 (["1.2.0" "1.5.0" "1.10.0" "1.5.0"] pkg.version.max "1.10.0" t.equal
  ["1.0.0-rc.1" "1.0.0" "1.0.0-alpha"] pkg.version.max "1.0.0" t.equal
  ["0.1.0"] pkg.version.max "0.1.0" t.equal
  ["2.0.0" "1.9.9" "2.0.0-rc.1"] dup pkg.version.max
  (|corpus max|
   corpus max (swap pkg.version.less?) cons each (1 =) any? not 1 t.equal
   corpus max (match?) cons each (1 =) any? 1 t.equal)
  apply
  ([] pkg.version.max) `shape "at least one version" t.raises-containing
  (5 pkg.version.max) `type "list of version strings" t.raises-containing
  (["9.0.0" "1.0"] pkg.version.max) `domain t.raises)
 `maximum test

 ### test documentation
 (-- : "Require documentation for every package-version export.")
 ((pkg.version.validate pkg.version.less? pkg.version.max) t.documented)
 `documentation test
) `pkg.version @defm
