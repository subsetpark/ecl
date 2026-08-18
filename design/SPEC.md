# ecl — language specification

This document is the authority on ecl's syntax and semantics. It describes
the language as implemented, completely and only: a construct appears here
exactly when the shipped interpreter provides it. The companion
INTERPRETER.md describes how the implementation delivers these semantics;
nothing there may change an observable behavior specified here.

ecl is a homoiconic concatenative array language. Programs are postfix:
evaluation pushes values onto a stack, and words consume and produce stack
values. Code and arrays are the same substance — lists — so programs can be
built, inspected, and transformed with the same vocabulary used on data.
Values are immutable. Errors are crash-only, observed as data at explicit
boundaries. Concurrency is structured tasks over immutable values.

## Source text

- Source is UTF-8, mandatorily. Invalid UTF-8 is a `'parse` error.
- `#` begins a comment that runs to end of line, outside strings. Shebang
  lines are therefore comments.
- Tokens are separated by whitespace: Unicode whitespace, plus comma —
  `,` is whitespace, so pasted `[1, 2, 3]` reads as `[1 2 3]`.
- `;` is reserved: a parse error outside strings and comments.
- `|` is a reserved delimiter: legal only as the binder markers
  immediately after `(` or `[` (see Forms); anywhere else it is a parse
  error.
- Every reader-produced token carries provenance (source name, line,
  column), which surfaces in error dicts when known.

## Tokens

The token kinds are the six delimiters `( ) [ ] { }`, string literals, and
*atoms*: maximal runs of non-whitespace, non-delimiter, non-reserved
characters. An atom is classified whole-token, in this order:

1. **Number** — the entire token parses as a number, else it is not one
   (`2dup` and `1+` are words; `-3` is a number; `-` is a word).
   - int64: optional `+`/`-` sign, then decimal digits with optional `_`
     separators strictly between digits (`1_000_000`), or `0x` followed by
     hex digits. `_` is not permitted in hex literals. A literal outside
     the int64 range is a parse error.
   - float64: `digits . digits` with an optional exponent (`e`/`E`,
     optional sign), or `digits` followed by an exponent. Digits are
     required on both sides of `.` — `.5` and `5.` are words, not numbers.
     `_` is not permitted in float literals. A literal that overflows
     float64 is a parse error.
   - The whole tokens `inf`, `+inf`, and `-inf` are float literals (they
     are numbers, so the names leave the word namespace). NaN has no
     literal; NaN values do not exist (see Numbers).
2. **Char** — `\` followed by exactly one character (`\a`), one of the
   names `\space`, `\tab`, `\newline`, or `\u{...}` with one to six hex
   digits naming a Unicode scalar value (surrogate halves and values above
   U+10FFFF are parse errors).
3. **Quoted symbol** — `'` followed by a symbol. `'` is reserved
   token-initially and banned inside symbols.
4. **Word** — anything else: a symbol, evaluated by lookup.

**Symbols** are one or more segments joined by `.`; the dot is the module
qualification separator and nothing else (`stats.mean`, quotable as
`'stats.mean`). Leading, trailing, or doubled dots are parse errors.
Segment characters are anything except whitespace, the six delimiters,
`"`, `#`, `'`, `\`, `.`, `,`, `;`, and `|`. Unicode letters are legal.

**Strings** are `"..."` and may span newlines. Raw newlines, indentation,
and blank lines inside the quotes are literal; there is no triple-quoted,
dedented, or margin-stripped form. The escapes are exactly `\\`, `\"`,
`\n`, `\t`, and `\u{...}` (one to six hex digits, Unicode scalar values
only); any other escape is a parse error. A string is a rank-1 char
vector, not a distinct type.

The exact decimal form `<task:N>` (ASCII digits, no sign) is reserved as an
unparseable runtime display marker wherever an atom may occur. The same
bytes inside a string literal are ordinary character data.

## Forms

```
program  :=  form*
form     :=  list | dict | atom
list     :=  "(" binder? form* ")"  |  "[" binder? form* "]"
dict     :=  "{" (form form)* "}"
binder   :=  "|" name+ "|"           # names: distinct unqualified symbols
```

- `( )` and `[ ]` construct the same kind of value — a list of the
  enclosed forms, unevaluated. Brackets quote; nothing inside runs at read
  time. The pair choice is free per pair, and **pairs must match**:
  `[1 2 3)` is a parse error. (Printing chooses brackets by
  representation; see Printing.)
- `{ k v ... }` constructs one dict value at read time. Adjacent top-level
  forms are paired as key and value; neither is evaluated, so bare words
  are stored as word values — `{foo bar}` stores the word `bar` under the
  word key `foo` without resolving either name. An odd form count and a
  duplicate key are parse errors. `{}` is the empty dict. When entries
  require computation, build a flat entry list and use `dict-of`.
- The binder is the locals sugar: `(|lo hi| hi lo - rand lo +)`,
  `(|x| x x *) each`. It is legal only immediately after `(` or `[` and is
  desugared to point-free code before the list value exists — the stored
  list contains no binder and no local names. Bind order: the leftmost
  name takes the deepest value, so `10 20 (|lo hi| …)` gives `lo` = 10 and
  `hi` = 20 — names read in argument order. Names must be distinct
  unqualified symbols; the empty binder `(||)` is a parse error; the exact
  names `--` and `:` are parse errors in a binder. A local name is not
  visible inside a nested quotation within the binder body; referencing
  one there is an error whose message suggests `partial`. The sugar does
  not involve `set`; locals and environment assignment are unrelated
  mechanisms.

## Values

Every value is one of eight kinds, as reported by `type`: `'int`,
`'float`, `'char`, `'symbol`, `'word`, `'list`, `'dict`, `'task`.

All values are immutable. Mutation exists only as environment rebinding
(`def`/`set`). Performance is a documented guarantee, not a semantic:
appending to or updating a value that is not shared updates in place in
amortized constant time; a shared value is copied once, after which
updates are cheap again. No operation can observe the difference except
through timing.

- **int** — a 64-bit signed integer. Overflow is an error, never wrapping
  or promotion.
- **float** — an IEEE 754 binary64 value, excluding NaN. `inf` and `-inf`
  are ordinary values. See Numbers.
- **char** — a Unicode codepoint. A char is a distinct atom, not an
  integer.
- **symbol** — an interned name, written quoted: `'mean`, `'stats.mean`.
- **word** — a name in executable position. A bare word in code and a
  quoted symbol are distinct atoms: `(dup) first` yields the word `dup`,
  `'dup` yields the symbol, and they do not `match`. Words print bare,
  symbols print quoted.
