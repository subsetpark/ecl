### module stream
(: "Byte streams. A stream is a byte endpoint: the standard devices, a file opened with
    `fs.open-reader`, a process pipe from `proc.stdin`, `proc.stdout`, or `proc.stderr`, and a
    connection's endpoints are all one kind to the words here, which provide the operations every
    byte endpoint shares. Nothing in `stream` decodes or encodes text: that is `io`. A read of
    either kind may leave bytes read ahead with the endpoint value, so a program that reads lines
    keeps the value it reads them through.")
(
 `stream.core [in out err read read-line] import

 ### def read-all
 (stream -- bytes :
  "Read to EOF and return every byte as one list. A later `read-all` on the same endpoint returns
   `[]`. Errors are `read`'s.")
 (|reader|
  reader [] reader 1048576 stream.core.read
  (dup len 0 >) (|reader chunks chunk| reader chunks chunk append reader 1048576 stream.core.read)
  while
  pop nip raze) `read-all def

 ### def write
 (stream data -- :
  "Write bytes. `data` is a list of integer bytes in `0...255`, or a list of such lists, written
   contiguously in order, so a program assembling output from pieces need not join them first. A
   string is `` `type ``: encode text with `io.write`. Invalid byte elements are `` `domain ``; a
   finished endpoint or transport failure is `` `io ``.")
 (dup type `list match? (dup empty? (dup first type `list match? (raze) when) unless) when
  stream.core.write) `write def

) `stream @defm
