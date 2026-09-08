# Multiplexed child channels

This deterministic ABI v4 fixture models independent message channels on one
connection. Each channel is an opaque dependent resource with its own operation
lane. Full output on one channel leaves sibling channels runnable. Cancelling a
channel exchange permits another exchange on the same channel after its
controller acknowledges cancellation.

From the repository root:

```sh
timeout 300 zig build native-fixture < /dev/null
timeout 300 zig build < /dev/null
ECL_PATH="$PWD/zig-out/native-fixture" timeout 30 ./zig-out/bin/ecl examples/port-multiplex/main.ecl < /dev/null
```

Expected output:

```text
{'channel 1 'payload ()}
'io
9
'cancelled
```

The disconnect operation reports a resource failure after accepting its final
diagnostic. That exchange retains its buffered diagnostic and terminal error.
The connection interrupts dependent channels, including those transferred to
other task scopes. Closing the connection joins all channel cleanup. Retained
channel identities remain opaque ports whose operations fail after closure.

The [native SDK fixture](../../test/native/ports.zig) models the protocol without
network access. It does not invoke the interpreter or implement automatic
reconnection.
