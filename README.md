# ecl

ecl is a clean-slate homoiconic concatenative array language. The repository
keeps the language design separate from the executable proof of concept so the
eventual application can evolve independently of the skeleton.

## Repository map

- [`design/`](design/) contains the settled design ledger, grammar, and
  vocabulary.
- [`poc/rust/`](poc/rust/) contains the Rust walking-skeleton interpreter and
  its examples and tests. It is a standalone Cargo project, not the eventual
  application.

To exercise the skeleton:

```sh
cd poc/rust
cargo test
cargo run -- '[1 2 3] (dup *) each'
```
