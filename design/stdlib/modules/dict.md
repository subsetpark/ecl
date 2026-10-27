## dict

These operations preserve the language's immutable, insertion-ordered
dictionary semantics. The constructor family accepts one key/value association,
flat adjacent entries, parallel key/value lists, association lists, or one
shared value for a key list. All constructors reject duplicate keys instead of
silently choosing a winner. Core `at`, `put`, `update`, and `del` treat a
dictionary selector as one whole-value key. `dict.put` also assigns one whole key and value. Batch operations `dict.at`,
`dict.at-or`, `dict.update`, `dict.take`, `dict.del`, and `dict.split` consume
a list of whole keys: strings and composite keys remain atomic. The public
`dict` module is ECL over the host kernels exported by `dict.core`, so a
failure inside a kernel reports its `dict.core` name.

### associate

#### Examples

```ecl
["inspect" "alpha"] `args dict.associate
# => {args ["inspect" "alpha"]}
```

### from-lists

#### Examples

```ecl
[a b] [1 2] dict.from-lists
# => {a 1 b 2}
```

### map

#### Examples

```ecl
{a 1 b 2} (swap pop 10 *) dict.map
# => {a 10 b 20}
```

### merge

#### Examples

```ecl
{a 1 b 2} {b 20 c 30} dict.merge
# => {a 1 b 20 c 30}
```

### split

#### Examples

```ecl
{a 1 b 2} [b] dict.split pair
# => ({b 2} {a 1})
```
