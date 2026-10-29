### module io
# Text over byte streams. Every word here that touches a stream encodes or
# decodes UTF-8 at that boundary through bytes and chars; the console
# conveniences are the same words applied to fd.out and fd.err.
[]
(
 `io.core [pp prin print eprint inspect debug stack] import

 ### def read
 (fd -- string :
  "Read a byte endpoint to EOF and decode it as UTF-8: `fd.read-all chars`. Invalid UTF-8 is ``
   `domain `` with `reason invalid-utf8`; read the bytes with `fd.read-all` instead. A later `read`
   returns `\"\"`.")
 (fd.read-all chars) `read def

 ### def read-line
 (fd -- string :
  "Read one line of UTF-8 text through its newline, newline included, so `\"\"` is unambiguously
   EOF: `fd.read-line chars`. At EOF the rest of the stream is the line. Invalid UTF-8 is `` `domain
   ``. Bytes past the newline stay with the endpoint value, so read lines through one value.")
 (fd.read-line chars) `read-line def

 ### def lines
 (fd -- strings :
  "Read a byte endpoint to EOF and split the decoded text at every newline, without the newlines; a
   final newline ends the last line rather than starting an empty one. Invalid UTF-8 is `` `domain
   ``.")
 (read "\n" split dup empty? not (dup last "" match? (-1 drop) when) when) `lines def

 ### def write
 (fd chardata -- :
  "Encode text as UTF-8 and write it to a byte endpoint. `chardata` is a string, or a list of
   strings written contiguously in order. No newline is added. A non-string element is `` `type
   ``.")
 (dup empty? (bytes) (dup first type `list match? ((bytes) each raze) (bytes) if) if fd.write)
 `write def

 ### def write-line
 (fd string -- :
  "Encode a string as UTF-8 and write it followed by a newline: `io.write`'s contract.")
 ("\n" cat write) `write-line def

 ### def stdin
 (-- string :
  "Read the whole of standard input as text: `fd.in read`. A later call returns `\"\"`; `` `io ``
   when standard input is the program source. Prefer `fd.in` with `fd.read-all` or `io.read`.")
 (fd.in read) `stdin def
) `io @defm
