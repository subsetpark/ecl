## json

### emit
`( value -- text )` — Render an ECL value as RFC 8259 JSON. Dict keys must be
strings or symbols; the only emitted symbol values are `'null`, `'true`, and
`'false`.

### parse
`( text -- value )` — Parse RFC 8259 JSON. Objects become string-keyed dicts,
arrays become lists, in-range integral numbers become ints, and other numbers
become floats. JSON null and booleans become the ordinary symbols `'null`,
`'true`, and `'false`.

#### Examples

```ecl
"{\"a\":[1,null]}" json.parse
# => {"a" (1 'null)}
```
