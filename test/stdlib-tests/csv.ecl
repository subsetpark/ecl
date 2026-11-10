### module stdlib.test.csv
(
 `stdlib.test.support
 (equal raises-containing documented)
 import
 `str (repeat) import

 ### test parse
 (-- : "Parse RFC 4180 records without losing text, empty fields, or widths.")
 ("a,b,c" csv.parse (("a" "b" "c")) equal
  "a,b\nc,d" csv.parse "a,b\u{d}\nc,d\u{d}\n" csv.parse match? 1 equal
  "\"a,b\",c" csv.parse (("a,b" "c")) equal
  "\"a\nb\",c" csv.parse (("a\nb" "c")) equal
  "\"a\u{d}\nb\",c" csv.parse (("a\u{d}\nb" "c")) equal
  "\"a\"\"b\",c" csv.parse (("a\"b" "c")) equal
  "\"\",\"\"\"\"" csv.parse (("" "\"")) equal
  "a,,c" csv.parse first len 3 equal
  "," csv.parse first (len) each [0 0] equal
  "" csv.parse len 0 equal
  "a" csv.parse (("a")) equal
  "a\n" csv.parse (("a")) equal
  "a\n\n" csv.parse (("a") ("")) equal
  "\n" csv.parse (("")) equal
  "name,age\nAda,36" csv.parse (("name" "age") ("Ada" "36")) equal
  "01,002,1.50, 7" csv.parse (("01" "002" "1.50" " 7")) equal
  "a;b" csv.parse first len 1 equal)
 `parse test

 ### test emit
 (-- : "Emit canonical CRLF records that parse back to the same rows.")
 ("a,b,c" csv.parse csv.emit "a,b,c\u{d}\n" equal
  "\"a,b\",c" csv.parse csv.emit "\"a,b\",c\u{d}\n" equal
  "\"a\"\"b\",c" csv.parse csv.emit "\"a\"\"b\",c\u{d}\n" equal
  "\"a\nb\",c" csv.parse csv.emit "\"a\nb\",c\u{d}\n" equal
  (("a\u{d}b" "") ("" "é😀")) csv.emit "\"a\u{d}b\",\u{d}\n,é😀\u{d}\n" equal
  "" csv.parse csv.emit len 0 equal
  (("")) csv.emit "\u{d}\n" equal
  "a,b\u{d}\nc,d\u{d}\n" dup csv.parse csv.emit match? 1 equal
  "\"a\"\"b\",\"c,d\"\u{d}\n" dup csv.parse csv.emit match? 1 equal
  "a,,c\u{d}\n" dup csv.parse csv.emit match? 1 equal)
 `emit test

 ### test across-blocks
 (-- : "Records, quoted fields, and escapes keep their text where the lexer's blocks meet.")
 ("ab,cd\u{d}\n" 12000 repeat dup csv.parse dup len 12000 equal csv.emit match? 1 equal
  "\"a\"\"b\",\"c,d\"\u{d}\n" 8000 repeat dup csv.parse csv.emit match? 1 equal
  "1\n" 40000 repeat "001\n" cat csv.parse dup len 40001 equal last ("001") equal
  "x" 150000 repeat
  (|long|
   "a,\"" long cat "\nq\"\"\",z\nb,c,d" cat csv.parse
   dup (len) each [3 3] equal dup first 1 at len 150003 equal 1 at ("b" "c" "d") equal)
  call
  ("a,b\n" 20000 repeat "\"open" cat csv.parse) `parse "record 20001, column 1"
  raises-containing)
 `across-blocks test

 ### test invalid-input
 (-- : "Reject malformed quoting, ragged records, and invalid row or field shapes.")
 (("\"unclosed" csv.parse) `parse "malformed quoting at record 1, column 1" raises-containing
  ("a\"b" csv.parse) `parse "record 1, column 1" raises-containing
  ("x,y\n1,\"a\"b" csv.parse) `parse "record 2, column 2" raises-containing
  ("a\u{d}b" csv.parse) `parse "malformed quoting" raises-containing
  ("a,b\u{d}" csv.parse) `parse "record 1, column 2" raises-containing
  ("a,b,c\nd" csv.parse) `shape "record 2 has 1 fields where record 1 has 3" raises-containing
  ("a,b\n\n" csv.parse) `shape "record 2" raises-containing
  (5 csv.parse) `type "chars expected" raises-containing
  (5 csv.emit) `type "a list of records" raises-containing
  (5 wrap csv.emit) `type "every record to be a list" raises-containing
  ((5) wrap csv.emit) `type "every field to be a string" raises-containing
  (([1 2]) wrap csv.emit) `type "every field to be a string" raises-containing
  ([] wrap csv.emit) `shape "no fields" raises-containing)
 `invalid-input test

 ### test typed-columns
 (-- : "Fields stay text until a table cast converts a column.")
 ("id,score,name\n1,2.5,Ada\n02,3,Bob" csv.parse table.from-header-rows
  dup {"id" ("1" "02") "score" ("2.5" "3") "name" ("Ada" "Bob")} equal
  {"id" (int) "score" (float)} table.cast
  {"id" [1 2] "score" [2.5 3.0] "name" ("Ada" "Bob")} equal
  ("id\nx" csv.parse table.from-header-rows {"id" (int)} table.cast pop) `parse "integer literal"
  raises-containing)
 `typed-columns test

 ### test bytes
 (-- : "Decode UTF-8 byte input as `chars` does.")
 ([105 100 44 110 97 109 101 10 49 44 195 169] csv.parse (("id" "name") ("1" "é")) equal
  ([195] csv.parse) `domain "not valid UTF-8" raises-containing
  "é,λ,😀" csv.parse (("é" "λ" "😀")) equal
  "é,λ,😀" bytes csv.parse (("é" "λ" "😀")) equal)
 `bytes test

 ### test documentation
 (-- : "Require documentation for every CSV export.")
 ((csv.parse csv.emit) documented)
 `documentation test

) `stdlib.test.csv @defm
