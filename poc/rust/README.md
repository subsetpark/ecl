# ecl Rust walking skeleton

This directory contains a small end-to-end interpreter for the language
specified by [DESIGN.md](../../design/DESIGN.md),
[GRAMMAR.md](../../design/GRAMMAR.md), and
[VOCABULARY.md](../../design/VOCABULARY.md). It is a walking skeleton: the
important runtime boundaries are real, while the full v1 vocabulary and
optimized storage are still future work.

From this directory, build and try it:

```sh
cargo run -- '3 4 +'
cargo run -- '[1 2 3] (dup *) each'
cargo run -- examples/tour.ecl
cargo run -- examples/modules.ecl
```

With an installed binary, the cold calculator form is simply:

```sh
ecl '3 4 +'
# 7
```

Run `cargo run` with no arguments for the REPL. Open strings and delimiters
continue onto the next line. A file is one unit; each complete REPL entry is
one unit. `-e SOURCE`, stdin (`-`), and source-as-the-first-argument are also
supported. File scripts only print explicitly (for example with `pp`), while
calculator and stdin modes print the final stack.

## What is implemented

- The UTF-8 grammar: comments, comma whitespace, numbers, chars, strings,
  quoted/qualified symbols, matched `()`/`[]`, provenance, and dict-literal
  desugaring.
- Binder lowering with no closures or hidden local environment. For example,
  `(|x| x x *)` becomes ordinary point-free code using `cons`, `at`, `swap`,
  `dip`, and `pop`; crossing a quotation boundary is rejected.
- Immutable, reference-shared values and canonical representation-exposing
  printing.
- One iterative frame machine for word calls, control flow, recursion, and
  isolated combinators. Evaluation does not recurse through the Rust call
  stack, and tail calls through words, `call`, and `if` reuse their trace/eval
  frame.
- Stack-transactional units. A failure restores the entry stack, while earlier
  writes to surviving environments, module-registry writes, and IO remain
  visible.
- Chained environments with a core root, a persistent session scope, and a
  disposable child scope for every isolated quotation application. `each`,
  `zip-with`, `for`, `fold`, `scan`, `dict-of`, and `attempt` cannot leak a
  temporary `def` or `let` into their caller; inline applications keep the
  current scope.
- Late-bound `def` versus non-executing `let`, private `defp`/`letp` inside
  modules, plus `body`, `parse`, and `str`.
- A per-session module registry. `'name (body) module` constructs a module in
  a fresh environment rooted at core; `def`/`let` export while `defp`/`letp`
  remain internal. Qualified words, scoped `use`, and registry `alias` are
  implemented.
- Module words carry their home module name and resolve through the current
  registry generation. Callers cannot shadow module internals, used modules
  follow reloads, aliases follow reloads, and a failed replacement leaves the
  previous generation registered. Fetching a word with `body` still returns a
  plain quotation, so applying it elsewhere intentionally loses module context.
- Pervasive numeric arithmetic/comparison with checked int64 overflow,
  float64 division, leading-axis broadcasting, ragged descent, dict value
  pervasion, and Unicode char arithmetic.
- A useful vertical slice of list, dict, string, IO, and contract-checked
  iteration words. `attempt` reifies isolated success/error outcomes.
- Error dictionaries with kind, message, innermost word, ecl trace, source
  location, and kind-specific data.

Use `words` to print the currently available vocabulary. The implemented
prelude includes `nip`, `when`, `wrap`, `pair`, `last`, `sort`, `sum`, `prod`,
`mean`, `print`, `inspect`, `keep`, `bi`, `tri`, `fail`, `lines`, and `find`
as ordinary ecl definitions.

Decision-22 rulings are implemented: words and symbols are distinct atoms
(`to-word`/`to-symbol` convert), `inf`/`-inf` are float literals with IEEE
propagation while NaN-producing operations error, all-char lists specialize
to strings at construction, `zip-with` extends atoms like broadcast,
`floor`/`ceil`/`round` return int64, and error dicts omit `'word` when no
word raised.

## Deliberately not in the skeleton

Module file transport and automatic `ECL_PATH` loading, concurrency,
`flip`/`reshape`/`group`, reflection tooling beyond `body`/`words`, `exit`, and
the deferred `seal` layer are not implemented yet. In particular, `use`
currently requires an already registered module. Lists use immutable `Arc`
slices but do not yet have typed leaf buffers or copy-on-write uniqueness
optimization.

These omissions are boundaries, not alternate semantics. Unsupported words
fail as `'undefined-word`; the implemented behavior is covered by unit and CLI
integration tests.

## Development

```sh
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
```
