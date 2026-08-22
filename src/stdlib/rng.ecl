### module rng
# The module stores one [key counter] generator state on its durable stack.
# Draw operations update that state through `within` transactions. The initial
# state is [0 0], so sequential draws are reproducible; `entropy rng.seed`
# selects a nondeterministic key.
#
# This generator is not cryptographic. Concurrent draws are serialized, but
# their order depends on scheduling and may vary with worker count. Reproducible
# parallel programs should assign separate keys to their tasks.
[[0 0]]
(
 ### def seed
 ((pop) swap 0 pair literal compose within)
 (key -- : "Set the generator key and reset its counter to zero.")
 'seed def

 ### def int
 ((rand-int without) partial within)
 (bound -- result : "Return a uniform integer from 0 through bound - 1.")
 'int def

 ### def ints
 (pair (rand-ints without) with within)
 (count bound -- results : "Return count uniform integers from 0 through bound - 1.")
 'ints def

 ### def float
 ((rand-float without) within)
 (-- result : "Return a uniform float in the half-open interval [0, 1).")
 'float def

 ### def deal-pick
 (|pool picked remaining chosen-index|
  pool chosen-index at
  picked swap append
  pool chosen-index pool remaining 1 - at put
  swap pair)

 (pool picked remaining index -- accumulated :
  "Append one selected pool entry and replace it with the final live entry.")
 'deal-pick defp

 ### def deal-step
 (|accumulated index bound|
  accumulated first
  accumulated 1 at
  bound index -
  bound index - int
  deal-pick)

 (accumulated index bound -- accumulated : "Apply one partial Fisher-Yates selection step.")
 'deal-step defp

 ### def deal
 (|count bound|
  count 0 >=
  {'kind 'domain 'msg "rng.deal needs a nonnegative count"} assert
  bound 0 >=
  {'kind 'domain 'msg "rng.deal needs a nonnegative pool size"} assert
  count bound <=
  {'kind 'domain 'msg "rng.deal cannot draw more values than the pool holds"} assert
  count range
  bound range [] pair
  bound (deal-step) partial
  fold
  1 at)

 (count bound -- results :
  "Return count distinct integers selected uniformly from 0 through bound - 1.

   Count and bound must be nonnegative, and count must not exceed bound.")
 'deal def

 ### def shuffle
 (dup len dup deal at)
 (values -- values : "Return a uniformly selected permutation of a list.")
 'shuffle def

 )
with
'rng
@defm
