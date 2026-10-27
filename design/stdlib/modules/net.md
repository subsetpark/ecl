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

### close

### listen

#### Examples

Bind an ephemeral port and read back the assigned address:

```ecl
{'address "127.0.0.1" 'port 0} net.listen
dup net.local-address
swap net.close
# Leaves {'address "127.0.0.1" 'port n}, where n is the assigned port.
```

A one-connection greeting server, which blocks until a peer connects. The
first close drains and closes the connection; the second closes the listener.

```ecl
{'address "127.0.0.1" 'port 8080} net.listen
dup net.accept
dup "hello\n" bytes net.write
net.close
net.close
```

### local-address

### peer-address

### read

### write
