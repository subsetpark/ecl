### module str
(: "Operations on strings.")
(
 `str.core [str? format split join] import

 ### setp blanks
 (-- string : "The ASCII whitespace characters recognized by trimming operations.")
 " \t\n\u{B}\u{C}\u{D}" `blanks setp

 ### defp type-error
 (message -- error : "Build a type error with the given message.")
 (`type error.new swap error.with-message) `type-error defp

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
 (string -- string : "Uppercase the ASCII codepoints in `string`.")
 ("str.upper expects a string" checked
  dup dup \a >= swap \z <= and 32 * - char) `upper def

 ### def lower
 (string -- string : "Lowercase the ASCII codepoints in `string`.")
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
 (string prefix -- bool : "Return 1 when `string` starts with `prefix`.")
 ("str.starts? expects a string and a string prefix" checked-pair starts-valid?) `starts? def

 ### defp ends-valid?
 (string suffix -- bool : "Return 1 when a validated string ends with a validated suffix.")
 (|s p| s p s len p len >= (closes-with?) (pop pop 0) if) `ends-valid? defp

 ### def ends?
 (string suffix -- bool : "Return 1 when `string` ends with `suffix`.")
 ("str.ends? expects a string and a string suffix" checked-pair ends-valid?) `ends? def

 ### defp contains-valid?
 (string needle -- bool : "Return 1 when a validated needle occurs in a validated string.")
 (|s n| n len 0 = s n split len 1 > or) `contains-valid? defp

 ### def contains?
 (string needle -- bool :
  "Return 1 when `needle` occurs anywhere in `string`. Return 1 if `needle` is \"\".")
 ("str.contains? expects a string and a string needle" checked-pair contains-valid?)
 `contains? def

 ### def index-of
 (string needle -- index :
  "Return the index of `needle`'s first occurrence in `string`, or the length of `string` when
   `needle` does not occur. Return 0 when `needle` is \"\".")
 ("str.index-of expects a string and a string needle" checked-pair
  dup len 0 = (pop pop 0) (split first len) if) `index-of def

 ### defp replace-valid
 (string needle replacement -- string : "Replace occurrences in validated strings.")
 (|s n r| s n split r join) `replace-valid defp

 ### def replace
 (string needle replacement -- string :
  "Replace every occurrence of `needle` in `string`. An empty needle inserts the replacement between
   adjacent codepoints.")
 ("str.replace expects string, needle, and replacement strings" checked-triple replace-valid)
 `replace def

 ### def repeat
 (string count -- string : "Concatenate `count` copies of `string`.")
 ("str.repeat expects a string and an integer count" checked-string-int
  dup 0 >=
  `domain error.new "str.repeat requires a nonnegative count" error.with-message assert
  over len 0 > over 0 > and
  (over len * take)
  (pop pop "")
  if) `repeat def

 ### defp checked-pad
 (text width pad message -- text width pad :
  "Validate and return a string, an integer, and a char.")
 (|text width pad message|
  text width message checked-string-int pop pop
  pad type `char match? message type-error assert
  text width pad)
 `checked-pad defp

 ### defp padding
 (string width pad -- string fill :
  "Return `string` and the run of `pad` that brings it to `width`, empty when it is already that
   wide.")
 (|s w c| s c wrap w s len - 0 max take) `padding defp

 ### def pad-left
 (string width pad -- string :
  "Add leading copies of the char `pad` until `string` reaches `width`; return a longer string
   unchanged.")
 ("str.pad-left expects a string, an integer width, and a char" checked-pad
  padding swap pair raze) `pad-left def

 ### def pad-right
 (string width pad -- string :
  "Add trailing copies of the char `pad` until `string` reaches `width`; return a longer string
   unchanged.")
 ("str.pad-right expects a string, an integer width, and a char" checked-pad
  padding pair raze) `pad-right def

) `str @defm
