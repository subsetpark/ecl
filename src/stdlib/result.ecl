### module result
(: "Results have the `{ok values}` or `{err error}` form produced by `@attempt` and `task.await`.
    Every entry validates its result envelope before invoking a caller quotation. A success payload
    is always a list representing a stack.

    Each word has one role. Transformers return a result and run their quotation isolated under
    `@attempt`, so a quotation that fails yields a failed result. Eliminators leave plain values and
    run their quotations inline, so they can reach the stack beneath the result.

    - Construct: `ok`, `err`.
    - Test: `ok?`, `err?`.
    - Transform the success: `map`.
    - Transform the failure: `recover`, `recover-kinds`, `map-err`.
    - Eliminate: `either`, `or-raise`, `or-default`.
    - Combine: `all`, `partition`.

    `map` replaces the success stack with what its quotation leaves, and a raising quotation turns
    the success into a failure. `recover` may likewise turn a failure into a success; `map-err`
    always keeps a failure and replaces only the error dict. `or-default` returns the success list
    or, on failure, the fallback value as given.

    `raise`, `fail`, and `assert` operate on errors directly and remain core words.")
[]
(
 ### defp checked
 (result -- result : "Validate and return a result.")
 (dup type `dict match?
  `type error.new "a result must be a dict tagged {ok values} or {err error}" error.with-message
  assert
  dup dict.size 1 =
  `type error.new "a result must carry exactly one of `ok or `err" error.with-message assert
  dup `ok dict.has?
  (dup `ok at type `list match?
   `type error.new "an ok result must carry a list of success values" error.with-message assert)
  (dup `err dict.has?
   `type error.new "a result must carry exactly one of `ok or `err" error.with-message assert
   dup `err at error.valid?
   `type error.new "an err result must carry an error dict" error.with-message assert)
  if) `checked defp

 ### defp checked-all
 (results -- results : "Validate and return a list of results.")
 (dup type `list match?
  `type error.new "expected a list of results" error.with-message assert
  dup (checked pop) for) `checked-all defp

 ### def ok
 (values -- result :
  "Build an ok result from a list of successful stack values, representing the stack a successful
   computation left.")
 (dup type `list match?
  `type error.new "result.ok expects a list of success values" error.with-message assert
  `ok swap pair dict.from-flat) `ok def

 ### def err
 (error -- result : "Tag an error dict as a failed result.")
 (dup error.valid?
  `type error.new "result.err expects an error dict" error.with-message assert
  `err swap pair dict.from-flat) `err def

 ### def ok?
 (result -- bool : "Return 1 when a well-formed result is a success.")
 (checked `ok dict.has?) `ok? def

 ### def err?
 (result -- bool : "Return 1 when a well-formed result is a failure.")
 (checked `err dict.has?) `err? def

 ### def or-raise
 (result -- values : "Return a success list, or re-raise the stored error dict unchanged.")
 (checked dup `ok dict.has? (`ok at) (`err at raise) if) `or-raise def

 ### def or-default
 (result fallback -- value : "Return a success list, or the fallback value for a failure.")
 (swap checked swap over `ok dict.has? (pop `ok at) (nip) if) `or-default def

 ### def map
 (result quotation -- result :
  "For a success, use its payload as the explicit values list for `@attempt`, running the quotation
   on an isolated stack seeded with the success values. Return a failure unchanged.")
 (swap checked swap over `ok dict.has?
  (swap `ok at swap @attempt)
  (pop)
  if) `map def

 ### def map-err
 (result (error -- error) -- result :
  "Replace a failure's error dict with the one its isolated quotation returns. Return a success
   unchanged.")
 (swap checked swap over `err dict.has?
  (swap `err at wrap swap @attempt
   dup `ok dict.has?
   (`ok at dup len 1 =
    `contract error.new "result.map-err expects ( error -- error )" error.with-message assert
    first dup error.valid?
    `type error.new "result.map-err must produce an error dict" error.with-message assert
    err)
   when)
  (pop)
  if) `map-err def

 ### def recover
 (result quotation -- result :
  "For a failure, run the recovery quotation under `@attempt` on an isolated stack seeded with the
   stored error dict. Return a success unchanged.")
 (swap checked swap over `err dict.has?
  (swap `err at wrap swap @attempt)
  (pop)
  if) `recover def

 ### def recover-kinds
 (result kinds quotation -- result :
  "Recover a failure only when its kind is one of the listed symbols. Return every other result
   unchanged.")
 (|result kinds handler|
  result checked pop
  kinds type `list match?
  `type error.new "result.recover-kinds expects a list of kind symbols" error.with-message assert
  kinds
  (type `symbol match?
   `type error.new "result.recover-kinds expects a list of kind symbols" error.with-message assert)
  for
  result `err {} dict.get
  dup error.valid?
  kinds (error.kind-in?) cons
  (pop 0)
  if
  result `err dict.has? and
  result handler pair (recover) with
  result wrap
  if) `recover-kinds def

 ### def either
 (result on-ok on-err -- ... :
  "Eliminate a result exhaustively: call `on-ok` with the success list or `on-err` with the error
   dict. Neither branch is isolated; each runs inline and may leave any number of values.")
 (|result on-ok on-err|
  result checked pop
  result `ok dict.has?
  result (`ok at) cons on-ok cat
  result (`err at) cons on-err cat
  if) `either def

 ### def all
 (results -- result :
  "Return the leftmost failure unchanged, or one success whose value is the list of success stacks
   in input order.")
 (checked-all
  dup (`err dict.has?) each where
  dup len 0 >
  (first at)
  (pop (`ok at) each ok)
  if) `all def

 ### def partition
 (results -- successes errors :
  "Split results into success lists and error dicts, both in input order, without re-raising.")
 (checked-all (`ok dict.has?) core.partition
  ((`ok at) each) dip (`err at) each) `partition def

) `result @defm
