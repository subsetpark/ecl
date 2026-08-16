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
  count-vector where, canonical `str`, pervasive transcendentals, Unicode
  split/join/format, isolated quotation combinators, inline control, pure
  `parse`, guarded phrase recognition, identity task values, structured
  concurrency on a lazy fixed worker pool, deadline waits, whole-call console
  serialization, and an embedded source prelude.
  Test suites and their helpers live under [`src/tests/`](src/tests/);
  build-only architecture checks live under [`src/tools/`](src/tools/).
- [`poc/rust/`](poc/rust/) contains the Rust walking-skeleton interpreter and
  its examples and tests. It is a standalone Cargo project and is not evolved
  with the real interpreter.

To test the Zig implementation with the pinned Zig 0.16 toolchain:

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test-workers
zig build test-oom
zig build test-tsan
zig build test-repl
zig build test-repl -Doptimize=ReleaseSafe
zig build fuzz
zig build source-audit
zig build differential
```

`zig build fuzz` runs the seed corpus as an ordinary smoke test. Add a bounded
coverage-guided campaign for one independently wired target, for example
`zig build fuzz-editor --fuzz=10K`. The available suffixes are `reader`,
`formatter`, `editor`, `completion`, `history`, and `scheduler`; CI invokes
every target separately for 100 generated iterations so Zig's single-target
fuzz runner cannot silently select only one surface.
The editor target is a shrinkable arbitrary-byte/action state machine that
checks exact byte preservation, cursor and UTF-8 boundary invariants, the line
limit, and owned-line cleanup after every transition.

`test-workers` runs the complete library and real-binary suite at one and eight
workers. `test` keeps low-level exhaustive allocator checks alongside ordinary
behavioral coverage. `test-oom` is the separate ReleaseSafe gate for the
costlier full-session sweep; it initializes one session and traverses every
runtime surface under each injected allocation failure without repeatedly
bootstrapping the embedded prelude.

Scheduler interleavings are generated against the allocation-free policy core
with the pinned Minish property-testing library. Failures retain a fixed replay
seed and are automatically shrunk to a smaller event trace.

To run the calculator:

```sh
zig build
./zig-out/bin/ecl '3 4 +'

# Source modules are named registry values; files are transport.
ECL_PATH=test/acceptance/modules \
  ./zig-out/bin/ecl -e "'stats use answer"

# Re-registering heals qualified, used, and aliased callers.
./zig-out/bin/ecl test/acceptance/hot-reload.ecl

# Concurrency is configured per process.
ECL_WORKERS=8 ./zig-out/bin/ecl '[1 2 3] (dup *) par-each'

# Format a file, or pipe source through standard input. Output is stdout-only.
./zig-out/bin/ecl fmt src/prelude.ecl
./zig-out/bin/ecl fmt - < src/prelude.ecl
```

## Interactive REPL

With no arguments and a TTY on stdin, ecl uses a dependency-free single-row
ANSI/VT100 editor. Left/Right and Ctrl-B/Ctrl-F move by UTF-8 scalar; Home/End
and Ctrl-A/Ctrl-E move to the ends. Backspace, Delete, Ctrl-H, Ctrl-D,
Ctrl-K, Ctrl-U, Ctrl-W, and Ctrl-T provide the usual deletion, kill, and
transpose operations. Up/Down and Ctrl-P/Ctrl-N navigate history; Ctrl-L
clears and redraws the screen. Editing is scalar-safe rather than
grapheme-aware, and a physical line is limited to 1 MiB.

Tab completes the current atom from live public session/core names, public
exports of used modules, and registered module and alias names. A unique match
is inserted. Multiple matches extend their common prefix; pressing Tab again
prints the sorted candidates. Dotted input such as `stats.<Tab>` completes
only public exports and preserves the namespace or alias spelling that was
typed. Completion does not intern partial input.

Every nonempty submitted physical line enters a 100-entry history. When HOME
is available, processes share `$HOME/.ecl_history`; writers merge under a
sibling lock and replace the UTF-8 newline-delimited file atomically. Missing,
corrupt, oversized, locked, or unwritable history never disables the REPL and
emits at most one warning per Session. Ctrl-C abandons both the current edit
and an incomplete continuation. Ctrl-D deletes at a nonempty cursor, exits at
an empty primary prompt, and retains the incomplete-at-EOF diagnostic at an
empty continuation prompt.

Raw editing is supported on Linux and macOS, with terminal attributes restored
on every return and error path. Other targets build with canonical line input.
Piped stdin and explicit `-` remain one-unit noninteractive modes: they do not
load history, interpret escape keys, or request completion. The Expect-based
PTY contract is exercised with `zig build test-repl -Doptimize=ReleaseSafe`.
Its binary corpus includes first-turn completion, queued lines, malformed and
truncated UTF-8/escape input, EOF/error recovery, durable-history parseability,
and terminal restoration.

`ecl fmt` parses a trivia-preserving source tree without evaluating it and
renders through a 100-column document algebra. Delimited forms use uniform
structural alignment; comments and ordinary literal contents are preserved.
Literal `def`/`defp` blocks receive canonical `### def <name>` section headers.
Definition docstrings are the one reflowable string position: their canonical
text folds physical prose lines, retains paragraphs and Markdown `- ` items,
and therefore remains unchanged when the formatted definition is loaded.

