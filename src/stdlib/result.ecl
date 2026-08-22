### module result
# Results have the same {'ok values} or {'err error} form produced by `@attempt`
# and `await`.
#
# The success payload is a list containing the values left on the successful
# stack. Operations that accept results validate their inputs before invoking a
# caller quotation.
#
# `raise`, `fail`, and `assert` operate on errors directly and remain core words.
(
 ### defp checked
 (result -- result : "Validate and return a result.")
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
 'checked defp

 ### defp checked-all
 (results -- results : "Validate and return a list of results.")
 (dup type 'list match?
  {'kind 'type 'msg "expected a list of results"} assert
  dup (checked pop) for)
 'checked-all defp

 ### def ok
 (values -- result : "Build an ok result from a list of successful stack values.")
 (dup type 'list match?
  {'kind 'type 'msg "result.ok expects a list of success values"} assert
  'ok swap pair dict-of)
 'ok def

 ### def err
 (error -- result : "Tag an error dict as a failed result.")
 (dup type 'dict match?
  {'kind 'type 'msg "result.err expects an error dict"} assert
  'err swap pair dict-of)
 'err def

 ### def ok?
 (result -- bool : "Return 1 for an ok result.")
 (checked 'ok has?)
 'ok? def

 ### def err?
 (result -- bool : "Return 1 for an err result.")
 (checked 'err has?)
 'err? def

 ### def or-raise
 (result -- values : "Return the success list or raise the stored error.")
 (checked dup 'ok has? ('ok at) ('err at raise) if)
 'or-raise def

 ### def or-else
 (result fallback -- value : "Return the success list or a fallback value for an err result.")
 (swap checked swap over 'ok has? (pop 'ok at) (nip) if)
 'or-else def

 ### def and-then
 (result quotation -- result :
  "For an ok result, run the quotation under @attempt on an isolated stack seeded with the success
   values. Return an err result unchanged.")
 (swap checked swap over 'ok has?
  (swap 'ok at swap with @attempt)
  (pop)
  if)
 'and-then def

 ### def map-err
 (result quotation -- result :
  "Apply an isolated ( error -- error ) quotation to an err result. Return an ok result unchanged.")
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
 'map-err def

 ### def recover
 (result quotation -- result :
  "For an err result, run the quotation under @attempt with the stored error. Return an ok result
   unchanged.")
 (swap checked swap over 'err has?
  (swap 'err at wrap swap with @attempt)
  (pop)
  if)
 'recover def

 ### def recover-kinds
 (result kinds quotation -- result :
  "Recover an err result when its kind is listed. Return all other results unchanged.")
 (|result kinds handler|
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
 'recover-kinds def

 ### def either
 (result on-ok on-err -- ... :
  "Call on-ok with the success list or on-err with the error dictionary. Branches run inline and may
   leave any number of values.")
 (|result on-ok on-err|
  result checked pop
  result 'ok has?
  result ('ok at) partial on-ok compose
  result ('err at) partial on-err compose
  if)
 'either def

 ### def all
 (results -- result :
  "Return the first err result, or an ok result containing all success lists in input order.")
 (checked-all
  dup ('err has?) each where
  dup len 0 >
  (first at)
  (pop ('ok at) each ok)
  if)
 'all def

 ### def partition
 (results -- successes errors :
  "Return the success lists and error dictionaries as separate lists in input order.")
 (checked-all
  dup ('ok has?) filter ('ok at) each
  swap ('err has?) filter ('err at) each)
 'partition def

 )
'result
@defm
