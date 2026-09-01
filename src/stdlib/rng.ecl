### module rng
# The module stores one [key counter] generator state on its durable stack.
# Draw operations update that state through `within` transactions. The initial
# state is [0 0], so sequential draws are reproducible; `rand.entropy rng.seed`
# selects a nondeterministic key.
#
# This generator is not cryptographic. Concurrent draws are serialized, but
# their order depends on scheduling and may vary with worker count. Reproducible
# parallel programs should assign separate keys to their tasks.
[[0 0]]
(
 ### def seed
 (key -- : "Set the generator key and reset its counter to zero.")
 ((pop) swap 0 pair literal compose within)
 'seed def

 ### def int
 (bound -- result : "Return a uniform integer from 0 through bound - 1.")
 ((rand.int without) partial within)
 'int def

 ### def ints
 (count bound -- results : "Return count uniform integers from 0 through bound - 1.")
 (pair (rand.ints without) with within)
 'ints def

 ### def float
 (-- result : "Return a uniform float in the half-open interval [0, 1).")
 ((rand.float without) within)
 'float def

 ### defp deal-pick
 (pool picked remaining index -- accumulated :
  "Append one selected pool entry and replace it with the final live entry.")
 (|pool picked remaining chosen-index|
  pool chosen-index at
  picked swap append
  pool chosen-index pool remaining 1 - at put
  swap pair)
 'deal-pick defp

 ### defp deal-step
 (accumulated index bound -- accumulated : "Apply one partial Fisher-Yates selection step.")
 (|accumulated index bound|
  accumulated first
  accumulated 1 at
  bound index -
  bound index - int
  deal-pick)
 'deal-step defp

 ### def deal
 (count bound -- results :
  "Return count distinct integers selected uniformly from 0 through bound - 1.

   Count and bound must be nonnegative, and count must not exceed bound.")
 (|count bound|
  count 0 >=
  'domain error.new "rng.deal needs a nonnegative count" error.with-message assert
  bound 0 >=
  'domain error.new "rng.deal needs a nonnegative pool size" error.with-message assert
  count bound <=
  'domain error.new "rng.deal cannot draw more values than the pool holds" error.with-message assert
  count range
  bound range [] pair
  bound (deal-step) partial
  fold
  1 at)
 'deal def

 ### def shuffle
 (values -- values : "Return a uniformly selected permutation of a list.")
 (dup len dup deal at)
 'shuffle def

) 'rng @defm
