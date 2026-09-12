### module pkg.test.glob
[]
(
 ### defp check
 (pattern path expected -- : "Assert source-pattern selection independently of the matcher.")
 (|pattern path expected|
  pattern path pkg.glob.matches? expected match?
  {'kind 'user 'msg "source glob assertion failed"} assert) 'check defp

 ### test source-patterns
 (-- : "Match component wildcards and recursive paths with no exponential backtracking.")
 ("src/**/*.ecl" "src/main.ecl" 1 check
  "src/**/*.ecl" "src/deep/main.ecl" 1 check
  "src/*.ecl" "src/deep/main.ecl" 0 check
  "**/main.ecl" "main.ecl" 1 check
  "**/main.ecl" "src/main.ecl" 1 check
  "**/main.ecl" "src/main.txt" 0 check
  "src/**" "src/one/two" 1 check
  "a?c" "abc" 1 check
  "a?c" "ac" 0 check
  "a*c" "ac" 1 check
  "a*c" "abc" 1 check
  "a*c" "ab" 0 check
  "a*b*c" "abbc" 1 check
  "a*b*c" "abcx" 0 check
  "?" "λ" 0 check
  "??" "λ" 1 check
  "λ*.ecl" "λ.ecl" 1 check
  "**/a/**/b" "x/a/y/z/b" 1 check)
 'source-patterns test
) 'pkg.test.glob @defm
