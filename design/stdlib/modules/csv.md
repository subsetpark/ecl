## csv

### parse-header

#### Examples

```ecl
"1,a\n2,b" [] csv.parse
# => ([1 2] ("a" "b"))

"id,name\n1,Ada\n2,Bob" [] csv.parse-header
dict.from-lists table.from-columns
# => {"id" [1 2] "name" ("Ada" "Bob")}

"01,2\n03,4" [text int] csv.parse
# => (("01" "03") [2 4])
```
