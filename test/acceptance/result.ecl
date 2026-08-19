# DoD-25a: the result module's whole contract, reached both by `use` and by
# bare qualified reference.
'result use

# Construction and observation. A success payload is always a stack.
[1 2] ok pp
{'kind 'io} err pp
[] ok pp
[1 2] ok ok? pp
{'kind 'io} err ok? pp
{'kind 'io} err err? pp

# `@attempt` results are ordinary results, so the vocabularies compose.
(2 3 +) @attempt ok? pp

# and-then seeds the success stack and short-circuits an existing failure.
[2 3] ok (+) and-then pp
[] ok (42) and-then pp
{'kind 'io 'msg "boom"} err (+) and-then pp
[2 3] ok (+) and-then (10 *) and-then pp
[2 0] ok (/) and-then err? pp

# Failure transformation leaves a success alone.
{'kind 'io} err (pop {'kind 'domain 'msg "mapped"}) map-err pp
[1] ok (pop {'kind 'domain}) map-err pp

# Broad recovery seeds the error dict; kind-selective recovery leaves an
# unmatched result untouched, and a failing recovery becomes the new error.
{'kind 'io 'msg "x"} err ('kind at wrap) recover pp
[1] ok ((9)) recover pp
{'kind 'io} err ['io 'timeout] (pop 99 wrap) recover-kinds pp
{'kind 'type} err ['io] (pop 99 wrap) recover-kinds pp
[5] ok ['io] (pop 99 wrap) recover-kinds pp
{'kind 'io} err (pop missing) recover err? pp

# The eliminator is exhaustive and calls exactly one branch.
[7] ok (first) (pop 0) either pp
{'kind 'io} err (first) ('kind at) either pp

# The three envelope interpreters that moved out of the prelude: qualified,
# and spliced in by `use`.
(2 3 +) @attempt or-raise pp
(missing) @attempt 9 or-else pp
(2 3 +) @attempt result.or-raise pp
({'nope 1} result.or-raise) @attempt 'err at 'kind at pp

# Aggregation preserves input order: leftmost error, or the per-result stacks.
[1 2] ok [3] ok [] ok 3 pack all pp
[1] ok {'kind 'io} err [2] ok {'kind 'type} err 4 pack all pp
[] all pp
[1] ok {'kind 'io} err [2 3] ok {'kind 'type} err 4 pack partition pp pp
[] partition pp pp

# Malformed results are rejected before any supplied quotation runs: each
# probe below would fail loudly on its own if it were ever executed.
(7 (missing) result.and-then) @attempt 'err at 'kind at pp
({'nope [1]} (missing) result.and-then) @attempt 'err at 'kind at pp
({'ok [1] 'err {'kind 'io}} (missing) result.and-then) @attempt 'err at 'kind at pp
({'ok 5} (missing) result.and-then) @attempt 'err at 'kind at pp
({'err 5} (missing) result.and-then) @attempt 'err at 'kind at pp
(7 result.ok?) @attempt 'err at 'kind at pp
({'ok 5} 1 pack result.all) @attempt 'err at 'kind at pp
({'nope 1} (missing) (missing) result.either) @attempt 'err at 'kind at pp
