### module str
# String operations use ASCII case and whitespace rules. Case conversion leaves
# non-ASCII characters unchanged.
(
 ### def blanks
 (" \t\n\u{B}\u{C}\u{D}")
 (-- string : "Return the ASCII whitespace characters recognized by trimming operations.")
 'blanks defp

 ### def type-error
 (wrap ('kind 'type 'msg) swap compose dict-of)
 (message -- error : "Build a type error with the given message.")
 'type-error defp

 ### def str?
 (dup type 'list match? ((type 'char match?) all?) (pop 0) if)
 (value -- bool :
  "Return 1 for a list containing only characters and 0 for every other value.

   The empty string and empty list are the same value and return 1.")
 'str? def

 ### def checked-error
 (|candidate failure| candidate str? failure assert candidate)
 (candidate failure -- string :
  "Validate and return a string, using the supplied error on failure.")
 'checked-error defp

 ### def checked
 (type-error checked-error)
 (candidate message -- string : "Validate and return a string, using the message for a type error.")
 'checked defp

 ### def checked-int
 (|candidate failure| candidate type 'int match? failure assert candidate)
 (candidate failure -- integer :
  "Validate and return an integer, using the supplied error on failure.")
 'checked-int defp

 ### def checked-pair
 (type-error (|a b failure| a failure checked-error pop b failure checked-error pop a b) call)
 (first second message -- first second : "Validate and return two strings.")
 'checked-pair defp

 ### def checked-triple
 (type-error
  (|a b c failure|
   a failure checked-error pop b failure checked-error pop c failure checked-error pop a b c)
  call)
 (first second third message -- first second third : "Validate and return three strings.")
 'checked-triple defp

 ### def checked-string-int
 (type-error
  (|text integer failure|
   text failure checked-error pop integer failure checked-int pop text integer)
  call)
 (text integer message -- text integer : "Validate and return a string and an integer.")
 'checked-string-int defp

 ### def upper
 ("str.upper expects a string" checked
  dup dup \a >= swap \z <= and 32 * -)
 (string -- string : "Convert ASCII lowercase letters to uppercase.")
 'upper def

 ### def lower
 ("str.lower expects a string" checked
  dup dup \A >= swap \Z <= and 32 * +)
 (string -- string : "Convert ASCII uppercase letters to lowercase.")
 'lower def

 ### def trim-left-valid
 (dup blanks in? not where dup len 0 =
  (pop pop "")
  (first drop)
  if)
 (string -- string : "Remove leading ASCII whitespace from a validated string.")
 'trim-left-valid defp

 ### def trim-left
 ("str.trim-left expects a string" checked trim-left-valid)
 (string -- string : "Remove leading ASCII whitespace.")
 'trim-left def

 ### def trim-right-valid
 (dup blanks in? not where dup len 0 =
  (pop pop "")
  (last 1 + take)
  if)
 (string -- string : "Remove trailing ASCII whitespace from a validated string.")
 'trim-right-valid defp

 ### def trim-right
 ("str.trim-right expects a string" checked trim-right-valid)
 (string -- string : "Remove trailing ASCII whitespace.")
 'trim-right def

 ### def trim
 ("str.trim expects a string" checked trim-left-valid trim-right-valid)
 (string -- string : "Remove ASCII whitespace from both ends of a string.")
 'trim def

 ### def opens-with?
 (|s p| s p len take p match?)
 (string prefix -- bool : "Compare a validated string with a prefix no longer than the string.")
 'opens-with? defp

 ### def closes-with?
 (|s p| s p len neg take p match?)
 (string suffix -- bool : "Compare a validated string with a suffix no longer than the string.")
 'closes-with? defp

 ### def starts?
 ("str.starts? expects a string and a string prefix" checked-pair
  (|s p| s len p len >= s p pair (opens-with?) with (0) if) call)
 (string prefix -- bool : "Return 1 when the string starts with the prefix.")
 'starts? def

 ### def ends?
 ("str.ends? expects a string and a string suffix" checked-pair
  (|s p| s len p len >= s p pair (closes-with?) with (0) if) call)
 (string suffix -- bool : "Return 1 when the string ends with the suffix.")
 'ends? def

 ### def contains?
 ("str.contains? expects a string and a string needle" checked-pair
  (|s n| n len 0 = s n split len 1 > or) call)
 (string needle -- bool : "Return 1 when the needle occurs in the string. An empty needle matches.")
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
  "Return the index of the first occurrence of the needle. Raise 'domain when it is absent.")
 'index-of def

 ### def replace
 ("str.replace expects string, needle, and replacement strings" checked-triple
  (|s n r| s n split r join) call)
 (string needle replacement -- string : "Replace every occurrence of the needle.")
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
 (string count -- string : "Concatenate count copies of the string. Count must be nonnegative.")
 'repeat def

 ### def pad-left
 ("str.pad-left expects a string and an integer width" checked-string-int
  (|s w| " " w s len - 0 max take s pair raze) call)
 (string width -- string : "Add leading spaces until the string reaches the requested width.")
 'pad-left def

 ### def pad-right
 ("str.pad-right expects a string and an integer width" checked-string-int
  (|s w| s " " w s len - 0 max take pair raze) call)
 (string width -- string : "Add trailing spaces until the string reaches the requested width.")
 'pad-right def

 )
'str
@defm
