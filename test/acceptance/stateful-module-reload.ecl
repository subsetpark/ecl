### A counter whose durable stack is one integer.

### module counter
[5]
(
 ### def tick
 ((1 +) within) 'tick def

 ### def peek
 ((dup without) within) 'peek def
) seed 'counter @defm
counter.tick
counter.peek io.pp

### Re-registration proposes a different initial stack and different code.
### The proposal is discarded and the retained stack is what the new code
### operates on.

### module counter
[900]
(
 ### def tick
 ((10 +) within) 'tick def

 ### def peek
 ((dup without) within) 'peek def

 ### def doubled
 ((dup 2 * without) within) 'doubled def
) seed 'counter @defm
counter.peek io.pp
counter.tick
counter.peek io.pp
counter.doubled io.pp

### Replacement code may migrate the retained representation with an
### ordinary first transactional update; the runtime names no positions.

### module counter
[0]
(
 ### def migrate
 ((dup 100 * swap pop) within) 'migrate def

 ### def peek
 ((dup without) within) 'peek def
) seed 'counter @defm
counter.migrate
counter.peek io.pp

### A failed registration changes neither the code generation nor the state.
((
  ### def x
  (bad -- shape -- here)
  (1 2) 'x def)
 'counter
 @defm)
@attempt
'err
at
'kind
at
io.pp
counter.peek io.pp
counter.migrate
counter.peek io.pp

### Access through a previously used qualified path and through an alias
### both resolve the current generation over the retained stack.
'c 'counter alias
c.peek io.pp
