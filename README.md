# ecl

ecl is a concatenative array language for command-line data work. Programs run
from left to right over an operand stack. Lists are both data and code;
pervasive arithmetic and comparison apply the same way to scalars, vectors,
nested arrays, and ragged data.

The implementation is one Zig executable containing the evaluator, REPL,
formatter, core vocabulary, and standard library. It has no runtime dependency
on a prelude or module directory.

ecl is pre-1.0 software. Version `0.1.0` is usable, but language and native
extension compatibility may change between prereleases.

## Build

Building requires Zig 0.16.0, as pinned by `build.zig.zon` and CI.
The default install prefix is the repository's `zig-out` directory:

```sh
git clone https://git.sr.ht/~subsetpark/ecl
cd ecl
zig build install -Doptimize=ReleaseSafe
./zig-out/bin/ecl --version
```

To install under `~/.local` instead:

```sh
zig build install -Doptimize=ReleaseSafe --prefix ~/.local
~/.local/bin/ecl --version
```

Add `~/.local/bin` to `PATH` to invoke the executable as `ecl`. The matching
removal command is `zig build uninstall --prefix ~/.local`.

## The language model

### Values move through a stack

Literals push values. Words consume values and leave results.

```sh
ecl '3 4 +'                         # 7
ecl '1 2 3 3 pack sum'              # 6
ecl '[5 -3 8 -1] dup 0 > where at'  # [5 8]
```

There are no statement or expression forms around this model. A word's inputs
are the values immediately beneath it, and its outputs become the inputs to
the words that follow.

### A list is an array and a quotation

Parentheses and square brackets read the same immutable list value. Printing
uses brackets for specialized homogeneous storage and parentheses for generic
storage; the delimiter is not a distinct runtime type. Strings are lists of
characters, and matrices and higher-dimensional data are nested lists.

Arithmetic and comparison pervade through list structure:

```sh
ecl '[1 2 3] 10 *'        # [10 20 30]
ecl '[[1 2] [3]] 10 *'    # ([10 20] [30])
```

Dictionaries are immutable insertion-ordered maps. Any value can be a key;
quoted symbols are the usual choice:

```sh
ecl "{'name \"Ada\" 'scores [8 9]} 'scores at mean"  # 8.5
```

A list is inert until a word applies it as code:

```sh
ecl '6 (dup *) call'          # 36
ecl '[1 2 3] (dup *) each'    # [1 4 9]
ecl '3 (1 +) (2 *) bi'        # 4 6
```

Quotations carry no hidden environment. Names resolve when the quotation runs,
and quotation construction is the metaprogramming system.

### Definitions are data

`def` binds a quotation to a name. An optional annotation quotation comes
before the body and supplies a stack effect, documentation, or both.

```ecl
### def square
(number -- square : "Return a number multiplied by itself.")
(dup *)
'square def

9 square
```

At top level an effect is reflective metadata. On a public module word it is
also a dynamically checked boundary contract. `doc`, `body`, `which`, and
`see` inspect definitions through ordinary language values.

### Failure has an explicit boundary

An error aborts its current unit and restores that unit's operand stack.
`@attempt` runs a self-contained quotation in a fresh unit and returns an
ordinary result dictionary:

```sh
ecl '(1 0 /) @attempt'
# {'err {'kind 'domain ...}}
```

The `result` module validates and composes the same `{'ok values}` and
`{'err error}` envelopes produced by tasks. Errors carry a kind, message,
ecl-level trace, and source position when one is known.

### Concurrency is structured

`@spawn` starts a quotation in an isolated unit. `await`, `await-any`, and
`await-for` observe its result; `cancel` stops it. A unit cannot leave detached
tasks behind. `@each` is the parallel counterpart of `each` and preserves input
order:

```sh
ECL_WORKERS=8 ecl '[1 2 3] (dup *) @each'  # [1 4 9]
```

Immutable values cross task boundaries safely. Sequential combinators remain
left-to-right and deterministic; parallel combinators define their result and
failure ordering independently of scheduling.

## Running ecl

```text
ecl                         Start a REPL, or read non-TTY stdin as one unit
ecl -e <SOURCE> [ARGS...]  Evaluate source and print the final stack
ecl <FILE> [ARGS...]       Run a UTF-8 script
ecl <SOURCE> [ARGS...]     Evaluate source and print the final stack
ecl fmt <FILE|->           Format source without evaluating it
ecl pkg <SUBCOMMAND>       Manage the current project's packages
ecl -h | --help            Show command help
ecl -V | --version         Show the version
```

A script file prints only when it calls `io.pp`, `io.print`, `io.prin`,
`io.inspect`, or `io.debug`. Calculator input, `-e`, and non-TTY stdin print
the final stack. Trailing arguments are available through `args`.

Running `ecl` on a terminal starts the built-in editor:

```text
$ ecl
ecl> 3 4
3 4
ecl> +
7
```

The REPL retains its stack between units and provides multiline input,
history, UTF-8 cursor movement, and completion from the live environment.
Ctrl-C abandons the current unit; Ctrl-D exits from an empty primary prompt.

`str` is the compact, round-trippable rendering of a value. REPL display and
`io.pp` favor readable matrix layout and bound terminal output by eliding very
large values.

### Packages

