### module str
(: "All case and whitespace operations use the ASCII character classes; every non-ASCII scalar
    passes through unchanged.")
(
 `str.core [format] import

 ### setp blanks
 (-- string : "Return the ASCII whitespace characters recognized by trimming operations.")
 " \t\n\u{B}\u{C}\u{D}" `blanks setp

 ### defp type-error
 (message -- error : "Build a type error with the given message.")
 (`type error.new swap error.with-message) `type-error defp

 ### def str?
 (value -- bool :
  "Return 1 when a value is a string, a list whose every element is a char, and 0 for every other
   value. The empty string answers 1, and so does the empty list: they are one value. Never
   raises.")
 (dup str.core.kind [string (pop 1) generic ((type `char match?) all?) (pop pop 0)] case) `str? def

 ### defp checked-error
 (candidate failure -- string :
  "Validate and return a string, using the supplied error on failure.")
 (|candidate failure| candidate str? failure assert candidate) `checked-error defp

 ### defp checked
 (candidate message -- string : "Validate and return a string, using the message for a type error.")
 (type-error checked-error) `checked defp

 ### defp checked-int
 (candidate failure -- integer :
  "Validate and return an integer, using the supplied error on failure.")
 (|candidate failure| candidate type `int match? failure assert candidate) `checked-int defp

 ### defp checked-pair
 (first second message -- first second : "Validate and return two strings.")
 (|a b message| a message checked pop b message checked pop a b) `checked-pair defp

 ### defp checked-triple
 (first second third message -- first second third : "Validate and return three strings.")
 (|a b c message|
  a message checked pop b message checked pop c message checked pop a b c) `checked-triple defp

 ### defp checked-string-int
 (text integer message -- text integer : "Validate and return a string and an integer.")
 (|text integer message|
  text message checked pop integer message type-error checked-int pop text integer)
 `checked-string-int defp

 ### def upper
 (string -- string : "Uppercase ASCII letters, leaving every other scalar unchanged.")
 ("str.upper expects a string" checked
  dup dup \a >= swap \z <= and 32 * - char) `upper def

 ### def lower
 (string -- string : "Lowercase ASCII letters, leaving every other scalar unchanged.")
 ("str.lower expects a string" checked
  dup dup \A >= swap \Z <= and 32 * + char) `lower def

 ### defp trim-left-valid
 (string -- string : "Remove leading ASCII whitespace from a validated string.")
 (dup blanks in? not where dup len 0 =
  (pop pop "")
  (first drop)
  if) `trim-left-valid defp

 ### def trim-left
 (string -- string : "Remove leading ASCII whitespace.")
 ("str.trim-left expects a string" checked trim-left-valid) `trim-left def

 ### defp trim-right-valid
 (string -- string : "Remove trailing ASCII whitespace from a validated string.")
 (dup blanks in? not where dup len 0 =
  (pop pop "")
  (last 1 + take)
  if) `trim-right-valid defp

 ### def trim-right
 (string -- string : "Remove trailing ASCII whitespace.")
 ("str.trim-right expects a string" checked trim-right-valid) `trim-right def

 ### def trim
 (string -- string : "Remove ASCII whitespace from both ends of a string.")
 ("str.trim expects a string" checked trim-left-valid trim-right-valid) `trim def

 ### defp opens-with?
 (string prefix -- bool : "Compare a validated string with a prefix no longer than the string.")
 (|s p| s p len take p match?) `opens-with? defp

 ### defp closes-with?
 (string suffix -- bool : "Compare a validated string with a suffix no longer than the string.")
 (|s p| s p len neg take p match?) `closes-with? defp

 ### defp starts-valid?
 (string prefix -- bool : "Return 1 when a validated string starts with a validated prefix.")
 (|s p| s p s len p len >= (opens-with?) (pop pop 0) if) `starts-valid? defp

 ### def starts?
 (string prefix -- bool : "Return 1 when the string starts with the prefix.")
 ("str.starts? expects a string and a string prefix" checked-pair starts-valid?) `starts? def

 ### defp ends-valid?
 (string suffix -- bool : "Return 1 when a validated string ends with a validated suffix.")
 (|s p| s p s len p len >= (closes-with?) (pop pop 0) if) `ends-valid? defp

 ### def ends?
 (string suffix -- bool : "Return 1 when the string ends with the suffix.")
 ("str.ends? expects a string and a string suffix" checked-pair ends-valid?) `ends? def

 ### defp contains-valid?
 (string needle -- bool : "Return 1 when a validated needle occurs in a validated string.")
 (|s n| n len 0 = s n split len 1 > or) `contains-valid? defp

 ### def contains?
 (string needle -- bool :
  "Return 1 when a needle occurs anywhere in a string. The empty needle is present at index zero.")
 ("str.contains? expects a string and a string needle" checked-pair contains-valid?)
 `contains? def

 ### defp index-of-valid
 (string needle -- index : "Find a validated needle's first occurrence in a validated string.")
 (|s n| s n n len 0 =
  (pop pop 0)
  (split dup len 1 >
   `domain error.new "str.index-of found no occurrence of the needle" error.with-message assert
   first len)
  if) `index-of-valid defp

 ### def index-of
 (string needle -- index :
  "Return the zero-based index of a needle's first occurrence. Return 0 for the empty needle and
   raise `` `domain `` when a nonempty needle is absent.")
 ("str.index-of expects a string and a string needle" checked-pair index-of-valid) `index-of def

 ### defp replace-valid
 (string needle replacement -- string : "Replace occurrences in validated strings.")
 (|s n r| s n split r join) `replace-valid defp

 ### def replace
 (string needle replacement -- string :
  "Replace every occurrence of a needle. An empty needle inserts the replacement between adjacent
   scalars only, with no boundary insertion.")
 ("str.replace expects string, needle, and replacement strings" checked-triple replace-valid)
 `replace def

 ### defp repeat-valid
 (string count -- string : "Repeat a validated string a validated number of times.")
 (|s n| n 0 >=
  `domain error.new "str.repeat requires a nonnegative count" error.with-message assert
  s n n 0 > s len 0 > and
  (over len * take)
  (pop pop "")
  if) `repeat-valid defp

 ### def repeat
 (string count -- string : "Concatenate `count` copies of a string; `count` must be nonnegative.")
 ("str.repeat expects a string and an integer count" checked-string-int repeat-valid) `repeat def

 ### def pad-left
 (string width -- string :
  "Add leading spaces until the string reaches the requested width; return a longer string
   unchanged.")
 ("str.pad-left expects a string and an integer width" checked-string-int
  over len - 0 max " " swap take swap pair raze) `pad-left def

 ### def pad-right
 (string width -- string :
  "Add trailing spaces until the string reaches the requested width; return a longer string
   unchanged.")
 ("str.pad-right expects a string and an integer width" checked-string-int
  over len - 0 max " " swap take pair raze) `pad-right def

) `str @defm
