# ECL

ECL combines the stack-based composition of Forth and Joy with the whole-array
operations of APL, J, and K. It is intended for interactive data exploration,
command-line work, and everyday programs, evolving the ideas behind
[ec](https://ec-calc.com/) beyond a desk calculator.

- **Stack-based composition.** Values go on a stack; words consume them and
  leave results. Programs read from left to right.
- **Array operations.** Arithmetic works on scalars and nested lists, often
  removing the need for explicit loops.
- **Programs as data.** Quotations are ordinary lists that you can construct,
  inspect, combine, and execute.
- **Immutable values.** Lists, strings, and dictionaries can be freely shared.
  Modules provide encapsulation and private state.
- **Built-in tools for real programs.** ECL includes modules, packages, tests,
  concurrency, and libraries for tables, JSON, CSV, files, HTTP, and processes.
  Trusted native extensions can be written in Zig.

ECL is pre-1.0 software. Language and native extension compatibility may change
between prereleases.

## Get and build

Building requires Zig 0.16.0, as pinned by `build.zig.zon`:

```sh
git clone https://github.com/subsetpark/ecl.git
cd ecl
zig build install -Doptimize=ReleaseSafe
./zig-out/bin/ecl --version
./zig-out/bin/ecl
```

To install under `~/.local` and make `ecl` available in your shell:

```sh
zig build install -Doptimize=ReleaseSafe --prefix ~/.local
export PATH="$HOME/.local/bin:$PATH"
ecl --version
```

Add the `export` line to your shell's startup file to keep it across sessions.
To remove that installation, run `zig build uninstall --prefix ~/.local`.

## Start using ECL

Run `ecl` in a terminal to start the REPL. Each input leaves its results on
the stack for the next input:

```text
$ ecl
ecl> 3 4
3 4
ecl> +
7
```

The REPL supports multiline input, history, and completion. Ctrl-C abandons
the current input; Ctrl-D exits from an empty prompt.

You can also evaluate an expression directly:

```sh
ecl '3 4 +'                         # 7
ecl '[1 2 3] 10 *'                  # [10 20 30]
ecl '[5 -3 8 -1] dup 0 > where at'  # [5 8]
ecl '"hello" str.upper'             # "HELLO"
```

Parentheses quote a program; `def` gives it a name:

```text
$ ecl
ecl> ((sum) (len) bi /) 'mean def
ecl> 10 range mean
4.5
```

Here, `bi` applies both `(sum)` and `(len)` to the same list, then `/`
divides their results. The built-in help lets you explore words as you go:

```ecl
'fold1 doc
'fold1 see
'str.upper which
```

Use `doc` for documentation, `see` for a definition, and `which` to locate a
binding. The [getting-started guide](GETTING_STARTED.md) introduces more of
the language with worked examples.

### Scripts and commands

Save this as `hello.ecl`:

```ecl
"Hello, world!" io.print
```

Then run `ecl hello.ecl`. Scripts print through words such as `io.print` and
`io.pp`; expressions and piped input print the final stack. Arguments after
a script or expression are available through `args`.

```sh
ecl hello.ecl              # Run a script
ecl -e '3 4 +'             # Explicitly evaluate source
printf '3 4 +' | ecl       # Evaluate standard input
ecl fmt hello.ecl          # Print formatted source
ecl fmt -w hello.ecl       # Format a file in place
ecl --help                 # Show command help
```

Standard-library modules are bundled with the interpreter: use qualified
words such as `str.upper`, `json.parse`, or `csv.parse` directly, without
installing packages.

### Projects and packages

Start a project and synchronize its dependencies:

```sh
ecl pkg init my.app
ecl pkg sync
```

`pkg init` creates `src/` and selects `src/**/*.ecl`, with no public exports.
Put source files there and run `ecl test`. Literal top-level module declarations
are visible within the local scope; `exports` selects what installed consumers see.

To add a dependency, run `ecl pkg add <name> <version> <https-url>` with the
package's name, version, and archive URL, then run `ecl pkg update`.
Public HTTPS Git repositories can also supply packages:

```sh
ecl pkg add https://example.com/author/library.git --tag v1.2.0
# Or: ecl pkg add https://example.com/author/library.git --commit <full-commit-id>
ecl pkg update
```

The repository must contain `ecl.pkg` at its root. `add` infers its name and
version and records the resolved commit and artifact hash; `sync` installs it
without resolving the tag again. Exactly one tag or full lowercase 40-digit
commit is required. Branches, credentials, symlinks, and submodules are rejected.
Ordinary tracked data files are included. Git need not be installed.
For a private certificate authority, set `ECL_GIT_CA_FILE` to an absolute PEM
certificate bundle path; certificate verification remains enabled.

Commit both `ecl.pkg` and `ecl.lock`.

Synchronization publishes an immutable project-local generation and activates
its `ecl.modules` map. The interpreter reads only that map and discovers local
sources afresh; it never reads manifests or lockfiles, fetches, or repairs state.
Normal sync honors the portable lock; dependency changes require `ecl pkg update`.
Each generation retains its own resolution snapshot. Interrupted publication is
recovered by the next mutating package command, preserving the previous runnable
generation until activation. `ecl pkg verify` checks the active generation without
repair. See the [package application contract](apps/pkg/README.md).

List your source files and the modules other files may use in `ecl.pkg`:

```ecl
{'format 2 'name "my.app" 'version "0.1.0"
 'sources ["src/*.ecl"] 'exports ["my.app"]
 'requires {}}
```

Exports name exact modules exposed to installed consumers. Other registrations
in installed artifacts stay private to their defining file.

Use `ecl pkg tree` to inspect dependencies, `ecl pkg verify` to check them,
and `ecl pkg vendor` to prepare the project for offline use. Run a synchronized
project's declared tests with `ecl test`, which loads all declared source files,
including files whose modules are all private. The
[package example](examples/pkg-smoke/README.md) walks through a complete workflow.

### Neovim

The repository includes filetype detection, syntax highlighting, indentation,
and formatting support. Add this to your Neovim configuration:

```lua
vim.opt.runtimepath:append("/path/to/ecl/runtime")
vim.cmd("filetype indent on")
```

Replace the path with your checkout and restart Neovim. Opening an `.ecl`
file enables the integration. With `ecl` on Neovim's `PATH`, use `gggqG`
to format the whole buffer. Formatting partial ranges is not supported.

## Repository layout

| Path | Contents |
|---|---|
| [`src/`](src) | Zig interpreter and runtime |
| [`src/prelude.ecl`](src/prelude.ecl) | Core vocabulary written in ECL |
| [`src/stdlib/`](src/stdlib) | Embedded standard-library modules |
| [`src/native/`](src/native) | Public Zig extension SDK |
| [`src/tests/`](src/tests), [`test/`](test) | Runtime tests, acceptance suites, and fixtures |
| [`src/tools/`](src/tools) | Source checks and benchmarks |
| [`examples/`](examples) | Package and native-extension examples |
| [`runtime/`](runtime) | Neovim integration |
| [`design/`](design) | Language, library, environment, and architecture references |
| [`gameplans/`](gameplans) | Implementation plans |
| [`agent-guides/`](agent-guides) | Engineering and verification guidance |
| [`build.zig`](build.zig), [`build.zig.zon`](build.zig.zon) | Build tasks, version, and dependencies |
| [`.github/workflows/`](.github/workflows) | CI and release validation |

For development, `zig build check` is the quick compile check and
`zig build precommit` is the local source-change gate. See
[AGENTS.md](AGENTS.md) and the [testing guide](agent-guides/testing.md) for
contributor instructions.

## Reference

- [Language specification](design/SPEC.md): syntax and semantics.
- [Standard library](design/STDLIB.md): words, stack effects, and examples.
- [Environment](design/ENVIRONMENT.md): command behavior, module loading,
  packages, and host integration.
- [ECL style](design/ECL_STYLE.md): conventions for ECL source.
- [Interpreter architecture](design/INTERPRETER.md): runtime design and invariants.
- [Native extension tutorial](examples/port-authoring/README.md): build a Zig extension.

ECL is distributed under the [BSD 3-Clause License](LICENSE).

The default distribution includes maintained applications. `zig build -Dapps=false`
installs the same interpreter without application sources or Git
dependencies; it does not fetch or link libgit2. Use a separate installation prefix
when comparing core-only and complete distributions.
