# ecl

ecl is a small homoiconic concatenative array language for command-line data
work. The shipped implementation is the Zig interpreter in this repository:
one executable containing the evaluator, interactive editor, core vocabulary,
and standard library.

Version `0.1.0` is the first prerelease. The language is usable, but source and
native-extension compatibility are not yet promised across prereleases.

## Install

Building requires Zig 0.16.0, the version pinned by `build.zig.zon` and CI.

```sh
git clone https://git.sr.ht/~subsetpark/ecl
cd ecl
zig build -Doptimize=ReleaseSafe
install -m 0755 zig-out/bin/ecl ~/.local/bin/ecl
ecl --version
```

The executable does not need a separate prelude or standard-library directory.
Optional source and native modules are discovered through `ECL_PATH`.

## A quick tour

ecl reads values and words from left to right. Values accumulate on a stack;
words consume inputs and leave results.

```sh
ecl '3 4 +'                               # 7
ecl '[1 2 3] 10 *'                        # [10 20 30]
ecl '[[1 2] [3]] 10 *'                    # ([10 20] [30])
ecl '[5 -3 8 -1] dup 0 > where at'        # [5 8]
```

Parentheses quote code and generic data. Square brackets are the same list
value with a request for flat specialization; printing exposes the resulting
representation. Quotations can be applied sequentially or in isolated units:

```sh
ecl '6 (dup *) call'                       # 36
ecl '[1 2 3] (dup *) each'                # [1 4 9]
ECL_WORKERS=8 ecl '[1 2 3] (dup *) @each' # [1 4 9]
ecl '(1 0 /) @attempt'                     # {'err {...}}
```

Definitions are ordinary quoted bodies. The optional annotation is reflective
documentation and, when it contains an effect, a live module-boundary
contract.

```ecl
### def square
(dup *)
(number -- square : "Return a number multiplied by itself.")
'square def

9 square
```

Run a source file without implicitly printing its final stack, or use `-e` to
print the final stack. Scripts print explicitly with `io.pp` or `io.prin`.

```sh
ecl program.ecl
ecl -e '9 square'
printf 'a\nb\n' | ecl -e 'io.stdin "\n" split len'
```

`str` is the canonical, round-trippable value rendering. `io.pp` and the REPL
favor readable matrix layout and elide very large lists, so a mistaken terminal
probe stays bounded.

## Standard library and data pipelines

The `result`, `str`, `io`, `csv`, `json`, `table`, `http`, and `rng` modules are
embedded and load on first use. A qualified name is enough; `use` additionally
imports a module's public names into the current environment.

```sh
ecl '"hello" str.upper'                         # "HELLO"
ecl "['a 1] str"                                # "('a 1)"
ecl '"a,b\nc,d" csv.parse'                      # (("a" "b") ("c" "d"))
ecl '"{\"a\":[1,null]}" json.parse'            # {"a" (1 'null)}
ecl -e "'result use 3 result.ok result.or-raise call"
```

Tables are validated ordinary dictionaries whose string keys name equal-length
list columns. There is no hidden table runtime kind. CSV and JSON preserve
their external data models; scalar conversion is explicit through
`table.cast`.

The `io` module contains `pp`, `prin`, `print`, `inspect`, `stdin`, `slurp`,
`spit`, and `lines`; the last composes `io.slurp` with newline splitting.
Process capabilities `args`, `getenv`, and `exit` remain global. `http.get` and
`http.post` return ordinary response
dictionaries. See [`design/SPEC.md`](design/SPEC.md) for the complete grammar,
vocabulary, errors, and module contracts.

## Interactive use

Running `ecl` on a terminal starts the built-in line editor. It supports
UTF-8-scalar cursor movement, common Emacs keys, a shared 100-line history,
multiline continuation, and completion from the live environment. Tab
completion understands qualified module names such as `str.<Tab>`.

```sh
ecl
> 10
10
> dup *
10 100
```

Ctrl-C abandons the current edit or continuation. Ctrl-D deletes at a nonempty
cursor, exits at an empty primary prompt, and reports incomplete input at an
empty continuation prompt. Raw editing is supported on Linux and macOS;
non-TTY stdin remains a single noninteractive source unit.

`ecl fmt FILE` formats source without evaluating it. Use `ecl fmt -` for
standard input. Literal definitions and modules receive navigable
`### def <name>` and `### module <name>` headers.

## Source modules

A source module is an ordinary `.ecl` file that registers a canonical module
name. The filename is transport, not identity. For example, save this as
`modules/stats.ecl`:

```ecl
### module stats
(
 ### def twice
 (2 *)
 (x -- y : "Double a number.")
 'twice def)
'stats
@module
```

Place the containing directory on `ECL_PATH`. On the first unresolved
qualified reference or `use`, ecl loads `stats.ecl`, requires it to register
`stats`, and retries resolution.

```sh
ECL_PATH="$PWD/modules" ecl '21 stats.twice'
ECL_PATH="$PWD/modules" ecl "'stats use 21 twice"
```

