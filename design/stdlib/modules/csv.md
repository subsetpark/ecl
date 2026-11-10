## csv

### parse

#### Examples

```ecl
"1,a\n2,\"b,c\"" csv.parse
# => (("1" "a") ("2" "b,c"))

"id,name\n1,Ada\n2,Bob" csv.parse table.from-header-rows {"id" (int)} table.cast
# => {"id" [1 2] "name" ("Ada" "Bob")}
```

### emit

#### Examples

```ecl
(("a,b" "c") ("say \"hi\"" "")) csv.emit
# => "\"a,b\",c\u{d}\n\"say \"\"hi\"\"\",\u{d}\n"
```
