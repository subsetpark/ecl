## net

TCP listeners and connections. Any local IP literal and port can be requested,
subject to operating-system restrictions and runtime resource limits. Port zero
requests an ephemeral bind. Names are never resolved. IPv4-mapped IPv6 literals
normalize to IPv4. Binding uses address reuse, so a closed connection's
`TIME_WAIT` does not prevent rebinding; two live listeners cannot hold the same
address and port.

The public words are ECL compositions over `net.core.listener`, the registered
operations `net.core.accept`, `net.core.local-address`, and
`net.core.peer-address`, and the endpoint selectors `net.core.input` and
`net.core.output`. Each operation requires `[]`. Accept occupies its FIFO lane
until completion or cancellation. Address operations use an independent control
lane. Factories and selectors are opaque identities for their resource kinds.

Listeners and connections belong to task scopes. Retaining or sending a port
shares use; `@give` transfers ownership. A newly accepted connection remains
provisionally owned by its exchange until `port.result` publishes it into the
receiving scope. Failed publication retains that provisional ownership, and
closing an unclaimed exchange closes the connection. Accepted connections are
independent of their listener, including after listener closure. Scope closure
aborts its resources and joins socket cleanup even while identities remain
retained elsewhere.

A listener takes a connection from the kernel backlog only for an active
accept with connection capacity available. At capacity, accept parks until a
connection closes. A waiting accept holds no connection slot. Admission itself
is bounded by the resource's operation capacity; additional callers park.
Competing accepts consume distinct connections and do not broadcast. A peer
that aborts before acceptance is skipped. The runtime does not retry a failed
operation or reopen a failed resource.

Byte endpoints preserve exact integer bytes in `0...255`; they perform no text
decoding. Reads have a single-pending-reader rule. Writes execute FIFO and each
call stays contiguous under bounded pressure. `port.finish` on the output
endpoint rejects new writers and sends EOF after admitted writers and queued
bytes drain, while the input direction remains readable. Framing, TLS,
encoding, and protocol limits belong to libraries. Deadlines compose tasks
with `task.await-for`, cancellation, and joining.

### accept
`( listener -- connection )` — Wait for a peer and claim the accepted resource
into the calling scope. A non-listener is `'type`. Abortive listener closure
cancels admitted accepts; graceful shutdown may instead report backend closure
as `'io`. A new call after closure is `'io`. Socket or buffer exhaustion
and host failures are `'io`. Cancelling an accept closes any connection still
provisionally owned by that exchange. Completed exchanges retain their own
result and cleanup lifetime independently of the listener.

### close
`( resource -- )` — Compose `port.shutdown`: perform registered graceful
shutdown and join cleanup. A listener closes its socket and ends admitted
accepts with `'io` or `'cancelled`. A connection delivers accepted writes to the kernel before closing
its socket; this does not establish peer receipt or an external acknowledgement.
Cancelling shutdown may discard remaining queued bytes. Repeated graceful
shutdown observes the same outcome. Graceful shutdown after abortive closure
raises `'io`; `port.close` supplies idempotent abortive cleanup. This composition
also accepts other resources with registered graceful shutdown.

### listen
`( config -- listener )` — Open `net.core.listener` with exactly these two
symbol-keyed fields; neither has a default:

| Field | Value | Examples |
| --- | --- | --- |
| `'address` | IPv4 or IPv6 literal string, without IPv6 brackets | `"127.0.0.1"`, `"::1"`, `"0.0.0.0"`, `"::"` |
| `'port` | Integer in `0...65535`; `0` requests an ephemeral port | `8080`, `0` |

Loopback addresses accept local connections; wildcard addresses `"0.0.0.0"`
and `"::"` bind available interfaces of their address family, subject to operating-system restrictions. Do not use a hostname such as `"localhost"`, a URL, or an address with
an embedded port. Backlog and buffer capacities are runtime limits, not listener config
fields. Inspect the assigned port with `net.local-address` after a port-zero bind.

```ecl
{'address "127.0.0.1" 'port 0} net.listen
dup net.local-address
swap net.close
# Leaves {'address "127.0.0.1" 'port n}, where n is the assigned port.
```

The returned socket is already listening. A non-dict or wrongly typed field
is `'type`; missing or unknown fields, invalid literals or ports,
exhausted listener capacity is
`'domain`. Common structured-value limits also apply. Host bind and listen
failures are `'io`. Configuration failures include the requested
address, port, and reason where available; controller and lifecycle failures
report the common error kind and message.

A one-connection greeting server (blocks until a peer connects):

```ecl
{'address "127.0.0.1" 'port 8080} net.listen
dup net.accept
dup "hello\n" bytes net.write
net.close
net.close
```

The first close drains and closes the connection; the second closes the
listener. This module provides listeners and accepted TCP connections, with
no outbound-connect word. TCP is a byte stream: a read can return less than
requested or combine data from multiple peer writes. Supply framing in the
application, and assemble complete UTF-8 sequences before calling `chars`.
For a write-side half-close that keeps the connection readable, use
`dup net.core.output port.endpoint port.finish`.

### local-address
`( resource -- address )` — Return `{'address string 'port int}` for an open
listener or connection. IPv4 uses dotted-quad text; IPv6 uses RFC 5952 text
without brackets. An ephemeral listener reports its assigned port; a connection
accepted through a wildcard listener reports the actual local endpoint.
A wrong resource kind is `'type`; closure or backend failure is `'io`.

### peer-address
`( connection -- address )` — Return the peer endpoint in the same dictionary
shape and canonical text. A non-connection is `'type`; closure or backend
failure is `'io`.

### read
`( connection max -- bytes )` — Read at most positive `max` bytes, bounded by
the host receive capacity. Park when no data is ready. Return `[]` only at
stable EOF; later reads also return `[]`. A wrong capability or non-integer
maximum is `'type`; a nonpositive maximum is `'domain`; an overlapping read
is `'contract`. Buffered bytes precede a transport failure, which raises `'io`.
Abortive closure may discard buffered bytes.

### write
`( connection bytes -- )` — Accept a complete byte list under bounded FIFO
pressure. A non-list is `'type`; an element outside `0...255` is `'domain`.
Convert strings explicitly with `bytes`. Finished output, closure, peer reset,
and other transport failures raise `'io`. Acceptance is distinct from delivery,
output EOF, and resource cleanup.
