# ECL

ECL is a programming language that tries to bring together three main ideas:

- Concatenative syntax: ECL is strongly influenced by the
  [Joy](https://hypercubed.github.io/joy/joy.html) programming language, which
  uses a stack-based operating model and postfix syntax to try to achieve the
  most natural kind of pointfree (or tacit) programming. As a result ECL is
  also influenced by [Factor](https://factorcode.org/), a very robust and
  usable daughter language to Joy. 
- Array semantics: ECL doesn't look like
  [K](https://wiki.k-language.dev/wiki/Main_Page), but it tries to behave like
  it and other members of the array family. This primarily means: pervading
  primitives over conforming data structures, and optimizations designed to
  make array-wise logic both the most performant and convenient.
- Ergonomics: While ECL is intended to be convenient for one-off scripts and
  REPL sessions, it should be able to scale up to large programs; thus it also
  has first-class support for program-organization structures like modules,
  package management, and tests.

ECL is pre-1.0 software. Language and native extension compatibility may change
between prereleases.

## Get and build

Building requires Zig 0.17.0, as pinned by `build.zig.zon`:

```sh
git clone https://github.com/subsetpark/ecl.git
cd ecl
zig build install --release=fast
./zig-out/bin/ecl --version
./zig-out/bin/ecl
```

To install under `~/.local` and make `ecl` available in your shell:

```sh
zig build install --release=fast --prefix ~/.local
export PATH="$HOME/.local/bin:$PATH"
ecl --version
```

Add the `export` line to your shell's startup file to keep it across sessions.
To remove that installation, run `zig build uninstall --prefix ~/.local`.

## Running ECL

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

The above snippets demonstrate some of the core datatypes in ECL: integers,
symbols, and strings. Lists are formed with `()` or `[]`. An invocation like
`[1 2 3] 10 *` will apply the multiplication operation to 10 and each element
in the list `[1 2 3]`. Strings are formed with double-quotes.

Evaluating an unquoted symbol (like `*` or `where`) invokes its word.
To push a symbol without invoking its word, quote it with `` ` ``.
A quotation is a list of values, including other quotations. To define new
words, call `def` with a quotation and a quoted symbol.

```text
$ ecl
ecl> ((sum) (len) bi /) `mean def
ecl> 10 range mean
4.5
```

Once the word is defined, evaluating `mean` executes its quotation.

Here, `(sum)` and `(len)` are also both quotations. `bi` is a **combinator**: a
word which expects quotations on the stack and applies them in useful patterns.
`bi` applies both `(sum)` and `(len)` to the same list, then `/` divides their
results. 

There are some simple reflection words which allow for exploration in the REPL:

```ecl
`fold1 see
`fold1 doc
`str.upper which
```

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

### Projects and packages

Start a project and synchronize its dependencies:

```sh
ecl pkg init my.app
ecl pkg sync
```

`pkg init` creates `src/` and selects `src/**/*.ecl`, with no public exports.
Put source files there and run `ecl test`. 

To add a dependency, run `ecl pkg add <name> <version> <https-url>` with the
package's name, version, and archive URL, then run `ecl pkg update`.
Public HTTPS Git repositories can also supply packages:

```sh
ecl pkg add https://example.com/author/library.git --tag v1.2.0
# Or: ecl pkg add https://example.com/author/library.git --commit <full-commit-id>
ecl pkg update
```

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

## Reference

The following documents are partially or totally suitable for human
consumption. The other design docs in this repo are written by AI.

- [Getting Started](GETTING_STARTED.md)
- [Language specification](design/SPEC.md)
- [Standard library](design/STDLIB.md)

ECL is distributed under the [BSD 3-Clause License](LICENSE).