`ecl pkg` manages inert `ecl.pkg` manifests, reproducible `ecl.lock` files,
and immutable source-package store entries. Its commands initialize projects,
add exact HTTPS requirements, synchronize online or offline, inspect the
locked graph, verify retained archive hashes, vendor a lock into the fixed
project-local `vendor/` store, and garbage-collect the shared cache against an
explicit set of lock files:

```sh
ecl pkg init [name]
ecl pkg add smoke 1.0.0 https://example.com/smoke-1.0.0.tgz
ecl pkg sync
ecl pkg tree
ecl pkg why smoke.answer
ecl pkg verify
ecl pkg vendor
ecl pkg gc ../one/ecl.lock ../two/ecl.lock
```

`vendor` verifies each retained archive before reinstalling it beneath the
project and rewrites `ecl.lock` with the closed `'store 'vendor` mode. Locked
execution, synchronization, and `verify` then remain on that project-local
store and need no shared cache or network. `init` accepts an explicit canonical
name when the working-directory basename is unsuitable and creates `ecl.pkg`
without replacing a racing file. `gc` requires at
least one named lock and removes only canonical package-store directories not
selected by any of them; unknown cache nodes are preserved.

[`examples/pkg-smoke`](examples/pkg-smoke) is a checked-in consumer of the
public source-only smoke package. Its walkthrough covers `add`, `sync`, locked
execution, offline sync, `tree`, `why`, and `verify` while asserting that the
committed manifest and lock remain byte-stable.

## Modules and the standard library

A qualified reference loads its module on first use. The embedded standard
library is checked before the filesystem, so it works without `ECL_PATH` and
cannot be replaced accidentally by a file with the same name.

| Modules | Purpose |
|---|---|
| `result` | Validated success and error envelopes |
| `str` | Text search, replacement, case, trimming, and padding |
| `io` | Terminal, stdin, and UTF-8 file operations |
| `csv`, `json` | External data formats |
| `table` | Column-oriented tables represented as ordinary dictionaries |
| `http` | HTTP GET and POST |
| `rng` | Explicit-state and module-state random generation |
| `archive` | SHA-256 and atomic validated `.tgz` extraction |
| `pkg.*` | Package names, versions, manifests, locks, and minimal-version resolution |

Use a qualified word directly:

```sh
ecl '"hello" str.upper'                    # "HELLO"
ecl '"a,b\nc,d" csv.parse'                 # (("a" "b") ("c" "d"))
ecl '"{\"a\":[1,null]}" json.parse'       # {"a" (1 'null)}
```

`import` gives one qualified word a chosen bare name in the current
environment. It does not import or re-export an entire module.

```ecl
'str.upper 'upper import
"hello" upper
```

### Source modules

A source module is an ordinary `.ecl` program that registers a canonical
module name. For example, save this as `modules/stats.ecl`:

```ecl
### module stats
# Small statistical helpers.
(
 ### def twice
 (value -- doubled : "Double a number.")
 (2 *)
 'twice def
 )
'stats
@defm
```

Put its containing directory on `ECL_PATH`:

```sh
ECL_PATH="$PWD/modules" ecl '21 stats.twice'
ECL_PATH="$PWD/modules" ecl "'stats.twice 'twice import 21 twice"
```

The first unresolved `stats.*` reference loads `stats.ecl`, requires it to
register `stats`, and resumes the original operation. Inside a module, `def`
publishes a public word and `defp` creates a private implementation word.
Module bodies may also own transactional durable state through `within` and
`without`.

`ECL_PATH` is an ordered platform path list. For each root, the loader tries
`<module>.ecl` and then `<module>.eclmod`; the first existing candidate is
authoritative, including its errors.

### Native modules

A `.eclmod` is a target-specific shared library for trusted Zig code. Native
words use the public `ecl-native` SDK, declare exact effects, and request only
the narrow host capabilities they need. Their tables validate and publish
atomically through the same module registry used by source modules.

[`test/native/sample.zig`](test/native/sample.zig) is the reference extension
used by the acceptance suite. Native loading is a trusted-code boundary:
opening a shared library executes machine code before ecl can validate its
descriptor. Do not place untrusted directories on an `ECL_PATH` used for
native modules.

## Documentation

- [`design/SPEC.md`](design/SPEC.md) is the authority on syntax, semantics,
  errors, modules, and the complete vocabulary.
- [`design/ECL_STYLE.md`](design/ECL_STYLE.md) is the authoring guide for
  first-party ECL source.
- [`design/INTERPRETER.md`](design/INTERPRETER.md) describes the runtime
  architecture and its ownership, scheduling, and reclamation invariants.
- [`design/workstream-v1.md`](design/workstream-v1.md) records the language's
  design history. [`design/workstream-pkg.md`](design/workstream-pkg.md)
  tracks the package-management workstream.

The runtime also documents itself:

```ecl
'fold1 doc
'fold1 see
'str.upper which
```

## Development

Run the local gate before committing:

```sh
zig build precommit < /dev/null
```

`zig build check` is the quicker whole-tree compile check. Per-push CI owns the
complete Debug and ReleaseSafe suites, PTY and native-extension acceptance,
worker-count variants, fuzz and differential checks, TSan, lint, and terminal
acceptance. See [`AGENTS.md`](AGENTS.md) for the repository's testing and
architectural rules.

ecl is distributed under the [BSD 3-Clause License](LICENSE).
