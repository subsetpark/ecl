### module stdlib.test.pkg-shadow
(
 'stdlib.test.support ('equal) import
 'table ('where) import

 ### test caller-shadowing
 (-- : "Keep package ordering independent of a caller's imported where word.")
 ("1.2.0" "1.10.0" pkg.version.less? 1 equal
  ["1.0.0-a" "1.0.0"] pkg.version.max "1.0.0" equal)
 'caller-shadowing test
) 'stdlib.test.pkg-shadow @defm
