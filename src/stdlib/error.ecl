### module error
# Errors are immutable dictionaries with a required symbol at 'kind and
# optional, typed diagnostic fields. Constructors preserve that ordinary-data
# representation; raising and catching remain core control effects.
# This module's own contract failures use schema literals so constructor
# validation cannot recursively call the constructor it is validating.
[]
(
 ### defp text?
 (value -- bool : "Return 1 when a value is a string without loading the str module.")
 (dup type 'list match? ((type 'char match?) all?) (pop 0) if) 'text? defp

 ### def valid?
 (value -- bool :
  "Return 1 when a value satisfies the error dictionary schema: a required symbol `'kind` and
   well-typed optional `'msg`, `'word`, `'trace`, and `'data` fields. Extra fields are allowed.")
 (dup type 'dict match?
  (dup 'kind dict.has?
   over 'kind 'missing dict.get type 'symbol match?
   and
   over 'msg dict.has? (over 'msg at text?) (1) if
   and
   over 'word dict.has? (over 'word at type 'symbol match?) (1) if
   and
   over 'trace dict.has?
   (over 'trace at dup type 'list match?
    ((type 'symbol match?) all?)
    (pop 0)
    if)
   (1)
   if
   and
   over 'data dict.has? (over 'data at type 'dict match?) (1) if
   and
   nip)
  (pop 0)
  if) 'valid? def

 ### defp checked
 (error -- error : "Validate and return an error dictionary.")
 (dup valid?
  {'kind 'type 'msg "expected a valid error dict"} assert) 'checked defp

 ### def new
 (kind -- error : "Build the error dictionary `{'kind kind}` from a kind symbol.")
 (dup type 'symbol match?
  {'kind 'type 'msg "error.new expects a kind symbol"} assert
  'kind swap pair dict.from-flat) 'new def

 ### def with-message
 (error message -- error :
  "Validate the error and string message and return the error with `'msg` set to `message`.")
 (|failure message|
  failure checked pop
  message text?
  {'kind 'type 'msg "error.with-message expects a string message"} assert
  failure 'msg message put) 'with-message def

 ### def with-data
 (error data -- error :
  "Validate both dictionaries and return the error with `'data` set to `data`.")
 (|failure data|
  failure checked pop
  data type 'dict match?
  {'kind 'type 'msg "error.with-data expects a data dict"} assert
  failure 'data data put) 'with-data def

 ### def kind?
 (error kind -- bool :
  "Validate both inputs and return 1 when the error has the given kind symbol.")
 (|failure kind|
  failure checked pop
  kind type 'symbol match?
  {'kind 'type 'msg "error.kind? expects a kind symbol"} assert
  failure 'kind at kind match?) 'kind? def

 ### def kind-in?
 (error kinds -- bool :
  "Validate an error and a list of kind symbols, then return 1 when the error's kind occurs in the
   list.")
 (|failure kinds|
  failure checked pop
  kinds type 'list match?
  {'kind 'type 'msg "error.kind-in? expects a list of kind symbols"} assert
  kinds (type 'symbol match?) all?
  {'kind 'type 'msg "error.kind-in? expects a list of kind symbols"} assert
  failure 'kind at kinds in?) 'kind-in? def

) 'error @defm
