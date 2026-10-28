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

### send

#### Examples

```ecl
[] (task.receive 1 +) @spawn dup task.address 41 swap task.send task.await
# => {ok [42]}
```
