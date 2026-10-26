### module stdlib.test.random
[]
(
 'stdlib.test.support
 ('equal 'raises-containing 'raises-word 'documented)
 import

 ### test counter-streams
 (-- : "Keep counter-based random draws deterministic and order-independent.")
 ([0 0] 100 rand.int pair ([0 1] 35) equal
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

 ### test deal
 (-- :
  "Deal distinct values below a pool as a pure function of state, in work proportional to the
   count.")
 ([42 0] 4 8 rand.deal nip dup distinct len 4 equal
  dup (0 <) any? 0 equal
  (8 >=) any? 0 equal
  [42 0] 8 8 rand.deal nip sort [0 1 2 3 4 5 6 7] equal
  [42 0] 0 0 rand.deal nip len 0 equal
  [42 0] 0 5 rand.deal pop [42 0] equal
  [42 0] 3 10 rand.deal pop [42 3] equal
  [42 0] 3 10 rand.deal nip [42 0] 3 10 rand.deal nip match? 1 equal
  [42 0] 3 10 rand.deal nip [43 0] 3 10 rand.deal nip match? 0 equal
  [42 0] 2 1000000000 rand.deal nip dup distinct len 2 equal (1000000000 >=) any? 0 equal
  ([42 0] 9 8 rand.deal) 'domain "more values than the pool" raises-containing
  ([42 0] -1 8 rand.deal) 'domain 'rand.deal raises-word
  ([42 0] 1 -8 rand.deal) 'domain 'rand.deal raises-word
  ([42 0] 'x 8 rand.deal) 'type 'rand.deal raises-word
  (5 1 8 rand.deal) 'type "generator state" raises-containing)
 'deal test

 ### test shuffle
 (-- : "Shuffle as a pure function of state, keeping the multiset and the representation.")
 ([42 0] [10 20 30 40] rand.shuffle [42 0] [10 20 30 40] rand.shuffle 4 pack
  dup 0 at over 2 at match? 1 equal
  dup 1 at over 3 at match? 1 equal
  0 at [42 4] equal
  [42 0] [10 20 30 40] rand.shuffle nip sort [10 20 30 40] equal
  [42 0] [] rand.shuffle nip [] equal
  [42 0] [] rand.shuffle pop [42 0] equal
  [42 0] "abcd" rand.shuffle nip dup len 4 equal dup type 'list equal sort "abcd" equal
  [42 0] [1 'two "three" [4]] rand.shuffle nip len 4 equal
  [42 0] 1000 range rand.shuffle nip sort 1000 range equal
  ([42 0] 1 rand.shuffle) 'type 'rand.shuffle raises-word
  (5 [1 2] rand.shuffle) 'type "generator state" raises-containing)
 'shuffle test

 ### test documentation
 (-- : "Require documentation for every rand word.")
 (('rand.int 'rand.ints 'rand.float 'rand.entropy 'rand.deal 'rand.shuffle) documented)
 'documentation test
) 'stdlib.test.random @defm