- **list** — the one aggregate: a finite ordered sequence of values. A
  quotation, a vector, and a row of a matrix are all lists. A homogeneous
  list of atoms *is* a vector — `(1 2 3)` and `[1 2 3]` are the same
  value. There is no rank-carrying array type: a matrix is a list of
  equal-length lists, and rank is depth, not an intrinsic property.
  Ragged data (a list of lists of unequal length) is legal. A string is a
  list of chars. Homogeneous lists are stored specialized (flat typed
  buffers); specialization is representation, never semantics, and is
  observable only through printing.
- **dict** — an insertion-ordered map. Any value is a legal key
  (immutability makes every value hashable); symbols are the idiom. Key
  identity is whole-value `match` identity. Insertion order is preserved
  by storage, iteration, and printing, but ignored by equality: two dicts
  with the same key–value pairs in different orders are equal.
- **task** — a handle to a concurrent unit of work (see Concurrency).
  Tasks are runtime capabilities bound to their session: `match` and
  hashing use handle identity, and a task prints as `<task:N>`, which the
  reader rejects. A task value cannot be forged from text.

### Equality and ordering

- `=` is pervasive equality: it descends structure to atoms and produces
  0/1 masks (see Pervasion).
- `match` is whole-value structural equality: `[1 2] [1 2] =` is `[1 1]`;
  `[1 2] [1 2] match` is `1`.
- Numbers compare numerically everywhere, across int and float: `2` and
  `2.0` are equal under `=`, `match`, and `cmp`, are the same dict key,
  and `0.0` equals `-0.0`. Mixed int/float comparison is exact; no
  rounding occurs through 2^53.
- `cmp` is a three-way total ordering (−1/0/1) on numbers, chars (by
  codepoint), and strings (codepoint-lexicographic). Anything else,
  including cross-kind pairs, is a `'type` error. `grade` orders by
  exactly this ordering.
- Booleans are the ints 0 and 1. Words that require a boolean reject
  every other value, including other ints.

## Evaluation

Evaluation walks a list of forms left to right:

- A literal (number, char, string, quoted symbol, list, dict) pushes
  itself.
- A word resolves in the current environment and applies, running its
  stored body. There is one kind of binding; reference always applies.

Applying a quotation evaluates its forms on some stack; a quotation
containing only data therefore pushes its elements. All binding is late:
an unqualified reference resolves when it executes, so words observe
re-`def`s and re-`set`s of their dependencies immediately. There are no
closures: a quotation is a plain inspectable list that captures nothing.

Tail calls are guaranteed: through word calls, `if`, and every
combinator's tail position, iteration and tail recursion run in constant
space and never exhaust a host call stack.

### Units and the transactional stack

The *unit* is the granularity of failure. A unit that fails dies whole:
its stack is rolled back to its entry state, so a failed unit leaves
nothing on the stack — no partial results, no torn state. The guarantee is
stack-only: environment writes and IO performed before the failure
survive. Units are delimited by the reader:

- **REPL**: one logical line is one unit. The reader continues the line
  (continuation prompt) while a delimiter or string is open, so a unit is
  the complete forms of one possibly-continued line.
- **Script file, `-e`, stdin**: the whole source is a single unit. A
  failing script dies whole — error dict to stderr, nonzero exit.
- **`load`**: the loaded file is one unit inside the calling session and
  fails atomically.
- **`attempt` and `spawn`**: each runs its quotation as a new unit on an
  isolated substack (see Errors, Concurrency).

A dying unit also cancels its unawaited tasks (see Concurrency).

### Application contexts

Two kinds of quotation application exist:

- **Inline**: the quotation runs on the current stack. The inline words
  are `call`, `dip`, `keep`, `bi`, `tri`, `bi2`, `both`, `if`, `when`,
  `unless`, `cond`, `case`, `while`, and `times`.
- **Isolated**: the quotation runs on a fresh substack per application,
  seeded with its declared inputs, and its result count is checked
  against the contract. The isolated words are `each`, `zip-with`, `for`,
  `fold`, `scan`, `infra`, `attempt`, `spawn`, `par-each`, and `module`.

Every isolated combinator states the stack effect it requires of its
quotation argument (given per word in the reference). The contract is
checked dynamically at each application; a violation is an immediate
`'contract` error naming the element and the observed effect.

Quotations given to `attempt` and `spawn` must be self-contained: their
effect is `( -- ... )`, inputs arrive via `literal`/`partial`/`compose`
or environment names, never the ambient stack.

### Bindings

One namespace, one kind of binding: a name binds a body, and reference
always applies it. Values are bound by capturing them in a body.

- `(body) 'name def` binds a word: reference applies the body. The body
  must be a list (a non-list is an error directing to `set`); a list of
  plain data is legal and yields a multi-value constant word.
- `value 'name set` binds a constant. It is sugar, defined in ecl as
  `swap literal swap (-- value) swap def`: the value is captured with
  `literal`, so the published body is `((value) first)` and the
  synthesized effect is `( -- value )`. Reference applies that body and
  pushes exactly the captured value, quotations included — the capture is
  inert, so nothing in it executes or resolves. `v 'name set` is therefore
  observationally `v literal (-- value) 'name def` — the annotation is part
  of the equivalence, not incidental: it is what `which` and `see` report,
  and what satisfies the mandatory module effect. `set` is environment
  assignment, not a lexical binding form. For ordinary local values, prefer
  stack flow or binder locals.
- Redefinition (`def` or `set` over an existing name) replaces the
  complete binding snapshot: omitting an effect or docstring clears the
  old one. Code holding the old body keeps running it safely.
- `defp`/`setp` are the private forms, legal only inside a module body
  (see Modules); at top level they are errors.
- Because `set`/`setp` are sugar, their failures are raised by the words
  they call: an underflowing `set` is `'underflow` from `swap`, and a
  non-symbol or reserved name is raised by `def`/`defp`. The error kind is
  unchanged; the trace names `set`/`setp` as the parent.

### Definition annotations

A definition may place one annotation quotation between the body and the
quoted name:

```
(body) 'name def
(body) (before -- after) 'name def
(body) (: "Documentation.") 'name def
(body) (before -- after : "Documentation.") 'name def
```

The annotation is ordinary quotation data — no special grammar — and is
recognized only when it contains a top-level word `--` or `:`. Nested
markers and the quoted symbols `'--`/`':` are inert. A recognized
annotation is validated as a whole before the binding publishes: at most
one marker of each kind, `--` before `:`, only words around `--`, and
exactly one string after `:`. A malformed recognized annotation is a
`'domain` error, never reinterpreted as a body; an annotation with no body
beneath it is `'underflow`. `set`/`setp` capture their value with
`literal` before `def`/`defp` sees it, so the value sits nested one list
deep inside the capture body, where markers are inert: a constant holding
bare marker words is never reinterpreted as an annotation.

