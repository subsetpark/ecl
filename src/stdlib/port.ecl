### module port
(: "Factories, operation selectors, and endpoint selectors are opaque `` `port `` values exported
    through ordinary library bindings. Repeated lookup preserves identity. Selectors belong to their
    issuing module instance and resource kind; using another kind or the wrong capability variant
    raises `` `type ``. These borrowed capabilities are not transferable scope owners.

    Exchanges are opaque `` `port `` values with their own task-scope ownership. An exchange
    survives the invocation that created it. Retaining or sending its value shares use; `@give`
    transfers its scope ownership. Exiting the owning scope aborts outstanding work and joins
    cancellation cleanup.

    New child resources carried by a result or message remain provisionally owned until
    `port.result` or `port.receive` succeeds. A claim publishes all attached children into the
    receiving scope together; failed publication retains the source and its owners. Discarding an
    unclaimed result or queued message closes its provisional children, and exchange cleanup joins
    their retirement. Already published capabilities share use without moving scope ownership.
    Children declare whether they depend on their issuing parent. Parent closure closes and joins
    dependent children even after `@give`; independent children remain usable in their receiving
    scope. Closed children remain opaque identities.

    For TCP resources, `port.shutdown` closes a listener or delivers a connection's accepted writes
    before closing its socket. Accepted connections remain independent of their listener.
    `port.close` may discard queued connection bytes. Both words join socket cleanup. For a process,
    `port.shutdown` requests process-group termination with the host's escalation policy;
    `port.close` requests immediate process-group kill. Both join process cleanup, including blocked
    pipe transport. A completed process wait exchange remains observable after resource closure; new
    wait operations require an open resource.

    A cancelled exchange raises `` `cancelled `` from `port.await` and `port.result`. Observation
    does not consume the result. Operations that produce only stream output have `[]` as their
    result. Input finish, output EOF, completion, and cleanup are distinct events. An active
    cancellation releases its controller lane only after acknowledgement and return; a controller
    that cannot restore reusable state closes its resource.

    Endpoints may belong to a resource or to one exchange. Resource endpoints retain their direction
    and buffered data across exchange completion; finishing a resource endpoint or closing its
    resource ends that direction. A message may carry a sender through which its recipient replies
    to a backend request. Such a sender retains only its permitted direction; request identifiers,
    notifications, and response ordering follow the issuing library's protocol. Endpoint
    capabilities preserve the source identity and cannot be transferred independently with `@give`.
    A selector from another issuing kind, or a read or write through the wrong direction, raises ``
    `type ``; an endpoint not permitted by its source raises `` `domain ``. Buffered output remains
    readable before a terminal failure is raised. Once observed, EOF remains stable through later
    exchange failure or resource cleanup. An early input consumer exit wakes blocked writers with ``
    `io ``. Streaming callers must drain independent outputs concurrently when necessary for
    progress; waiting for completion does not drain them.

    `port.call` is an ECL composition. It closes the exchange before returning its result or
    re-raising its terminal error. It leaves the resource with its owner. The public `port` module
    composes the host operations exported by `port.core`.

    Configuration and initial requests may contain integers, floats, characters, symbols, lists,
    dictionaries, and port capabilities. Executable words, tasks, and modules are rejected
    recursively with `` `type ``. Each value is bounded by 64 KiB of scalar/text bytes, 4,096 nodes,
    and 16 capability occurrences; exceeding a bound raises `` `overflow `` before initialization or
    admission. Retaining an existing resource in a request shares use and does not transfer its
    scope.

    Messages and terminal results use the same structured-value bounds. Default message capacity is
    16 per endpoint and a shared 1 MiB byte budget per resource. A controller-held message retains
    its capacity reservation until forwarded, returned as a result, or discarded. This permits
    forwarding when the shared budget is full. Exceeding the resource's entire byte budget raises ``
    `overflow ``; temporary saturation parks the producer. Receiving is competing consumption, not
    broadcast. Event construction failure leaves the message queued. A receiving scope that has
    begun closing cannot consume a message or result; the claim fails with `` `cancelled `` without
    consuming the source. Abortive close discards queued messages and unclaimed results; a discarded
    successful result raises `` `io `` if claimed later. Completion observation remains repeatable.
    Existing capabilities in messages share use and retain their owner.")
(
 `port.core [open begin endpoint send receive finish await result cancel shutdown close] import

 ### def call
 (resource operation request -- value :
  "Begin an operation, claim its result, and close the exchange. Use only when no additional
   streaming input or output is required. Close the exchange before returning or re-raising its
   error.")
 (begin dup (result) cons @attempt swap close result.or-raise first) `call def
) `port @defm
