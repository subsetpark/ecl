### module result
# The result module: composition over the core {'ok values} / {'err error}
# representation that `@attempt` already produces.
#
# A success payload is always a list standing for a stack, never one
# privileged scalar, so `and-then` can seed it straight back through
# `with @attempt`. Every word validates its result argument before running any
# quotation the caller supplied.
#
# The boundary: every word that *interprets* an envelope lives here. The words
# that *produce* an error — raise, fail, assert — stay core, because an error
# dict in flight is not a result. It becomes one only when @attempt or await
# reifies it.
(
 ### def checked
 (dup type 'dict match?
  {'kind 'type 'msg "a result must be a dict tagged {'ok values} or {'err error}"} assert
  dup keys len 1 =
  {'kind 'type 'msg "a result must carry exactly one of 'ok or 'err"} assert
  dup 'ok has?
  (dup 'ok at type 'list match?
   {'kind 'type 'msg "an ok result must carry a list of success values"} assert)
  (dup 'err has?
   {'kind 'type 'msg "a result must carry exactly one of 'ok or 'err"} assert
   dup 'err at type 'dict match?
   {'kind 'type 'msg "an err result must carry an error dict"} assert)
  if)
 (result -- result :
  "Return a tagged result unchanged, raising before any caller quotation runs when it is
   malformed.")
 'checked defp

 ### def checked-all
 (dup type 'list match?
  {'kind 'type 'msg "expected a list of results"} assert
  dup (checked pop) for)
 (results -- results :
  "Return a list of results unchanged, raising when the list or any member is malformed.")
 'checked-all defp

 ### def ok
 (dup type 'list match?
  {'kind 'type 'msg "result.ok expects a list of success values"} assert
  'ok swap pair dict-of)
 (values -- result :
  "Tag a list of success values, which stands for the stack a successful computation left.")
 'ok def

 ### def err
 (dup type 'dict match?
  {'kind 'type 'msg "result.err expects an error dict"} assert
  'err swap pair dict-of)
 (error -- result : "Tag an error dict as a failed result.")
 'err def

 ### def ok?
 (checked 'ok has?)
 (result -- bool : "Return 1 when a well-formed result is a success.")
 'ok? def

 ### def err?
 (checked 'err has?)
 (result -- bool : "Return 1 when a well-formed result is a failure.")
 'err? def

 ### def or-raise
 (checked dup 'ok has? ('ok at) ('err at raise) if)
 (result -- values : "Return a success payload, or re-raise the captured error dict unchanged.")
 'or-raise def

 ### def or-else
 (swap checked swap over 'ok has? (pop 'ok at) (nip) if)
 (result fallback -- value :
  "Return a success payload, or the fallback value when the result is a failure.")
 'or-else def

 ### def and-then
 (swap checked swap over 'ok has?
  (swap 'ok at swap with @attempt)
  (pop)
  if)
 (result quotation -- result :
  "Seed a success payload back onto an isolated stack and run the quotation, returning an existing
   failure unchanged.

   There is no separate map: @attempt's automatic {'ok [...]} wrapping collapses the functor map and
   the monadic bind into this one word on the success side. The distinction survives only on the
   failure side, which is why that side carries both map-err, which rewraps and never leaves the
   failure arm, and recover, which can replace the outcome.")
 'and-then def

 ### def map-err
 (swap checked swap over 'err has?
  (swap 'err at wrap swap with @attempt
   dup 'ok has?
   ('ok at dup len 1 =
    {'kind 'contract 'msg "result.map-err expects ( error -- error )"} assert
    first dup type 'dict match?
    {'kind 'type 'msg "result.map-err must produce an error dict"} assert
    err)
   when)
  (pop)
  if)
 (result quotation -- result :
  "Replace a failure's error dict with the one its ( error -- error ) quotation returns, leaving a
   success unchanged.")
 'map-err def

 ### def recover
 (swap checked swap over 'err has?
  (swap 'err at wrap swap with @attempt)
  (pop)
  if)
 (result quotation -- result :
  "Seed a failure's error dict onto an isolated stack and run the recovery quotation, leaving a
   success unchanged.")
 'recover def

 ### def recover-kinds
 ((|result kinds handler|
   result checked pop
   kinds type 'list match?
   {'kind 'type 'msg "result.recover-kinds expects a list of kind symbols"} assert
   kinds
   (type 'symbol match?
    {'kind 'type 'msg "result.recover-kinds expects a list of kind symbols"} assert)
   for
   result 'err {} at-or 'kind 'no-kind-present at-or kinds in?
   result 'err has? and
   result handler pair (recover) with
   result literal
   if)
  call)
 (result kinds quotation -- result :
  "Recover only when a failure's kind is one of the listed symbols, leaving every other result
   unchanged.")
 'recover-kinds def

 ### def either
 ((|result on-ok on-err|
   result checked pop
   result 'ok has?
   result ('ok at) partial on-ok compose
   result ('err at) partial on-err compose
   if)
  call)
 (result on-ok on-err -- ... :
  "Eliminate a result exhaustively: push its success list and call the first quotation, or push its
   error dict and call the second. Neither branch is isolated, so a branch may leave any number of
   values and its failures propagate.")
 'either def

 ### def all
 (checked-all
  dup ('err has?) each where
  dup len 0 >
  (first at)
  (pop ('ok at) each ok)
  if)
 (results -- result :
  "Return the leftmost failure unchanged, or one success holding every result's success list in
   input order.")
 'all def

 ### def partition
 (checked-all
  dup ('ok has?) filter ('ok at) each
  swap ('err has?) filter ('err at) each)
 (results -- successes errors :
  "Split results into success lists and error dicts, both in input order, without re-raising.")
 'partition def

 )
'result
@module
