### module result
# Results have the same {'ok values} or {'err error} form produced by `@attempt`
# and `await`.
#
# The success payload is a list containing the values left on the successful
# stack. Operations that accept results validate their inputs before invoking a
# caller quotation.
#
# `raise`, `fail`, and `assert` operate on errors directly and remain core words.
[]
(
 ### defp checked
 (result -- result : "Validate and return a result.")
 (dup type 'dict match?
  'type error.new "a result must be a dict tagged {'ok values} or {'err error}" error.with-message
  assert
  dup dict.size 1 =
  'type error.new "a result must carry exactly one of 'ok or 'err" error.with-message assert
  dup 'ok dict.has?
  (dup 'ok at type 'list match?
   'type error.new "an ok result must carry a list of success values" error.with-message assert)
  (dup 'err dict.has?
   'type error.new "a result must carry exactly one of 'ok or 'err" error.with-message assert
   dup 'err at error.valid?
   'type error.new "an err result must carry an error dict" error.with-message assert)
  if)
 'checked defp

 ### defp checked-all
 (results -- results : "Validate and return a list of results.")
 (dup type 'list match?
  'type error.new "expected a list of results" error.with-message assert
  dup (checked pop) for)
 'checked-all defp

 ### def ok
 (values -- result : "Build an ok result from a list of successful stack values.")
 (dup type 'list match?
  'type error.new "result.ok expects a list of success values" error.with-message assert
  'ok swap pair dict.from-flat)
 'ok def

 ### def err
 (error -- result : "Tag an error dict as a failed result.")
 (dup error.valid?
  'type error.new "result.err expects an error dict" error.with-message assert
  'err swap pair dict.from-flat)
 'err def

 ### def ok?
 (result -- bool : "Return 1 for an ok result.")
 (checked 'ok dict.has?)
 'ok? def

 ### def err?
 (result -- bool : "Return 1 for an err result.")
 (checked 'err dict.has?)
 'err? def

 ### def or-raise
 (result -- values : "Return the success list or raise the stored error.")
 (checked dup 'ok dict.has? ('ok at) ('err at raise) if)
 'or-raise def

 ### def or-else
 (result fallback -- value : "Return the success list or a fallback value for an err result.")
 (swap checked swap over 'ok dict.has? (pop 'ok at) (nip) if)
 'or-else def

 ### def and-then
 (result quotation -- result :
  "For an ok result, run the quotation under @attempt on an isolated stack seeded with the success
   values. Return an err result unchanged.")
 (swap checked swap over 'ok dict.has?
  (swap 'ok at swap @attempt)
  (pop)
  if)
 'and-then def

 ### def map-err
 (result quotation -- result :
  "Apply an isolated ( error -- error ) quotation to an err result. Return an ok result unchanged.")
 (swap checked swap over 'err dict.has?
  (swap 'err at wrap swap @attempt
   dup 'ok dict.has?
   ('ok at dup len 1 =
    'contract error.new "result.map-err expects ( error -- error )" error.with-message assert
    first dup error.valid?
    'type error.new "result.map-err must produce an error dict" error.with-message assert
    err)
   when)
  (pop)
  if)
 'map-err def

 ### def recover
 (result quotation -- result :
  "For an err result, run the quotation under @attempt with the stored error. Return an ok result
   unchanged.")
 (swap checked swap over 'err dict.has?
  (swap 'err at wrap swap @attempt)
  (pop)
  if)
 'recover def

 ### def recover-kinds
 (result kinds quotation -- result :
  "Recover an err result when its kind is listed. Return all other results unchanged.")
 (|result kinds handler|
  result checked pop
  kinds type 'list match?
  'type error.new "result.recover-kinds expects a list of kind symbols" error.with-message assert
  kinds
  (type 'symbol match?
   'type error.new "result.recover-kinds expects a list of kind symbols" error.with-message assert)
  for
  result 'err {} at-or
  dup error.valid?
  kinds (error.kind-in?) partial
  (pop 0)
  if
  result 'err dict.has? and
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
  result 'ok dict.has?
  result ('ok at) partial on-ok compose
  result ('err at) partial on-err compose
  if)
 'either def

 ### def all
 (results -- result :
  "Return the first err result, or an ok result containing all success lists in input order.")
 (checked-all
  dup ('err dict.has?) each where
  dup len 0 >
  (first at)
  (pop ('ok at) each ok)
  if)
 'all def

 ### def partition
 (results -- successes errors :
  "Return the success lists and error dictionaries as separate lists in input order.")
 (checked-all
  dup ('ok dict.has?) filter ('ok at) each
  swap ('err dict.has?) filter ('err at) each)
 'partition def

) 'result @defm
