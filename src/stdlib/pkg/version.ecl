### module pkg.version
# Validate and compare package versions using the supported SemVer subset.
(
 ### setp digit-chars
 # Decimal digits.
 "0123456789"
 'digit-chars setp

 ### setp identifier-chars
 # Characters allowed in prerelease identifiers.
 "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
 'identifier-chars setp

 ### defp chars-in?
 (string characters -- bool :
  "Return 1 when a string is nonempty and contains only characters from the given set.")
 (|string characters|
  string empty? not
  string characters (in?) partial all?
  and)
 'chars-in? defp

 ### defp digits?
 (string -- bool : "Return 1 for a nonempty string of decimal digits.")
 (digit-chars chars-in?)
 'digits? defp

 ### defp numeric-field?
 (string -- bool : "Return 1 for a decimal field with no leading zero except 0.")
 ([(digits? not) (pop 0)
   (len 1 =) (pop 1)
   (first \0 <>)]
  cond)
 'numeric-field? defp

 ### defp identifier?
 (string -- bool : "Return 1 for a nonempty prerelease identifier.")
 (identifier-chars chars-in?)
 'identifier? defp

 ### defp prerelease-identifier?
 (string -- bool :
  "Return 1 for a valid prerelease identifier. Numeric identifiers may not have leading zeros.")
 ([(identifier? not) (pop 0)
   (digits?) (numeric-field?)
   (pop 1)]
  cond)
 'prerelease-identifier? defp

 ### defp hyphen-parts
 (candidate -- parts :
  "Split a version at hyphens. The first item is the core; later items make up the prerelease.")
 ("-" split)
 'hyphen-parts defp

 ### defp core-fields
 (candidate -- fields : "Return the dot-separated fields before the first hyphen.")
 (hyphen-parts first "." split)
 'core-fields defp

 ### defp identifiers
 (candidate -- identifiers :
  "Return the dot-separated prerelease identifiers, or an empty list when none are present.")
 (hyphen-parts dup len 1 = (pop []) (rest "-" join "." split) if)
 'identifiers defp

 ### def validate
 (candidate -- parts : "Validate a version and return [core-fields prerelease-identifiers].")
 (dup str.str?
  'type error.new "a package version is a string" error.with-message assert
  dup "+" split len 1 =
  'domain error.new "build metadata is not part of a package version" error.with-message assert
  dup core-fields
  dup len 3 =
  'domain error.new "a package version core is major.minor.patch" error.with-message assert
  dup (numeric-field?) all?
  'domain error.new "a package version field is digits with no leading zero" error.with-message
  assert
  swap identifiers
  dup (prerelease-identifier?) all?
  'domain error.new
  "a prerelease identifier is alphanumeric or hyphen, with no leading zero when numeric"
  error.with-message
  assert
  pair)
 'validate def

 ### defp field-cmp
 (left right -- order : "Compare two validated decimal fields by numeric value.")
 (over len over len = (cmp) (swap len swap len cmp) if)
 'field-cmp defp

 ### defp core-cmp
 (left right -- order : "Compare validated major, minor, and patch fields in order.")
 ((field-cmp) lex-cmp)
 'core-cmp defp

 ### defp identifier-cmp
 (left right -- order :
  "Compare two prerelease identifiers. Numeric identifiers sort before nonnumeric identifiers.")
 ([(digits? swap digits? =) (over digits? (field-cmp) (cmp) if)
   (over digits? (pop pop -1) (pop pop 1) if)]
  cond)
 'identifier-cmp defp

 ### defp prerelease-cmp
 (left right -- order :
  "Compare prereleases. A release version sorts after a version with the same core and a
   prerelease.")
 ([(empty? swap empty? and) (pop pop 0)
   (pop empty?) (pop pop 1)
   (nip empty?) (pop pop -1)
   ((identifier-cmp) lex-cmp)]
  cond)
 'prerelease-cmp defp

 ### defp version-cmp
 (left right -- order : "Compare validated versions by core, then prerelease.")
 (over first over first core-cmp
  dup 0 = (pop swap 1 at swap 1 at prerelease-cmp) (nip nip) if)
 'version-cmp defp

 ### def less?
 (left right -- bool :
  "Return 1 when the left version has lower SemVer 2.0.0 precedence. Validate both versions.")
 (validate swap validate swap version-cmp -1 =)
 'less? def

 ### defp keep-larger
 (accumulated candidate -- accumulated : "Return the entry with higher version precedence.")
 (over 1 at over 1 at version-cmp -1 = (nip) (pop) if)
 'keep-larger defp

 ### def max
 (versions -- version :
  "Return the highest version in a nonempty list. Validate every item before comparing.")
 (dup type 'list match?
  'type error.new "pkg.version.max expects a list of version strings" error.with-message assert
  dup empty? not
  'shape error.new "pkg.version.max needs at least one version" error.with-message assert
  dup (str.str?) all?
  'type error.new "pkg.version.max expects a list of version strings" error.with-message assert
  (dup validate pair) each
  (keep-larger) fold1
  first)
 'max def
 ) 'pkg.version @defm
