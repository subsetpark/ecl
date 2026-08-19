# DoD-25: RFC 8259 mapping and round-trip over a corpus with nested objects and
# arrays, null, the booleans, integral and non-integral numbers.
"test/acceptance/json-corpus.json" slurp 'corpus set

corpus json.parse 'value set
value pp

# Objects become dicts with string keys, arrays become lists.
value "tags" at pp
value "scores" at pp

# Integral in-range numbers become ints; everything else numeric is a float.
value "scores" at "a" at type pp
value "scores" at "b" at type pp
value "neg" at type pp
value "big" at type pp

# null, true, and false are ordinary symbols: data, not language nil or
# language booleans, which is what lets them round-trip.
value "note" at pp
value "note" at type pp
value "active" at pp
value "retired" at pp

# Emission is the inverse of parsing on the canonical corpus.
value json.emit corpus match pp

# Nested and empty aggregates round-trip too.
"[1,2,[3,{\"x\":null}]]" dup json.parse json.emit match pp
"[]" dup json.parse json.emit match pp
"{}" dup json.parse json.emit match pp
"\"\"" dup json.parse json.emit match pp
"\"a\\nb\\\"c\"" dup json.parse json.emit match pp

# Emission requires string or symbol dict keys, and rejects values with no
# JSON form.
({1 2} json.emit) @attempt 'err at 'kind at pp
('foo json.emit) @attempt 'err at 'kind at pp
("a" first json.emit) @attempt 'err at 'kind at pp

# Malformed and empty input are 'parse.
("" json.parse) @attempt 'err at 'kind at pp
("{\"a\":}" json.parse) @attempt 'err at 'kind at pp
("1 2" json.parse) @attempt 'err at 'kind at pp
