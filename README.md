# ecl

ecl is a clean-slate homoiconic concatenative array language. The real
interpreter is being built in Zig at the repository root; the earlier Rust
walking skeleton remains a frozen executable semantics oracle.

## Repository map

- [`design/`](design/) contains the settled design ledger, grammar, and
  vocabulary.
- [`src/`](src/) contains the Zig implementation. The value core, reader,
  frame machine, chained environments, and module registry are live:
  `zig build` produces a working calculator with transactional units,
  definition-site privacy, declared module effects, hot reload, reflection,
  direct `load`, `ECL_PATH` auto-loading, pervasive checked arithmetic,
  sequence/shape/order/group kernels, exact whole-value `cmp`, immutable
  list/dict updates and construction, kind reflection, cycling take,
  count-vector where, canonical `str`, pervasive transcendentals, and Unicode
  split/join/format.
- [`poc/rust/`](poc/rust/) contains the Rust walking-skeleton interpreter and
  its examples and tests. It is a standalone Cargo project and is not evolved
  with the real interpreter.

To test the Zig implementation with the pinned Zig 0.16 toolchain:

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test-tsan
zig build source-audit
```

To run the calculator:

```sh
zig build
./zig-out/bin/ecl '3 4 +'

# Source modules are named registry values; files are transport.
ECL_PATH=test/acceptance/modules \
  ./zig-out/bin/ecl -e "'stats use answer"

# Re-registering heals qualified, used, and aliased callers.
./zig-out/bin/ecl test/acceptance/hot-reload.ecl
```

To exercise the Rust semantics oracle:

```sh
cargo test --locked --manifest-path poc/rust/Cargo.toml
cargo build --locked --manifest-path poc/rust/Cargo.toml
zig build oracle-differential \
  -Doracle-exe=poc/rust/target/debug/ecl
```

The differential step covers every M5 word shared by the implementations.
Normal `zig build test` remains independent of Cargo; `flip`, `reshape`,
`group`, `cmp`, `type`, `to-dict`, the transcendental floor, and the extended
list-`put`/cycling-`take`/count-`where` semantics are post-freeze Zig additions
with native unit and real-binary acceptance coverage.
