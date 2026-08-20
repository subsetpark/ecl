### module str
# The str module: the awk/sed text floor over core kernels.
#
# Case mapping is ASCII-only by ruling: a non-ASCII scalar passes through
# untouched rather than being folded by a locale nobody chose. Both cases are
# written as pervasive char arithmetic, so they walk the string once through
# the ordinary kernels instead of a host fast path.
(
 ### def blanks
 (" \t\n\u{B}\u{C}\u{D}")
 (-- string : "The ASCII whitespace scalars the trimming words recognize.")
 'blanks defp

 ### def type-error
 (wrap ('kind 'type 'msg) swap compose dict-of)
 (message -- error : "Build the caller-specific type error used by a public string word.")
 'type-error defp

 ### def checked-error
 ((|candidate failure|
   candidate type 'list match? failure assert
   candidate (type 'char match?) all? failure assert
   candidate)
  call)
 (candidate failure -- string :
  "Return a rank-1 character vector unchanged, using the supplied error when validation fails.")
 'checked-error defp

 ### def checked
 (type-error checked-error)
 (candidate message -- string :
  "Return a string unchanged, raising a type error carrying the caller-specific message.")
 'checked defp

 ### def checked-int
 ((|candidate failure| candidate type 'int match? failure assert candidate) call)
 (candidate failure -- integer :
  "Return an integer unchanged, using the supplied error when validation fails.")
 'checked-int defp

 ### def checked-pair
 (type-error (|a b failure| a failure checked-error pop b failure checked-error pop a b) call)
 (first second message -- first second :
  "Return two strings unchanged after validating both with one caller-specific error.")
 'checked-pair defp

 ### def checked-triple
 (type-error
  (|a b c failure|
   a failure checked-error pop b failure checked-error pop c failure checked-error pop a b c)
  call)
 (first second third message -- first second third :
  "Return three strings unchanged after validating all with one caller-specific error.")
 'checked-triple defp

 ### def checked-string-int
 (type-error
  (|text integer failure|
   text failure checked-error pop integer failure checked-int pop text integer)
  call)
 (text integer message -- text integer :
  "Return a string and integer unchanged after validating both with one caller-specific error.")
 'checked-string-int defp

 ### def upper
 ("str.upper expects a string" checked
  dup dup \a >= swap \z <= and 32 * -)
 (string -- string :
  "Uppercase the ASCII letters in a string, leaving every other scalar unchanged.")
 'upper def

 ### def lower
 ("str.lower expects a string" checked
  dup dup \A >= swap \Z <= and 32 * +)
 (string -- string :
  "Lowercase the ASCII letters in a string, leaving every other scalar unchanged.")
 'lower def

 ### def trim-left-valid
 (dup blanks in? not where dup len 0 =
  (pop pop "")
  (first drop)
  if)
 (string -- string : "Remove leading ASCII whitespace from an already validated string.")
 'trim-left-valid defp

 ### def trim-left
 ("str.trim-left expects a string" checked trim-left-valid)
 (string -- string :
  "Remove leading ASCII whitespace, returning the empty string when every scalar is whitespace.")
 'trim-left def

 ### def trim-right-valid
 (dup blanks in? not where dup len 0 =
  (pop pop "")
  (last 1 + take)
  if)
 (string -- string : "Remove trailing ASCII whitespace from an already validated string.")
 'trim-right-valid defp

 ### def trim-right
 ("str.trim-right expects a string" checked trim-right-valid)
 (string -- string :
  "Remove trailing ASCII whitespace, returning the empty string when every scalar is whitespace.")
 'trim-right def

 ### def trim
 ("str.trim expects a string" checked trim-left-valid trim-right-valid)
 (string -- string : "Remove ASCII whitespace from both ends of a string.")
 'trim def

 ### def opens-with?
 ((|s p| s p len take p match?) call)
 (string prefix -- bool : "Compare a string's opening scalars with a prefix no longer than it.")
 'opens-with? defp

 ### def closes-with?
 ((|s p| s p len neg take p match?) call)
 (string suffix -- bool : "Compare a string's closing scalars with a suffix no longer than it.")
 'closes-with? defp

 ### def starts?
 ("str.starts? expects a string and a string prefix" checked-pair
  (|s p| s len p len >= s p pair (opens-with?) with (0) if) call)
 (string prefix -- bool : "Return 1 when a string begins with a prefix.")
 'starts? def

 ### def ends?
 ("str.ends? expects a string and a string suffix" checked-pair
  (|s p| s len p len >= s p pair (closes-with?) with (0) if) call)
 (string suffix -- bool : "Return 1 when a string ends with a suffix.")
 'ends? def

 ### def contains?
 ("str.contains? expects a string and a string needle" checked-pair
  (|s n| n len 0 = s n split len 1 > or) call)
 (string needle -- bool : "Return 1 when a needle occurs anywhere in a string, including empty.")
 'contains? def

 ### def index-of
 ("str.index-of expects a string and a string needle" checked-pair
  (|s n| n len 0 =
   (0)
   s n pair
   (split dup len 1 >
    {'kind 'domain 'msg "str.index-of found no occurrence of the needle"} assert
    first len)
   with
   if)
  call)
 (string needle -- index :
  "Return the zero-based index of a needle's first occurrence, raising 'domain when it is absent.")
 'index-of def

 ### def replace
 ("str.replace expects string, needle, and replacement strings" checked-triple
  (|s n r| s n split r join) call)
 (string needle replacement -- string :
  "Replace every occurrence of a needle with a replacement string.")
 'replace def

 ### def repeat
 ("str.repeat expects a string and an integer count" checked-string-int
  (|s n| n 0 >=
   {'kind 'domain 'msg "str.repeat requires a nonnegative count"} assert
   n 0 > s len 0 > and
   s s len n * pair (take) with
   ("")
   if)
  call)
 (string count -- string : "Concatenate a nonnegative number of copies of a string.")
 'repeat def

 ### def pad-left
 ("str.pad-left expects a string and an integer width" checked-string-int
  (|s w| " " w s len - 0 max take s pair raze) call)
 (string width -- string :
  "Pad a string with leading spaces up to a width, returning it unchanged when it is longer.")
 'pad-left def

 ### def pad-right
 ("str.pad-right expects a string and an integer width" checked-string-int
  (|s w| s " " w s len - 0 max take pair raze) call)
 (string width -- string :
  "Pad a string with trailing spaces up to a width, returning it unchanged when it is longer.")
 'pad-right def

 )
'str
@defm
