### One body quotation, two independently seeded counter slots.
(
  ((swap + dup without) partial within) 'add def
  ((dup without) within) 'peek def
  ((1 +) within) 'tick def
) 'counter-body set

[10] counter-body with 'left @module
[100] counter-body with 'right @module

### Independent slots: separately constructed names own independent stacks.
left.peek pp
right.peek pp
5 left.add pp
7 right.add pp
left.peek pp
right.peek pp

### Namespaced modules and dynamic dispatch use the same final-dot lookup.
((0) 'utils def) 'core @module
((1) 'f def) 'core.utils @module
core.utils pp
'core.utils 'f qualify dup type pp execute pp

### A pool built from `with`: checkout moves a value outward, checkin
### returns one, and both are ordinary transactional updates.
[['a 'b 'c]] (
  ((uncons swap without) within) 'checkout def
  ((append) partial within) 'checkin def
  ((dup len without) within) 'size def
) with 'pool @module
pool.size pp
pool.checkout pp
pool.size pp
'z pool.checkin
pool.size pp

### Serialization: contending updates publish exactly the successful ones.
[1] 50 take (pop (left.tick) @spawn) each await-all pop
left.peek pp

### The prohibited shapes are 'domain, and they publish nothing.
(1 execute) @attempt 'err at 'kind at pp
((1) within) @attempt 'err at 'kind at pp
(without) @attempt 'err at 'kind at pp
