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
`( value key -- dict )` — Build a one-entry dictionary associating `key` with `value`.

#### Examples

```ecl
["inspect" "alpha"] `args dict.associate
# => {args ["inspect" "alpha"]}
```

### from-lists
`( keys values -- dict )` — Build a dictionary from parallel conforming key and value lists. Unequal lengths are `` `shape ``; duplicate keys are `` `domain ``.

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
`( left right -- dict )` — Merge two dictionaries; right-hand values win. Existing left keys retain their positions and right-only keys append in right order. Key-aligned arithmetic remains pervasive `+` on dicts.

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

### at-or
`( dict keys default -- values )` — Like `dict.at`, using `default` as a whole value for each missing key.

### size
`( dict -- count )` — Return the dictionary's entry count.

### keys
`( dict -- keys )` — Return keys in insertion order.

### vals
`( dict -- values )` — Return values in insertion order.

### get
`( dict key default -- value )` — The value of one whole-value key, or `default` when the dictionary has no such key. A non-dictionary is `` `type ``.

### has?
`( dict key -- bool )` — Whole-value key membership. Keys are inert and only absence is false: lookup machinery failures are errors, never converted to 0.

### at
`( dict keys -- values )` — Look up each top-level key in request order, preserving duplicates. An absent key is `` `domain ``. Strings and composite keys are whole values; the result has one element per requested key.

### from-flat
`( entries -- dict )` — Build a dictionary from one flat, even-length list by pairing adjacent entries without executing them. This is the runtime counterpart of the `{…}` literal: `` `total 3 4 + pair dict.from-flat `` is `{total 7}`. An odd entry count is `` `contract ``; duplicate keys are `` `domain ``.

### put
`( dict key value -- dict )` — Assign one whole key and value. An existing key retains its position; a new key appends at the end.

### update
`( dict keys quotation -- dict )` — Apply an isolated `( value -- value )` quotation to each whole top-level key without moving entries. Keys are processed in request order, so duplicates observe earlier updates. All keys are validated before the quotation is first applied; an absent key is `` `domain ``, and an empty key list returns the dictionary unchanged.

### take
`( dict keys -- dict )` — Keep entries named by a key list, ignoring absent keys. Output follows dictionary order independently of the requested key-list order.

### del
`( dict keys -- dict )` — Remove entries named by whole top-level keys, ignoring absent and duplicate keys and preserving retained dictionary order.

### merge-with
`( left right quotation -- dict )` — Merge two dictionaries, resolving each shared key with `( key left-value right-value -- value )`. Existing left keys keep their positions; right-only keys append in right order.