Inside a module, `def` publishes a public word and `defp` publishes a private
word. Public bodies can resolve their definition-site privates; callers cannot
name them. Re-registering the same canonical name atomically publishes a new
code generation, healing qualified, used, and aliased access paths.

A module body may leave construction values behind. Those values initialize
the module slot's durable stack exactly once. Module-homed code accesses that
stack transactionally with `within` and transfers explicit outputs with
`without`; re-registration preserves the durable stack. `unmodule` closes new
admission and retires the slot after active operations quiesce.

`ECL_PATH` is an ordered platform path list. For each root, ecl tries
`<name>.ecl` before `<name>.eclmod`; the first existing candidate is
authoritative, including parse, validation, or initialization failure.

## Native extensions

Native extensions are optional target-specific `.eclmod` shared libraries.
They are for trusted Zig code that needs host performance or facilities not in
the source language. Core and the embedded standard library do not depend on
them.

Author against the public `ecl-native` module on Zig 0.16.0. A callback's
typed `Call` declares its exact effect. Additional typed parameters request
the narrow capabilities the adapter will expose.

```zig
const ecl = @import("ecl-native");

fn increment(call: *ecl.Call("n -- result")) ecl.CallbackResult {
    const n = call.input(0).int() orelse
        return call.fail(.type, "increment expects an integer");
    return call.complete(.{ecl.Scalar.int(n + 1)});
}

pub const Extension = ecl.module(.{
    .name = "sample",
    .doc = "Example native extension.",
    .words = .{
        ecl.word("increment", "Increment an integer.", increment),
    },
});

comptime {
    _ = Extension;
}
```

Add ecl as a package dependency and build one dynamic library whose installed
name is exactly `<module>.eclmod`. This minimal `build.zig` uses the exported
SDK module directly:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ecl_dep = b.dependency("ecl", .{
        .target = target,
        .optimize = optimize,
    });

    const root = b.createModule(.{
        .root_source_file = b.path("src/sample.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addImport("ecl-native", ecl_dep.module("ecl-native"));
    const extension = b.addLibrary(.{
        .name = "sample",
        .root_module = root,
        .linkage = .dynamic,
    });
    const install = b.addInstallFileWithDir(
        extension.getEmittedBin(),
        .{ .custom = "ecl" },
        "sample.eclmod",
    );
    b.getInstallStep().dependOn(&install.step);
}
```

Then load it from its installed directory:

```sh
zig build -Doptimize=ReleaseSafe
ECL_PATH="$PWD/zig-out/ecl" ecl '41 sample.increment'
```

The loader validates the exact ABI version and record sizes, module identity,
word uniqueness, effects, documentation, continuation layout, and declared
capabilities before publishing anything. Validation is not sandboxing:
opening a shared library executes arbitrary machine code, native side effects
are outside operand-stack rollback, and a callback that does not return cannot
be preempted. Only put trusted directories on `ECL_PATH`.

Long or aggregate native work must be cooperative. Request
`ecl.Reschedule(State)` and consume scheduler budget; request
`*ecl.BuildValues` for incremental list or dictionary construction. Candidate
handles live for one callback turn, while the host-owned builder carries
validated values across yields. `ECL_NATIVE_DIAGNOSTICS=1` enables an
after-the-fact warning for long callback slices; it does not impose a deadline
or make untrusted code safe.

The supported SDK deliberately exposes no allocator, raw operand stack,
environment, scheduler, reclamation root, external wake handle, quotation
evaluator, or durable module-state authority.

## Build and verification

The terminal release-candidate gate uses a ReleaseSafe binary:

```sh
zig build acceptance -Doptimize=ReleaseSafe
```

This is a narrow final gate: it runs the M13 release assertions and the
source-architecture audit. In CI it follows, rather than repeats, the ordinary
behavioral, PTY, snapshot, native-runtime, one/eight-worker, fuzz, focused
allocation-failure, differential, sanitizer, and lint gates.

Per-push CI runs the complete suite in Debug and in the distributed
ReleaseSafe mode. ReleaseFast, which disables safety checks and is not a
distributed configuration, compiles the real binary and runs the promoted CLI
snapshot corpus per push; its complete suite belongs to the release-candidate
matrix.

The exhaustive initialized-Session allocation-failure proof is run once for a
release candidate, while the sanitizer proof remains in per-push CI:

```sh
zig build test-oom < /dev/null
zig build test-tsan < /dev/null        # Linux/x86_64 CI environment
```

Useful focused gates include `zig build test`, `test-repl`, `test-workers`,
`test-native-runtime`, `test-native-sdk-negative`, `differential`,
`source-audit`, and `test-snapshots`. `zig build fuzz` runs all seed corpora;
the named `fuzz-*` steps start bounded coverage-guided campaigns.

Implementation architecture and proof boundaries are documented in
[`design/INTERPRETER.md`](design/INTERPRETER.md). The historical milestone and
decision record is [`design/workstream-v1.md`](design/workstream-v1.md).
