### module stdlib.test.json
[]
(
 'stdlib.test.support
 ('equal 'raises-containing 'raises-word 'documented)
 import

 ### test values
 (-- : "Parse and canonically emit every JSON value class.")
 ("1" json.parse 1 equal
  "3.5" json.parse 3.5 equal
  "[1,2,3]" json.parse [1 2 3] equal
  "{\"a\":1}" json.parse {"a" 1} equal
  "1" json.parse type 'int equal
  "3.5" json.parse type 'float equal
  "1e3" json.parse type 'float equal
  "9223372036854775808" json.parse type 'float equal
  "-9223372036854775808" json.parse type 'int equal
  "{\"a\":1,\"b\":[2,3],\"c\":null}"
  dup json.parse json.emit match? 1 equal
  "[1,2,[3,{\"x\":true}]]" dup json.parse json.emit match? 1 equal
  "{\"nested\":{\"deep\":[1,{\"x\":null}]}}"
  dup json.parse json.emit match? 1 equal
  "\"a\\nb\\\"c\"" dup json.parse json.emit match? 1 equal
  "[]" dup json.parse json.emit match? 1 equal
  "{}" dup json.parse json.emit match? 1 equal
  "\"\"" dup json.parse json.emit match? 1 equal
  1 json.emit "1" equal
  3.5 json.emit "3.5" equal
  "hi" json.emit "\"hi\"" equal
  [1 2 3] json.emit "[1,2,3]" equal
  {'a 1} json.emit "{\"a\":1}" equal)
 'values test

 ### test literals
 (-- : "Map JSON literals to ordinary ECL symbols in both directions.")
 ("null" json.parse 'null equal
  "null" json.parse type 'symbol equal
  'null json.emit "null" equal
  "[true,false,null]" json.parse ['true 'false 'null] equal
  "[true,false,null]" dup json.parse json.emit match? 1 equal
  "[1,null]" json.parse dup 1 at type 'symbol equal len 2 equal)
 'literals test

 ### test invalid-input
 (-- : "Reject malformed documents and values with no JSON representation.")
 (("" json.parse) 'parse 'json.parse raises-word
  ("1 2" json.parse) 'parse 'json.parse raises-word
  ("{\"a\":}" json.parse) 'parse 'json.parse raises-word
  ({1 2} json.emit) 'type "string or symbol dictionary keys" raises-containing
  ({} [1] 2 put json.emit)
  'type
  "string or symbol dictionary keys"
  raises-containing
  ('foo json.emit) 'type "cannot represent the symbol" raises-containing
  ("a" first json.emit) 'type 'json.emit raises-word)
 'invalid-input test

 ### test documentation
 (-- : "Require documentation for every JSON export.")
 (('json.parse 'json.emit) documented)
 'documentation test
) 'stdlib.test.json @defm
