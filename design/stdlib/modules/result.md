## result

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
