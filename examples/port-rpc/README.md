# Native requests and opaque ECL replies

This example runs the deterministic ABI v5 conformance fixture. It receives
two native requests with an interleaved notification, then replies in reverse
order. Each request carries an opaque sender; ECL never sees an operation
number, native pointer, or descriptor.

From the repository root:

```sh
timeout 300 zig build native-fixture < /dev/null
timeout 300 zig build < /dev/null
ECL_PATH="$PWD/zig-out/native-fixture" timeout 30 ./zig-out/bin/ecl examples/port-rpc/main.ecl < /dev/null
```

Expected output:

```text
{'notification 7}
[2 20]
[1 10]
42
```

The child task owns both resource and exchange. Scope exit joins cleanup even
if handling a request fails. Explicit closes demonstrate the normal completion
path. The exchange's terminal result is claimed once, after the replies have
been consumed; awaiting completion does not drain messages.

The native side lives in [the SDK fixture](../../test/native/ports.zig), in
the `rpc` operation. It constructs requests using `MessageBuilder`, adds reply
senders with `replyEndpoint`, and receives responses through `Controller`.
Correlation and ordering belong to that protocol. Cancellation interrupts
blocked transport and requires acknowledgement before the lane is reused.

This is a conformance example, not a production RPC library.
