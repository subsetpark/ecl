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

 ### test documentation
 (-- : "Require documentation for every rand word.")
 (('rand.int 'rand.ints 'rand.float 'rand.entropy) documented)
 'documentation test
) 'stdlib.test.random @defm
