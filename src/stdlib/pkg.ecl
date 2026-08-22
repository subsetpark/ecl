### module pkg
# The pkg module: the package formats — see SPEC.md, Packages — as data.
#
# Every word here is pure. `ecl.pkg` and `ecl.lock` are ECL data read with
# `parse` and never evaluated, so validation is the whole of what makes a
# candidate a manifest: nothing in this module finds a file, reads one, or
# writes one, and the host capabilities that would are deliberately out of
# reach.
#
# `find`, `filter`, and `partition` are unavailable to this module even though
# they would read well here. All three reach the core `where` kernel through a
# prelude body, and a session that has imported `table` has spliced
# `table.where` into the scope those bodies resolve against — so a version
# comparison would end in "a table must be a dict of columns". `split` and
# `fold` are the safe spellings, which is the same conclusion `str.contains?`
# and `table.selected` each reached independently.
#
# Error messages are constants rather than interpolations. The version words
# are called once per comparison inside a resolution, so a message assembled
# on the happy path would be an allocation per comparison; the raising word
# and its trace already name where the failure was.
(# The decimal digits, so digit classification is one membership test.
 "0123456789"
 'digit-chars setp

 # The characters a prerelease identifier may hold.
 "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
 'identifier-chars setp

 ### def digits?
 (dup empty? (pop 0) ((digit-chars in?) all?) if)
 (string -- bool : "Return 1 for a nonempty string of decimal digits.")
 'digits? defp

 ### def numeric-field?
 (dup digits? (dup len 1 = (pop 1) (first \0 <>) if) (pop 0) if)
 (string -- bool :
  "Return 1 for a numeric version field: digits throughout, and a leading zero only when it is the
   whole field.")
 'numeric-field? defp

 ### def identifier?
 (dup empty? (pop 0) ((identifier-chars in?) all?) if)
 (string -- bool : "Return 1 for a nonempty string of prerelease identifier characters.")
 'identifier? defp

 ### def prerelease-identifier?
 (dup identifier? (dup digits? (numeric-field?) (pop 1) if) (pop 0) if)
 (string -- bool :
  "Return 1 for a legal prerelease identifier: identifier characters throughout, and no leading zero
   in an all-digit one.")
 'prerelease-identifier? defp

 ### def hyphen-parts
 ("-" split)
 (candidate -- parts :
  "Split a version at every hyphen: the first part is its core and the rest are the prerelease with
   its own hyphens taken apart.

   Splitting rather than indexing is what keeps this module clear of `find`.")
 'hyphen-parts defp

 ### def core-fields
 (hyphen-parts first "." split)
 (candidate -- fields : "The dot-separated core fields of a version, before any prerelease.")
 'core-fields defp

 ### def identifiers
 (hyphen-parts dup len 1 = (pop []) (rest "-" join "." split) if)
 (candidate -- identifiers :
  "The prerelease identifiers of a version, empty when it carries no hyphen.

   Rejoining the tail with hyphens preserves an identifier that contains one, and a trailing hyphen
   yields one empty identifier rather than no prerelease — so `\"1.0.0-\"` is rejected instead of
   read as a release.")
 'identifiers defp

 ### def version-checked
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
 (candidate -- parts :
  "Return a validated version as its core fields paired with its prerelease identifiers.

   Every rejection is the version grammar's: a non-string is 'type and every spelling outside the
   grammar is 'domain, so no caller has to treat a malformed version as merely unordered.")
 'version-checked defp

 ### def field-cmp
 (over len over len = (cmp) (swap len swap len cmp) if)
 (left right -- order :
  "Order two validated numeric fields.

   Leading zeros are already excluded, so the longer field is the larger number and equal lengths
   compare codepoint-wise.")
 'field-cmp defp

 ### def order-then
 (over 0 = (nip) (pop) if)
 (accumulated next -- order :
  "Keep the accumulated order unless it is 0, in which case take the next one.")
 'order-then defp

 ### def first-nonzero
 (0 (order-then) fold)
 (orders -- order :
  "The leftmost nonzero order, or 0 when every one of them is 0.

   A fold rather than a filter, because `filter` reaches the core `where` this module cannot use.")
 'first-nonzero defp

 ### def core-cmp
 (zip (call field-cmp) each first-nonzero)
 (left right -- order : "Order two validated three-field cores, most significant field first.")
 'core-cmp defp

 ### def identifier-cmp
 (over digits? over digits? over over =
  (pop (field-cmp) (cmp) if)
  (swap - nip nip)
  if)
 (left right -- order :
  "Order two prerelease identifiers per semver 2.0.0 §11: a numeric identifier below an alphanumeric
   one, two numerics numerically, two alphanumerics codepoint-wise.")
 'identifier-cmp defp

 ### def common-order
 ((|index left right| left index at right index at identifier-cmp) call)
 (index left right -- order :
  "Order the identifiers two prereleases share at one position.

   The captured prereleases arrive above the index, because `partial` pushes what it captured after
   `each` has already pushed the element.")
 'common-order defp

 ### def identifier-walk
 ((|left right|
   left len right len cmp
   left len right len min range left right (common-order) partial partial each first-nonzero
   dup 0 = (pop) (nip) if)
  call)
 (left right -- order :
  "Order two nonempty prereleases: the leftmost differing identifier decides, and when every shared
   identifier agrees the shorter prerelease is the smaller one.")
 'identifier-walk defp

 ### def prerelease-cmp
 ([(over empty? over empty? and) (pop pop 0)
   (over empty?) (pop pop 1)
   (dup empty?) (pop pop -1)
   (identifier-walk)]
  cond)
 (left right -- order :
  "Order two prereleases, where absent beats present: a version carrying a prerelease is below the
   same core without one.")
 'prerelease-cmp defp

 ### def version-cmp
 (over first over first core-cmp
  dup 0 = (pop swap 1 at swap 1 at prerelease-cmp) (nip nip) if)
 (left right -- order :
  "Order two validated version parts: the core decides unless the cores agree, and then the
   prerelease does.")
 'version-cmp defp

 ### def version<
 (version-checked swap version-checked swap version-cmp -1 =)
 (left right -- bool :
  "Return 1 when the left version precedes the right under semver 2.0.0 §11.

   A spelling outside the version grammar raises rather than answering 0: a total order over a
   subset of its inputs is not a total order.")
 'version< def

 ### def keep-larger
 (over over version< (nip) (pop) if)
 (accumulated candidate -- accumulated : "Keep whichever of two versions is the later one.")
 'keep-larger defp

 ### def version-max
 (dup type 'list match?
  {'kind 'type 'msg "pkg.version-max expects a list of version strings"} assert
  dup empty? not
  {'kind 'shape 'msg "pkg.version-max needs at least one version"} assert
  dup (str.str?) all?
  {'kind 'type 'msg "pkg.version-max expects a list of version strings"} assert
  dup (version-checked) each pop
  dup first (keep-larger) fold)
 (versions -- version :
  "The greatest of a nonempty list of version strings.

   Every element is validated before any comparison runs, so a malformed version late in the list is
   an error rather than something an earlier maximum can hide.")
 'version-max def

 )
'pkg
@defm
