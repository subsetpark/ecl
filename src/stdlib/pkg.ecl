### module pkg
# Pure functions for validating and formatting `ecl.pkg` and `ecl.lock` data.
# This module accepts values and text. It does not read files, write files, or
# access the network. Parsed package data is validated but never evaluated.
#
# Predicates in `cond` may consume their inputs because each predicate starts
# from the same stack checkpoint.
(# Decimal digits.
 "0123456789"
 'digit-chars setp

 # Characters allowed in prerelease identifiers.
 "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
 'identifier-chars setp

 ### def chars-in?
 (|string characters|
  string empty? not
  string characters (in?) partial all?
  and)
 (string characters -- bool :
  "Test whether a string is nonempty and contains only the allowed characters.")
 'chars-in? defp

 ### def digits?
 (digit-chars chars-in?)
 (string -- bool : "Test whether a string is nonempty and contains only decimal digits.")
 'digits? defp

 ### def numeric-field?
 ([(digits? not) (pop 0)
   (len 1 =) (pop 1)
   (first \0 <>)]
  cond)
 (string -- bool : "Test whether a string is a decimal field with no leading zero, except for `0`.")
 'numeric-field? defp

 ### def identifier?
 (identifier-chars chars-in?)
 (string -- bool : "Test whether a string is a nonempty prerelease identifier.")
 'identifier? defp

 ### def prerelease-identifier?
 ([(identifier? not) (pop 0)
   (digits?) (numeric-field?)
   (pop 1)]
  cond)
 (string -- bool :
  "Test a prerelease identifier, including the no-leading-zero rule for numeric identifiers.")
 'prerelease-identifier? defp

 ### def hyphen-parts
 ("-" split)
 (candidate -- parts :
  "Split a version at hyphens. The first item is the core; later items make up the prerelease.")
 'hyphen-parts defp

 ### def core-fields
 (hyphen-parts first "." split)
 (candidate -- fields : "Return the dot-separated fields before the first hyphen.")
 'core-fields defp

 ### def identifiers
 (hyphen-parts dup len 1 = (pop []) (rest "-" join "." split) if)
 (candidate -- identifiers :
  "Return the dot-separated prerelease identifiers, or an empty list when none are present.")
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
 (candidate -- parts : "Validate a version and return `[core-fields prerelease-identifiers]`.")
 'version-checked defp

 ### def field-cmp
 (over len over len = (cmp) (swap len swap len cmp) if)
 (left right -- order : "Compare two validated decimal fields without converting them to integers.")
 'field-cmp defp

 ### def core-cmp
 ((field-cmp) lex-cmp)
 (left right -- order : "Compare validated major, minor, and patch fields in order.")
 'core-cmp defp

 ### def identifier-cmp
 ([(digits? swap digits? =) (over digits? (field-cmp) (cmp) if)
   (over digits? (pop pop -1) (pop pop 1) if)]
  cond)
 (left right -- order :
  "Compare two prerelease identifiers. Numeric identifiers sort before nonnumeric identifiers.")
 'identifier-cmp defp

 ### def prerelease-cmp
 ([(empty? swap empty? and) (pop pop 0)
   (pop empty?) (pop pop 1)
   (nip empty?) (pop pop -1)
   ((identifier-cmp) lex-cmp)]
  cond)
 (left right -- order :
  "Compare prereleases. A release version sorts after a version with the same core and a
   prerelease.")
 'prerelease-cmp defp

 ### def version-cmp
 (over first over first core-cmp
  dup 0 = (pop swap 1 at swap 1 at prerelease-cmp) (nip nip) if)
 (left right -- order : "Compare validated versions by core, then prerelease.")
 'version-cmp defp

 ### def version<
 (version-checked swap version-checked swap version-cmp -1 =)
 (left right -- bool :
  "Test whether the left version has lower SemVer 2.0.0 precedence. Invalid versions raise.")
 'version< def

 ### def keep-larger
 (over 1 at over 1 at version-cmp -1 = (nip) (pop) if)
 (accumulated candidate -- accumulated : "Return the entry with higher parsed version precedence.")
 'keep-larger defp

 ### def version-max
 (dup type 'list match?
  {'kind 'type 'msg "pkg.version-max expects a list of version strings"} assert
  dup empty? not
  {'kind 'shape 'msg "pkg.version-max needs at least one version"} assert
  dup (str.str?) all?
  {'kind 'type 'msg "pkg.version-max expects a list of version strings"} assert
  (dup version-checked pair) each
  dup first (keep-larger) fold
  first)
 (versions -- version :
  "Return the highest version in a nonempty list. Validate every item before comparing.")
 'version-max def

 # --- names ---------------------------------------------------------------

 ### def lead-chars
 # Valid first characters for a package-name segment.
 "abcdefghijklmnopqrstuvwxyz"
 'lead-chars setp

 ### def segment-chars
 # Valid later characters for a package-name segment.
 "-0123456789abcdefghijklmnopqrstuvwxyz"
 'segment-chars setp

 ### def hex-chars
 # Lowercase hexadecimal digits.
 "0123456789abcdef"
 'hex-chars setp

 ### def segment?
 (dup empty? (pop 0) ((first lead-chars in?) (segment-chars chars-in?) bi and) if)
 (text -- bool : "Test whether text is a valid package-name segment.")
 'segment? defp

 ### def name?
 ([(str.str? not) (pop 0)
   (empty?) (pop 0)
   ("." split (segment?) all?)]
  cond)
 (value -- bool :
  "Test whether a value is a dot-separated package name. Each segment starts with a lowercase letter
   and continues with lowercase letters, digits, or hyphens.")
 'name? defp

 ### def hash?
 ([(str.str? not) (pop 0)
   ("sha256-" str.starts? not) (pop 0)
   (7 drop (len 64 =) ((hex-chars in?) all?) bi and)]
  cond)
 (value -- bool : "Test for `sha256-` followed by exactly 64 lowercase hexadecimal digits.")
 'hash? defp

 ### def url?
 (dup str.str? (("https://" str.starts?) (len 8 >) bi and) (pop 0) if)
 (value -- bool : "Test for a nonempty HTTPS URL.")
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
  "Test whether a module name equals a package name or begins with that name followed by a dot.")
 'owns-prefix? def

 ### def related?
 ((|left right| left right owns-prefix? right left owns-prefix? or) call)
 (left right -- bool : "Test whether either package name owns the other as a prefix.")
 'related? defp

 ### def row-related?
 ((|index names| names index 1 + drop names index at (swap related?) partial each (1 =) any?) call)
 (index names -- bool : "Test one name against the names after it for prefix overlap.")
 'row-related? defp

 ### def collides?
 ((|names| names len range names (row-related?) partial each (1 =) any?) call)
 (names -- bool : "Test whether any two package names have overlapping owned prefixes.")
 'collides? defp

 # --- inertness -----------------------------------------------------------

 ### def inert?
 ([(type 'word match?) (pop 0)
   (type 'dict match?) (vals (inert?) all?)
   (type 'list match?) ((inert?) all?)
   (pop 1)]
  cond)
 (value -- bool : "Test recursively whether a value contains no executable word values.")
 'inert? defp

 ### def offending
 ((|key|
   {'kind 'domain 'msg "a manifest or lock holds only inert data"}
   'data
   'key key pair dict-of
   put
   raise)
  call)
 (key -- : "Raise an inert-data error for a dict entry.")
 'offending defp

 ### def inert-entry
 (dup inert? (pop) (first offending) if)
 (pair -- : "Discard an inert entry, or raise an error that names its key.")
 'inert-entry defp

 # --- manifests -----------------------------------------------------------

 ### def manifest-keys
 # Required manifest keys.
 ['format 'name 'version 'requires]
 'manifest-keys setp

 ### def requirement-keys
 # Required package-requirement keys.
 ['version 'url 'hash]
 'requirement-keys setp

 ### def lock-keys
 # Required lock keys.
 ['format 'root 'packages 'requires]
 'lock-keys setp

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
 (requirement -- requirement : "Validate and return a package requirement.")
 'requirement-checked defp

 ### def validate-manifest
 ((|candidate|
   candidate type 'dict match?
   {'kind 'type 'msg "a manifest is a dict"} assert
   candidate pairs (inert-entry) for
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
   candidate 'requires at vals (requirement-checked pop) for
   candidate 'name at wrap candidate 'requires at keys cat collides? not
   {'kind 'domain 'msg "no package may own another's name, its own included"} assert
   candidate)
  call)
 (candidate -- manifest :
  "Validate and return a manifest. Executable word values are rejected before structural checks.")
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
 (text -- form : "Parse text containing exactly one form and return it without evaluation.")
 'one-form defp

 ### def read-manifest
 (one-form validate-manifest)
 (text -- manifest : "Parse and validate a manifest without evaluating it.")
 'read-manifest def

 # --- locks ---------------------------------------------------------------

 ### def minimums-checked
 ((|minimums|
   minimums type 'dict match?
   {'kind 'type 'msg "a lock's requirements are a dict from package name to version"} assert
   minimums keys (name?) all?
   {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
   minimums vals (version-checked pop) for
   minimums)
  call)
 (minimums -- minimums : "Validate and return one package's minimum-version requirements.")
 'minimums-checked defp

 ### def known?
 ((|pair packages| packages pair first has?) call)
 (pair packages -- bool : "Test whether a required package has a locked selection.")
 'known? defp

 ### def satisfied?
 ((|pair packages| packages pair first at 'version at pair 1 at version< not) call)
 (pair packages -- bool : "Test whether a locked version meets a minimum version.")
 'satisfied? defp

 ### def lock-checked
 ((|candidate|
   candidate type 'dict match?
   {'kind 'type 'msg "a lock is a dict"} assert
   candidate pairs (inert-entry) for
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
   candidate 'packages at vals (requirement-checked pop) for
   candidate 'requires at type 'dict match?
   {'kind 'type 'msg "a lock's requirements are keyed by the requiring package"} assert
   candidate 'requires at keys (name?) all?
   {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
   candidate 'requires at vals (minimums-checked pop) for
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
  "Validate and return a lock. Each required package must have a selection that meets every recorded
   minimum version.")
 'lock-checked defp

 ### def read-lock
 (one-form lock-checked)
 (text -- lock : "Parse and validate a lock without evaluating it.")
 'read-lock def

 ### def entry-of
 ((|key holder| key holder key at pair) call)
 (key holder -- pair : "Return a key and its value as a pair.")
 'entry-of defp

 ### def sorted-entries
 ((|holder| holder keys sort holder (entry-of) partial each) call)
 (holder -- pairs : "Return a dict's entries in ascending key order.")
 'sorted-entries defp

 ### def render-requirement
 ((|requirement|
   requirement 'version at
   requirement 'url at
   requirement 'hash at
   3 pack "{{'version {} 'url {} 'hash {}}}" format)
  call)
 (requirement -- text : "Render one selection in the canonical field order.")
 'render-requirement defp

 ### def render-selection
 ((|pair| pair first str " " pair 1 at render-requirement 3 pack raze) call)
 (pair -- text : "Render one `packages` entry.")
 'render-selection defp

 ### def render-minimum
 ((|pair| pair first pair 1 at 2 pack "{} {}" format) call)
 (pair -- text : "Render one package name and minimum version.")
 'render-minimum defp

 ### def render-minimums
 ((|minimums| "{" minimums sorted-entries (render-minimum) each " " join "}" 3 pack raze) call)
 (minimums -- text : "Render one package's minimum versions on a single line.")
 'render-minimums defp

 ### def render-requirer
 ((|pair| pair first str " " pair 1 at render-minimums 3 pack raze) call)
 (pair -- text : "Render one `requires` entry.")
 'render-requirer defp

 ### def render-block
 ((|holder renderer| "{" holder sorted-entries renderer each "\n  " join "}" 3 pack raze) call)
 (holder renderer -- text : "Render a dict as an indented block.")
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
   7 pack raze)
  call)
 (lock -- text :
  "Validate a lock and render canonical text. Keys are sorted and the output ends with a newline.")
 'write-lock def

 )
'pkg
@defm
