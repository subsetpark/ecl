### module stdlib.test.support
(
 ### defp assert-true
 (condition -- : "Fail a userland stdlib assertion when condition is false.")
 ({'kind 'user 'msg "userland stdlib assertion failed"} assert)
 'assert-true defp

 ### def equal
 (actual expected -- : "Assert structural equality between two values.")
 (match? assert-true)
 'equal def

 ### def raises
 (quotation kind -- : "Assert that a quotation fails with the expected kind.")
 (|quotation kind|
  quotation @attempt
  dup result.err? assert-true
  'err at 'kind at kind equal)
 'raises def

 ### def raises-containing
 (quotation kind text -- : "Assert a failure kind and message fragment.")
 (|quotation kind text|
  quotation @attempt
  dup result.err? assert-true
  'err at
  dup 'kind at kind equal
  'msg at text str.contains? assert-true)
 'raises-containing def

 ### def raises-word
 (quotation kind word -- : "Assert a failure kind and responsible word.")
 (|quotation kind word|
  quotation @attempt
  dup result.err? assert-true
  'err at
  dup 'kind at kind equal
  'word at word equal)
 'raises-word def

 ### def raises-data
 (quotation kind key expected -- : "Assert a failure kind and one data field.")
 (|quotation kind key expected|
  quotation @attempt
  dup result.err? assert-true
  'err at
  dup 'kind at kind equal
  'data at key at expected equal)
 'raises-data def

 ### def documented
 (names -- : "Assert that every qualified word has nonempty documentation.")
 ((doc len 0 >) all? assert-true)
 'documented def
) 'stdlib.test.support @defm