Module `def`/`defp` require the effect portion; a documentation-only
annotation is a registration error there. Top-level `def` accepts no
annotation, either portion, or both. A top-level effect is reflective
metadata only; a module word's declared effect is a live contract, checked
dynamically against the observed effect when application crosses a module
boundary (violation: `'contract`).

Documentation has canonical form. Publication trims source-only
indentation, folds physical line breaks within prose to spaces, collapses
a paragraph boundary to one blank line, and preserves each Markdown `- `
item on its own logical line with its continuations folded in. `doc`
returns this canonical string, so source formatting cannot change
reflective documentation. Strings anywhere else retain their exact decoded
codepoints.

The exact names `--` and `:` are reserved against binding: they remain
legal word and symbol values and can be built into annotations at runtime,
but cannot be introduced as definitions, values, locals, module names,
aliases, exports, or native entries. Binding attempts are `'domain`;
binder use is a parse error. Longer names containing the same punctuation
remain legal.

### Metaprogramming

There is no macro system. Runtime quotation construction — `literal`,
`compose`, `cons`, and the list words — plus `def` is the metaprogramming
system: `'word body` fetches a word's list, list surgery builds a new one,
`def` rebinds. `parse` turns source text into a quotation. Parse-time
transforms are capped at the binder desugaring and the literal readers.

## Pervasion and conformability

Scalar arithmetic and comparison words are *pervasive*: they recurse
through nesting to atoms, ragged lists included, by leading-axis pairwise
descent:

- An atom extends to every element of a list: `10 [1 2 3] +` is
  `[11 12 13]`.
- Two lists pair elementwise at each level and recurse; a top-level length
  mismatch is a `'conform` error.
- Dicts pervade over their values, preserving keys. A dict with a dict
  aligns by key: matching keys combine, unmatched keys pass through
  unchanged (union with identity fill).
- Symbols and words are not numeric: pervading into a quotation errors at
  the first symbol or word leaf.
- Chars participate ordinally: `char int +` is a char, `char char -` is an
  int, `char char +` is an error; comparison is by codepoint.

There is a unified-value dividend: an all-numeric quotation *is* a vector,
so `(1 2 3) 10 *` is simply `[10 20 30]`.

## Numbers

- Arithmetic on int64 that overflows is an `'overflow` error — no
  wrapping, no promotion to float or bignum. Scalar and array arithmetic
  behave identically.
- `/` is float division. `div` is checked integer division. Division by
  zero is `'domain`.
- `inf` and `-inf` are values and propagate through arithmetic IEEE-style
  when an *operand* is non-finite. Producing a non-finite result from
  finite inputs is `'overflow` (e.g. `0 log`, float overflow). Any
  operation whose IEEE result would be NaN is `'domain` (e.g. `-1 log`,
  `inf -inf +`). NaN therefore never exists.
- `floor`, `ceil`, and `round` return int64 (`'overflow` when the result
  exceeds the range): their results are indices and mask material, and
  int-ness keeps integer pipelines integer. `pow` returns float.
- `str` output for numbers round-trips (see Printing); float equality is
  numeric everywhere (see Equality).

## Chars and strings

A string is a rank-1 char vector; there is no separate string type. `len`,
`at`, `reverse`, `each`, and every other list word operate on codepoints.
UTF-8 exists only at IO boundaries: source files and `prin`/`pp` encode
and decode UTF-8, and invalid UTF-8 on input is an error. Char semantics
are codepoint semantics, stated honestly: grapheme segmentation,
normalization, non-ASCII case mapping, and locale collation are not
provided, so composed and decomposed `"café"` have lengths 4 and 5.
Symbols are interned at parse; strings are plain uninterned vectors.

## Modules

A module is a named, registered value — not a file. A per-session registry
maps symbols to modules; files are transport.

- `'name (body) module` runs the body on a fresh environment and registers
  the result under the name. The body's contract is `( -- )` and it runs
  stack-isolated: registration produces no stack values. Modules are
  first-class: enumerable, diffable, constructible by building the body
  quotation programmatically.
- `values 'name (body) module-with` captures every value inertly and in order
  before running the same isolated module-registration operation. The values
  form the body unit's initial stack and the body must consume them.
- Registration commits only after the body succeeds. A failed
  re-registration leaves the previous registration in place.
- The registry is flat. A module body may register another module, but that
  registration creates an independent module with its own unqualified name
  and lifetime; it does not establish lexical nesting or parent ownership.
  Registrations commit independently, so a completed inner registration is
  not rolled back if the registering module's body later fails.
- **Privacy is set at the definition site**: inside a module body, `def`
  and `set` bind public (exported); `defp` and `setp` bind private. Every
  module binding is a word carrying a declared effect; module constants
  satisfy the mandatory-effect rule automatically, because `set`/`setp`
  always supply `( -- value )`. Privacy is subtractive — privates are
  absent from the module's public face, not access-checked. Definitions
  made inside the module body's isolated child units (e.g. inside an
  `attempt`) are dynamic and are never exported.
- **Resolution context is a property of the binding**: an exported word
  carries its home module's name, and its body resolves against that
  module's chain — internal environment, then the module's own `use`s,
  then core — never the caller's environment. Publics therefore reach
  privates, and callers cannot perturb a module's behavior by shadowing.
  A module word's body is still a plain list: `'stats.stdev body` is data,
  and re-`def`ing that list elsewhere loses the private context.
- Re-registering a module heals all callers immediately: module words
  resolve through the registry, and each application pins one registry
  generation for the whole body — no mixed-generation execution.
- **Surface**: `use` splices a module's exports into scope. Session
  definitions shadow used exports; a later `use` shadows an earlier one;
  re-`use`ing a module moves it to the top of the shadow order; `use` is
  idempotent. Each session binding that shadows an incoming export is
  reported on stderr ("session `mean` shadows `stats.mean`") —
  informational only; shadowing is the documented way to locally patch a
  module word. Dotted symbols (`stats.mean`) give qualified access with no
  import. `alias` registers a short registry name; aliases and module
  names may not collide in either direction. `which` shows any name's
  resolution.
- **Loading**: `'stats use` on an unregistered name searches each
  `ECL_PATH` entry in order, trying `stats.ecl` and then `stats.eclmod`;
  the first existing candidate is authoritative, including its errors. A
  loaded `.ecl` file registers a module as an ordinary side effect of
  running; `load` replays any file as one unit in the calling session.

### Native modules

