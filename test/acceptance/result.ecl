# DoD-25a: the result module's whole contract, reached both through explicit
# metadata-preserving imports and by bare qualified reference.
'result
('ok 'err 'ok? 'err? 'or-raise 'or-else 'and-then 'map-err 'recover
 'recover-kinds 'either 'all 'partition)
import

# Construction and observation. A success payload is always a stack.
[1 2] ok io.pp
{'kind 'io} err io.pp
[] ok io.pp
[1 2] ok ok? io.pp
{'kind 'io} err ok? io.pp
{'kind 'io} err err? io.pp

# `@attempt` results are ordinary results, so the vocabularies compose.
(2 3 +) @attempt ok? io.pp

# and-then seeds the success stack and short-circuits an existing failure.
[2 3] ok (+) and-then io.pp
[] ok (42) and-then io.pp
{'kind 'io 'msg "boom"} err (+) and-then io.pp
[2 3] ok (+) and-then (10 *) and-then io.pp
[2 0] ok (/) and-then err? io.pp

# Failure transformation leaves a success alone.
{'kind 'io} err (pop {'kind 'domain 'msg "mapped"}) map-err io.pp
[1] ok (pop {'kind 'domain}) map-err io.pp

# Broad recovery seeds the error dict; kind-selective recovery leaves an
# unmatched result untouched, and a failing recovery becomes the new error.
{'kind 'io 'msg "x"} err ('kind at wrap) recover io.pp
[1] ok ((9)) recover io.pp
{'kind 'io} err ['io 'timeout] (pop 99 wrap) recover-kinds io.pp
{'kind 'type} err ['io] (pop 99 wrap) recover-kinds io.pp
[5] ok ['io] (pop 99 wrap) recover-kinds io.pp
{'kind 'io} err (pop missing) recover err? io.pp

# The eliminator is exhaustive and calls exactly one branch.
[7] ok (first) (pop 0) either io.pp
{'kind 'io} err (first) ('kind at) either io.pp

# The envelope interpreters that moved out of the prelude: qualified and
# explicitly imported.
(2 3 +) @attempt or-raise io.pp
(missing) @attempt 9 or-else io.pp
(2 3 +) @attempt result.or-raise io.pp
({'nope 1} result.or-raise) @attempt 'err at 'kind at io.pp

# Aggregation preserves input order: leftmost error, or the per-result stacks.
[1 2] ok [3] ok [] ok 3 pack all io.pp
[1] ok {'kind 'io} err [2] ok {'kind 'type} err 4 pack all io.pp
[] all io.pp
[1] ok {'kind 'io} err [2 3] ok {'kind 'type} err 4 pack partition io.pp io.pp
[] partition io.pp io.pp

# Malformed results are rejected before any supplied quotation runs: each
# probe below would fail loudly on its own if it were ever executed.
(7 (missing) result.and-then) @attempt 'err at 'kind at io.pp
({'nope [1]} (missing) result.and-then) @attempt 'err at 'kind at io.pp
({'ok [1] 'err {'kind 'io}} (missing) result.and-then) @attempt 'err at 'kind at io.pp
({'ok 5} (missing) result.and-then) @attempt 'err at 'kind at io.pp
({'err 5} (missing) result.and-then) @attempt 'err at 'kind at io.pp
(7 result.ok?) @attempt 'err at 'kind at io.pp
({'ok 5} 1 pack result.all) @attempt 'err at 'kind at io.pp
({'nope 1} (missing) (missing) result.either) @attempt 'err at 'kind at io.pp
