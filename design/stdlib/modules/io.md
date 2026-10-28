## io

Text over byte streams. Every word here that touches a stream encodes or
decodes UTF-8 at that boundary, through `bytes` and `chars`; the console
conveniences are the same words applied to `fd.out` and `fd.err`. The host
primitives are published as `io.core`.

### pp
`( value -- )` — Pretty-print any value plus newline in the display layout of Printing. Best-effort: huge leaves may be elided, so there is no round-trip guarantee. Use core `str` for canonical rendering.

### prin
`( string -- )` — Write a string's characters as UTF-8 to standard output without adding a newline. Non-string is `` `type ``.

### print
`( string -- )` — Write a string followed by a newline to standard output. Semantically `io.prin "\n" io.prin`.

### eprint
`( string -- )` — Write a string followed by a newline to the Session's diagnostics stream: standard error under the command line, the host's diagnostics writer when embedded, and never standard output. When the host supplies no diagnostics writer the string is dropped and the word succeeds. Non-string is `` `type ``; a failed write is `` `io ``.

### inspect
`( value -- value )` — Pretty-print a value while leaving it on the stack; the pipeline probe. Semantically `dup io.pp`.

### debug
`( value label -- value )` — Write the string label, `": "`, and the value's pretty-printed representation plus newline, leaving the value on the stack. Semantically `io.prin ": " io.prin io.inspect`; a non-string label is the same `` `type `` failure as `io.prin`.

### stack
`( -- )` — Stack-polymorphic; leaves the operand stack unchanged. Print each value in the currently visible operand window as a bottom-up indexed display block. `[0]` is the bottom and the largest index is the top; continuation lines align after the prefix. An isolated quotation sees only values above its isolation floor. An empty visible window writes nothing. Rendering is best-effort and may use the same multiline dictionary, array, and elision layout as `io.pp`.