A `<name>.eclmod` is a precompiled native module: one artifact is one
module, whose complete word table validates and publishes atomically — an
artifact cannot partially register. Its canonical name must equal the
requested name. Native words are ordinary module words: they carry a
mandatory effect and nonempty documentation, participate in `use`, dotted
access, `doc`, `which`, and `see` (which display the native origin), and
their calls are transactional — a failing native call leaves the stack
unchanged. A native word can raise only the kinds `'type`, `'shape`,
`'conform`, `'overflow`, `'domain`, `'parse`, `'io`, or `'user`; the
runtime alone raises the rest. Native modules are neither reloaded nor
unloaded within a session.

Opening a shared library executes arbitrary machine code before ecl can
inspect it, so every directory on an `ECL_PATH` used for native loading is
a trusted-code boundary.

## Errors

Errors are crash-only. There is no try/catch and no handler quotation: an
error propagates until the enclosing unit dies, and the transactional
stack makes that death clean. Failure is observed from outside, as data,
at one explicit boundary word: `attempt` (and its concurrent form,
`spawn`/`await`). The REPL is the implicit top-level boundary; a script's
boundary is the process.

Every error is a dict:

| key | value |
|---|---|
| `'kind` | symbol — the dispatch taxonomy |
| `'msg` | string, preformatted |
| `'word` | qualified symbol of the innermost raising word, when known |
| `'trace` | list of qualified word symbols, innermost first — ecl-level only |
| `'data` | kind-specific payload dict (e.g. expected/got shapes, required vs observed effect and element index) |

Source position fields appear when known. Absence is absence: fields not
known are not present (test with `has?`), never nil — there is no nil.
Code assembled at runtime has no source position by construction. No host
exception or host stack frame ever leaks into an error.

The core kinds are a closed set: `'underflow`, `'undefined-word`, `'type`,
`'shape`, `'conform`, `'overflow`, `'domain`, `'contract`, `'parse`,
`'io`, `'cancelled`, `'timeout`, `'user`. User kinds are any other symbol.
`raise` throws a dict; `fail` is sugar for raising
`{'kind 'user 'msg msg}`.

`(q) attempt` runs a self-contained quotation as a new unit on an isolated
substack and always pushes exactly one result value: `{'ok (values)}`
or `{'err <error dict>}`. Uniform arity is what makes reified failure safe
in a stack language: a failure never shares a stack with the code
observing it. Handling is ordinary dict handling — `ok?`, `or-raise`,
`or-else`. Errors are plain immutable data and cross task boundaries
unchanged.

## Concurrency

Concurrency is structured tasks — futures with enforced lifetime — over
share-nothing units. Immutability makes sharing safe without copying.

- `spawn` `( q -- task )` runs a self-contained quotation (the `attempt`
  contract: inputs via `partial`/environment, never the ambient stack) on
  its own isolated substack, concurrently.
- `await` `( task -- result )` parks the current unit until the task
  completes and delivers the same `{'ok …}`/`{'err …}` result shape as
  `attempt`. It is idempotent — the result is cached — so task handles
  are observationally value-like. **`attempt` is observationally
  equivalent to `spawn await`.**
- `await-for` adds a deadline in milliseconds: on expiry it returns
  `{'err {'kind 'timeout}}` without cancelling the task. A task that is
  already terminal beats even a zero deadline.
- `await-any` races a nonempty list of tasks, returning the index and
  result of the first to finish; among tasks already terminal at entry,
  the lowest index wins.
- `cancel` makes a task die with `{'err {'kind 'cancelled}}`; it is a
  no-op on a finished task. Cancellation is unconditional and safe because
  tasks are transactions: killing one discards an isolated substack.
- `await-all` (defined as `(await) each`) waits for every task and
  preserves each result as data, in input order; it never re-raises and
  never cancels siblings.
- `par-each` `( l q -- l' )` applies the quotation to every element
  concurrently, enforcing exactly one result per element, and returns
  results in input order. After the leftmost failure it cancels the
  remaining elements, waits for quiescence, and re-raises that failure —
  parallel failure is deterministic. Elements are guaranteed no
  cross-element rendezvous: they may run fully serially, so a program
  whose elements must run concurrently to make progress is incorrect.

**Structured lifetime.** A dying unit cancels its unawaited tasks — "a
failed unit leaves nothing" extends to processes. Dropped handles are
cancelled at scope end; there are no detached daemons. The session is the
root scope. `tasks` lists pending descendant tasks in spawn preorder.

**Determinism.** Await order is program order, so `await-all` results and
`par-each`'s leftmost-error rule are schedule-invariant. Nondeterminism
enters only where chosen (`await-any`) and in IO interleaving across
concurrent tasks; within one task IO is ordered. Sequential combinators
(`each`, `for`, `fold`) guarantee left-to-right order, so IO inside them
is well-defined.

**Process exit.** `exit` belongs to the root unit outside `attempt`: a
call from a descendant task or inside `attempt` raises a catchable
`'domain` error. An allowed exit first cancels and quiesces the root task
scope, then terminates the process with the given status.

## Printing and round-trip

Printing exposes representation. A list prints with `[...]` when
specialized — a homogeneous flat vector, or rectangular nesting of
specialized lists — and `(...)` when generic; both are the same kind of
value, and either bracket pair is accepted on input. So `(1 2 3)` prints
as `[1 2 3]`, and the ragged result of `[[1 2] [3]] 10 *` prints as
`([10 20] [30])`. Specialization is visible at the prompt, not mysterious.

- `str` produces the compact single-line canonical form and carries the
  round-trip guarantee: reading `str` output yields the same value, with
  one exception — a task prints as its stable per-session `<task:N>`
  marker, which the reader deliberately rejects.
- `pp` and the REPL stack display are best-effort human layout: the same
  delimiters and atom spellings, with the rows of rectangular matrices
  (and one enclosing group axis) separated by newline-plus-indentation.
  Their output carries no round-trip guarantee — huge leaves may be
  elided so that displaying a large value cannot flood the terminal.
  Only `str` is canonical.
- The stack display keeps stack order left to right whatever a value's
  height. Each value occupies the rectangle its own layout needs, and the
  rectangles sit side by side sharing a bottom row, so a matrix grows the
  display upward instead of stacking its neighbours vertically. Padding is
  counted in bytes, matching the column arithmetic of the row breaks above,
  and no row is padded past its last value. The display is not wrapped to
  the terminal: width is a measured fact the display has no access to.
- Dicts print as `{key value ...}` in insertion order.

Printing at unit end: script files and `load` print only explicitly
(`pp`/`prin`); `-e`, stdin, and calculator invocations print the final
stack; the REPL prints the stack after every unit.

## The ecl command

```
ecl                      REPL on a terminal; otherwise read stdin as one unit
ecl -e <SOURCE> [ARGS…]  evaluate source, print the final stack
ecl <FILE> [ARGS…]       run a script file
ecl <SOURCE> [ARGS…]     evaluate source when the argument is not a readable
                         file (a missing file ending in .ecl is an error
                         instead), print the final stack
ecl - [ARGS…]            read stdin as one unit
ecl fmt <FILE|->         format source to stdout
ecl -h | --help          usage
ecl -V | --version       version
```

