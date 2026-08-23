### One body quotation, two independently seeded counter slots.

### def counter-body
(
 ### def add
 ((swap + dup without) partial within) 'add def

 ### def peek
 ((dup without) within) 'peek def

 ### def tick
 ((1 +) within) 'tick def
 )
'counter-body
set

[10] counter-body with 'left @defm
[100] counter-body with 'right @defm

### Independent slots: separately constructed names own independent stacks.
left.peek io.pp
right.peek io.pp
5 left.add io.pp
7 right.add io.pp
left.peek io.pp
right.peek io.pp

### Namespaced modules and dynamic dispatch use the same final-dot lookup.

### module core
(
 ### def utils
 (0) 'utils def) 'core @defm

### module core.utils
(
 ### def f
 (1) 'f def) 'core.utils @defm
core.utils io.pp
'core.utils 'f qualify dup type io.pp execute io.pp

### A pool built from `with`: checkout moves a value outward, checkin
### returns one, and both are ordinary transactional updates.

### module pool
[['a 'b 'c]]
(
 ### def checkout
 ((uncons swap without) within) 'checkout def

 ### def checkin
 ((append) partial within) 'checkin def

 ### def size
 ((dup len without) within) 'size def
 ) with 'pool @defm
pool.size io.pp
pool.checkout io.pp
pool.size io.pp
'z pool.checkin
pool.size io.pp

### Serialization: contending updates publish exactly the successful ones.
[1] 50 take (pop (left.tick) @spawn) each await-all pop
left.peek io.pp

### The prohibited shapes are 'domain, and they publish nothing.
(1 execute) @attempt 'err at 'kind at io.pp
((1) within) @attempt 'err at 'kind at io.pp
(without) @attempt 'err at 'kind at io.pp
