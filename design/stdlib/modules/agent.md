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
`( quotation address -- result )` — Apply the quotation to the agent's stack
and return the top of the result stack; the agent keeps the rest. The
quotation's own error is re-raised here with the agent unchanged. A result
stack with nothing on it is `'domain`. Replies travel through a helper task.
A call to an agent that has ended raises `'io`; a call whose request was
accepted never returns if the agent ends before replying.

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
`( quotation address milliseconds -- result )` — `agent.call` with a
nonnegative int deadline, checked before anything is sent: a negative duration
is `'domain` and a non-int is `'type`. When no reply arrives in time the call
raises `'timeout`, whether the deadline passed while waiting for room in a full
mailbox or for the reply; the quotation, if it was sent, still runs on the
agent when its turn comes, and its reply is discarded.

### send
`( quotation address -- )` — Apply the quotation to the agent's stack without
waiting. The whole result stack becomes the new state; a failing quotation
changes nothing and reports nothing.

### serve
Stack-polymorphic. Turn the current task into an agent whose state is the
stack it has now, and serve until cancelled. Spawn it directly to keep the
handle: `[[7 0]] (agent.serve) @spawn` serves `[7 0]` and `task.cancel` on the
handle ends it with `'cancelled`.

### start
`( state -- address )` — Spawn a server whose stack holds the one value
`state` and return its address. The server is owned by the spawning task
scope, as any `@spawn` is.
