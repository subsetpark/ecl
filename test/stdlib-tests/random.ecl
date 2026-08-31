### module stdlib.test.random
[]
(
 'stdlib.test.support
 ('equal 'raises-containing 'raises-word 'documented)
 import

 ### test counter-streams
 (-- : "Keep counter-based random draws deterministic and order-independent.")
 ([0 0] 100 rand.int 2 pack ([0 1] 35) equal
  [0 0] 100 rand.int nip [0 0] 100 rand.int nip = 1 equal
  [0 0] 100 rand.int nip [7 0] 100 rand.int nip <> 1 equal
  [0 0] 100 rand.int pop [0 1] equal
  [0 5] 3 100 rand.ints pop [0 8] equal
  [4 9] 0 100 rand.ints () equal [4 9] equal
  [0 0] 3 100 rand.ints nip
  [0 0] 100 rand.int nip
  [0 1] 100 rand.int nip
  [0 2] 100 rand.int nip
  3 pack
  match? 1 equal
  [3 0] 200 6 rand.ints nip
  dup (0 <) any? 0 equal
  dup (6 >=) any? 0 equal
  len 200 equal
  [0 0] 4 1 rand.ints nip [0 0 0 0] equal
  [0 0] rand.float nip dup 0.0 >= 1 equal 1.0 < 1 equal)
 'counter-streams test

 ### test invalid-input
 (-- : "Reject malformed generator states, counts, and bounds.")
 ((5 100 rand.int) 'type "generator state" raises-containing
  ([0] 100 rand.int) 'type 'rand.int raises-word
  ([0 1.5] 100 rand.int) 'type 'rand.int raises-word
  ([0 0] 0 rand.int) 'domain 'rand.int raises-word
  ([0 0] 3 -1 rand.ints) 'domain 'rand.ints raises-word
  ([0 0] -1 100 rand.ints) 'domain 'rand.ints raises-word
  ([0 0] 1.5 rand.int) 'type 'rand.int raises-word)
 'invalid-input test

 ### test durable-state
 (-- : "Draw reproducibly from the rng module's durable state.")
 (0 rng.seed
  100 rng.int 35 equal
  100 rng.int 0 equal
  42 rng.seed 100 rng.int 42 rng.seed 100 rng.int = 1 equal
  42 rng.seed 100 rng.int 43 rng.seed 100 rng.int <> 1 equal
  42 rng.seed 3 6 rng.ints 42 rng.seed 3 6 rng.ints match? 1 equal
  rng.float dup 0.0 >= 1 equal 1.0 < 1 equal)
 'durable-state test

 ### test deal-and-shuffle
 (-- : "Deal without replacement and shuffle without changing the multiset.")
 (5 10 rng.deal dup distinct len 5 equal
  dup len 5 equal
  dup (0 <) any? 0 equal
  (10 >=) any? 0 equal
  8 8 rng.deal sort [0 1 2 3 4 5 6 7] equal
  0 0 rng.deal len 0 equal
  0 5 rng.deal len 0 equal
  [10 20 30 40] rng.shuffle sort [10 20 30 40] equal
  (11 10 rng.deal) 'domain "more values than the pool" raises-containing
  (-1 10 rng.deal) 'domain "nonnegative count" raises-containing)
 'deal-and-shuffle test

 ### test documentation
 (-- : "Require documentation for every stateful RNG export.")
 (('rng.seed 'rng.int 'rng.ints 'rng.float 'rng.deal 'rng.shuffle) documented)
 'documentation test
) 'stdlib.test.random @defm
