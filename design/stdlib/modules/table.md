## table

### at

#### Examples

```ecl
{"name" ("Ada" "Lin" "Bo") "score" [20 10 30]} dup "score" at grade table.at
# => {"name" ("Lin" "Ada" "Bo") "score" [10 20 30]}

{"name" ("Ada" "Lin") "score" [10 20]} [1 0] where table.at
# => {"name" ("Ada") "score" [10]}
```

Gathering `group-by`'s index lists makes each column a list of per-group
slices. The first cell of each key slice is that group's key, and reducing
each value slice aggregates it:

```ecl
{"region" ["east" "west" "east"] "amount" [10 20 30]} dup ["region"] table.group-by
dict.vals table.at
# => {"region" (("east" "east") ("west")) "amount" ([10 30] [20])}

dup ["region"] table.select ((first) each) each
"total" rolldown "amount" at (sum) each table.with-column
# => {"region" ("east" "west") "total" [40 20]}
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
