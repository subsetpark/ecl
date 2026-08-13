# TODO

## Testing harness cleanup

- [ ] Keep `std.testing` as the test runner and assertion foundation; do not
  replace it with a general-purpose third-party framework.
- [ ] Hide `std.testing.allocator` inside the ordinary kernel-test helpers,
  while keeping allocator-parameterized probes for OOM tests.
- [ ] Add table-driven stack and language-error cases so related kernel
  examples can share one runner without losing per-case diagnostics.
- [ ] Inspect language-error dicts structurally (`kind`, `word`, `data`, and
  so on) instead of matching fragments of their rendered form.
- [ ] Add an owned CLI result/helper that releases `stdout` and `stderr` and
  centralizes exit/output/error expectations for end-to-end tests.
- [ ] Evaluate `ohsnap` only for genuinely large canonical outputs; keep short
  stack and diagnostic expectations inline with `std.testing`.
