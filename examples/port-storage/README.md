# Structured storage sessions

This deterministic ABI v5 fixture demonstrates an exclusive transaction child,
separate commit and durability acknowledgements, and a cursor that streams row
messages. Cursor positioning is a registered operation. Dependent children
retain access to their parent's native state through cleanup and scope transfer.

From the repository root:

```sh
timeout 300 zig build native-fixture < /dev/null
timeout 300 zig build < /dev/null
ECL_PATH="$PWD/zig-out/native-fixture" timeout 30 ./zig-out/bin/ecl examples/port-storage/main.ecl < /dev/null
```

Expected output:

```text
40
[40 0 1]
40
{'id 1 'value 41}
{'id 2 'value 42}
'eof
```

The status list contains the committed value, durable value, and whether a
transaction remains open. Closing an uncommitted transaction releases its
exclusive claim and discards its pending value. Closing the session joins all
dependent children, even when another task owns them. Each exchange result has
one claimant; row delivery and operation completion are separate.

The native implementation is in [the SDK fixture](../../test/native/ports.zig).
It uses bounded message builders and typed native parent-state borrowing. This
fixture models a storage protocol; it does not implement a database or persist
data to disk.
