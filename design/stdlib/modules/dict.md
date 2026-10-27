## dict

These operations preserve the language's immutable, insertion-ordered
dictionary semantics. The constructor family accepts one key/value association,
flat adjacent entries, parallel key/value lists, association lists, or one
shared value for a key list. All constructors reject duplicate keys instead of
silently choosing a winner. Core `at`, `put`, `update`, and `del` treat a
dictionary selector as one whole-value key. `dict.put` also assigns one whole key and value. Batch operations `dict.at`,
`dict.at-or`, `dict.update`, `dict.take`, `dict.del`, and `dict.split` consume
a list of whole keys: strings and composite keys remain atomic.

### associate
`( value key -- dict )` — Build a one-entry dictionary associating `key` with
`value`.

#### Examples

```ecl
["inspect" "alpha"] 'args dict.associate
# => {'args ["inspect" "alpha"]}
```

### at
`( dict keys -- values )` — Look up each top-level key in request order,
preserving duplicates. An absent key is `'domain`. Strings and composite keys
are whole values; the result has one element per requested key.

### at-or
`( dict keys default -- values )` — Like `dict.at`, using `default` as a whole
value for each missing key.

### get
`( dict key default -- value )` — The value of one whole-value key, or
`default` when the dictionary has no such key. A non-dictionary is `'type`.

### put
`( dict key value -- dict )` — Assign one whole key and value. An existing key
retains its position; a new key appends at the end.

### del
`( dict keys -- dict )` — Remove entries named by whole top-level keys,
ignoring absent and duplicate keys and preserving retained dictionary order.

### filter
`( dict predicate -- dict )` — Call a `( key value -- bool )` predicate in
insertion order and retain the entries for which it returns 1.

### from-flat
`( entries -- dict )` — Build a dictionary from one flat, even-length list by
pairing adjacent entries without executing them. This is the runtime
counterpart of the `{…}` literal: `'total 3 4 + pair dict.from-flat` is
`{'total 7}`. An odd entry count is `'contract`; duplicate keys are `'domain`.

### from-keys
`( keys value -- dict )` — Build a dictionary assigning one value to every
distinct key. Duplicate keys are `'domain`.

### from-lists
`( keys values -- dict )` — Build a dictionary from parallel conforming key
and value lists. Unequal lengths are `'shape`; duplicate keys are `'domain`.

#### Examples

```ecl
['a 'b] [1 2] dict.from-lists
# => {'a 1 'b 2}
```

### from-pairs
`( pairs -- dict )` — Build a dictionary from a list of exact `[key value]`
pairs in list order. A malformed pair is `'shape`; duplicate keys are
`'domain`.

### has?
`( dict key -- bool )` — Whole-value key membership. Keys are inert and only
absence is false: lookup machinery failures are errors, never converted to 0.

### keys
`( dict -- keys )` — Return keys in insertion order.

### keys-exactly?
`( candidate declared -- bool )` — Return 1 when a dictionary has exactly the
declared keys in any order. A duplicate declaration returns 0.

### map
`( dict quotation -- dict )` — Call a `( key value -- value )` quotation for
every entry, replacing values while preserving keys and insertion order.

#### Examples

```ecl
{'a 1 'b 2} (swap pop 10 *) dict.map
# => {'a 10 'b 20}
```

### size
`( dict -- count )` — Return the dictionary's entry count.

### merge
`( left right -- dict )` — Merge two dictionaries; right-hand values win.
Existing left keys retain their positions and right-only keys append in right
order. Key-aligned arithmetic remains pervasive `+` on dicts.

#### Examples

```ecl
{'a 1 'b 2} {'b 20 'c 30} dict.merge
# => {'a 1 'b 20 'c 30}
```

### merge-with
`( left right quotation -- dict )` — Merge two dictionaries, resolving each
shared key with `( key left-value right-value -- value )`. Existing left keys
keep their positions; right-only keys append in right order.

### pairs
`( dict -- pairs )` — Return insertion-ordered `[key value]` pairs. This is the
bridge to generic entry iteration when keys are needed. Value-only `each`
operates on a dictionary directly; reductions and predicates can consume
`dict.vals`, so they need no dictionary-specific duplicates.

### reject
`( dict predicate -- dict )` — Call a `( key value -- bool )` predicate in
insertion order and discard the entries for which it returns 1.

### split
`( dict keys -- selected rejected )` — Partition a dictionary by a key list,
returning selected then rejected entries; ignore absent keys and preserve
dictionary order in both results.

#### Examples

```ecl
{'a 1 'b 2} ['b] dict.split pair
# => ({'b 2} {'a 1})
```

### take
`( dict keys -- dict )` — Keep entries named by a key list, ignoring absent
keys. Output follows dictionary order independently of the requested key-list
order.

### update
`( dict keys quotation -- dict )` — Apply an isolated `( value -- value )`
quotation to each whole top-level key without moving entries. Keys are
processed in request order, so duplicates observe earlier updates. All keys
are validated before the quotation is first applied; an absent key is
`'domain`, and an empty key list returns the dictionary unchanged.

### update-or
`( dict key default quotation -- dict )` — Update an existing value as
`update` does, or append the absent key with the default unchanged. The default
does not pass through the quotation.

### vals
`( dict -- values )` — Return values in insertion order.
