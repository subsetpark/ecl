### A counter whose durable stack is one integer.
[5] 'counter (
  ((1 +) within) 'tick def
  ((dup without) within) 'peek def
) module-with
counter.tick
counter.peek pp

### Re-registration proposes a different initial stack and different code.
### The proposal is discarded and the retained stack is what the new code
### operates on.
[900] 'counter (
  ((10 +) within) 'tick def
  ((dup without) within) 'peek def
  ((dup 2 * without) within) 'doubled def
) module-with
counter.peek pp
counter.tick
counter.peek pp
counter.doubled pp

### Replacement code may migrate the retained representation with an
### ordinary first transactional update; the runtime names no positions.
[0] 'counter (
  ((dup 100 * swap pop) within) 'migrate def
  ((dup without) within) 'peek def
) module-with
counter.migrate
counter.peek pp

### A failed registration changes neither the code generation nor the state.
('counter ((1 2) (bad -- shape -- here) 'x def) module) attempt 'err at 'kind at pp
counter.peek pp
counter.migrate
counter.peek pp

### Access through a previously used qualified path and through an alias
### both resolve the current generation over the retained stack.
'c 'counter alias
c.peek pp
