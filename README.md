# ecl

ecl is a clean-slate homoiconic concatenative array language. The real
interpreter is being built in Zig at the repository root; the earlier Rust
walking skeleton remains a frozen executable semantics oracle.

## Repository map

- [`design/`](design/) contains the settled design ledger, grammar, and
  vocabulary.
- [`src/`](src/) contains the Zig implementation. The value core, reader, and
  frame machine are live: `zig build` produces a working `ecl` calculator with
  late-bound definitions, transactional units, error dicts, and a small M3
  primitive vocabulary.
- [`poc/rust/`](poc/rust/) contains the Rust walking-skeleton interpreter and
  its examples and tests. It is a standalone Cargo project and is not evolved
  with the real interpreter.

To test the Zig implementation with the pinned Zig 0.16 toolchain:

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test-tsan
```

To run the calculator:

```sh
zig build
./zig-out/bin/ecl '3 4 +'
```

To exercise the Rust semantics oracle:

```sh
cd poc/rust
cargo test
cargo run -- '[1 2 3] (dup *) each'
```
