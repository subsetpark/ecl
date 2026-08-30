### module stdlib.test.csv
(
 'stdlib.test.support
 ('equal 'raises-containing 'raises-word 'documented)
 import
 'str ('repeat) import

 ### test parse
 (-- : "Parse RFC 4180 records without losing text, empty fields, or widths.")
 ("a,b,c" csv.parse (("a" "b" "c")) equal
  "a,b\nc,d" csv.parse "a,b\u{d}\nc,d\u{d}\n" csv.parse match? 1 equal
  "\"a,b\",c" csv.parse (("a,b" "c")) equal
  "\"a\nb\",c" csv.parse (("a\nb" "c")) equal
  "\"a\"\"b\",c" csv.parse (("a\"b" "c")) equal
  "a,,c" csv.parse first len 3 equal
  "a,b,c\nd" csv.parse (len) each [3 1] equal
  "," csv.parse first (len) each [0 0] equal
  "" csv.parse len 0 equal
  "a" csv.parse len 1 equal
  "a\n" csv.parse len 1 equal
  "a\n\n" csv.parse len 2 equal
  "\n" csv.parse len 1 equal
  "name,age\nAda,36" csv.parse
  (("name" "age") ("Ada" "36")) equal
  "01,002" csv.parse first first "01" equal
  "a;b" csv.parse first len 1 equal)
 'parse test

 ### test emit
 (-- : "Emit canonical CRLF records and resume across scheduler quanta.")
 ("a,b,c" csv.parse csv.emit "a,b,c\u{d}\n" equal
  "\"a,b\",c" csv.parse csv.emit "\"a,b\",c\u{d}\n" equal
  "\"a\"\"b\",c" csv.parse csv.emit
  "\"a\"\"b\",c\u{d}\n" equal
  "\"a\nb\",c" csv.parse csv.emit "\"a\nb\",c\u{d}\n" equal
  "" csv.parse csv.emit len 0 equal
  "a,b\u{d}\nc,d\u{d}\n" dup csv.parse csv.emit match? 1 equal
  "\"a\"\"b\",\"c,d\"\u{d}\n" dup csv.parse csv.emit match? 1 equal
  "a,,c\u{d}\n" dup csv.parse csv.emit match? 1 equal
  "ab,cd\u{d}\n" 12000 repeat dup csv.parse csv.emit match? 1 equal
  "\"a\"\"b\",\"c,d\"\u{d}\n" 8000 repeat
  dup csv.parse csv.emit match? 1 equal)
 'emit test

 ### test invalid-input
 (-- : "Reject malformed quoting and invalid row or field shapes.")
 (("\"unclosed" csv.parse) 'parse "malformed quoting" raises-containing
  ("a\"b" csv.parse) 'parse 'csv.parse raises-word
  ("\"a\"b" csv.parse) 'parse 'csv.parse raises-word
  (5 csv.parse) 'type 'csv.parse raises-word
  (5 csv.emit) 'type 'csv.emit raises-word
  (5 1 pack csv.emit) 'type "every record to be a list" raises-containing
  ((5) 1 pack csv.emit) 'type "every field to be a string" raises-containing
  ([] 1 pack csv.emit) 'shape "no fields" raises-containing)
 'invalid-input test

 ### test documentation
 (-- : "Require documentation for every CSV export.")
 (('csv.parse 'csv.emit) documented)
 'documentation test
) 'stdlib.test.csv @defm
