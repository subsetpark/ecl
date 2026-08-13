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
  direct `load`, and `ECL_PATH` auto-loading.
- [`poc/rust/`](poc/rust/) contains the Rust walking-skeleton interpreter and
  its examples and tests. It is a standalone Cargo project and is not evolved
  with the real interpreter.

To test the Zig implementation with the pinned Zig 0.16 toolchain:

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test-tsan
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
cd poc/rust
cargo test
cargo run -- '[1 2 3] (dup *) each'
```
