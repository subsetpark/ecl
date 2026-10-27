### module net
# TCP operations compose registered capabilities with the common port API.
[]
(
 ### def listen
 (config -- listener :
  "Bind a TCP listener by opening `net.core.listener` with a configuration of exactly these two
   symbol-keyed fields; neither has a default:
   - `` `address ``: an IPv4 or IPv6 literal string without IPv6 brackets, such as `\"127.0.0.1\"`,
     `\"::1\"`, `\"0.0.0.0\"`, or `\"::\"`.
   - `` `port ``: an integer in `0...65535`, such as `8080`; `0` requests an ephemeral port.

   Loopback addresses accept local connections; wildcard addresses `\"0.0.0.0\"` and `\"::\"` bind
   available interfaces of their address family, subject to operating-system restrictions. Hostnames
   are not resolved: do not use a hostname such as `\"localhost\"`, a URL, or an address with an
   embedded port. Backlog and buffer capacities are runtime limits, not configuration fields.
   Inspect the assigned port with `net.local-address` after a port-zero bind.

   The returned listener port is already listening and belongs to the calling task scope. Use
   `net.accept` for connections and `net.close` for graceful shutdown. CLI sessions grant listening;
   embeddings deny it by default. A non-dictionary or wrongly typed field is `` `type ``; missing or
   unknown fields, invalid literals or ports, denied host authority, or exhausted listener capacity
   is `` `domain ``. Common structured-value limits also apply. Host bind and listen failures are ``
   `io ``. Configuration failures include the requested address, port, and reason where available;
   controller and lifecycle failures report the common error kind and message.

   This module provides listeners and accepted TCP connections, with no outbound-connect word. TCP
   is a byte stream: a read can return less than requested or combine data from multiple peer
   writes. Supply framing in the application, and assemble complete UTF-8 sequences before calling
   `chars`. For a write-side half-close that keeps the connection readable, use `dup net.core.output
   port.endpoint port.finish`.")
 (net.core.listener swap port.open) `listen def

 ### def accept
 (listener -- connection :
  "Wait for a peer and claim the accepted connection port into the calling task scope. Accepted
   connections remain usable after their listener closes. At host connection capacity, wait until a
   slot is free; competing accepts receive distinct connections. A non-listener is `` `type ``.
   Abortive listener closure cancels admitted accepts; graceful shutdown may instead report backend
   closure as `` `io ``. A new call after closure is `` `io ``. Socket or buffer exhaustion and host
   failures are `` `io ``. Cancelling an accept closes any connection still provisionally owned by
   that exchange, so none is lost before delivery. Completed exchanges retain their own result and
   cleanup lifetime independently of the listener.")
 (net.core.accept [] port.call) `accept def

 ### def local-address
 (resource -- address :
  "Return `{address string port int}` for an open listener or connection. IPv4 uses dotted-quad
   text; IPv6 uses RFC 5952 text without brackets. A listener bound to port 0 reports its assigned
   port; a connection accepted through a wildcard listener reports its actual local endpoint. A
   wrong resource kind is `` `type ``; closure or backend failure is `` `io ``.")
 (net.core.local-address [] port.call) `local-address def

 ### def peer-address
 (connection -- address :
  "Return the remote endpoint of an open connection in the same `{address string port int}` shape
   and canonical text as `net.local-address`; a listener has no peer. A non-connection is `` `type
   ``; closure or backend failure is `` `io ``.")
 (net.core.peer-address [] port.call) `peer-address def

 ### def read
 (connection max -- bytes :
  "Read at most positive integer `max` bytes, also bounded by the host receive capacity. Park when
   no data is ready; short reads are normal and do not mark message boundaries. Return exact integer
   bytes in `0...255`, or `[]` only at stable EOF; later reads also return `[]`. A wrong capability
   or non-integer maximum is `` `type ``; a nonpositive maximum is `` `domain ``; an overlapping
   read is `` `contract ``. Buffered bytes precede a transport failure, which raises `` `io ``.
   Abortive closure may discard buffered bytes. No text decoding is performed; use `chars` only on
   complete UTF-8 sequences.")
 (swap net.core.input port.endpoint swap fd.read) `read def

 ### def write
 (connection bytes -- :
  "Accept a complete list of integer bytes in `0...255` in FIFO order, parking under bounded
   pressure. Each call stays contiguous, but TCP does not preserve message boundaries. Convert
   strings explicitly with `bytes`. A non-list or a string is `` `type ``; an element outside
   `0...255` is `` `domain ``; finished output, closure, peer reset, or other transport failure is
   `` `io ``. Acceptance is distinct from delivery, output EOF, and resource cleanup, and does not
   establish peer receipt. To send EOF while retaining input, use `net.core.output port.endpoint
   fd.finish`.")
 (swap net.core.output port.endpoint swap fd.write) `write def

 ### def close
 (resource -- :
  "Gracefully shut down a resource and join cleanup through `port.shutdown`. A listener closes its
   socket and stops accepting; its admitted accepts end with `` `io `` or `` `cancelled ``. A
   connection delivers accepted writes to the kernel before closing its socket; this does not
   establish peer receipt or an external acknowledgement. Cancelling shutdown may discard remaining
   queued bytes. Repeated graceful shutdown observes the same outcome; graceful shutdown after
   abortive closure raises `` `io ``. Use `port.close` for idempotent abortive cleanup. This
   composition also accepts other resources with registered graceful shutdown.")
 (port.shutdown) `close def
) `net @defm
