# Opaque native buffers and deferred work

This deterministic ABI v5 fixture creates an opaque eight-byte buffer dependent
on a device. A native worker computes its checksum only after a separate
controller lane permits completion. Positioned updates are registered operations.
Cancellation interrupts the worker, joins it, and acknowledges that the compute
lane can be reused. Device cleanup joins every dependent buffer's backend work.

From the repository root:

```sh
timeout 300 zig build native-fixture < /dev/null
timeout 300 zig build < /dev/null
ECL_PATH="$PWD/zig-out/native-fixture" timeout 30 ./zig-out/bin/ecl examples/port-device/main.ecl < /dev/null
```

Expected output:

```text
[1 1 0]
30
[1 0 1]
'cancelled
[1 0 1]
```

Device status reports live buffers, outstanding native workers, and completed
computations. Completion observation is repeatable, while the result has one
claimant. Transferring a buffer to another task preserves its device dependency.
Native workers borrow backend state without receiving ECL values or interpreter
access. The [SDK fixture](../../test/native/ports.zig) uses an ordinary native
thread; it does not require accelerator hardware or expose mapped buffer memory.
