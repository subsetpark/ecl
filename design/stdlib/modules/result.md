## result

Every entry validates its result envelope before invoking a caller quotation.
A success payload is always a list representing a stack.

### all

### and-then

#### Examples

```ecl
[2 3] result.ok (+) result.and-then
# => {ok [5]}
```

### either

#### Examples

```ecl
{kind io} result.err (first) (`kind at) result.either
# => io
```

### err

### err?

### map-err

### ok

### ok?

### or-else

### or-raise

### partition

### recover

### recover-kinds

#### Examples

```ecl
{kind io} result.err [io timeout] (pop 99 wrap) result.recover-kinds
# => {ok ([99])}
```
