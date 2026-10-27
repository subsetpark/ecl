### module io
# Text over byte streams. Every word here that touches a stream encodes or
# decodes UTF-8 at that boundary through bytes and chars; the console
# conveniences are the same words applied to fd.out and fd.err.
[]
(
 ### def pp
 (value -- :
  "Pretty-print any value plus newline in the display layout of Printing. Best-effort: huge leaves
   may be elided, so there is no round-trip guarantee. Use core `str` for canonical rendering.")
 (io.core.pp) 'pp def

 ### def prin
 (string -- :
  "Write a string's characters as UTF-8 to standard output without adding a newline. Non-string is
   `'type`.")
 (io.core.prin) 'prin def

 ### def print
 (string -- :
  "Write a string followed by a newline to standard output. Semantically `io.prin \"\\n\"
   io.prin`.")
 (io.core.print) 'print def

 ### def eprint
 (string -- :
  "Write a string followed by a newline to the Session's diagnostics stream: standard error under
   the command line, the host's diagnostics writer when embedded, and never standard output. When
   the host supplies no diagnostics writer the string is dropped and the word succeeds. Non-string
   is `'type`; a failed write is `'io`.")
 (io.core.eprint) 'eprint def

 ### def inspect
 (value -- value :
  "Pretty-print a value while leaving it on the stack; the pipeline probe. Semantically `dup
   io.pp`.")
 (io.core.inspect) 'inspect def

 ### def debug
 (value label -- value :
  "Write the string label, `\": \"`, and the value's pretty-printed representation plus newline,
   leaving the value on the stack. Semantically `io.prin \": \" io.prin io.inspect`; a non-string
   label is the same `'type` failure as `io.prin`.")
 (io.core.debug) 'debug def

 ### def stack
 (-- :
  "Stack-polymorphic; leaves the operand stack unchanged. Print each value in the currently visible
   operand window as a bottom-up indexed display block. `[0]` is the bottom and the largest index is
   the top; continuation lines align after the prefix. An isolated quotation sees only values above
   its isolation floor. An empty visible window writes nothing. Rendering is best-effort and may use
   the same multiline dictionary, array, and elision layout as `io.pp`.")
 (io.core.stack) 'stack def

 ### def read
 (fd -- string :
  "Read a byte endpoint to EOF and decode it as UTF-8: `fd.read-all chars`. Invalid UTF-8 is
   `'domain` with `'reason 'invalid-utf8`; read the bytes with `fd.read-all` instead. A later `read`
   returns `\"\"`.")
 (fd.read-all chars) 'read def

 ### def read-line
 (fd -- string :
  "Read one line of UTF-8 text through its newline, newline included, so `\"\"` is unambiguously
   EOF: `fd.read-line chars`. At EOF the rest of the stream is the line. Invalid UTF-8 is `'domain`.
   Bytes past the newline stay with the endpoint value, so read lines through one value.")
 (fd.read-line chars) 'read-line def

 ### def lines
 (fd -- strings :
  "Read a byte endpoint to EOF and split the decoded text at every newline, without the newlines; a
   final newline ends the last line rather than starting an empty one. Invalid UTF-8 is `'domain`.")
 (read "\n" split dup empty? not (dup last "" match? (-1 drop) when) when) 'lines def

 ### def write
 (fd chardata -- :
  "Encode text as UTF-8 and write it to a byte endpoint. `chardata` is a string, or a list of
   strings written contiguously in order. No newline is added. A non-string element is `'type`.")
 (dup empty? (bytes) (dup first type 'list match? ((bytes) each raze) (bytes) if) if fd.write)
 'write def

 ### def write-line
 (fd string -- :
  "Encode a string as UTF-8 and write it followed by a newline: `io.write`'s contract.")
 ("\n" cat write) 'write-line def

 ### def stdin
 (-- string :
  "Read the whole of standard input as text: `fd.in read`. A later call returns `\"\"`; `'io` when
   standard input is the program source. Prefer `fd.in` with `fd.read-all` or `io.read`.")
 (fd.in read) 'stdin def
) 'io @defm
