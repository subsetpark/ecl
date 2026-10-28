## table

Every operation except `valid?` first validates the ordinary column dict as a
table. See the environment's [table contract](ENVIRONMENT.md#tables) for the
table convention and frozen error kinds.

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
