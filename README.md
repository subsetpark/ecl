# ECL

ECL is a language drawing from two primary programming language families:

*concatenative* - Like Forth, Factor, and Joy, ECL's operational semantics
model the pushing and popping of values to and from an **operand stack**.
The language's syntax is a reverse-Polish notation, where stack
manipulation words are evaluated from left to right. Like Joy in particular,
ECL is homoiconic (or refective), and lists are special cases of programs.

*array* - Like APL, J, and K, primitive operators are pervasive: they
automatically conform to arbitrary-dimensional lists without having to
invoke higher-order-functions like `map` or constructs like loops.

As the name suggests, ECL represents the attempt to evolve an old
project---[ec](https://ec-calc.com/) into a proper programming language.
Like ECL, ec attempted to combine the two above attributes in a single
computing environment; both both the semantics and implementation of the
older project limited it to desk-calculator use and omitted capabilities needed
by a programming language.

ECL is intended to attain some of the usefulness for live data exploration and
command-line use of K, some of the elegance and functional character of Joy,
while being more suited to writing standard and maintainble user-land programs
  than either.

ECL is pre-1.0 software. Version `0.1.0` is usable, but language and native
extension compatibility may change between prereleases.

## Build

Building requires Zig 0.16.0, as pinned by `build.zig.zon` and CI.
The default install prefix is the repository's `zig-out` directory:

```sh
git clone https://github.com/subsetpark/ecl.git
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

### Values

Literals push values. Words consume values and leave results.

```sh
ecl '3 4 +'                         # 7
ecl '1 2 3 3 pack sum'              # 6
ecl '[5 -3 8 -1] dup 0 > where at'  # [5 8]
```

### Quotations

Programs are represented both in syntax and in data as simple lists of words.
Executing a program is equivalent to pushing its words to the operand stack.
Defining a function is equivalent to assigning a program to a new word, and
functions are words which push their programs to the stack.

```sh
ecl> 10 range (sum) (len) bi /
4.5
ecl> 10 range ((sum) (len) bi /) call
4.5
ecl> ((sum) (len) bi /) 'mean def
ecl> 10 range mean
4.5
```

Because there's no internal compiled representation of programs besides their
quoted spellings (see _idioms_ below for an internal exception), program
construction and metaprogramming by quotation manipulation is a common
and universally available technique.

```sh
ecl> 4 range [4 3] reshape 3 4 rng.ints
([0 1 2]
 [3 0 1]
 [2 3 0]
 [1 2 3]) [2 2 0]
ecl> (lex-cmp) partial each
[-1 1 1 -1]
```

### Array operations

The primitive operators in ECL conform to the shapes of their operands.
This means that one applies a program like `1 +` to a value of any shape:
if the value is a scalar then 1 is added to it and the result is pushed on
  the stack; if the value is a list, or list of lists, then 1 is added to
  every scalar inside the value in a way that preserves its shape.

```sh
ecl> 20 100 rng.ints [4 5] reshape
([35 0 79 44 47]
 [90 13 40 99 90]
 [1 26 83 31 17]
 [7 25 2 92 84])
ecl> 1 + sqrt
([6.0 1.0 8.94427190999916 6.708203932499369 6.928203230275509]
 [9.539392014169456 3.7416573867739413 6.4031242374328485 10.0 9.539392014169456]
 [1.4142135623730951 5.196152422706632 9.16515138991168 5.656854249492381 4.242640687119285]
 [2.8284271247461903 5.0990195135927845 1.7320508075688772 9.643650760992955 9.219544457292887])
ecl>
```

This semantic unity has both language-level and interpreter-level
implications: at the level of syntax, many looping constructs necessary in
other languages are elided. At the level of execution, the
representation of `1 +` as a single operation allows for optimization
of its execution over the sequential execution of scalar operations.

### Modules

Modules are the unit of encapsulation and binding-sealing. The word `@defm`
constructs a module and registers it globally, namespacing its exposed
definitions and (optionally) encapsulating private state.

```sh
ecl> [] (((1 +) within) 'inc def
..    ((1 -) within) 'dec def
..    ((dup without) within) 'get def 0) 'counter @defm
ecl> counter.get
0
ecl> pop counter.inc counter.inc counter.get
2
```

## Running ecl

```text
ecl                         Start a REPL, or read non-TTY stdin as one unit
ecl -e <SOURCE> [ARGS...]  Evaluate source and print the final stack
ecl <FILE> [ARGS...]       Run a UTF-8 script
ecl <SOURCE> [ARGS...]     Evaluate source and print the final stack
ecl fmt <FILE|->           Format source to standard output without evaluating it
ecl fmt -w <FILE>          Format and atomically rewrite a file
ecl pkg <SUBCOMMAND>       Manage the current project's packages
ecl test [--runner <qualified-word>] [-- <ARGS...>]
                            Run the root project's tests
ecl -h | --help            Show command help
ecl -V | --version         Show the version
```

A script file prints only when it calls `io.pp`, `io.print`, `io.prin`,
`io.inspect`, or `io.debug`. Calculator input, `-e`, and non-TTY stdin print
the final stack. Trailing arguments are available through `args`.

Running `ecl` on a terminal starts the built-in REPL:

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

### Neovim

The repository includes filetype detection and lightweight syntax highlighting
for Neovim. Add its `runtime` directory to Neovim's runtime path:

```lua
vim.opt.runtimepath:append("/path/to/ecl/runtime")
vim.cmd("filetype indent on")
```

Opening an `.ecl` file then enables highlighting for comments, strings and
escapes, numbers, characters, quoted symbols, delimiters, binders, and
definition words. With filetype indentation enabled, Neovim also aligns nested
forms using the formatter's one-space style while preserving whitespace inside
multiline strings. Run `gggqG` to format the whole buffer through `ecl fmt -`;
the `ecl` executable must be on Neovim's `PATH`. Formatting arbitrary partial
ranges is not supported because they may not be complete ECL programs. Restart
Neovim after changing the runtime path.

### Packages

`ecl pkg` manages exact HTTPS dependencies with an `ecl.pkg` manifest and a
reproducible `ecl.lock` file. A typical workflow is:

```sh
ecl pkg init
ecl pkg add smoke 1.0.0 https://example.com/smoke-1.0.0.tgz
ecl pkg sync
ecl pkg verify
```

Commit both files. Packages are installed in an immutable shared cache;
`ecl pkg vendor` copies the locked packages into the project for self-contained
offline use. Use `tree` and `why` to inspect the lock, and `gc` to clean the
shared cache. See [`examples/pkg-smoke`](examples/pkg-smoke) for a complete
workflow.

### Tests

Tests use module declarations and do not require exported words. They may call private
definitions and may use the same name as an ordinary definition. Ordinary
application loading validates and then discards them, so test bodies and test
catalog indexes are not retained in shipped module images:

```ecl
### module app.math
[]
(
 ### defp double
 (n -- n : "Double a number.")
 (2 *) 'double defp

 ### test doubles
 (: "Exercise the private implementation.")
 (21 double 42 = {'kind 'user} assert) 'doubles test
) 'app.math @defm
```

From a synchronized root project, `ecl test` loads every root-package module
declared by the lock-backed catalog and runs tests in canonical module/name
order. Each invocation has an isolated operand stack, while module state is
shared for the lifetime of that test command. Session teardown discards that
state; file, network, process, and other external effects are real and are not
rolled back.

The bundled `test.default.run` runner is deliberately replaceable. Use
`ecl test --runner app.custom.run -- --filter smoke` to select any public
qualified runner word and expose the tokens after `--` through `args`.
Userland runners compose the closed `tests` and `@test` substrate to implement
filtering, hooks, retries, concurrency, reporting, and exit policy without
receiving test bodies or private module authority.

## Modules and the standard library

A qualified reference loads its module on first use. The embedded standard
library is checked before the filesystem, so it works without `ECL_PATH` and
cannot be replaced accidentally by a file with the same name.

| Modules | Purpose |
|---|---|
| `dict` | Immutable map construction, observation, transformation, selection, and merging |
| `error` | Structured error construction and inspection |
| `result` | Validated success and error envelopes |
| `str` | Text formatting, search, replacement, case, trimming, and padding |
| `io` | Terminal, stdin, and UTF-8 file operations |
| `csv`, `json` | External data formats |
| `table` | Column-oriented tables represented as ordinary dictionaries |
| `http` | HTTP GET and POST |
| `proc` | Capability-gated subprocess ports and bounded process execution |
| `rand` | Explicit-state random draws and host entropy |
| `rng` | Durable module-state random generation |
| `archive` | SHA-256 and atomic validated `.tgz` extraction |
| `pkg.*` | Package names, versions, manifests, locks, and minimal-version resolution |

Use a qualified word directly:

```sh
ecl '"hello" str.upper'                    # "HELLO"
ecl "[['a 1] ['b 2]] dict.from-pairs"     # {'a 1 'b 2}
ecl '"a,b\nc,d" csv.parse'                 # (("a" "b") ("c" "d"))
ecl '"{\"a\":[1,null]}" json.parse'       # {"a" (1 'null)}
```

Subprocesses use BEAM-style opaque ports rather than PIDs. The CLI grants an
explicit process capability; library Sessions deny it unless their Host opts
in with a `ProcessPolicy`. `proc.spawn` accepts an absolute executable path,
argv/cwd/environment data, and no shell string or `PATH` lookup. Stdin,
stdout, and stderr are exact byte lists with bounded scheduler backpressure;
the spawning task scope owns termination and reap, so retaining a port cannot
detach a child. `proc.run` is the bounded capture convenience over the same
controller. The initial backend supports POSIX hosts; other targets fail
closed until they can provide equivalent process-tree ownership. Child side
effects are external effects and are not rolled back when an ECL unit fails.

`import` gives selected public module words bare names in the current
environment. Every requested word must be public.

```ecl
'str ('upper 'lower) import
"hello" upper
```

### Module namespacing

Module definition registers a canonical module name. Module-qualified words
can then be looked up for any ECL file in `ECL_PATH`. For example, save this as
`modules/stats.ecl`:

```ecl
### module stats
# Small statistical helpers.
[]
(
 ### def twice
 (value -- doubled : "Double a number.")
 (2 *) 'twice def
) 'stats @defm
```

Put its containing directory on `ECL_PATH`:

```sh
ECL_PATH="$PWD/modules" ecl '21 stats.twice'
ECL_PATH="$PWD/modules" ecl "'stats ('twice) import 21 twice"
```

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

- [`design/SPEC.md`](design/SPEC.md) is the authority on language syntax,
  semantics, errors, and modules.
- [`design/STDLIB.md`](design/STDLIB.md) is the exhaustive reference for the
  shipped core, prelude, and standard-library vocabulary.
- [`design/ENVIRONMENT.md`](design/ENVIRONMENT.md) defines module loading,
  packages, command-line behavior, and source formatting.
- [`design/ECL_STYLE.md`](design/ECL_STYLE.md) is the authoring guide for
  first-party ECL source.
- [`design/INTERPRETER.md`](design/INTERPRETER.md) describes the runtime
  architecture and its ownership, scheduling, and reclamation invariants.

ECL is also highly reflective:

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

`zig build check` is the quicker whole-tree compile check. Pull-request CI runs
the Debug precommit tier and one complete ReleaseSafe suite. `zig build
test-ecl` is the single first-class ECL test entrypoint and is owned by the
complete `zig build test` suite, so pull-request CI invokes it once. That suite
is accompanied by PTY and standalone native-extension acceptance. Master and
manual CI add the full Debug suite, bounded fuzz campaigns, eight-worker
concurrency, differential checks, TSan, and ReleaseFast snapshots. The manual
release-candidate workflow is the exhaustive superset: it repeats every test
surface and adds the initialized-Session OOM sweep and complete ReleaseFast
suite. Each optimization mode runs its tiers in one job so Zig can reuse that
mode's cache and emitted artifacts. See
[`AGENTS.md`](AGENTS.md) for the repository's testing and architectural rules.

ecl is distributed under the [BSD 3-Clause License](LICENSE).
