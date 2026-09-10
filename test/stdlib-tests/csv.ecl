### module stdlib.test.csv
[]
(
 'stdlib.test.support
 ('equal 'raises-containing 'raises-word 'documented)
 import
 'str ('repeat) import

 ### test parse
 (-- : "Parse RFC 4180 records without losing text, empty fields, or widths.")
 ("a,b,c" [] csv.parse flip (("a" "b" "c")) equal
  "a,b\nc,d" [] csv.parse "a,b\u{d}\nc,d\u{d}\n" [] csv.parse match? 1 equal
  "\"a,b\",c" [] csv.parse flip (("a,b" "c")) equal
  "\"a\nb\",c" [] csv.parse flip (("a\nb" "c")) equal
  "\"a\"\"b\",c" [] csv.parse flip (("a\"b" "c")) equal
  "a,,c" [] csv.parse len 3 equal
  ("a,b,c\nd" [] csv.parse) 'shape 'csv.parse raises-word
  "," [] csv.parse flip first (len) each [0 0] equal
  "" [] csv.parse len 0 equal
  "a" [] csv.parse len 1 equal
  "a\n" [] csv.parse len 1 equal
  "a\n\n" [] csv.parse first len 2 equal
  "\n" [] csv.parse len 1 equal
  "name,age\nAda,36" [] csv.parse flip
  (("name" "age") ("Ada" "36")) equal
  "01,002" [] csv.parse first first "01" equal
  "a;b" [] csv.parse first len 1 equal)
 'parse test

 ### test emit
 (-- : "Emit canonical CRLF records and resume across scheduler quanta.")
 ("a,b,c" [] csv.parse flip csv.emit "a,b,c\u{d}\n" equal
  "\"a,b\",c" [] csv.parse flip csv.emit "\"a,b\",c\u{d}\n" equal
  "\"a\"\"b\",c" [] csv.parse flip csv.emit
  "\"a\"\"b\",c\u{d}\n" equal
  "\"a\nb\",c" [] csv.parse flip csv.emit "\"a\nb\",c\u{d}\n" equal
  "" [] csv.parse flip csv.emit len 0 equal
  "a,b\u{d}\nc,d\u{d}\n" dup [] csv.parse flip csv.emit match? 1 equal
  "\"a\"\"b\",\"c,d\"\u{d}\n" dup [] csv.parse flip csv.emit match? 1 equal
  "a,,c\u{d}\n" dup [] csv.parse flip csv.emit match? 1 equal
  "ab,cd\u{d}\n" 12000 repeat dup [] csv.parse flip csv.emit match? 1 equal
  "\"a\"\"b\",\"c,d\"\u{d}\n" 8000 repeat
  dup [] csv.parse flip csv.emit match? 1 equal)
 'emit test

 ### test invalid-input
 (-- : "Reject malformed quoting and invalid row or field shapes.")
 (("\"unclosed" [] csv.parse) 'parse "malformed quoting" raises-containing
  ("a\"b" [] csv.parse) 'parse 'csv.parse raises-word
  ("\"a\"b" [] csv.parse) 'parse 'csv.parse raises-word
  (5 [] csv.parse) 'type 'csv.parse raises-word
  (5 csv.emit) 'type 'csv.emit raises-word
  (5 1 pack csv.emit) 'type "every record to be a list" raises-containing
  ((5) 1 pack csv.emit) 'type "every field to be a string" raises-containing
  ([] 1 pack csv.emit) 'shape "no fields" raises-containing)
 'invalid-input test

 ### test columns-and-schema
 (-- : "Infer whole columns conservatively and apply strict positional overrides.")
 ("1,2.5,a\n2,3.5,b" [] csv.parse ([1 2] [2.5 3.5] ("a" "b")) equal
  "1\n2.5" [] csv.parse ([1.0 2.5]) equal
  "01\n2" [] csv.parse (("01" "2")) equal
  "1\n\n" [] csv.parse (("1" "")) equal
  "9007199254740993\n1.5" [] csv.parse (("9007199254740993" "1.5")) equal
  "9223372036854775808\n2" [] csv.parse (("9223372036854775808" "2")) equal
  "01,+2\n003,4" ['int 'float] csv.parse ([1 3] [2.0 4.0]) equal
  "1,2\n3,4" ['text 'auto] csv.parse (("1" "3") [2 4]) equal
  "" ['int 'text] csv.parse ([] []) equal
  ("1\n\n" ['int] csv.parse) 'parse "record 2, column 1" raises-containing
  ("1,2" ['int] csv.parse) 'shape 'csv.parse raises-word
  ("1" ['bool] csv.parse) 'domain 'csv.parse raises-word
  ("1" [1] csv.parse) 'domain 'csv.parse raises-word)
 'columns-and-schema test

 ### test headers
 (-- : "Return headers separately and compose ordinary table constructors.")
 ("id,name\n1,Ada\n2,Bob" [] csv.parse-header
  dict.from-lists table.from-columns
  {"id" [1 2] "name" ("Ada" "Bob")} equal
  "id,name" [] csv.parse-header ([] []) equal ("id" "name") equal
  "x,x," [] csv.parse-header pop ("x" "x" "") equal
  ("" [] csv.parse-header) 'shape 'csv.parse-header raises-word
  ("id\n" ['float 'text] csv.parse-header) 'shape 'csv.parse-header raises-word)
 'headers test

 ### test bytes-and-boundaries
 (-- : "Decode UTF-8 and preserve fields across bulk and scheduler boundaries.")
 ([105 100 44 110 97 109 101 10 49 44 195 169] [] csv.parse-header
  dict.from-lists {"id" [1] "name" ("é")} equal
  ([195] [] csv.parse) 'parse 'csv.parse raises-word
  ([237 160 128] [] csv.parse) 'parse 'csv.parse raises-word
  ([192 128] [] csv.parse) 'parse 'csv.parse raises-word
  "é,λ,😀" [] csv.parse flip (("é" "λ" "😀")) equal
  "1\n" 6000 repeat "001\n" cat [] csv.parse first
  dup len 6001 equal dup first "1" equal last "001" equal
  "0" 2000 repeat "1" cat ['int] csv.parse ([1]) equal
  "1." "0" 2000 repeat cat "1" cat ['float] csv.parse ([1.0]) equal)
 'bytes-and-boundaries test

 ### test documentation
 (-- : "Require documentation for every CSV export.")
 (('csv.parse 'csv.parse-header 'csv.emit) documented)
 'documentation test
) 'stdlib.test.csv @defm