To exercise the Rust semantics oracle:

```sh
cargo test --locked --manifest-path poc/rust/Cargo.toml
cargo build --locked --manifest-path poc/rust/Cargo.toml
zig build oracle-differential \
  -Doracle-exe=poc/rust/target/debug/ecl
```

The in-process differential requires a fast-path hit for every registered
idiom and compares it with forced-generic execution, including representation
and float-bit parity. The oracle differential covers every shared M5/M6 word
without changing the frozen Rust tree.
Normal `zig build test` remains independent of Cargo; `flip`, `reshape`,
`group`, `cmp`, `type`, `to-dict`, the transcendental floor, and the extended
list-`put`/cycling-`take`/count-`where` semantics are post-freeze Zig additions
with native unit and real-binary acceptance coverage.

## M6 quotation and source surface

`each`, `each2`, `for`, `fold`, and `scan` run each application on a fresh
isolated stack and scope, enforcing `(a -- b)`, `(a b -- c)`, `(a --)`, and
`(acc a -- acc)` contracts as appropriate. `infra` also isolates its
quotation but collects any number of results. `times`, `cond`, and `case` run
inline: `cond` is `[test action ... else]`, while `case` is
`subject [key action ... else]` with inert keys. Both clause lists are
nonempty, odd, exhaustive, and prevalidated before selection.

The embedded, commented [`src/prelude.ecl`](src/prelude.ecl) is the sole body
for the M6 derived vocabulary: cleaves and control adapters, collection
helpers, aggregates, `find`, and the failure/outcome protocol. Each definition
is a navigable `### def <name>` block with reflective documentation:

```ecl
### def signum
(dup 0 > swap 0 < -)
(number -- sign : "Return -1, 0, or 1 according to the sign of a number.")
'signum def
```

Top-level `def` accepts no annotation, an effect, a docstring, or both; module
`def`/`defp` require the effect portion. The annotation is ordinary quotation
data, `doc` retrieves its string through normal name resolution, and `see`
prints a canonical re-readable definition. Documentation is canonicalized at
definition time: formatting indentation and soft prose line breaks disappear,
while paragraph boundaries and Markdown `- ` items remain. Ordinary strings
retain raw newlines exactly. For example:

```sh
./zig-out/bin/ecl -e \
  '(dup *) (x -- y : "Square a numeric value.") '\''square def 4 square '\''square doc '\''square see'
```

The public
`parse` word uses the same bounded reader to return unevaluated forms with
`<parse>` provenance; it performs no filesystem access. `slurp`, `spit`,
`getenv`, and `lines` remain deferred to M9.

## M7 tasks and structured concurrency

`spawn` runs a quotation with an empty isolated stack and returns an opaque
identity handle. `await` parks the calling unit and returns the child's cached
`{'ok [...]}` or `{'err {...}}` outcome; duplicated handles and multiple
waiters observe the same result. `cancel` recursively flags a task tree,
`tasks` snapshots pending descendants in spawn preorder, `await-any` selects
one indexed completion, and `await-for` limits a wait without cancelling the
task. Source-defined `await-all` waits for a list of tasks and returns every
ordinary outcome in input order without re-raising task failures. Task
displays such as `<task:1>` are intentionally rejected by the reader because
they are live Session capabilities, not serializable values.
Large native operations, result publication, joins, and cancellation walks
resume in bounded scheduler slices; no task runs another task recursively on
its suspended native stack.

`par-each` is a public primitive backed by a bounded native driver. It spawns
each child with the element as an explicit initial stack value, then transfers
the exact task list into the evaluator's ordered join state. That state
enforces the one-result-per-child, suffix-cancellation, and leftmost-failure
contract; it is not a word and grants no private dictionary authority.
Successful results and the leftmost failure are stable across worker counts.
Cross-task console calls and genuinely concurrent `await-any` completions may
reorder. Use `par-each` for coarse independent work; ordinary pervasive array
kernels are the efficient choice for element-wise arithmetic. `ECL_WORKERS`
accepts only a positive base-10 integer and defaults to the available CPU
count. Workers and the single timer thread are both started lazily.

Scheduler policy is an allocation-free functional core; the threaded runtime
is its imperative shell. Minish checks both generated core interleavings and
shrinking public-CLI scenarios under a liveness deadline, so wait-registration
or handler bypasses are covered as well as policy transitions. The core also
tracks directory, cell, detached-delivery, and retired registration ownership;
the shell uses stable owning wake handles and publishes a root wake only as its
final access to that stack generation.