Trailing arguments are exposed to the program by `args`. Exit status: `0`
on success; the status passed to `exit`; `1` when the unit fails (the
error dict is printed to stderr); `2` on out-of-memory.

Environment variables: `ECL_PATH` is the module search path (see Modules).
`ECL_WORKERS` sets the worker count (a positive integer; default is the
CPU count). `ECL_NATIVE_DIAGNOSTICS`, when set, enables native-module
loading diagnostics.

The REPL reads one unit per logical line, continuing while a delimiter or
string is open. Ctrl-C discards the pending unit; Ctrl-D at an empty
prompt exits (and mid-continuation submits the pending unit, whose
incompleteness is then an error). Completion is available. History is kept
in `~/.ecl_history` — the last 100 single-line, valid-UTF-8 entries,
merged across concurrent sessions; history failures degrade to a warning,
never disable the editor.

## Source formatting

`ecl fmt` reads valid source without evaluating it and writes canonical
source. Formatting is idempotent, preserves program structure and every
ordinary literal value byte-for-byte, and never applies layout rules based
on a form's first word. Specifics:

- Space-separated items pack into locally grouped runs up to 100 columns;
  continuation lines begin immediately inside the opening delimiter.
  Existing physical newlines remain hard boundaries. A comment or
  multiline child breaks only its local run. An indivisible token or
  preserved comment may exceed the target width.
- Comments are preserved and force physical line boundaries while staying
  attached to their neighboring forms.
- Strings are indivisible and byte-preserved, with one exception: the
  docstring of a structurally recognized definition annotation immediately
  followed by `'name def`/`defp` is refilled paragraph-aware (semantics
  unchanged — `doc` canonicalization already ignores soft wrapping).
- Every literal definition block is introduced by a `### def <name>`
  navigation comment, preceded by exactly one empty line (omitted at the
  start of a file or container). Existing `# def`/`### def` comments are
  canonicalized; recognition is purely structural — never evaluation — and
  is disabled for words directly contained by dict literals.

---

# Word reference

Every binding below ships in the core image, one entry per word, ordered
by codepoint — the language's own string ordering (`cmp`) — so
symbol-spelled words precede letter-spelled ones. An entry gives the
word's stack effect as declared in the implementation — `doc` and `see`
return the same effect and documentation — followed by its semantics.
Conventions:

- Words marked **pervasive** follow the Pervasion section.
- "Equivalent to `…`" names a word defined in ecl itself; the definition
  is normative and `body` returns it.
- Words applying quotations are marked *inline* or *isolated* (see
  Application contexts); isolated combinators state the contract required
  of their quotation, enforced at each application.
- Effects containing `…` are informal pictures: those words have no fixed
  declared effect.
- Indexing is 0-based throughout: `range` counts from 0, `at` indexes
  from 0, `where` and `grade` produce 0-based indices, and `find` returns
  the length on a miss.
- Booleans are the ints 0 and 1; a word requiring a boolean rejects every
  other value.

### *
`( x y -- z )` — **Pervasive.** Multiply. Integer overflow is
`'overflow`.

### +
`( x y -- z )` — **Pervasive.** Add. Acts ordinally on chars:
`char int +` (either order) is a char; `char char +` is `'type`. Integer
overflow is `'overflow`.

### -
`( x y -- z )` — **Pervasive.** Subtract. Acts ordinally on chars:
`char char -` is an int, `char int -` is a char, `int char -` is `'type`.
Integer overflow is `'overflow`.

### /
`( x y -- z )` — **Pervasive.** Float division. Division by zero is
`'domain`.

### <
`( x y -- bool )` — **Pervasive.** Ascending comparison, producing 0/1
masks.

### <=
`( x y -- bool )` — **Pervasive.** Less-than-or-equal. Equivalent to
`> not`.

### <>
`( x y -- bool )` — **Pervasive.** Inequality. Equivalent to `= not`. (On
0/1 masks this is xor; there is no separate word.)

### =
`( x y -- bool )` — **Pervasive.** Equality; numbers compare numerically
across int and float. Whole-value equality is `match`.

### >
`( x y -- bool )` — **Pervasive.** Descending comparison, producing 0/1
masks.

### >=
`( x y -- bool )` — **Pervasive.** Greater-than-or-equal. Equivalent to
`< not`.

### abs
`( x -- y )` — **Pervasive.** Absolute value. Defined in ecl (see
`'abs body`).

### alias
`( 'short 'name -- )` — Register a short registry name for a module.
Aliases and module names may not collide in either direction.

### all?
`( sequence predicate -- bool )` — *Isolated*, contract `( a -- bool )`.
1 when the predicate returns 1 for every element. Equivalent to
`(|l q| l q each 1 (and) fold)`.

### and
`( x y -- bool )` — **Pervasive.** Boolean conjunction on 0/1 values.
Both operands are already evaluated — there is no short-circuiting.
Defined in ecl.

### any?
`( sequence predicate -- bool )` — *Isolated*, contract `( a -- bool )`.
1 when the predicate returns 1 for at least one element; the predicate
runs on every element (no early exit). Equivalent to
`(|l q| l q each 0 (or) fold)`.

### append
`( sequence value -- sequence )` — Append one value to the end.
Equivalent to `wrap cat`.

### args
`( -- arguments )` — The process arguments following the script or
source, as a list of strings.

### at
`( collection key -- value )` — Index a list or look up a dict key.
Pervades over list indices, so an index vector selects:
`[10 20 30] [2 0] at` is `[30 10]`. A missing dict key is an error.

### at-or
`( collection key default -- value )` — The value at a key or index, or
the default when lookup would fail. Defined in ecl.

### at-path
`( ds l -- x )` — Repeatedly index nested lists/dicts by each key or
index in the path, left to right; an empty path returns `ds` unchanged.
Equivalent to `swap (at) fold`.

### atan2
`( y x -- z )` — **Pervasive.** Two-argument arctangent; returns float.

### attempt
`( quotation -- result )` — *Isolated.* Run a self-contained quotation
(contract `( -- … )`; inputs via `literal`/`partial`/environment) as a
new unit on an isolated substack. Always pushes exactly one result:
`{'ok (values)}` with the successful stack values as a list, or
`{'err <error dict>}`.
Observationally equivalent to `spawn await`. See Errors.

### attempt-with
`( values quotation -- result )` — Construct a self-contained quotation
by capturing every element of the values list inertly and in order, then
`attempt` it. The values therefore form the attempted unit's initial stack;
the quotation cannot reach the caller's ambient stack. Defined in ecl as
`with attempt`. Observationally equivalent to `spawn-with await`.

