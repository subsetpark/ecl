### module stdlib.test.result
(
 'stdlib.test.support
 ('equal 'raises 'raises-containing 'documented)
 import

 ### test constructors-and-observations
 (-- : "Construct and observe the documented tagged result representation.")
 ([1 2] result.ok {'ok [1 2]} equal
  {'kind 'io} result.err {'err {'kind 'io}} equal
  [] result.ok {'ok ()} equal
  [7] result.ok {'ok [7]} equal
  [1] result.ok result.ok? 1 equal
  [1] result.ok result.err? 0 equal
  {'kind 'io} result.err result.ok? 0 equal
  {'kind 'io} result.err result.err? 1 equal
  (2 3 +) @attempt result.ok? 1 equal
  (missing) @attempt result.err? 1 equal
  (7 result.ok) 'type "expects a list" raises-containing
  (7 result.err) 'type "expects an error dict" raises-containing
  ({'kind 7} result.err) 'type "expects an error dict" raises-containing)
 'constructors-and-observations test

 ### test composition
 (-- : "Compose success stacks and transform only failures.")
 ([2 3] result.ok (+) result.and-then {'ok [5]} equal
  [] result.ok (42) result.and-then {'ok [42]} equal
  {'kind 'io 'msg "boom"} result.err (+) result.and-then
  {'err {'kind 'io 'msg "boom"}} equal
  [2 0] result.ok (/) result.and-then result.err? 1 equal
  [2 3] result.ok (+) result.and-then (10 *) result.and-then
  {'ok [50]} equal
  {'kind 'io} result.err (pop {'kind 'domain}) result.map-err
  {'err {'kind 'domain}} equal
  [1] result.ok (pop {'kind 'domain}) result.map-err {'ok [1]} equal
  ({'kind 'io} result.err (pop) result.map-err)
  'contract
  "( error -- error )"
  raises-containing
  ({'kind 'io} result.err (pop 7) result.map-err)
  'type
  "must produce an error dict"
  raises-containing)
 'composition test

 ### test recovery-and-elimination
 (-- : "Recover selected errors and eliminate exactly one result branch.")
 ({'kind 'io 'msg "x"} result.err ('kind at wrap) result.recover
  {'ok (['io])} equal
  [1] result.ok ((9)) result.recover {'ok [1]} equal
  {'kind 'io} result.err ['io 'timeout] (pop 99 wrap) result.recover-kinds
  {'ok ([99])} equal
  {'kind 'type} result.err ['io] (pop 99 wrap) result.recover-kinds
  {'err {'kind 'type}} equal
  [5] result.ok ['io] (pop 99 wrap) result.recover-kinds {'ok [5]} equal
  {'kind 'io} result.err [] (pop 99 wrap) result.recover-kinds
  {'err {'kind 'io}} equal
  {'kind 'io} result.err (pop missing) result.recover result.err? 1 equal
  [7] result.ok (first) (pop 0) result.either 7 equal
  {'kind 'io} result.err (first) ('kind at) result.either 'io equal
  ({'kind 'io} result.err ["io"] (pop) result.recover-kinds)
  'type
  "list of kind symbols"
  raises-containing)
 'recovery-and-elimination test

 ### test aggregation
 (-- : "Aggregate successes and preserve ordered success and error partitions.")
 ([1 2] result.ok [3] result.ok [] result.ok 3 pack result.all
  {'ok ([1 2] [3] ())} equal
  [1] result.ok {'kind 'io} result.err [2] result.ok
  {'kind 'type} result.err 4 pack result.all
  {'err {'kind 'io}} equal
  [] result.all {'ok ()} equal
  [1] result.ok {'kind 'io} result.err [2 3] result.ok
  {'kind 'type} result.err 4 pack result.partition
  ({'kind 'io} {'kind 'type}) equal
  ([1] [2 3]) equal
  [] result.partition () equal () equal
  {'kind 'io} result.err 1 pack result.partition
  len 1 equal
  len 0 equal)
 'aggregation test

 ### test malformed-input
 (-- : "Reject malformed results before running caller quotations.")
 ((7 (missing) result.and-then) 'type "must be a dict tagged" raises-containing
  ({'nope [1]} (missing) result.and-then)
  'type
  "exactly one of 'ok or 'err"
  raises-containing
  ({'ok [1] 'err {'kind 'io}} (missing) result.and-then)
  'type
  "exactly one of 'ok or 'err"
  raises-containing
  ({'ok 5} (missing) result.and-then)
  'type
  "list of success values"
  raises-containing
  ({'err 5} (missing) result.and-then)
  'type
  "must carry an error dict"
  raises-containing
  (7 result.ok?) 'type "must be a dict tagged" raises-containing
  (7 result.err?) 'type "must be a dict tagged" raises-containing
  ({'nope 1} result.or-raise)
  'type
  "exactly one of 'ok or 'err"
  raises-containing
  ({'nope 1} 9 result.or-else)
  'type
  "exactly one of 'ok or 'err"
  raises-containing
  ({'nope 1} (missing) result.map-err)
  'type
  "exactly one of 'ok or 'err"
  raises-containing
  ({'ok 5} (missing) result.recover)
  'type
  "list of success values"
  raises-containing
  ({'nope 1} ['io] (missing) result.recover-kinds)
  'type
  "exactly one of 'ok or 'err"
  raises-containing
  ({'nope 1} (missing) (missing) result.either)
  'type
  "exactly one of 'ok or 'err"
  raises-containing
  (7 result.all) 'type "expected a list of results" raises-containing
  ({'ok 5} 1 pack result.all)
  'type
  "list of success values"
  raises-containing
  ({'nope 1} 1 pack result.partition)
  'type
  "exactly one of 'ok or 'err"
  raises-containing)
 'malformed-input test

 ### test documentation
 (-- : "Expose documentation for every result module export.")
 (['result.ok 'result.err 'result.ok? 'result.err? 'result.or-raise
   'result.or-else 'result.and-then 'result.map-err 'result.recover
   'result.recover-kinds 'result.either 'result.all 'result.partition]
  documented)
 'documentation test
) 'stdlib.test.result @defm
