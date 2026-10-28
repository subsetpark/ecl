## port

Factories, operation selectors, and endpoint selectors are opaque `` `port ``
values exported through ordinary library bindings. Repeated lookup preserves
identity. Selectors belong to their issuing module instance and resource kind;
using another kind or the wrong capability variant raises `` `type ``. These
borrowed capabilities are not transferable scope owners.

Exchanges are opaque `` `port `` values with their own task-scope ownership.
An exchange survives the invocation that created it. Retaining or sending its
value shares use; `@give` transfers its scope ownership. Exiting
the owning scope aborts outstanding work and joins cancellation cleanup.

New child resources carried by a result or message remain provisionally
owned until `port.result` or `port.receive` succeeds. A claim publishes all
attached children into the receiving scope together; failed publication retains
the source and its owners. Discarding an unclaimed result or queued message
closes its provisional children, and exchange cleanup joins their retirement.
Already published capabilities share use without moving scope ownership.
Children declare whether they depend on their issuing parent. Parent closure
closes and joins dependent children even after `@give`; independent children
remain usable in their receiving scope. Closed children remain opaque identities.

| Word | Effect | Contract |
|---|---|---|
| `port.open` | `( factory config -- resource )` | Initialize a resource and publish it into the calling scope. Failure joins cleanup through that scope. |
| `port.begin` | `( resource operation request -- exchange )` | Admit a registered operation on its declared FIFO lane, parking while admission capacity is full. |
| `port.call` | `( resource operation request -- value )` | Begin, claim the result, and close the exchange. Requires no additional streaming input or output. |
| `port.endpoint` | `( source selector -- endpoint )` | Borrow a direction-specific endpoint supported by its resource or permitted by its exchange's operation. Supports registered byte and message endpoints; a byte endpoint is an fd for the `fd` words. |
| `port.send` | `( sender message -- )` | Enqueue one complete structured message atomically, parking under pressure. Empty values are valid messages. |
| `port.receive` | `( receiver -- event )` | Return `{kind message value value}` or `{kind eof}`. Overlapping receivers raise `` `contract ``. |
| `port.finish` | `( sender -- )` | Finish a message sender after accepted sends, so its receiver sees `{kind eof}`. Idempotent; later sends raise `` `io ``. Byte endpoints finish with `fd.finish`. |
| `port.await` | `( exchange -- )` | Wait for successful completion or raise the terminal error. Repeatable; does not drain output. |
| `port.result` | `( exchange -- value )` | Wait and claim the terminal result once. A later successful-result claim raises `` `contract ``. |
| `port.cancel` | `( exchange -- )` | Request cancellation idempotently. Completion remains observable and waits for controller return. |
| `port.shutdown` | `( resource -- )` | Stop new admission, perform registered graceful shutdown, and join cleanup. Unsupported resources raise `` `domain ``. Repeated calls observe the same outcome. |
| `port.close` | `( resource-or-exchange -- )` | Abort and join cleanup. Idempotent for every resource and exchange. |

For TCP resources, `port.shutdown` closes a listener or delivers a connection's
accepted writes before closing its socket. Accepted connections remain independent
of their listener. `port.close` may discard queued connection bytes. Both words
join socket cleanup. For a process, `port.shutdown` requests process-group
termination with the host's escalation policy; `port.close` requests immediate
process-group kill. Both join process cleanup, including blocked pipe transport.
A completed process wait exchange remains observable after resource closure;
new wait operations require an open resource.

A cancelled exchange raises `` `cancelled `` from `port.await` and `port.result`.
Observation does not consume the result. Operations that produce only
stream output have `[]` as their result. Input finish, output EOF, completion,
and cleanup are distinct events. An active cancellation releases its controller
lane only after acknowledgement and return; a controller that cannot restore
reusable state closes its resource.

Endpoints may belong to a resource or to one exchange. Resource endpoints
retain their direction and buffered data across exchange completion; finishing
a resource endpoint or closing its resource ends that direction.
A message may carry a sender through which its recipient replies to a backend
request. Such a sender retains only its permitted direction; request identifiers,
notifications, and response ordering follow the issuing library's protocol.
Endpoint capabilities preserve the source identity and cannot be transferred
independently with `@give`. A selector from another issuing kind, or a read or
write through the wrong direction, raises `` `type ``; an endpoint not permitted
by its source raises `` `domain ``. Buffered output remains readable before a
terminal failure is raised. Once observed, EOF remains stable through later
exchange failure or resource cleanup. An early input consumer exit wakes blocked
writers with `` `io ``. Streaming callers must drain independent outputs concurrently when
necessary for progress; waiting for completion does not drain them.

`port.call` is an ECL composition. It closes the exchange before returning its
result or re-raising its terminal error. It leaves the resource with its owner.
The public `port` module composes the host operations exported by `port.core`.

Configuration and initial requests may contain integers, floats, characters,
symbols, lists, dictionaries, and port capabilities. Executable words, tasks,
and modules are rejected recursively with `` `type ``. Each value is bounded by
64 KiB of scalar/text bytes, 4,096 nodes, and 16 capability occurrences; exceeding
a bound raises `` `overflow `` before initialization or admission. Retaining an
existing resource in a request shares use and does not transfer its scope.

Messages and terminal results use the same structured-value bounds. Default
message capacity is 16 per endpoint and a shared 1 MiB byte budget per resource.
A controller-held message retains its capacity reservation until forwarded,
returned as a result, or discarded. This permits forwarding when the shared
budget is full. Exceeding the resource's entire byte budget raises `` `overflow ``;
temporary saturation parks the producer. Receiving is competing consumption,
not broadcast. Event construction failure leaves the message queued. A receiving
scope that has begun closing cannot consume a message or result; the claim
fails with `` `cancelled `` without consuming the source.
Abortive close discards queued messages and unclaimed results; a discarded
successful result raises `` `io `` if claimed later. Completion observation remains
repeatable. Existing capabilities in messages share use and retain their owner.

### open
`( factory config -- resource )` — Initialize a registered resource in the calling scope.

### begin
`( resource operation request -- exchange )` — Admit an operation with bounded structured parameters.

### endpoint
`( source selector -- endpoint )` — Borrow an attenuated endpoint supported by its source.

### send
`( sender message -- )` — Atomically enqueue one bounded structured message, including an empty value.

### receive
`( receiver -- event )` — Receive {kind message value value} or {kind eof}; one receiver may wait.

### finish
`( sender -- )` — Finish a message sender after admitted sends, so its receiver sees {kind eof}. Idempotent. Byte endpoints finish with fd.finish.

### await
`( exchange -- )` — Observe completion without consuming the result or draining output.

### result
`( exchange -- value )` — Wait and claim a result once; a later claim raises `contract.

### cancel
`( exchange -- )` — Request cancellation. Completion remains observable.

### shutdown
`( resource -- )` — Perform registered graceful shutdown and join cleanup. Unsupported resources raise `domain.

### close
`( resource-or-exchange -- )` — Abort and join cleanup. Idempotent.
