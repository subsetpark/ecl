## task

#### Examples

Request and reply:

```ecl
(|a v| (task.receive) @spawn dup task.address {} `value v put `from rolldown put a swap task.send task.await `ok at first) `ask def
(task.receive dup `from at swap `value at 1 + task.send) @spawn task.address 41 ask
# => 42
```

### send

#### Examples

```ecl
(task.receive 1 +) @spawn dup task.address 41 task.send task.await
# => {ok [42]}
```
