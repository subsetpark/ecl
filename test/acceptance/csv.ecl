# DoD-26: RFC 4180 parsing and canonical emission over a corpus holding CRLF
# and LF records, empty fields, a header-looking first row,
# leading-zero text, a semicolon, an embedded comma, an embedded newline, and
# an escaped quote.
'cwd "test/acceptance/csv-corpus.csv" fs.read-text 'corpus set

# An explicit schema preserves text; transpose parsed columns for row emission.
corpus ['text 'text 'text] csv.parse flip 'rows set
rows io.pp
rows len io.pp
rows (len) each io.pp
rows 1 at first io.pp
rows 4 at first io.pp

# Canonical emission is CRLF-terminated and quotes exactly what must be quoted.
rows csv.emit io.pp

# Emission is the inverse of parsing on its own canonical output.
rows csv.emit ['text 'text 'text] csv.parse flip rows match? io.pp

# Empty input maps to an empty record list, and back to the empty string.
"" [] csv.parse len io.pp
"" [] csv.parse flip csv.emit len io.pp

# Malformed quoting is 'parse; invalid rows are 'type or 'shape.
[] ("\"unclosed" [] csv.parse) @attempt 'err at 'kind at io.pp
[] ("a\"b" [] csv.parse) @attempt 'err at 'kind at io.pp
[] (5 [] csv.parse) @attempt 'err at 'kind at io.pp
[] ((5) 1 pack csv.emit) @attempt 'err at 'kind at io.pp
[] (5 1 pack csv.emit) @attempt 'err at 'kind at io.pp
[] ([] 1 pack csv.emit) @attempt 'err at 'kind at io.pp

# Ragged and blank records cannot fit a multi-column result.
[] ("a,b\nc" [] csv.parse) @attempt 'err at 'kind at io.pp
[] ("a,b\n\n" [] csv.parse) @attempt 'err at 'kind at io.pp
