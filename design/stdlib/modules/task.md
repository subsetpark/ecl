## task

Task handles are created by the core unit constructors `@spawn` and `@give`.
A handle observes a task's lifetime and result. `task.address` derives the
task's address, which names only its mailbox, and `task.self` is the
executing task's own. Use `(task.await) each` to collect results in input
order without cancelling siblings or re-raising task errors.

Request and reply is a composition over `send` and `receive`: spawn a helper
task, send its address with the request, and await the helper, whose result
is the reply. `task.await-for` bounds the exchange.

```ecl
(|a v| [] (task.receive) @spawn dup task.address {} `value v put `from rolldown put a task.send task.await `ok at first) `ask def
[] (task.receive dup `from at swap `value at 1 + swap task.send) @spawn task.address 41 ask
# => 42
```

### address
`( task -- address )` — The address of a task's mailbox. Two addresses of
one task match. An address outlives its task; after the task ends it names a
closed mailbox.

### await
`( task -- result )` — Park until the task completes; return its cached
`{ok …}`/`{err …}` result. Idempotent. See
[Concurrency](SPEC.md#concurrency).

### await-any
`( tasks -- index result )` — Race a nonempty all-task list; among tasks
already terminal at entry the lowest index wins, otherwise the first
completion.

### await-for
`( task milliseconds -- result )` — `task.await` with a nonnegative int
deadline; expiry returns `{err {kind timeout}}` without cancelling the
task. A terminal task beats even a zero deadline. A deadline beyond any
instant the scheduler clock can report is `` `overflow `` before the wait
registers.

### cancel
`( task -- )` — Request cancellation; the task's result becomes
`{err {kind cancelled …}}`. No-op when already terminal.

### cancel-self
`( -- )` — Request cancellation of the current task, exactly as `task.cancel`
does with its handle. It is only a request: execution continues, and the task
observes it at its next safe point. `` `domain `` outside a task. There is
deliberately no way to obtain the current task's handle, so a task's result
can never retain its own task.

### pending
`( -- tasks )` — Pending descendant tasks in deterministic spawn
preorder.

### receive
`( -- value )` — Take the oldest message from the executing task's mailbox,
parking until one arrives. `` `domain `` outside a task.

### receive-for
`( milliseconds -- result )` — `task.receive` with a nonnegative int
deadline: `{ok value}`, or `{err {kind timeout}}` when nothing arrives in
time. A deadline beyond any instant the scheduler clock can report is
`` `overflow ``. `` `domain `` outside a task.

### self
`( -- address )` — The executing task's own address. `` `domain `` outside a
task: the session root owns tasks but has no mailbox.

### send
`( value address -- )` — Queue a value in the mailbox an address names. Any
value may be sent except one containing a task handle, which is `` `type ``;
addresses and ports pass. A mailbox holds sixteen messages, and a sender to a
full one parks until the receiver takes a message. Sending to a task that has
ended is `` `io `` with `` `reason `closed ``. Messages from one sender arrive in
order; order across senders is unspecified.

#### Examples

```ecl
[] (task.receive 1 +) @spawn dup task.address 41 swap task.send task.await
# => {ok [42]}
```
