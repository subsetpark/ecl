# Common ports

`net`, `proc`, and ABI v5 extensions use the same port capabilities and
controller lifecycle. Libraries supply factories, operations, and endpoint
selectors as ordinary module bindings. The runtime owns admission, scope
publication, cancellation settlement, transport pressure, and joined cleanup.
The network and process adapters call their typed backends directly; extension
adapters translate the SDK's opaque views and builders at the ABI boundary.

Use `port.call` for an operation whose result needs no additional streaming.
For streams, use `port.begin`, borrow the declared endpoints, and run input and
independent output consumers concurrently. `port.await` observes completion;
`port.result` claims one result. Neither drains output. `port.finish` ends one
direction, `port.shutdown` invokes a registered graceful shutdown, and
`port.close` aborts and joins cleanup.

Retaining a capability shares its permitted use. `@give` transfers ownership
of resources and exchanges, while endpoints remain borrowed uses. New child
resources carried by results or messages stay provisional until atomic receipt.
Parent dependencies survive scope transfer; accepted TCP connections are
independent of their listeners.

The observable contracts and limits are in [STDLIB.md](../design/STDLIB.md#port).
Native loading and SDK ownership contracts are in
[ENVIRONMENT.md](../design/ENVIRONMENT.md#native-modules).

## Executable examples

These examples use the deterministic [ABI v5 fixture](../test/native/ports.zig).
Each directory includes build instructions and an exact output transcript.

- [Storage](port-storage/README.md): structured rows, exclusive transactions,
  cursor positioning, and separate durability acknowledgement.
- [RPC](port-rpc/README.md): backend requests with opaque reply endpoints,
  interleaved notifications, and replies delivered out of order.
- [Broker](port-broker/README.md): delivery capabilities, one-time
  acknowledgement, and explicit redelivery.
- [Device](port-device/README.md): dependent buffer handles, deferred backend
  work, and cancellation that joins that work.
- [Multiplexing](port-multiplex/README.md): independent child channels and
  parent failure propagation.

These fixtures demonstrate protocols; they are not production database,
network broker, GUI, or accelerator integrations.

## Conformance evidence

The public ECL tests in [native_test.zig](../src/tests/native_test.zig) exercise
all eight interaction families. The primary scenarios below are supplemented
in that file by ownership, cancellation, publication failure, queue pressure,
competing claims, retained identities, and cleanup tests.

| Family | Primary public ECL test (after the `native:` prefix) |
|---|---|
| Process/media | `media pipeline drains output and diagnostics concurrently under pressure` |
| Database/storage | `storage transactions are exclusive and commit does not imply durability` |
| Datagram | `datagrams preserve empty payload metadata and explicit loss events` |
| Serial/file watcher | `watcher configuration progresses independently of a subscription and disconnect` |
| Multiplexed connection | `multiplexed channels preserve boundaries and independent progress under pressure` |
| Broker consumer | `broker delivery messages carry one-time acknowledgement capabilities` |
| Bidirectional RPC | `bidirectional RPC interleaves notifications and correlates out of order replies` |
| Native object/accelerator | `device closure joins backend work on transferred buffer children` |

The fixture runners exercise one and eight workers with tiny transport
capacities. [Process tests](../src/tests/process_test.zig) and
[network tests](../src/tests/net_test.zig) exercise the corresponding first-party
compositions, including concurrent bounded capture and provisional accepted
connections. [Initialized-Session OOM probes](../src/tests/oom_test.zig) cover
allocation failure at publication and transport boundaries.

Run `zig build test-ports` for these behavior families and `zig build precommit`
for the source-change gate, with closed stdin and bounded timeouts. Scheduler
lifetime changes also require the Linux/Docker TSan procedure in the
[testing guide](../agent-guides/testing.md#tsan).
