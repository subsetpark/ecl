### module rng
# The rng module: one shared generator state as durable module state.
#
# The state is an ordinary [key counter] list held on the module's durable
# stack and advanced through `within` transactions, so every word here is a
# thin transactional wrapper over the pure kernels. It starts at a fixed
# documented constant, which makes a sequential program reproducible by
# default; nondeterminism is opt-in and explicit: `entropy rng.seed`.
#
# This is not a cryptographic generator. Concurrent draws through this shared

### module rng
# worker-count-stable, so a cross-unit draw sequence is not reproducible. For
# reproducible parallel randomness, pass explicit per-task states to the pure
# kernels instead, giving each task a distinct key.
[[0 0]]
(
 ### def seed
 ((pop) swap 0 pair literal compose within)
 (key -- :
  "Rekey the generator and reset its counter, making every later draw a function of this key.")
 'seed def

 ### def int
 ((rand-int without) partial within)
 (bound -- result : "Draw one uniform integer below a positive bound.")
 'int def

 ### def ints
 (pair (rand-ints without) with within)
 (count bound -- results : "Draw a vector of uniform integers below a positive bound.")
 'ints def

 ### def roll
 (ints)
 (count bound -- results : "Draw a vector of uniform integers; the dice-roll spelling of ints.")
 'roll def

 ### def float
 ((rand-float without) within)
 (-- result : "Draw one uniform float in the unit interval.")
 'float def

 ### def deal-pick
 ((|pool picked remaining chosen-index|
   pool chosen-index at
   picked swap append
   pool chosen-index pool remaining 1 - at put
   swap pair)
  call)
 (pool picked remaining index -- accumulated :
  "Take one pool entry and refill its slot from the live tail, the selection-sampling step.")
 'deal-pick defp

 ### def deal-step
 ((|accumulated index bound|
   accumulated first
   accumulated 1 at
   bound index -
   bound index - int
   deal-pick)
  call)
 (accumulated index bound -- accumulated :
  "One partial Fisher-Yates step, drawing uniformly from the shrinking live prefix.")
 'deal-step defp

 ### def deal
 ((|count bound|
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
  call)
 (count bound -- results :
  "Draw distinct values from the range below a pool size, without replacement.

   Each step draws uniformly from the entries not yet taken, so the result is an unbiased sample
   rather than a filtered sequence of independent draws.")
 'deal def

 ### def shuffle
 (dup len dup deal at)
 (values -- values : "Return a uniformly random permutation of a list.")
 'shuffle def

 )
with
'rng
@defm
