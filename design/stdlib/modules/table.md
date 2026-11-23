## table

### aggregate

#### Examples

Given this table, grouped by `"region"`:

```ecl
{"region" ["east" "west" "east"] "amount" [10 20 30]}
```

the quotation receives the non-key columns, each holding one slice per group,
in first-seen group order (`"east"`, then `"west"`):

```ecl
{"amount" ([10 30] [20])}
```

It reduces each slice and returns the output columns, which follow the key
columns in the result:

```ecl
{"region" ["east" "west" "east"] "amount" [10 20 30]} ["region"]
(|g| {} "total" g "amount" at (sum) each put "n" g "amount" at (len) each put)
table.aggregate
# => {"region" ("east" "west") "total" [40 20] "n" [2 1]}
```

### from-records

#### Examples

```ecl
[{"name" "Ada" "score" 10} {"name" "Lin" "score" 20}] table.from-records
# => {"name" ("Ada" "Lin") "score" [10 20]}
```

### from-rows

#### Examples

```ecl
["name" "score"] [("Ada" 10) ("Lin" 20)] table.from-rows
# => {"name" ("Ada" "Lin") "score" [10 20]}
```

### records

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} table.records
# => ({"name" "Ada" "score" 10} {"name" "Lin" "score" 20})
```

### select

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} ("score") table.select
# => {"score" [10 20]}
```

### where

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} [1 0] table.where
# => {"name" ("Ada") "score" [10]}
```
