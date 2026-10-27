## agent

An agent is a task whose stack is its state. Quotations sent to it run in
arrival order, each as an isolated unit over that stack, so a failing
quotation leaves the state exactly as it was. A `call` quotation is
`( state... -- state... result )`: the top of its result stack is the reply and
the rest is the new state. A `send` quotation is `( state... -- state... )` and
keeps its whole result stack. This is how a program keeps state that outlives
a word, for example an ambient random generator:

```ecl
[0 0] agent.start 'rng set
(5 rand.int) rng agent.call
# => 0
```

A call to an agent that has ended raises `'io`. A call whose request was
accepted waits forever if the agent ends before replying, unless it bounds the
call with `call-for`.

### call

#### Examples

```ecl
[0 0] agent.start 'g set
(100 rand.int) g agent.call (100 rand.int) g agent.call pair
# => [35 0]
[7 0] agent.start 'g set
[] ((1 0 div) g agent.call) @attempt 'err at 'kind at (dup) g agent.call pair
# => ('domain [7 0])
```

### call-for

### send

### serve

### start
