### module pkg.version
# Validate and compare package versions using the supported SemVer subset.
(
 ### defp digit-chars
 # Decimal digits.
 "0123456789"
 'digit-chars setp

 ### defp identifier-chars
 # Characters allowed in prerelease identifiers.
 "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
 'identifier-chars setp

 ### defp chars-in?
 (|string characters|
  string empty? not
  string characters (in?) partial all?
  and)
 (string characters -- bool :
  "Return 1 when a string is nonempty and contains only characters from the given set.")
 'chars-in? defp

 ### defp digits?
 (digit-chars chars-in?)
 (string -- bool : "Return 1 for a nonempty string of decimal digits.")
 'digits? defp

 ### defp numeric-field?
 ([(digits? not) (pop 0)
   (len 1 =) (pop 1)
   (first \0 <>)]
  cond)
 (string -- bool : "Return 1 for a decimal field with no leading zero except 0.")
 'numeric-field? defp

 ### defp identifier?
 (identifier-chars chars-in?)
 (string -- bool : "Return 1 for a nonempty prerelease identifier.")
 'identifier? defp

 ### defp prerelease-identifier?
 ([(identifier? not) (pop 0)
   (digits?) (numeric-field?)
   (pop 1)]
  cond)
 (string -- bool :
  "Return 1 for a valid prerelease identifier. Numeric identifiers may not have leading zeros.")
 'prerelease-identifier? defp

 ### defp hyphen-parts
 ("-" split)
 (candidate -- parts :
  "Split a version at hyphens. The first item is the core; later items make up the prerelease.")
 'hyphen-parts defp

 ### defp core-fields
 (hyphen-parts first "." split)
 (candidate -- fields : "Return the dot-separated fields before the first hyphen.")
 'core-fields defp

 ### defp identifiers
 (hyphen-parts dup len 1 = (pop []) (rest "-" join "." split) if)
 (candidate -- identifiers :
  "Return the dot-separated prerelease identifiers, or an empty list when none are present.")
 'identifiers defp

 ### def validate
 (dup str.str?
  {'kind 'type 'msg "a package version is a string"} assert
  dup "+" split len 1 =
  {'kind 'domain 'msg "build metadata is not part of a package version"} assert
  dup core-fields
  dup len 3 =
  {'kind 'domain 'msg "a package version core is major.minor.patch"} assert
  dup (numeric-field?) all?
  {'kind 'domain 'msg "a package version field is digits with no leading zero"} assert
  swap identifiers
  dup (prerelease-identifier?) all?
  {'kind 'domain
   'msg "a prerelease identifier is alphanumeric or hyphen, with no leading zero when numeric"}
  assert
  pair)
 (candidate -- parts : "Validate a version and return [core-fields prerelease-identifiers].")
 'validate def

 ### defp field-cmp
 (over len over len = (cmp) (swap len swap len cmp) if)
 (left right -- order : "Compare two validated decimal fields by numeric value.")
 'field-cmp defp

 ### defp core-cmp
 ((field-cmp) lex-cmp)
 (left right -- order : "Compare validated major, minor, and patch fields in order.")
 'core-cmp defp

 ### defp identifier-cmp
 ([(digits? swap digits? =) (over digits? (field-cmp) (cmp) if)
   (over digits? (pop pop -1) (pop pop 1) if)]
  cond)
 (left right -- order :
  "Compare two prerelease identifiers. Numeric identifiers sort before nonnumeric identifiers.")
 'identifier-cmp defp

 ### defp prerelease-cmp
 ([(empty? swap empty? and) (pop pop 0)
   (pop empty?) (pop pop 1)
   (nip empty?) (pop pop -1)
   ((identifier-cmp) lex-cmp)]
  cond)
 (left right -- order :
  "Compare prereleases. A release version sorts after a version with the same core and a
   prerelease.")
 'prerelease-cmp defp

 ### defp version-cmp
 (over first over first core-cmp
  dup 0 = (pop swap 1 at swap 1 at prerelease-cmp) (nip nip) if)
 (left right -- order : "Compare validated versions by core, then prerelease.")
 'version-cmp defp

 ### def less?
 (validate swap validate swap version-cmp -1 =)
 (left right -- bool :
  "Return 1 when the left version has lower SemVer 2.0.0 precedence. Validate both versions.")
 'less? def

 ### defp keep-larger
 (over 1 at over 1 at version-cmp -1 = (nip) (pop) if)
 (accumulated candidate -- accumulated : "Return the entry with higher version precedence.")
 'keep-larger defp

 ### def max
 (dup type 'list match?
  {'kind 'type 'msg "pkg.version.max expects a list of version strings"} assert
  dup empty? not
  {'kind 'shape 'msg "pkg.version.max needs at least one version"} assert
  dup (str.str?) all?
  {'kind 'type 'msg "pkg.version.max expects a list of version strings"} assert
  (dup validate pair) each
  (keep-larger) fold1
  first)
 (versions -- version :
  "Return the highest version in a nonempty list. Validate every item before comparing.")
 'max def
 )
'pkg.version
@defm