### await
`( task -- result )` — Park until the task completes; return its cached
`{'ok …}`/`{'err …}` result. Idempotent. See Concurrency.

### await-all
`( tasks -- results )` — Result of every task, in input order; never
re-raises and never cancels siblings. Equivalent to `(await) each`.

### await-any
`( tasks -- index result )` — Race a nonempty all-task list; among tasks
already terminal at entry the lowest index wins, otherwise the first
completion.

### await-for
`( task milliseconds -- result )` — `await` with a nonnegative int
deadline; expiry returns `{'err {'kind 'timeout}}` without cancelling the
task. A terminal task beats even a zero deadline.

### bi
`( x p q -- … )` — *Inline.* Apply two quotations to the same input,
first `p`, then `q`. Equivalent to `(keep) dip call`.

### bi2
`( x y p q -- … )` — *Inline.* Binary cleave: apply each of two
quotations to the same pair of inputs. Equivalent to
`(|x y p q| x y p call x y q call)`.

### body
`( 'name -- quotation )` — Return the stored body of a resolved word, as
a plain list. Total over everything defined in ecl, constants included: a
name bound by `set` returns its capture body `((value) first)`. Host
builtins and native words have no ecl body and are `'type`.

### both
`( x y q -- … )` — *Inline.* Apply one quotation independently to two
values, `x` first. Equivalent to `(|x y q| x q call y q call)`.

### call
`( q -- … )` — *Inline.* Run a quotation on the current stack. A data
list pushes its elements.

### cancel
`( task -- )` — Request cancellation; the task's result becomes
`{'err {'kind 'cancelled …}}`. No-op when already terminal.

### case
`( x clauses -- … )` — *Inline.* The clause list is flat, nonempty, and
odd: `[key action … else]`. Keys are inert data — any value, never
executed, duplicates legal with the first `match` winning; every action
and the else must be a quotation, validated before any comparison. The
first key that `match`es the subject selects its action. Defined in ecl
(see `'case body`).

### cat
`( left right -- list )` — Concatenate two lists.

### ceil
`( x -- integer )` — **Pervasive.** Round up; the result is int64,
`'overflow` outside its range.

### clamp
`( value lower upper -- bounded )` — **Pervasive** by composition.
Constrain to the inclusive interval. Equivalent to `(max) dip min`.

### cmp
`( left right -- ordering )` — Three-way whole-value ordering, −1/0/1;
**not** pervasive — `cmp` is to `<` what `match` is to `=`. Domain:
numbers (exact across int/float), chars by codepoint, strings
codepoint-lexicographic; anything else, including cross-kind pairs, is
`'type`. `cmp` exists because the subtraction idiom is unsafe for
ordering: `-` errors on int64 overflow where an ordering must be total.

### compose
`( left right -- quotation )` — Concatenate two quotations in execution
order.

### cond
`( clauses -- … )` — *Inline.* The clause list is flat, nonempty, and
odd: `[test action … else]`, all quotations. The whole list is validated
before the first test runs (empty or even lists are `'shape`; a non-list
or non-quotation member is `'type`). The first test leaving 1 selects its
action; otherwise the final else runs.

### cons
`( value list -- list )` — Raw structural prepend. On data,
`1 [2 3] cons` is `[1 2 3]`. On code it inserts a form: a prepended word
executes when the result is called, so `cons` is not safe partial
application — that is `partial`.

### cos
`( x -- y )` — **Pervasive.** Cosine; float transcendental.

### def
`( body annotation? 'name -- )` — Bind a quotation to a public word, with
optional effect and documentation metadata. See Definition annotations
for the annotation forms and validation; see Modules for module-context
requirements.

### defp
`( body annotation 'name -- )` — Bind a private module word; the
annotation's effect portion is mandatory. A top-level `defp` is an error.

### del
`( dict key -- dict )` — Functionally remove a key.

### dict-of
`( entries -- dict )` — Build a dict from one flat, even-length list by
pairing adjacent entries; executes nothing. The runtime counterpart of
the `{…}` literal: `'total 3 4 + pair dict-of` is `{'total 7}`. Duplicate
keys error.

### dip
`( x q -- … x )` — *Inline.* Run a quotation beneath a protected top
value: `q` runs with `x` removed, then `x` returns. Equivalent to
`swap literal compose call`.

### distinct
`( list -- list )` — First occurrence of each distinct value, in input
order. Equivalent to `group keys`.

### div
`( x y -- z )` — **Pervasive.** Checked integer division. Division by
zero is `'domain`.

### doc
`( 'name -- string )` — Return the canonical documentation string of a
resolved binding. Missing documentation is `'domain`.

### drop
`( list count -- list )` — Remove `count` elements from the front, or
from the end when negative. (The stack word is `pop`.)

### dup
`( x -- x x )` — Duplicate the top stack value.

### each
`( list quotation -- list )` — *Isolated*, contract `( a -- b )`. Apply
one level down the leading axis, exactly one result per element; the
result specializes when rectangular. Depth composes by nesting:
`((q) each) each`. There is no collect-all map whose output length
follows dynamic stack behavior: filtering is the mask idiom (or
`filter`), and flat-map is `each raze`. Derived verbs come free from
homoiconicity: `((1 +) each) 'inc-all def`.

### empty?
`( sequence -- bool )` — 1 when the sequence has no elements. Equivalent
to `len 0 =`.

### exit
`( status -- )` — Root-only outside `attempt` (`'domain` otherwise):
cancel and quiesce all descendants, then terminate the process with the
given status.

### exp
`( x -- y )` — **Pervasive.** Natural exponential; float transcendental.

### fail
`( msg -- )` — Raise `{'kind 'user 'msg msg}`. Defined in ecl.

### filter
`( sequence predicate -- matches )` — *Isolated*, contract
`( a -- count )`. Apply the predicate to every element; retain each
element as many times as its returned nonnegative int. A 0/1 predicate is
ordinary filtering. Equivalent to `over swap each where at`.

### find
`( sequence needle -- index )` — Index of the first element that
`match`es the needle, or the sequence length on a miss. Defined in ecl.

### first
`( list -- value )` — First element of a nonempty list.

### flip
`( list -- list )` — Transpose; requires an exact rectangular
list-of-lists.

### floor
`( x -- integer )` — **Pervasive.** Round down; the result is int64,
`'overflow` outside its range.

### fold
`( list accumulator quotation -- accumulator )` — *Isolated*, contract
`( acc a -- acc )`. Reduce left-to-right from the supplied accumulator.

### for
`( list quotation -- )` — *Isolated*, contract `( a -- )`. The ordered
effect loop: left-to-right, collects nothing.

