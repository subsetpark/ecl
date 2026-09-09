### module net
# TCP operations compose registered capabilities with the common port API.
[]
(
 ### def listen
 (config -- listener :
  "Bind a TCP listener. config must contain exactly two symbol keys: 'address is an IPv4 or IPv6
   literal string (for example \"127.0.0.1\" or \"::1\", without IPv6 brackets), and 'port is an
   integer in 0...65535. Both are required; 0 requests an ephemeral port, retrieved with
   net.local-address. Hostnames are not resolved. A non-dict or wrongly typed field is 'type;
   missing/unknown fields, invalid literals/ports, denied host authority, or exhausted listener
   capacity are 'domain; bind/listen failures are 'io. The returned port is already listening and
   belongs to the calling task scope. Use net.accept for connections and net.close for graceful
   shutdown. CLI sessions grant listening; embeddings deny it by default.")
 (net.core.listener swap port.open)
 'listen def

 ### def accept
 (listener -- connection :
  "Wait for a peer and return a connection port owned by the calling task scope. Accepted
   connections remain usable after their listener closes. At host connection capacity, wait until a
   slot is free; competing accepts receive distinct connections. A non-listener is 'type; closure or
   host failure is 'io, and abortive closure can cancel admitted accepts. Cancelling an accept
   cleans any connection not yet delivered to its caller.")
 (net.core.accept [] port.call)
 'accept def

 ### def local-address
 (resource -- address :
  "Return {'address string 'port int} for an open listener or connection. IPv4 uses dotted-quad text
   and IPv6 uses canonical text without brackets. A listener bound to port 0 reports its assigned
   port. A connection accepted on a wildcard listener reports its actual local endpoint. A wrong
   resource kind is 'type; closure or backend failure is 'io.")
 (net.core.local-address [] port.call)
 'local-address def

 ### def peer-address
 (connection -- address :
  "Return the remote endpoint as {'address string 'port int}, with dotted-quad IPv4 or canonical
   IPv6 text without brackets. Requires an open connection, not a listener. A non-connection is
   'type; closure or backend failure is 'io.")
 (net.core.peer-address [] port.call)
 'peer-address def

 ### def read
 (connection max -- bytes :
  "Read at most positive integer max bytes, also bounded by host receive capacity. Park when no data
   is ready; short reads are normal and do not mark message boundaries. Return exact integer bytes
   in 0...255, or [] at stable EOF (also on later reads). A wrong resource or non-integer max is
   'type; max <= 0 is 'domain; overlapping reads are 'contract. Buffered bytes precede a transport
   failure, which raises 'io. Abortive closure may discard buffered bytes. No text decoding is
   performed; use chars only on complete UTF-8 sequences.")
 (swap net.core.input port.endpoint swap port.read)
 'read def

 ### def write
 (connection bytes -- :
  "Accept a complete list of integer bytes in 0...255 in FIFO order, parking under bounded pressure.
   Each call stays contiguous, but TCP does not preserve message boundaries. Convert strings with
   bytes. A non-list is 'type; invalid byte elements are 'domain; finished output, closure, reset,
   or transport failure is 'io. Acceptance does not establish peer receipt. To send EOF while
   retaining input, use net.core.output port.endpoint port.finish.")
 (swap net.core.output port.endpoint swap port.write)
 'write def

 ### def close
 (resource -- :
  "Gracefully shut down a resource and join cleanup through port.shutdown. A listener stops
   accepting; its admitted accepts end with 'io or 'cancelled. A connection drains accepted writes
   to the kernel before closing, without guaranteeing peer receipt. Repeated graceful shutdown
   observes the same outcome; graceful shutdown after abortive closure is 'io. Cancellation may
   discard queued bytes. Use port.close for idempotent abortive cleanup.")
 (port.shutdown)
 'close def
) 'net @defm
