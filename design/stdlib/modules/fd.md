## fd

Byte streams. An fd is a byte endpoint: the standard devices, a file opened
with `fs.open-reader`, a process pipe from `proc.stdin`, `proc.stdout`, or
`proc.stderr`, and a connection's endpoints are all one kind to the words
here, which name the operations every byte endpoint shares. Nothing in `fd`
decodes or encodes text: that is `io`. A read of either kind may leave bytes
read ahead with the endpoint value, so a program that reads lines keeps the
value it reads them through. The host primitives are published as `fd.core`.

### in
`( -- fd )` — The standard input device: a readable byte endpoint shared by every unit of the session, the same value on every call. Reads return what the host has, `[]` at stable EOF, and keep returning `[]` afterwards; one read may be pending at a time. `` `io `` when standard input is the program source (`ecl -`, and non-terminal invocation with no arguments).

### out
`( -- fd )` — The standard output device: a writable byte endpoint shared by every unit of the session, the same value on every call. Writes from different units are served in the order they began and each call's bytes stay contiguous.

### err
`( -- fd )` — The diagnostics device: a writable byte endpoint on standard error, shared by every unit of the session and the same value on every call.

### read
`( fd max -- bytes )` — Read at most positive integer `max` bytes, parking until data or EOF. Return exact integer bytes in `0...255`; `[]` means stable EOF, including on later reads. Reads may be shorter than `max`. A wrong resource or non-integer `max` is `` `type ``; `max <= 0` is `` `domain ``; overlapping reads are `` `contract ``; a transport failure is `` `io ``. No text decoding is performed; use `chars`.

### read-line
`( fd -- bytes )` — Read through the next newline and return those bytes, newline included, so `[]` is unambiguously EOF. At EOF the rest of the stream is the line, and `[]` follows on every later read. Bytes after the newline stay with the endpoint value for its next read of either kind, so read lines through one value. Errors are `read`'s.

### finish
`( fd -- )` — Finish an endpoint's write direction after accepted writes drain. Idempotent; later writes are `` `io ``.

### bytes?
`( value -- bool )` — Return 1 when the value is a list of integers in `0...255`, what `write` accepts as one piece, and 0 for anything else, including a string.
