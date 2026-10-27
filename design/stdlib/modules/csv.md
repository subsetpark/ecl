## csv

### emit
`( rows -- text )` — Render rows of string fields as canonical,
CRLF-terminated RFC 4180 text, quoting exactly the fields that require it.
Non-list rows and non-string cells are `` `type ``; a zero-field row is `` `shape ``.

### parse
`( input schema -- columns )` — Parse comma-separated content into a list
of equal-length columns. Input is a string or a list of UTF-8 bytes. All records
are data. Accept CRLF or LF records, quoted commas and newlines, doubled-quote
escapes, and a final CR at EOF. Preserve blank records and empty fields.

Schema is `[]` for inference, or one symbol per column: `` `auto ``, `` `int ``,
`` `float ``, or `` `text ``. Inference considers every data field. Canonical decimal
integers become signed 64-bit integers; decimal fractions and exponent forms
become finite binary64 floats. Integer-to-float widening requires exact
representation of every integer. Empty fields, leading zeros, leading plus,
negative integer zero, whitespace, incompatible text, and numeric overflow
make an inferred column text. Quoting does not force text. Text fallback
preserves decoded source spelling, including earlier numeric-looking fields.
An inferred column with no data is text.

Explicit numeric schemas accept decimal leading zeros and signs, reject empty
or unconvertible fields, and never fall back to text. Explicit floats permit
rounding integers. Boolean, date, and null inference are not performed.

Empty input produces no columns with `[]`, or empty columns matching the
schema. Unequal record widths and schema-width mismatches are `` `shape ``.
Malformed quoting, invalid UTF-8, and failed numeric conversions are `` `parse ``;
conversion failures identify record and column. Invalid schema entries are
`` `domain ``, and invalid input kinds are `` `type ``. Parsing supports at most 1,019
columns, reserving the remaining native builder slots for materialization;
exceeding that limit is `` `shape ``.

### parse-header
`( input schema -- headers columns )` — Like `parse`, but return the first
record separately as text headers and exclude it from inference. Empty input
is `` `shape ``; a header-only input produces matching empty columns. Preserve
header names verbatim, including duplicates and empty names. Dictionary and
table constructors apply their own name restrictions.

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
