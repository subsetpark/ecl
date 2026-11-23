### module result
(: "Operations on the conventional `result` dict.")
(
 ### defp checked
 (result -- result : "Validate and return a result.")
 (dup type `dict match?
  `type error.new "a result must be a dict tagged {ok values} or {err error}" error.with-message
  assert
  dup dict.size 1 =
  `type error.new "a result must carry exactly one of `ok or `err" error.with-message assert
  dup `ok has?
  (dup `ok at type `list match?
   `type error.new "an ok result must carry a list of success values" error.with-message assert)
  (dup `err has?
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
 (values -- result : "Wrap `values` in a successful result dict.")
 (dup type `list match?
  `type error.new "result.ok expects a list of success values" error.with-message assert
  `ok swap pair dict.from-kvs) `ok def

 ### def err
 (error -- result : "Wrap `error` in an unsuccessful result dict.")
 (dup error.valid?
  `type error.new "result.err expects an error dict" error.with-message assert
  `err swap pair dict.from-kvs) `err def

 ### def ok?
 (result -- bool : "Return 1 when a result is successful.")
 (checked `ok has?) `ok? def

 ### def err?
 (result -- bool : "Return 1 when a result is unsuccessful.")
 (checked `err has?) `err? def

 ### def or-raise
 (result -- values :
  "If `result` is successful, extract the success values; otherwise raise its error.")
 (checked dup `ok has? (`ok at) (`err at raise) if) `or-raise def

 ### def or-default
 (result default -- value :
  "If `result` is successful, extract the success values; otherwise return `default`.")
 (swap checked swap over `ok has? (pop `ok at) (nip) if) `or-default def

 ### def map
 (result quotation -- result :
  "If `result` is successful, then apply `quotation` to its values in a new unit and return a new
   result. Otherwise return `result` unchanged.")
 (swap checked swap over `ok has?
  (swap `ok at swap cat @attempt)
  (pop)
  if) `map def

 ### def map-err
 (result (q: error -- error) -- result :
  "If `result` is successful, return it unchanged. Otherwise apply `q` to its error and return a new
   unsuccessful result.")
 (swap checked swap over `err has?
  (swap `err at swap cons @attempt
   dup `ok has?
   (`ok at dup len 1 =
    `contract error.new "result.map-err expects ( error -- error )" error.with-message assert
    first dup error.valid?
    `type error.new "result.map-err must produce an error dict" error.with-message assert
    `err swap pair dict.from-kvs)
   when)
  (pop)
  if) `map-err def

 ### def recover
 (result quotation -- result :
  "If `result` is successful, return it unchanged. Otherwise apply `quotation` to its error and
   return a new result.")
 (swap checked swap over `err has?
  (swap `err at swap cons @attempt)
  (pop)
  if) `recover def

 ### def recover-kinds
 (result kinds quotation -- result :
  "Recover an unsuccessful result only when its kind is in `kinds`. Return every other result
   unchanged.")
 (|result kinds handler|
  result checked pop
  kinds type `list match?
  `type error.new "result.recover-kinds expects a list of kind symbols" error.with-message assert
  kinds
  (type `symbol match?
   `type error.new "result.recover-kinds expects a list of kind symbols" error.with-message assert)
  for
  result kinds over `err has? (swap `err at swap error.kind-in?) (pop pop 0) if
  result handler pair (recover) cat
  result wrap
  if) `recover-kinds def

 ### def either
 (result on-ok on-err -- ... :
  "If `result` is successful, apply `on-ok` to its values. Otherwise, apply `on-err` to its error.")
 (|result on-ok on-err|
  result checked pop
  result `ok has?
  result (`ok at) cons on-ok cat
  result (`err at) cons on-err cat
  if) `either def

 ### def all
 (results -- result :
  "Return the leftmost unsuccessful element of `results`, or a successful result containing the
   success values of all of `results`.")
 (checked-all
  dup (`err has?) each where
  dup len 0 >
  (first at)
  (pop (`ok at) each ok)
  if) `all def

 ### def partition
 (results -- successes errors :
  "Partition results into success lists and error dicts, both in input order, without re-raising.")
 (checked-all (`ok has?) core.partition
  ((`ok at) each) dip (`err at) each) `partition def

) `result @defm