### format
`( values template -- string )` — Interpolate a list of values into the
template's `{}` positional placeholders, each filled with the value's
`str`; `{{` and `}}` are literal braces. `[3.14 2] "pi={} n={}" format`
is `"pi=3.14 n=2"`.

### grade
`( list -- indices )` — The stable ascending sort permutation. Orders by
`cmp`, so every element pair must be mutually comparable.

### group
`( list -- dict )` — Dict from each distinct value to the list of its
0-based indices, keyed in first-occurrence order.

### has?
`( dict key -- bool )` — Whole-value key membership. Keys are inert and
only absence is false: lookup machinery failures are errors, never
converted to 0.

### if
`( bool then else -- … )` — *Inline.* Run `then` when the condition is 1,
`else` when it is 0; any other condition value is `'type`.

### in
`( value list -- bool )` — Membership. Pervades over the sought value —
the left operand, never the list — down to its atoms; each atom is then
tested by whole-value `match` against the list's top-level elements, so
the result takes the sought value's shape: `[2 5] [1 2 3] in` is
`[1 0]`. The list is only ever read one level deep, and a list operand
is decomposed before any comparison, so `in` cannot ask whether a
sublist is an element: `[1 1] [[0 0] [1 1]] in` is `[0 0]`, two atom
searches, not a `0` answer about `[1 1]`. Use `([1 1] match) any?` for
that.

### infra
`( list quotation -- list )` — *Isolated*, contract unconstrained. Run
the quotation with the list's elements as the entire substack; the
substack that remains is the result list.

### inspect
`( value -- value )` — `pp` while leaving the value on the stack — the
pipeline probe. Equivalent to `dup pp`.

### join
`( strings separator -- string )` — Join a list of strings with a
separator string.

### keep
`( x q -- … x )` — *Inline.* Apply a quotation to a value, then restore
the value on top of the quotation's results. Equivalent to
`over (call) dip`.

### keys
`( dict -- keys )` — Keys in insertion order.

### last
`( sequence -- value )` — Final element of a nonempty sequence.
Equivalent to `dup len 1 - at`.

### len
`( list -- count )` — Top-level element count; works on any list,
including ragged data.

### literal
`( value -- quotation )` — Return the plain quotation `((x) first)`:
calling it pushes the exact captured value as inert data, without
executing or resolving it. Equivalent to `wrap (first) cons`.

### load
`( path -- )` — Read and evaluate a source file as one transactional unit
in the calling session.

### log
`( x -- y )` — **Pervasive.** Natural logarithm; float transcendental.
Edges follow the Numbers rules: `0 log` is `'overflow` (non-finite from
finite), `-1 log` is `'domain` (NaN).

### match
`( left right -- bool )` — Whole-value structural equality; **not**
pervasive. `[1 2] [1 2] =` is `[1 1]`; `[1 2] [1 2] match` is `1`.

### max
`( x y -- z )` — **Pervasive.** The greater of two comparable atoms.

### max-of
`( sequence -- value )` — Greatest element of a nonempty sequence.
Equivalent to `dup first (max) fold`.

### mean
`( sequence -- mean )` — Arithmetic mean of a nonempty numeric sequence.
Equivalent to `dup sum swap len /`.

### merge
`( left right -- dict )` — Merge two dicts; right-hand values win.
(Key-aligned arithmetic is the pervasive `+` on dicts.)

### min
`( x y -- z )` — **Pervasive.** The lesser of two comparable atoms.

### min-of
`( sequence -- value )` — Least element of a nonempty sequence.
Equivalent to `dup first (min) fold`.

### mod
`( x y -- z )` — **Pervasive.** Checked integer remainder. Equivalent to
`over over div * -`.

### module
`( 'name body -- )` — *Isolated.* Run the body (contract `( -- )`) on a
fresh environment and register the result as a module. See Modules.

### module-with
`( values 'name body -- )` — Capture every element of the values list inertly
and in order as the isolated module body's initial stack, then register the
module. The body must consume the supplied values and finish with an empty
stack. Defined in ecl as `swap (with) dip swap module`.

### neg
`( x -- y )` — **Pervasive.** Negation. Equivalent to `-1 *`.

### nip
`( x y -- y )` — Discard the value beneath the top. Equivalent to
`swap pop`.

### not
`( bool -- bool )` — **Pervasive.** Invert 0/1 values.

### ok?
`( result -- bool )` — 1 when a result is a success. Equivalent to
`'ok has?`.

### or
`( x y -- bool )` — **Pervasive.** Boolean disjunction on 0/1 values.
Both operands are already evaluated — there is no short-circuiting.
Defined in ecl.

### or-else
`( result fallback -- value )` — The success values list, or the
fallback on failure. Defined in ecl.

### or-raise
`( result -- values )` — The values list of a success, or re-raise the
captured error unchanged. (`or-raise call` unpacks the values onto the
stack.) Defined in ecl.

### over
`( x y -- x y x )` — Copy the value beneath the top onto the top.
Equivalent to `swap dup (swap) dip`.

### pack
`( x₁ … xₙ n -- list )` — Collect the top `n` values into a list,
preserving their order; `n` must be a nonnegative int. Equivalent to
`() swap (cons) times`. Deliberately state-dependent stack surgery.

### pair
`( first second -- list )` — Two-element list in stack order. Equivalent
to `() cons cons`.

### pairs
`( dict -- pairs )` — Entries as `[key value]` pairs in dict order — the
dict-iteration form (`pairs (…) each`). Equivalent to
`dup keys swap vals zip`; the inverse round-trip is
`dup keys swap vals to-dict`.

### par-each
`( sequence quotation -- results )` — *Isolated*, contract `( a -- b )`
enforced per element. Concurrent `each`: ordered results, leftmost
failure re-raised after cancelling and quiescing the remainder. See
Concurrency.

### parse
`( string -- quotation )` — The reader, reified: parse source text into
an unevaluated quotation. `"42" parse first` is string-to-number.

### partial
`( value quotation -- quotation )` — Safe partial application: the result
pushes the captured value inertly, then runs the quotation. Even a
captured word remains data. Equivalent to `swap literal swap compose`;
`3 (+) partial` is `((3) first +)`.

### partition
`( sequence predicate -- matches rejects )` — *Isolated*, contract
`( a -- bool )`. Split into elements whose predicate returned 1 and those
returning 0. Defined in ecl.

### pop
`( x -- )` — Discard the top stack value. (`drop` is the sequence word.)

### pow
`( x y -- z )` — **Pervasive.** Exponentiation; returns float.

### pp
`( value -- )` — Pretty-print any value plus newline, in the display
layout of Printing. Best-effort: no round-trip guarantee — huge leaves
may be elided. `str` is the canonical form.

