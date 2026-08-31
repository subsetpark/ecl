# DoD-25: RFC 8259 mapping and round-trip over a corpus with nested objects and
# arrays, null, the booleans, integral and non-integral numbers.
"test/acceptance/json-corpus.json" io.slurp 'corpus set

corpus json.parse 'value set
value io.pp

# Objects become dicts with string keys, arrays become lists.
value "tags" at io.pp
value "scores" at io.pp

# Integral in-range numbers become ints; everything else numeric is a float.
value "scores" at "a" at type io.pp
value "scores" at "b" at type io.pp
value "neg" at type io.pp
value "big" at type io.pp

# null, true, and false are ordinary data symbols. They introduce neither
# language nil nor language booleans, which lets them round-trip.
value "note" at io.pp
value "note" at type io.pp
value "active" at io.pp
value "retired" at io.pp

# Emission is the inverse of parsing on the canonical corpus.
value json.emit corpus match? io.pp

# Nested and empty aggregates round-trip too.
"[1,2,[3,{\"x\":null}]]" dup json.parse json.emit match? io.pp
"[]" dup json.parse json.emit match? io.pp
"{}" dup json.parse json.emit match? io.pp
"\"\"" dup json.parse json.emit match? io.pp
"\"a\\nb\\\"c\"" dup json.parse json.emit match? io.pp

# Emission requires string or symbol dict keys, and rejects values with no
# JSON form.
[] ({1 2} json.emit) @attempt 'err at 'kind at io.pp
[] ('foo json.emit) @attempt 'err at 'kind at io.pp
[] ("a" first json.emit) @attempt 'err at 'kind at io.pp

# Malformed and empty input are 'parse.
[] ("" json.parse) @attempt 'err at 'kind at io.pp
[] ("{\"a\":}" json.parse) @attempt 'err at 'kind at io.pp
[] ("1 2" json.parse) @attempt 'err at 'kind at io.pp
