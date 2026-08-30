### module stdlib.test.str
(
 'stdlib.test.support
 ('equal 'raises-containing 'documented)
 import

 ### test case-operations
 (-- : "Apply ASCII-only case conversion while preserving every codepoint.")
 ("hello" str.upper "HELLO" equal
  "HELLO" str.lower "hello" equal
  "HeLLo, Wörld! 123" str.upper "HELLO, WöRLD! 123" equal
  "HeLLo, Wörld! 123" str.lower "hello, wörld! 123" equal
  "HeLLo, Wörld!" dup len swap str.upper len = 1 equal
  "MiXeD" str.upper dup str.upper match? 1 equal
  "MiXeD" str.lower dup str.lower match? 1 equal
  "@[`{" str.upper "@[`{" equal
  "@[`{" str.lower "@[`{" equal)
 'case-operations test

 ### test trimming
 (-- : "Trim exactly the ASCII whitespace scalars from requested edges.")
 ("  hi  " str.trim "hi" equal
  "  hi  " str.trim-left "hi  " equal
  "  hi  " str.trim-right "  hi" equal
  " \t\n\u{B}\u{C}\u{D}hi\t " str.trim "hi" equal
  "   " str.trim "" equal
  "" str.trim "" equal
  "  a b  " str.trim "a b" equal
  "  hi  " str.trim dup str.trim match? 1 equal)
 'trimming test

 ### test search
 (-- : "Handle prefix, suffix, containment, and index edge cases consistently.")
 ("hello" "he" str.starts? 1 equal
  "hello" "lo" str.ends? 1 equal
  "hello" "lo" str.starts? 0 equal
  "hello" "he" str.ends? 0 equal
  "hello" "hello!" str.starts? 0 equal
  "hello" "!hello" str.ends? 0 equal
  "" "x" str.starts? 0 equal
  "" "x" str.ends? 0 equal
  "hello" "" str.starts? 1 equal
  "hello" "" str.ends? 1 equal
  "hello" "hello" str.starts? 1 equal
  "" "" str.starts? 1 equal
  "hello" "ell" str.contains? 1 equal
  "hello" "zz" str.contains? 0 equal
  "hello" "l" str.index-of 2 equal
  "hello" "hello" str.index-of 0 equal
  "a" "" str.contains? 1 equal
  "" "" str.contains? 1 equal
  "a" "" str.index-of 0 equal
  "" "" str.index-of 0 equal
  ("hello" "zz" str.index-of)
  'domain
  "no occurrence"
  raises-containing)
 'search test

 ### test construction
 (-- : "Replace, repeat, and pad strings by explicit widths.")
 ("a-b-c" "-" "+" str.replace "a+b+c" equal
  "a-b" "-" "" str.replace "ab" equal
  "abc" "z" "!" str.replace "abc" equal
  "ab" "" "-" str.replace "a-b" equal
  "ab" 3 str.repeat "ababab" equal
  "ab" 1 str.repeat "ab" equal
  "ab" 0 str.repeat "" equal
  "" 3 str.repeat "" equal
  "7" 3 str.pad-left "  7" equal
  "7" 3 str.pad-right "7  " equal
  "abcd" 3 str.pad-left "abcd" equal
  "abcd" 3 str.pad-right "abcd" equal
  "" 2 str.pad-left "  " equal
  ("ab" -1 str.repeat) 'domain "nonnegative count" raises-containing)
 'construction test

 ### test validation
 (-- : "Validate complete public arguments before executing string kernels.")
 ((5 str.upper) 'type "str.upper expects a string" raises-containing
  ([\a 1] str.lower) 'type "str.lower expects a string" raises-containing
  (5 str.trim-left) 'type "str.trim-left expects a string" raises-containing
  (5 str.trim-right) 'type "str.trim-right expects a string" raises-containing
  (5 str.trim) 'type "str.trim expects a string" raises-containing
  ("abc" 5 str.starts?)
  'type
  "string and a string prefix"
  raises-containing
  (5 "c" str.ends?) 'type "string and a string suffix" raises-containing
  ("abc" 5 str.contains?)
  'type
  "string and a string needle"
  raises-containing
  (5 "a" str.index-of)
  'type
  "string and a string needle"
  raises-containing
  ("a" "a" 5 str.replace)
  'type
  "needle, and replacement strings"
  raises-containing
  (5 2 str.repeat)
  'type
  "string and an integer count"
  raises-containing
  ("a" 2.5 str.repeat)
  'type
  "string and an integer count"
  raises-containing
  ("a" 2.5 str.pad-left)
  'type
  "string and an integer width"
  raises-containing
  (5 2 str.pad-right)
  'type
  "string and an integer width"
  raises-containing)
 'validation test

 ### test documentation
 (-- : "Expose documentation for every str module export.")
 (['str.upper 'str.lower 'str.trim 'str.trim-left 'str.trim-right
   'str.starts? 'str.ends? 'str.contains? 'str.index-of 'str.replace
   'str.repeat 'str.pad-left 'str.pad-right]
  documented)
 'documentation test
) 'stdlib.test.str @defm
