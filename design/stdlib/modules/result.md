## result

Every entry validates its result envelope before invoking a caller quotation.
A success payload is always a list representing a stack.

### all
`( results -- result )` — Return the leftmost failure unchanged, or one
success whose value is the list of success stacks in input order.

### and-then
`( result quotation -- result )` — Use a success payload as the explicit values
list for `@attempt`; return an existing
failure unchanged.

#### Examples

```ecl
[2 3] result.ok (+) result.and-then
# => {'ok [5]}
```

### either
`( result on-ok on-err -- ... )` — Eliminate a result exhaustively: call the
first quotation with the success list or the second with the error dict.
Neither branch is isolated.

#### Examples

```ecl
{'kind 'io} result.err (first) ('kind at) result.either
# => 'io
```

### err
`( error -- result )` — Tag an error dict as a failed result.

### err?
`( result -- bool )` — Return 1 when a well-formed result is a failure.

### map-err
`( result quotation -- result )` — Replace a failure's error dict with the one
its `( error -- error )` quotation returns; leave a success unchanged.

### ok
`( values -- result )` — Tag a list of success values, representing the stack
a successful computation left.

### ok?
`( result -- bool )` — Return 1 when a well-formed result is a success.

### or-else
`( result fallback -- value )` — Return a success payload, or the fallback
value for a failure.

### or-raise
`( result -- values )` — Return a success payload, or re-raise the captured
error dict unchanged.

### partition
`( results -- successes errors )` — Split results into success lists and error
dicts, both in input order, without re-raising.

### recover
`( result quotation -- result )` — Seed a failure's error dict onto an
isolated stack and run the recovery quotation; leave a success unchanged.

### recover-kinds
`( result kinds quotation -- result )` — Recover only when a failure's kind is
one of the listed symbols; leave every other result unchanged.

#### Examples

```ecl
{'kind 'io} result.err ['io 'timeout] (pop 99 wrap) result.recover-kinds
# => {'ok ([99])}
```
