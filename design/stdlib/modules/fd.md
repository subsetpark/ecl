## fd

Byte streams. An fd is a byte endpoint: the standard devices, a file opened
with `fs.open-reader`, a process pipe from `proc.stdin`, `proc.stdout`, or
`proc.stderr`, and a connection's endpoints are all one kind to the words
here, which name the operations every byte endpoint shares. Nothing in `fd`
decodes or encodes text: that is `io`. A read of either kind may leave bytes
read ahead with the endpoint value, so a program that reads lines keeps the
value it reads them through. The host primitives are published as `fd.core`.
