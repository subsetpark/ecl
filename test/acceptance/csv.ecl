# DoD-26: RFC 4180 parsing and canonical emission over a corpus holding CRLF
# and LF records, a blank record, a ragged record, a header-looking first row,
# leading-zero text, a semicolon, an embedded comma, an embedded newline, and
# an escaped quote.
"test/acceptance/csv-corpus.csv" slurp 'corpus set

# Every field is text. Nothing is inferred: no header, no delimiter sniffing,
# no scalar coercion.
corpus csv.parse 'rows set
rows pp
rows len pp
rows (len) each pp
rows 1 at first pp
rows 4 at first pp

# Canonical emission is CRLF-terminated and quotes exactly what must be quoted.
rows csv.emit pp

# Emission is the inverse of parsing on its own canonical output.
rows csv.emit csv.parse rows match pp

# Empty input maps to an empty record list, and back to the empty string.
"" csv.parse len pp
"" csv.parse csv.emit len pp

# Malformed quoting is 'parse; invalid rows are 'type or 'shape.
("\"unclosed" csv.parse) @attempt 'err at 'kind at pp
("a\"b" csv.parse) @attempt 'err at 'kind at pp
(5 csv.parse) @attempt 'err at 'kind at pp
((5) 1 pack csv.emit) @attempt 'err at 'kind at pp
(5 1 pack csv.emit) @attempt 'err at 'kind at pp
([] 1 pack csv.emit) @attempt 'err at 'kind at pp
