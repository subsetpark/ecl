### module fd
# Byte streams. The standard devices are endpoints like a connection's or a
# process pipe's, and the operations here are the ones every byte endpoint
# shares. Nothing in this module decodes or encodes text; that is io.
[]
(
 ### def in
 (-- fd :
  "The standard input device: a readable byte endpoint shared by every unit of the session, the same
   value on every call. Reads return what the host has, `[]` at stable EOF, and keep returning `[]`
   afterwards; one read may be pending at a time. `` `io `` when standard input is the program
   source (`ecl -`, and non-terminal invocation with no arguments).")
 (fd.core.in) `in def

 ### def out
 (-- fd :
  "The standard output device: a writable byte endpoint shared by every unit of the session, the
   same value on every call. Writes from different units are served in the order they began and each
   call's bytes stay contiguous.")
 (fd.core.out) `out def

 ### def err
 (-- fd :
  "The diagnostics device: a writable byte endpoint on standard error, shared by every unit of the
   session and the same value on every call.")
 (fd.core.err) `err def

 ### def read
 (fd max -- bytes :
  "Read at most positive integer `max` bytes, parking until data or EOF. Return exact integer bytes
   in `0...255`; `[]` means stable EOF, including on later reads. Reads may be shorter than `max`. A
   wrong resource or non-integer `max` is `` `type ``; `max <= 0` is `` `domain ``; overlapping
   reads are `` `contract ``; a transport failure is `` `io ``. No text decoding is performed; use
   `chars`.")
 (fd.core.read) `read def

 ### def read-line
 (fd -- bytes :
  "Read through the next newline and return those bytes, newline included, so `[]` is unambiguously
   EOF. At EOF the rest of the stream is the line, and `[]` follows on every later read. Bytes after
   the newline stay with the endpoint value for its next read of either kind, so read lines through
   one value. Errors are `read`'s.")
 (fd.core.read-line) `read-line def

 ### def read-all
 (fd -- bytes :
  "Read to EOF and return every byte as one list. A later `read-all` on the same endpoint returns
   `[]`. Errors are `read`'s.")
 (|fd|
  fd [] fd 1048576 fd.core.read
  (dup len 0 >) (|fd chunks chunk| fd chunks chunk append fd 1048576 fd.core.read) while
  pop nip raze) `read-all def

 ### def write
 (fd data -- :
  "Write bytes. `data` is a list of integer bytes in `0...255`, or a list of such lists, written
   contiguously in order, so a program assembling output from pieces need not join them first. A
   string is `` `type ``: encode text with `io.write`. Invalid byte elements are `` `domain ``; a
   finished endpoint or transport failure is `` `io ``.")
 (dup type `list match? (dup empty? not (dup first type `list match? (raze) when) when) when
  fd.core.write) `write def

 ### def finish
 (fd -- :
  "Finish an endpoint's write direction after accepted writes drain. Idempotent; later writes are ``
   `io ``.")
 (fd.core.finish) `finish def

 ### def close
 (fd -- :
  "Close an endpoint that is its own resource, such as `fs.open-reader`'s, and join its cleanup;
   idempotent. A resource closes as `port.close` closes it. An endpoint borrowed from a resource (a
   process pipe, a connection) closes with that resource, and the standard devices never close: both
   are `` `type ``.")
 (port.close) `close def

 ### def bytes?
 (value -- bool :
  "Return 1 when the value is a list of integers in `0...255`, what `write` accepts as one piece,
   and 0 for anything else, including a string.")
 (fd.core.bytes?) `bytes? def
) `fd @defm
