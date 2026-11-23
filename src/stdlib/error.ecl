### module error
# This module's own contract failures use schema literals so constructor
# validation cannot recursively call the constructor it is validating.
(: "Words for manipulating the conventional `error` dict.")
(
 `error.core [valid?] import

 ### defp text?
 (value -- bool : "Return 1 when a value is a string without loading the str module.")
 (dup type `list match? ((type `char match?) all?) (pop 0) if) `text? defp

 ### defp checked
 (error -- error : "Validate and return an error dictionary.")
 (dup valid?
  {kind type msg "expected a valid error dict"} assert) `checked defp

 ### def new
 (kind -- error : "Build the error dictionary `{kind kind}` from a kind symbol.")
 (dup type `symbol match?
  {kind type msg "error.new expects a kind symbol"} assert
  `kind swap pair dict.from-kvs) `new def

 ### def with-message
 (error message -- error : "Set the `` ` ``message field on `error` to `message`.")
 (|failure message|
  failure checked pop
  message text?
  {kind type msg "error.with-message expects a string message"} assert
  failure `msg message put) `with-message def

 ### def with-data
 (error data -- error :
  "Validate both dictionaries and return the error with `` `data `` set to `data`.")
 (|failure data|
  failure checked pop
  data type `dict match?
  {kind type msg "error.with-data expects a data dict"} assert
  failure `data data put) `with-data def

 ### def kind?
 (error kind -- bool : "Return 1 when `error` has the given kind symbol.")
 (|failure kind|
  failure checked pop
  kind type `symbol match?
  {kind type msg "error.kind? expects a kind symbol"} assert
  failure `kind at kind match?) `kind? def

 ### def kind-in?
 (error kinds -- bool : "Return 1 when `error`'s kind occurs in `kinds`.")
 (|failure kinds|
  failure checked pop
  kinds type `list match?
  {kind type msg "error.kind-in? expects a list of kind symbols"} assert
  kinds (type `symbol match?) all?
  {kind type msg "error.kind-in? expects a list of kind symbols"} assert
  failure `kind at kinds in?) `kind-in? def

) `error @defm
