## io

Text over byte streams. Every word here that touches a stream encodes or
decodes UTF-8 at that boundary, through `bytes` and `chars`; the console
conveniences are the same words applied to `fd.out` and `fd.err`. The host
primitives are published as `io.core`.
