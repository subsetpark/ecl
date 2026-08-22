### module pkg
# The pkg module: the package formats — see SPEC.md, Packages — as data.
#
# Every word here is pure. `ecl.pkg` and `ecl.lock` are ECL data read with
# `parse` and never evaluated, so validation is the whole of what makes a
# candidate a manifest: nothing in this module finds a file, reads one, or
# writes one, and the host capabilities that would are deliberately out of
# reach.
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
 ([(dup digits? not) (pop 0)
   (dup len 1 =) (pop 1)
   (first \0 <>)]
  cond)
 (string -- bool :
  "Return 1 for a numeric version field: digits throughout, and a leading zero only when it is the
   whole field.")
 'numeric-field? defp

 ### def identifier?
 (dup empty? (pop 0) ((identifier-chars in?) all?) if)
 (string -- bool : "Return 1 for a nonempty string of prerelease identifier characters.")
 'identifier? defp

 ### def prerelease-identifier?
 ([(dup identifier? not) (pop 0)
   (dup digits?) (numeric-field?)
   (pop 1)]
  cond)
 (string -- bool :
  "Return 1 for a legal prerelease identifier: identifier characters throughout, and no leading zero
   in an all-digit one.")
 'prerelease-identifier? defp

 ### def hyphen-parts
 ("-" split)
 (candidate -- parts :
  "Split a version at every hyphen: the first part is its core and the rest are the prerelease with
   its own hyphens taken apart.

   Splitting beats locating the first hyphen and slicing around it: the trailing-hyphen case falls
   out as one empty identifier instead of needing its own branch.")
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

   A fold rather than a filter: one pass, and no intermediate list to allocate for a result that is
   one value.")
 'first-nonzero defp

 ### def core-cmp
 (zip (call field-cmp) each first-nonzero)
 (left right -- order : "Order two validated three-field cores, most significant field first.")
 'core-cmp defp

 ### def identifier-cmp
 ([(over digits? over digits? =) (over digits? (field-cmp) (cmp) if)
   (over digits? (pop pop -1) (pop pop 1) if)]
  cond)
 (left right -- order :
  "Order two prerelease identifiers per semver 2.0.0 §11.

   Two of a kind compare within their kind — numerics as numbers, alphanumerics by codepoint — and a
   numeric identifier is below an alphanumeric one.")
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

 # --- names ---------------------------------------------------------------

 ### def lead-chars
 # The characters a canonical name segment may begin with.
 "abcdefghijklmnopqrstuvwxyz"
 'lead-chars setp

 ### def segment-chars
 # The characters a canonical name segment may continue with.
 "-0123456789abcdefghijklmnopqrstuvwxyz"
 'segment-chars setp

 ### def hex-chars
 # The digits a hash body may hold, lowercase by ruling.
 "0123456789abcdef"
 'hex-chars setp

 ### def segment?
 (dup empty? (pop 0) ((first lead-chars in?) ((segment-chars in?) all?) bi and) if)
 (text -- bool : "Return 1 for one legal segment of a canonical package name.")
 'segment? defp

 ### def name?
 ([(dup str.str? not) (pop 0)
   (dup empty?) (pop 0)
   ("." split (segment?) all?)]
  cond)
 (value -- bool :
  "Return 1 for a canonical package name: dot-joined segments, each opening with a lowercase letter
   and continuing with lowercase letters, digits, or hyphens.

   A leading, trailing, or doubled dot leaves an empty segment behind, so the segment test rejects
   it without a separate rule.")
 'name? defp

 ### def hash?
 ([(dup str.str? not) (pop 0)
   (dup "sha256-" str.starts? not) (pop 0)
   (7 drop (len 64 =) ((hex-chars in?) all?) bi and)]
  cond)
 (value -- bool : "Return 1 for the literal `sha256-` followed by exactly 64 lowercase hex digits.")
 'hash? defp

 ### def url?
 (dup str.str? (("https://" str.starts?) (len 8 >) bi and) (pop 0) if)
 (value -- bool :
  "Return 1 for an https url with something after the scheme. Tarball over https is the only
   transport, so no other scheme is admitted.")
 'url? defp

 ### def owns-prefix?
 ((|package module|
   package str.str?
   {'kind 'type 'msg "pkg.owns-prefix? expects two package names"} assert
   module str.str?
   {'kind 'type 'msg "pkg.owns-prefix? expects two package names"} assert
   package name?
   {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
   module name?
   {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
   package module match?
   module package "." cat str.starts?
   or)
  call)
 (package-name module-name -- bool :
  "Return 1 when a package owns a module name: its own name, or a name continuing after a dot.

   The dot boundary is the whole point — `foo` owns `foo.bar` and does not own `foobar`.")
 'owns-prefix? def

 ### def related?
 ((|left right| left right owns-prefix? right left owns-prefix? or) call)
 (left right -- bool : "Return 1 when either of two package names owns the other.")
 'related? defp

 ### def row-related?
 ((|index names| names index 1 + drop names index at (swap related?) partial each (1 =) any?) call)
 (index names -- bool : "Return 1 when one name is related to any name after it.")
 'row-related? defp

 ### def collides?
 ((|names| names len range names (row-related?) partial each (1 =) any?) call)
 (names -- bool :
  "Return 1 when two members of a name list own one another.

   Only later members are compared against each one, so each pair is tested once and a name is never
   compared with itself.")
 'collides? defp

 # --- inertness -----------------------------------------------------------

 ### def inert?
 ([(dup type 'word match?) (pop 0)
   (dup type 'dict match?) (vals (inert?) all?)
   (dup type 'list match?) ((inert?) all?)
   (pop 1)]
  cond)
 (value -- bool :
  "Return 1 when a value holds no executable reference anywhere inside it.

   A word is the whole of what is forbidden: a quotation is an ordinary list and is legal as data,
   so what this rejects is exactly what an evaluated manifest would have run. Depth is whatever the
   reader already accepted; no separate limit is imposed here.")
 'inert? defp

 ### def offending
 ((|key|
   {'kind 'domain 'msg "a manifest or lock holds only inert data"}
   'data
   key wrap ('key) swap compose dict-of
   put
   raise)
  call)
 (key -- : "Raise the inertness failure, naming the entry that carried an executable reference.")
 'offending defp

 ### def inert-entry
 (dup inert? (pop 0) (first offending) if)
 (pair -- flag :
  "Answer 0 for an inert entry and raise for one that is not, so a walk over `pairs` reports which
   key was at fault rather than that some key was.")
 'inert-entry defp

 # --- manifests -----------------------------------------------------------

 ### def manifest-keys
 # Every key a manifest has, and no others.
 ['format 'name 'version 'requires]
 'manifest-keys setp

 ### def requirement-keys
 # Every key a requirement has, and no others.
 ['version 'url 'hash]
 'requirement-keys setp

 ### def lock-keys
 # Every key a lock has, and no others.
 ['format 'root 'packages 'requires]
 'lock-keys setp

 ### def keys-exactly?
 ((|candidate declared|
   candidate keys len declared len =
   declared candidate (swap has?) partial all?
   and)
  call)
 (candidate declared -- bool :
  "Return 1 when a dict's keys are exactly the declared ones.

   Dict keys are unique, so equal counts plus containment is set equality; order is not compared,
   because a hand-written manifest should not have to guess one.")
 'keys-exactly? defp

 ### def requirement-checked
 ((|requirement|
   requirement type 'dict match?
   {'kind 'type 'msg "a requirement is a dict"} assert
   requirement requirement-keys keys-exactly?
   {'kind 'domain 'msg "a requirement has exactly the keys 'version 'url 'hash"} assert
   requirement 'version at version-checked pop
   requirement 'url at url?
   {'kind 'domain 'msg "a requirement url is an https url"} assert
   requirement 'hash at hash?
   {'kind 'domain 'msg "a requirement hash is sha256- and 64 lowercase hex digits"} assert
   requirement)
  call)
 (requirement -- requirement :
  "Return a requirement unchanged, raising for any field the format does not admit.")
 'requirement-checked defp

 ### def validate-manifest
 ((|candidate|
   candidate type 'dict match?
   {'kind 'type 'msg "a manifest is a dict"} assert
   candidate pairs (inert-entry) each pop
   candidate manifest-keys keys-exactly?
   {'kind 'domain
    'msg "a manifest has exactly the keys 'format 'name 'version 'requires"}
   assert
   candidate 'format at 1 match?
   {'kind 'domain 'msg "the only manifest format is 1"} assert
   candidate 'name at name?
   {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
   candidate 'version at version-checked pop
   candidate 'requires at type 'dict match?
   {'kind 'type 'msg "manifest requirements are a dict from package name to requirement"} assert
   candidate 'requires at keys (name?) all?
   {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
   candidate 'requires at vals (requirement-checked) each pop
   candidate 'name at wrap candidate 'requires at keys cat collides? not
   {'kind 'domain 'msg "no package may own another's name, its own included"} assert
   candidate)
  call)
 (candidate -- manifest :
  "Return a manifest unchanged, or raise.

   Inertness is checked before anything else, so a candidate holding an executable reference is
   reported as that rather than as a bad key — and no part of it is ever evaluated. The name checks
   run last together, because self-requirement and a prefix collision are the same question.")
 'validate-manifest def

 ### def one-form
 ((|text|
   text str.str?
   {'kind 'type 'msg "pkg reads a package file from text"} assert
   text parse
   dup len 1 =
   {'kind 'shape 'msg "a package file is exactly one form"} assert
   first)
  call)
 (text -- form :
  "Read text as exactly one inert form.

   Unreadable text raises 'parse from the reader unchanged; the form is returned, never called.")
 'one-form defp

 ### def read-manifest
 (one-form validate-manifest)
 (text -- manifest : "Read and validate a manifest from text. The manifest is never evaluated.")
 'read-manifest def

 # --- locks ---------------------------------------------------------------

 ### def minimums-checked
 ((|minimums|
   minimums type 'dict match?
   {'kind 'type 'msg "a lock's requirements are a dict from package name to version"} assert
   minimums keys (name?) all?
   {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
   minimums vals (version-checked) each pop
   minimums)
  call)
 (minimums -- minimums :
  "Return one package's declared minimums unchanged, raising for a name or version the format does
   not admit.")
 'minimums-checked defp

 ### def known?
 ((|pair packages| packages pair first has?) call)
 (pair packages -- bool : "Return 1 when a required name has a selection in the lock.")
 'known? defp

 ### def satisfied?
 ((|pair packages| packages pair first at 'version at pair 1 at version< not) call)
 (pair packages -- bool : "Return 1 when a name's selected version is not below this minimum.")
 'satisfied? defp

 ### def lock-checked
 ((|candidate|
   candidate type 'dict match?
   {'kind 'type 'msg "a lock is a dict"} assert
   candidate pairs (inert-entry) each pop
   candidate lock-keys keys-exactly?
   {'kind 'domain
    'msg "a lock has exactly the keys 'format 'root 'packages 'requires"}
   assert
   candidate 'format at 1 match?
   {'kind 'domain 'msg "the only lock format is 1"} assert
   candidate 'root at name?
   {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
   candidate 'packages at type 'dict match?
   {'kind 'type 'msg "a lock's packages are a dict from package name to selection"} assert
   candidate 'packages at keys (name?) all?
   {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
   candidate 'packages at vals (requirement-checked) each pop
   candidate 'requires at type 'dict match?
   {'kind 'type 'msg "a lock's requirements are keyed by the requiring package"} assert
   candidate 'requires at keys (name?) all?
   {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
   candidate 'requires at vals (minimums-checked) each pop
   candidate 'requires at candidate 'root at has?
   {'kind 'domain 'msg "a lock records the root's own requirements under its name"} assert
   candidate 'requires at vals (pairs) each raze
   dup candidate 'packages at (known?) partial all?
   {'kind 'domain 'msg "every required package has a selection in the lock"} assert
   candidate 'packages at (satisfied?) partial all?
   {'kind 'domain 'msg "a selected version is never below a minimum recorded for it"} assert
   candidate)
  call)
 (candidate -- lock :
  "Return a lock unchanged, or raise.

   Beyond the grammar this enforces the two rules that make a lock usable without re-resolving:
   every required name has a selection, and no selection sits below a minimum recorded for it.")
 'lock-checked defp

 ### def read-lock
 (one-form lock-checked)
 (text -- lock : "Read and validate a lock from text. The lock is never evaluated.")
 'read-lock def

 ### def entry-of
 ((|key holder| key holder key at pair) call)
 (key holder -- pair : "Pair one key with its value.")
 'entry-of defp

 ### def sorted-entries
 ((|holder| holder keys sort holder (entry-of) partial each) call)
 (holder -- pairs :
  "A dict's entries in ascending key order, which is the order the lock is written in.")
 'sorted-entries defp

 ### def render-requirement
 ((|requirement|
   "{'version "
   requirement 'version at str
   " 'url "
   requirement 'url at str
   " 'hash "
   requirement 'hash at str
   "}"
   7 pack "" join)
  call)
 (requirement -- text : "Render one selection in the canonical field order.")
 'render-requirement defp

 ### def render-selection
 ((|pair| pair first str " " pair 1 at render-requirement 3 pack "" join) call)
 (pair -- text : "Render one `'packages` entry.")
 'render-selection defp

 ### def render-minimum
 ((|pair| pair first str " " pair 1 at str 3 pack "" join) call)
 (pair -- text : "Render one required name and its declared minimum.")
 'render-minimum defp

 ### def render-minimums
 ((|minimums| "{" minimums sorted-entries (render-minimum) each " " join "}" 3 pack "" join) call)
 (minimums -- text : "Render one package's minimums on a single line.")
 'render-minimums defp

 ### def render-requirer
 ((|pair| pair first str " " pair 1 at render-minimums 3 pack "" join) call)
 (pair -- text : "Render one `'requires` entry: the requiring package and what it declared.")
 'render-requirer defp

 ### def render-block
 ((|holder renderer| "{" holder sorted-entries renderer each "\n  " join "}" 3 pack "" join) call)
 (holder renderer -- text :
  "Render a dict as a block: the first entry beside the opening brace and every later one on its own
   indented line, so adding one entry is a one-line diff.")
 'render-block defp

 ### def write-lock
 (lock-checked
  (|lock|
   "{'format 1\n 'root "
   lock 'root at str
   "\n 'packages\n "
   lock 'packages at (render-selection) render-block
   "\n 'requires\n "
   lock 'requires at (render-requirer) render-block
   "}\n"
   7 pack "" join)
  call)
 (lock -- text :
  "Render a lock in its canonical layout.

   The lock is validated before anything is rendered, so an invalid one raises rather than producing
   partial text. Every scalar goes through `str`, which is the spelling that carries the round-trip
   guarantee, and the layout is fixed so that reading canonical text and writing it back reproduces
   its bytes — the closing newline included, because a lock is a file.")
 'write-lock def

 )
'pkg
@defm
