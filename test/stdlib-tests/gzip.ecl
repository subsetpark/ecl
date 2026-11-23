### module stdlib.test.gzip
(
 `stdlib.test.support (equal raises-word documented) import

 ### test decompress
 (-- : "Inflate a known gzip member.")
 ([31 139 8 0 0 0 0 0 0 255 75 76 74 6 0 194 65 36 53 3 0 0 0] gzip.decompress
  [97 98 99] equal)
 `decompress test

 ### test malformed
 (-- : "Reject non-gzip input, a corrupted checksum, and non-byte items.")
 (([1 2 3] gzip.decompress) `domain `gzip.decompress raises-word
  ([31 139 8 0 0 0 0 0 0 255 75 76 74 6 0 194 65 36 54 3 0 0 0] gzip.decompress)
  `domain `gzip.decompress raises-word
  ([31 256] gzip.decompress) `domain `gzip.decompress raises-word
  (42 gzip.decompress) `type `gzip.decompress raises-word)
 `malformed test

 ### test documentation
 (-- : "Require documentation for every gzip export.")
 ((gzip.decompress) documented)
 `documentation test
) `stdlib.test.gzip @defm
