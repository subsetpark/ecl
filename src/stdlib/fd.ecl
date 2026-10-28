### module fd
# Byte streams. The standard devices are endpoints like a connection's or a
# process pipe's, and the operations here are the ones every byte endpoint
# shares. Nothing in this module decodes or encodes text; that is io.
[]
(
 `fd.core [in out err read read-line finish bytes?] import

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

 ### def close
 (fd -- :
  "Close an endpoint that is its own resource, such as `fs.open-reader`'s, and join its cleanup;
   idempotent. A resource closes as `port.close` closes it. An endpoint borrowed from a resource (a
   process pipe, a connection) closes with that resource, and the standard devices never close: both
   are `` `type ``.")
 (port.close) `close def

) `fd @defm
