# Delivery capabilities and explicit redelivery

This deterministic native fixture delivers an empty message payload with an
opaque acknowledgement capability. Redelivery is an explicit registered
operation. It creates a new delivery and invalidates acknowledgement through
the earlier capability. Acknowledgement has one winner, including when tasks
compete; receiving a message and completing its exchange do not acknowledge it.

From the repository root:

```sh
timeout 300 zig build native-fixture < /dev/null
timeout 300 zig build < /dev/null
ECL_PATH="$PWD/zig-out/native-fixture" timeout 30 ./zig-out/bin/ecl examples/port-broker/main.ecl < /dev/null
```

Expected output:

```text
0
'contract
{'id 1 'attempt 2}
2
('acknowledged 2 1)
```

The status list contains the acknowledgement state, attempt number, and live
delivery count. Discarding an unread message closes its provisional delivery
resource; it does not trigger redelivery. Closing the broker joins dependent
delivery cleanup even when another task owns a delivery.

The [native fixture](../../test/native/ports.zig) owns acknowledgement and
attempt state behind a mutex. It accesses that state through the SDK's typed
parent borrow. ECL sees only port capabilities and structured data. This
example models a broker protocol and does not connect to a production broker.
