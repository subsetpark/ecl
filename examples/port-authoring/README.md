# Author a port

[`tutorial.zig`](../../test/native/tutorial.zig) is a complete extension with a
stateful `increment` operation and a byte-stream `echo` operation. It imports
only `ecl-native`. Both operations satisfy the same `port.*` contracts as the
network and process libraries.

Build and run from the repository root:

```sh
timeout 300 zig build native-fixture < /dev/null
code=$?; echo "build_exit=$code"
timeout 300 zig build < /dev/null
code=$?; echo "runtime_build_exit=$code"
ECL_PATH="$PWD/zig-out/native-fixture" timeout 30 ./zig-out/bin/ecl examples/port-authoring/main.ecl < /dev/null
code=$?; echo "example_exit=$code"
```

The program prints:

```text
3
7
[1 2 3 4]
[]
```

The empty list is byte EOF. Input writing runs in another task while the caller
drains output; the program remains live when the host reduces rings to one
byte. The surrounding task scope joins cleanup if either side fails.

## Declare the contract once

A port spec supplies `name`, private `State`, and the lifecycle callbacks `init`,
`open`, `cancel`, and `deinit`. `open` validates configuration before resource
publication. `deinit` runs once after all controller work joins, including after
failed initialization. `cancel` must interrupt any waits in your backend; the
runtime already interrupts its own byte and message waits.

The spec's `endpoints` entries declare transport, direction, ownership, and
documentation. Direction is from the controller's perspective: `.input` is
readable by the controller, `.output` is writable. Endpoints default to exchange
ownership; use `.owner = .resource` for streams shared across operations.

Each `operations` entry contains its handler, documentation, lane, and named
exchange endpoints. The default lane is `.operation`. Declare a `Lane` enum
when operations need independent progress; shared state then needs appropriate
synchronization. No operation codes or endpoint masks are authored.

Including the port in `module.ports` generates the operation and endpoint
bindings. Export a factory with `ecl.factory` when callers should create roots;
child-only resource kinds need no factory. Use an optional `.name` in a
selector declaration to keep a short local name and a different public ECL
spelling.

## Implement the operation

A handler receives your state and an opaque controller, and can return
`ecl.ControllerError!void`. Use `controller.input(path)` for bounded request
views. `controller.builder()` constructs a result through ordinary `try` calls;
`result()` validates and publishes it. Nested `list(count)` and
`dictionary(pair_count)` combine the last constructed values. All user-sized
construction work is driven and bounded by the host.

Acquire an endpoint with `try controller.endpoint(Port, .name)`. Its type only
provides methods appropriate to that direction:

| Capability | Methods |
|---|---|
| Byte input | `read(buffer)` returns a positive length or `null` for EOF |
| Byte output | `write(bytes)` accepts the entire slice; `finish()` ends output |
| Message input | `receive()` returns a view or `null`; `reply()` builds a reply sender |
| Message output | `send()` publishes the builder; `forward()` publishes the received message; `finish()` ends output |

A write failure may leave an accepted prefix; do not retry automatically.
Message sends and result publication consume their value only on success.
A failed consuming call retains ownership for cleanup. Only one received
message is held at a time; `discardMessage()` releases it, and `resultMessage()`
returns it as the operation result. Controller return cleans up unconsumed
messages and unfinished construction. Views and endpoint borrows must not
escape the controller invocation.

`child(Port, dependency)` consumes a configuration on success and replaces it
with a provisional resource. Failed creation retains the configuration and
cleans up partial startup. ECL receipt publishes the child into the receiving
scope. Dependent children close before their parent's backend is destroyed.

For a scalar result, ECL uses `port.call`. Streaming callers use `port.begin`
and concurrent tasks. `port.await` observes completion; it does not drain
output. Neither completion nor finishing a direction implies durability or an
external acknowledgement. Those remain explicit library operations.

See [the conformance examples](../PORTS.md) for transactions, broker delivery,
RPC replies, dependent buffers, and cancellation recovery. The native ABI is a
host translation boundary; extension authors do not access interpreter state,
allocators, scheduling, or manual advancement APIs.