### prin
`( string -- )` — Write a string's chars raw (UTF-8, no newline).
Non-string is `'type`.

### print
`( text -- )` — String plus newline. Equivalent to `prin "\n" prin`.

### prod
`( sequence -- product )` — Product of a numeric sequence; 1 when empty.
Equivalent to `1 (*) fold`.

### put
`( collection key value -- collection )` — Functional update of a list
index or dict key, producing a new value.

### raise
`( error -- )` — Raise a language error from an error dict.

### range
`( bound -- list )` — The ints `[0 1 … bound-1]`; the bound must be a
nonnegative int.

### raze
`( list -- list )` — Flatten one level. Flat-map is `each raze`.

### reshape
`( list shape -- list )` — Cycle the data into the exact nested-list
shape; a zero axis must be final.

### rest
`( list -- list )` — All but the first element of a nonempty list.

### reverse
`( list -- list )` — Reverse top-level element order. Defined in ecl as
an index permutation.

### round
`( x -- integer )` — **Pervasive.** Round to nearest; the result is
int64, `'overflow` outside its range.

### scan
`( list accumulator quotation -- list )` — *Isolated*, contract
`( acc a -- acc )`. Like `fold` but returns every intermediate
accumulator; same length as the input.

### see
`( 'name -- )` — Print a canonical, re-readable definition with one
combined annotation. What prints is what is stored: a name bound by `set`
prints its capture body and `( -- value )` effect ending in `'name def`,
not the `set` spelling that produced it. Native and module origins are
displayed.

### set
`( value 'name -- )` — Bind a value as a constant word in the current
environment. Reference applies the constant's body and pushes the exact
captured value, quotations included. Defined in ecl as
`swap literal swap (-- value) swap def`, so `v 'name set` is
observationally `v literal (-- value) 'name def`: the stored body is
`((v) first)` and the declared effect is `( -- value )`. Dropping the
annotation is not the same definition — it publishes no effect, which
`which` and `see` both show, and which a module rejects outright. The
value is captured before `def` sees it and therefore can never be read as
an annotation.

### setp
`( value 'name -- )` — Bind a private module constant. Defined in ecl as
`swap literal swap (-- value) swap defp`. A top-level `setp` is an error,
raised by the `defp` it calls.

### shape
`( list -- shape )` — The dimensions of rectangular data; `'shape` error
on ragged data (`len` is the word that works on anything).

### signum
`( number -- sign )` — **Pervasive** by composition. −1, 0, or 1 as an
int, by sign. Equivalent to `dup 0 > swap 0 < -`.

### sin
`( x -- y )` — **Pervasive.** Sine; float transcendental.

### sort
`( sequence -- sorted )` — Stable ascending sort by `cmp`. Equivalent to
`dup grade at`.

### spawn
`( quotation -- task )` — *Isolated*, contract `( -- … )` (inputs via
`partial`/environment, never the ambient stack). Run a self-contained
quotation concurrently in a child task. See Concurrency.

### spawn-with
`( values quotation -- task )` — Construct a self-contained quotation by
capturing every element of the values list inertly and in order, then
`spawn` it. The values therefore form the child task's initial stack. Defined
in ecl as `with spawn`; `spawn-with await` is observationally
equivalent to `attempt-with`.

### split
`( string separator -- parts )` — Split a string at every occurrence of a
separator string; the parts are strings.

### sqrt
`( x -- y )` — **Pervasive.** Square root. `'domain` on negative inputs
(the result would be NaN).

### str
`( value -- string )` — The canonical printed representation; carries the
round-trip guarantee (see Printing): reading it back yields the same
value, task handles excepted. Equivalent to `wrap "{}" format`.

### sum
`( sequence -- total )` — Sum of a numeric sequence; 0 when empty.
Equivalent to `0 (+) fold`.

### swap
`( x y -- y x )` — Exchange the top two stack values.

### take
`( list count -- list )` — The first `count` elements; a negative count
takes from the end. When the magnitude exceeds the length, the data
cycles.

### tasks
`( -- tasks )` — Pending descendant tasks in deterministic spawn
preorder.

### times
`( n q -- … )` — *Inline.* Run the quotation `n` times; `n` must be a
nonnegative int. Tail-call optimized.

### to-dict
`( keys values -- dict )` — Dict from two conforming lists; duplicate
keys error.

### tri
`( x p q r -- … )` — *Inline.* Apply three quotations to the same input
in order. Equivalent to `((keep) dip keep) dip call`.

### type
`( value -- type )` — Return the value's kind as a symbol: one of `'int`,
`'float`, `'char`, `'symbol`, `'word`, `'list`, `'dict`, `'task`.

### unappend
`( list -- initial last )` — Split a nonempty list into its initial
elements and last element. Equivalent to `reverse uncons reverse swap`.

### uncons
`( list -- first rest )` — Split a nonempty list into first element and
remainder. Equivalent to `dup first swap rest`.

### unless
`( bool else -- … )` — *Inline.* Run the quotation when the condition
is 0. Equivalent to `() swap if`.

### use
`( 'name -- )` — Splice a module's exports into the current scope,
loading `<name>.ecl`/`<name>.eclmod` from `ECL_PATH` when unregistered.
Reports each shadowed export on stderr. Idempotent; re-use moves the
module to the top of the shadow order. See Modules.

### vals
`( dict -- values )` — Values in insertion order. Defined in ecl.

### when
`( bool then -- … )` — *Inline.* Run the quotation when the condition
is 1. Equivalent to `() if`.

### where
`( counts -- indices )` — Expand a list of nonnegative ints into each
index replicated its count times. A 0/1 mask is the common case, yielding
the positions of 1s: `[0 1 1 0] where` is `[1 2]`.

### which
`( 'name -- )` — Print where a name resolves (module home, shadowing),
its kind (`def`, `primitive`, or `native`), visibility, and declared
effect. Constants report `def`, like every other ecl definition.

### while
`( cond body -- … )` — *Inline.* Repeatedly run `cond`, which must leave
one boolean; while it leaves 1, run `body`. Tail-call optimized.

### with
`( values quotation -- quotation )` — Capture every element of a list as
an inert input to a quotation, preserving order. Calling the result starts
with the list's elements as separate stack values. Defined in ecl as
`((literal) each) dip append raze`.

### words
`( -- )` — Print the visible dictionary in sorted order.

### wrap
`( value -- list )` — One-element list. Equivalent to `() cons`.

### zip
`( left right -- pairs )` — Pair corresponding elements of two conforming
sequences. Equivalent to `(pair) zip-with`.

### zip-with
`( left right quotation -- list )` — *Isolated*, contract `( a b -- c )`.
Zip two lists with broadcast conformability (an atom on either side
extends). Each-left/each-right are `partial` compositions, not separate
words.
