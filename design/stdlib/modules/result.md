## result

Every entry validates its result envelope before invoking a caller quotation.
A success payload is always a list representing a stack.

Each word has one role. Transformers return a result and run their quotation
isolated under `@attempt`, so a quotation that fails yields a failed result.
Eliminators leave plain values and run their quotations inline, so they can
reach the stack beneath the result.

| Role | Words |
|---|---|
| Construct | `ok`, `err` |
| Test | `ok?`, `err?` |
| Transform the success | `map` |
| Transform the failure | `recover`, `recover-kinds`, `map-err` |
| Eliminate | `either`, `or-raise`, `or-default` |
| Combine | `all`, `partition` |

`map` replaces the success stack with what its quotation leaves, and a raising
quotation turns the success into a failure. `recover` may likewise turn a
failure into a success; `map-err` always keeps a failure and replaces only the
error dict. `or-default` returns the success list or, on failure, the fallback
value as given.

### map

#### Examples

```ecl
[2 3] result.ok (+) result.map
# => {ok [5]}
```

### either

#### Examples

```ecl
{kind io} result.err (first) (`kind at) result.either
# => io
```

### recover-kinds

#### Examples

```ecl
{kind io} result.err [io timeout] (pop 99 wrap) result.recover-kinds
# => {ok ([99])}
```
