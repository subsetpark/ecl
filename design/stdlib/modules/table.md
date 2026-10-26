## table

Every operation except `valid?` first validates the ordinary column dict as a
table. See the environment's [table contract](ENVIRONMENT.md#tables) for the
table convention and frozen error kinds.

### aggregate
`( table names specs -- table )` — Group by `names` and aggregate each group
with `[output input reducer]` triples. A reducer is a quotation or one of
`'sum`, `'count`, `'min`, and `'max`. Symbols use `reduce-groups`;
quotations receive gathered slices and retain ordinary resolution and shadowing.
Validate the complete specification before running a quotation; key columns
precede aggregate columns.

### cast
`( table spec -- table )` — Coerce named columns with isolated
`( cell -- value )` quotations. Validate the complete specification before
running any quotation and replace the table only after all casts succeed.

### column
`( table name -- column )` — Return one existing named column.

### from-columns
`( columns -- table )` — Return a column dict as a table, raising when it does
not satisfy the convention.

### from-header-rows
`( rows -- table )` — Build a table from rows whose first row contains column
names.

### from-records
`( records -- table )` — Build a table from a nonempty list of dicts sharing
one key set; the first record fixes schema order.

#### Examples

```ecl
[{"name" "Ada" "score" 10} {"name" "Lin" "score" 20}] table.from-records
# => {"name" ("Ada" "Lin") "score" [10 20]}
```

### from-rows
`( names rows -- table )` — Build a table from explicit names and exact-width
rows. An empty row list preserves the named zero-row schema.

#### Examples

```ecl
["name" "score"] [("Ada" 10) ("Lin" 20)] table.from-rows
# => {"name" ("Ada" "Lin") "score" [10 20]}
```

### group-by
`( table names -- groups )` — Group row indices by named columns. Keys use
first-occurrence order and indices stay ascending; zero names yields one global
group keyed by the empty list.

### header-rows
`( table -- rows )` — Return data rows prefixed by the column-name row, the
schema-preserving row form.

### height
`( table -- count )` — Return the row count.

### inner-join
`( left right pairs -- table )` — Stable inner equijoin on
`[left-name right-name]` pairs. Duplicate keys expand to the full
many-to-many product in left-row then right-row order.

### left-join-with
`( left right pairs fill -- table )` — Stable left equijoin. `fill` must name
exactly every appended right column used for unmatched rows.

### names
`( table -- names )` — Return column names in schema order.

### records
`( table -- records )` — Return rows as dicts in schema order. An empty result
necessarily loses its schema.

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} table.records
# => ({"name" "Ada" "score" 10} {"name" "Lin" "score" 20})
```

### rename
`( table mapping -- table )` — Rename columns through an ordered old-to-new
mapping while preserving column order; collisions are `'domain`.

### rows
`( table -- rows )` — Return data rows in order.

### select
`( table names -- table )` — Keep named columns in the order given.

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} ("score") table.select
# => {"score" [10 20]}
```

### valid?
`( candidate -- bool )` — Return 1 when a candidate satisfies the convention
and 0 for a convention mismatch. Cancellation and allocation failure still
propagate.

### where
`( table mask -- table )` — Keep rows selected by an exact-length 0/1 mask.

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} [1 0] table.where
# => {"name" ("Ada") "score" [10]}
```

### with-column
`( table name column -- table )` — Replace an existing column or append a new
one, keeping the row count exact.
