### module str
# String operations use ASCII case and whitespace rules. Case conversion leaves
# non-ASCII characters unchanged.
[]
(
 ### defp blanks
 (-- string : "Return the ASCII whitespace characters recognized by trimming operations.")
 (" \t\n\u{B}\u{C}\u{D}")
 'blanks defp

 ### defp type-error
 (message -- error : "Build a type error with the given message.")
 ('type error.new swap error.with-message)
 'type-error defp

 ### def str?
 (value -- bool :
  "Return 1 for a list containing only characters and 0 for every other value.

   The empty string and empty list are the same value and return 1.")
 (dup type 'list match? ((type 'char match?) all?) (pop 0) if)
 'str? def

 ### defp checked-error
 (candidate failure -- string :
  "Validate and return a string, using the supplied error on failure.")
 (|candidate failure| candidate str? failure assert candidate)
 'checked-error defp

 ### defp checked
 (candidate message -- string : "Validate and return a string, using the message for a type error.")
 (type-error checked-error)
 'checked defp

 ### defp checked-int
 (candidate failure -- integer :
  "Validate and return an integer, using the supplied error on failure.")
 (|candidate failure| candidate type 'int match? failure assert candidate)
 'checked-int defp

 ### defp checked-pair
 (first second message -- first second : "Validate and return two strings.")
 (type-error (|a b failure| a failure checked-error pop b failure checked-error pop a b) call)
 'checked-pair defp

 ### defp checked-triple
 (first second third message -- first second third : "Validate and return three strings.")
 (type-error
  (|a b c failure|
   a failure checked-error pop b failure checked-error pop c failure checked-error pop a b c)
  call)
 'checked-triple defp

 ### defp checked-string-int
 (text integer message -- text integer : "Validate and return a string and an integer.")
 (type-error
  (|text integer failure|
   text failure checked-error pop integer failure checked-int pop text integer)
  call)
 'checked-string-int defp

 ### def upper
 (string -- string : "Convert ASCII lowercase letters to uppercase.")
 ("str.upper expects a string" checked
  dup dup \a >= swap \z <= and 32 * -)
 'upper def

 ### def lower
 (string -- string : "Convert ASCII uppercase letters to lowercase.")
 ("str.lower expects a string" checked
  dup dup \A >= swap \Z <= and 32 * +)
 'lower def

 ### defp trim-left-valid
 (string -- string : "Remove leading ASCII whitespace from a validated string.")
 (dup blanks in? not where dup len 0 =
  (pop pop "")
  (first drop)
  if)
 'trim-left-valid defp

 ### def trim-left
 (string -- string : "Remove leading ASCII whitespace.")
 ("str.trim-left expects a string" checked trim-left-valid)
 'trim-left def

 ### defp trim-right-valid
 (string -- string : "Remove trailing ASCII whitespace from a validated string.")
 (dup blanks in? not where dup len 0 =
  (pop pop "")
  (last 1 + take)
  if)
 'trim-right-valid defp

 ### def trim-right
 (string -- string : "Remove trailing ASCII whitespace.")
 ("str.trim-right expects a string" checked trim-right-valid)
 'trim-right def

 ### def trim
 (string -- string : "Remove ASCII whitespace from both ends of a string.")
 ("str.trim expects a string" checked trim-left-valid trim-right-valid)
 'trim def

 ### defp opens-with?
 (string prefix -- bool : "Compare a validated string with a prefix no longer than the string.")
 (|s p| s p len take p match?)
 'opens-with? defp

 ### defp closes-with?
 (string suffix -- bool : "Compare a validated string with a suffix no longer than the string.")
 (|s p| s p len neg take p match?)
 'closes-with? defp

 ### def starts?
 (string prefix -- bool : "Return 1 when the string starts with the prefix.")
 ("str.starts? expects a string and a string prefix" checked-pair
  (|s p| s len p len >= s p pair (opens-with?) with (0) if) call)
 'starts? def

 ### def ends?
 (string suffix -- bool : "Return 1 when the string ends with the suffix.")
 ("str.ends? expects a string and a string suffix" checked-pair
  (|s p| s len p len >= s p pair (closes-with?) with (0) if) call)
 'ends? def

 ### def contains?
 (string needle -- bool : "Return 1 when the needle occurs in the string. An empty needle matches.")
 ("str.contains? expects a string and a string needle" checked-pair
  (|s n| n len 0 = s n split len 1 > or) call)
 'contains? def

 ### def index-of
 (string needle -- index :
  "Return the index of the first occurrence of the needle. Raise 'domain when it is absent.")
 ("str.index-of expects a string and a string needle" checked-pair
  (|s n| n len 0 =
   (0)
   s n pair
   (split dup len 1 >
    'domain error.new "str.index-of found no occurrence of the needle" error.with-message assert
    first len)
   with
   if)
  call)
 'index-of def

 ### def replace
 (string needle replacement -- string : "Replace every occurrence of the needle.")
 ("str.replace expects string, needle, and replacement strings" checked-triple
  (|s n r| s n split r join) call)
 'replace def

 ### def repeat
 (string count -- string : "Concatenate count copies of the string. Count must be nonnegative.")
 ("str.repeat expects a string and an integer count" checked-string-int
  (|s n| n 0 >=
   'domain error.new "str.repeat requires a nonnegative count" error.with-message assert
   n 0 > s len 0 > and
   s s len n * pair (take) with
   ("")
   if)
  call)
 'repeat def

 ### def pad-left
 (string width -- string : "Add leading spaces until the string reaches the requested width.")
 ("str.pad-left expects a string and an integer width" checked-string-int
  (|s w| " " w s len - 0 max take s pair raze) call)
 'pad-left def

 ### def pad-right
 (string width -- string : "Add trailing spaces until the string reaches the requested width.")
 ("str.pad-right expects a string and an integer width" checked-string-int
  (|s w| s " " w s len - 0 max take pair raze) call)
 'pad-right def

 ### defp format-fail
 (kind message -- : "Raise a formatting error with the supplied kind and message.")
 (swap error.new swap error.with-message 0 swap assert)
 'format-fail defp

 ### defp format-render
 (value -- string : "Render one replacement, preserving string contents verbatim.")
 (dup str? () (str) if)
 'format-render defp

 ### defp format-template-char
 (state offset -- char : "Read a character relative to the state's template cursor.")
 (|state offset| state 2 at state 3 at offset + at)
 'format-template-char defp

 ### defp format-advance
 (state count part -- state : "Advance the template cursor and append one rendered part.")
 (|state count part|
  state 3 state 3 at count + put
  4 state 4 at part append put)
 'format-advance defp

 ### defp format-finish
 (state -- string : "Validate the final replacement count and join the accumulated parts.")
 (dup 1 at over 0 at len =
  (4 at "" join)
  ('contract "format has more values than placeholders" format-fail)
  if)
 'format-finish defp

 ### defp format-placeholder-valid
 (state -- string : "Render one available replacement and continue scanning.")
 (dup 0 at over 1 at at format-render
  2 swap format-advance
  dup 1 at 1 + 1 swap put
  format-loop)
 'format-placeholder-valid defp

 ### defp format-placeholder
 (state -- string : "Validate and consume one positional placeholder.")
 (dup 1 at over 0 at len >=
  ('contract "format has more placeholders than values" format-fail)
  (format-placeholder-valid)
  if)
 'format-placeholder defp

 ### defp format-open
 (state -- string : "Interpret an opening brace at the template cursor.")
 (dup 3 at 1 + over 2 at len >=
  ('domain "format contains an unmatched brace" format-fail)
  (dup 1 format-template-char
   dup \{ =
   (pop 2 "{" format-advance format-loop)
   (\} =
    (format-placeholder)
    ('domain "format contains an unmatched brace" format-fail)
    if)
   if)
  if)
 'format-open defp

 ### defp format-close
 (state -- string : "Interpret a closing brace at the template cursor.")
 (dup 3 at 1 + over 2 at len >=
  ('domain "format contains an unmatched brace" format-fail)
  (dup 1 format-template-char \} =
   (2 "}" format-advance format-loop)
   ('domain "format contains an unmatched brace" format-fail)
   if)
  if)
 'format-close defp

 ### defp format-step
 (state -- string : "Interpret one template character and continue scanning.")
 (dup 0 format-template-char
  dup \{ =
  (pop format-open)
  (dup \} =
   (pop format-close)
   (wrap 1 swap format-advance format-loop)
   if)
  if)
 'format-step defp

 ### defp format-loop
 (state -- string : "Scan a validated template from one immutable cursor state.")
 (dup 3 at over 2 at len =
  (format-finish)
  (format-step)
  if)
 'format-loop defp

 ### defp format-valid
 (values template -- string :
  "Validate formatting inputs and interpolate them through the hosted scanner.")
 (|values template|
  values type 'list match?
  'type error.new "str.format expects a value list and a template string" error.with-message assert
  template "str.format expects a value list and a template string" checked pop
  values 0 template 0 () 5 pack format-loop)
 'format-valid defp

 ### def format
 (values template -- string :
  "Interpolate positional braces, preserving strings and canonically rendering other values.")
 (format-valid)
 'format def

) 'str @defm
