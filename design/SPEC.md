# ecl — language specification

This document is the authority on ecl's syntax and semantics. It describes
the language as implemented, completely and only: a construct appears here
exactly when the shipped interpreter provides it. The companion
[`STDLIB.md`](STDLIB.md) is the exhaustive shipped-vocabulary reference, and
[`INTERPRETER.md`](INTERPRETER.md) describes how the implementation delivers
these semantics; neither may change an observable behavior specified here.

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
unparseable runtime display marker wherever an atom may occur. The same bytes
inside a string literal are ordinary character data.

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
  require computation, build a flat entry list and use `dict.from-flat`.
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

Every value is one of eight readable kinds, as reported by `type`: `'int`,
`'float`, `'char`, `'symbol`, `'word`, `'list`, `'dict`, or `'task`. Two
further kinds are opaque runtime capabilities that no source text can
denote: `'module` (see Modules) and `'unit-plan` (see Seeding a unit).

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
  `'dup` yields the symbol, and they do not `match?`. Words print bare,
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
  identity is whole-value `match?` identity. Insertion order is preserved
  by storage, iteration, and printing, but ignored by equality: two dicts
  with the same key–value pairs in different orders are equal.
- **task** — a handle to a concurrent unit of work (see Concurrency).
  Tasks are runtime capabilities bound to their session: `match?` and
  hashing use handle identity, and a task prints as `<task:N>`, which the
  reader rejects. A task value cannot be forged from text.
- **unit-plan** — a sealed pair of seed values and a construction body,
  built only by `seed` and consumed only by a unit constructor. Like a
  task it is opaque: `match?` and hashing use plan identity, it prints as
  `<unit-plan>`, which the reader rejects, and it cannot be called,
  concatenated, indexed, serialized, or passed to a native word. It is an
  ordinary first-class value for everything else — `dup`, `pop`, storage,
  selection, and passage between words.

### Equality and ordering

- `=` is pervasive equality: it descends structure to atoms and produces
  0/1 masks (see Pervasion).
- `match?` is whole-value structural equality: `[1 2] [1 2] =` is `[1 1]`;
  `[1 2] [1 2] match?` is `1`.
- Numbers compare numerically everywhere, across int and float: `2` and
  `2.0` are equal under `=`, `match?`, and `cmp`, are the same dict key,
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
closures: a quotation captures no values. It carries one thing — the scope
its text was written in, which is where its words resolve — and that is
resolution context, not a captured environment.

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
- **`@attempt` and `@spawn`**: each runs its quotation as a new unit on an
  isolated substack (see Errors, Concurrency).

A dying unit also cancels its unawaited tasks (see Concurrency).

### Application contexts

Three quotation-application behaviors exist:

- **Inline**: the quotation runs on the current stack. The inline words
  are `call`, `dip`, `keep`, `bi`, `tri`, `bi2`, `both`, `if`, `when`,
  `unless`, `case`, and `times`.
- **Checkpointed inline guards**: `cond` and `while` test quotations run
  in the current scope against a retained operand-stack checkpoint. A test
  may consume, rearrange, or add values; its top value must be a 0/1 boolean,
  and its complete operand result is discarded before control continues from
  the checkpoint. Environment writes, IO, and other non-stack effects are
  inline and therefore survive.
- **Isolated**: the quotation runs on a fresh substack per application,
  seeded with its declared inputs, and its result count is checked
  against the contract. The isolated words are `each`, `zip-with`, `for`,
  `fold`, `scan`, `stencil`, `unfold`, `infra`, `@attempt`, `@spawn`,
  `@each`, `@module`, and `@defm`.

Every isolated combinator states the stack effect it requires of its
quotation argument (given per word in the reference). The contract is
checked dynamically at each application; a violation is an immediate
`'contract` error naming the element and the observed effect.

#### The `@` spelling convention

A leading `@` marks exactly the words that apply their quotation **in a
fresh unit** — one unit per application for `@each`. There are five:
`@attempt`, `@spawn`, `@each`, `@module`, and `@defm`. Unit construction is
the whole of the class invariant; the marked word may or may not seed the
unit it makes. Handed a bare quotation, `@attempt`, `@spawn`,
`@module`, and `@defm` seed nothing, so that quotation must be
self-contained: its effect is `( -- ... )` and inputs arrive through a plan's
seeds, or via `literal`/`partial`/`compose`, or through environment names,
never the ambient stack. `@each` seeds each child with exactly its element.
Handed a plan, every one of the five seeds the unit it makes. `register` is not marked: it publishes an already-constructed
module value and takes no quotation.

Words that are isolated but *not* marked, with their reasons:

- `each`, `zip-with`, `fold`, `scan`, `stencil`, `unfold`, `for` — they
  apply in the **same** unit, on a substack, and are implicitly fed their
  elements, windows, or states.
- `infra` and `within` — they apply on an explicitly named *other* stack;
  the substitution is the word's meaning, not a new unit.
- `import`, `load`, `unmodule`, `register` — they construct, publish, or retire
  without taking a quotation.
- `await`, `await-all`, `await-any`, `await-for`, `cancel`, `tasks` —
  they consume tasks rather than making them.
- `with` — pure composition; it constructs nothing.
- `seed`, `unseed` — a unit constructor's *input*, sealed and unsealed. A
  plan is not a unit and running one is not a thing you can do.

`@` is an ordinary word character, not reader-reserved: a user's `@retry`
lexes and defines normally. The convention is enforced for first-party
vocabulary by the source audit and is the recommended spelling for any
user-defined word that wraps its quotation in a unit.

#### Seeding a unit

There are no `-with` words. Every unit constructor takes one input, the
tagged sum

    UnitInput = unseeded quotation | unit-plan

A bare quotation seeds nothing, which is why the concise spellings are
unchanged. A plan supplies seeds, and `seed` is the only word that builds
one:

    values (q) seed @attempt
    values (q) seed @spawn
    list values (q) seed @each          ( element deepest in each child )
    values (body) seed @module
    values (body) seed 'name @defm

`seed` is `( values quotation -- unit-plan )`. It consumes a values list
and a quotation and returns an immutable opaque plan owning the two
*separately*. It does not execute, stamp, copy, parse, or otherwise
transform either input, and it is not itself a unit constructor: a plan
is an input protocol, not a unit.

`unseed` is `( unit-plan -- values quotation )`, the metaprogramming
escape hatch: it returns the exact two values a plan holds, so a program
may unpack a plan, transform either ordinary value, and seal the result
into another plan.

The new unit's operand stack is initialized from the seed list in list
order, and then the body runs. Seeds are values, not code contributed to
the body: even when a seed is itself a reader-built quotation, none of its
contents is part of the construction body's text. `@each` puts the
iterated element deepest in each child stack, beneath the plan's shared
seeds.

Keeping the two apart is what makes seeding compatible with module text.
`with` also produces something a constructor accepts, because its result
is an ordinary quotation, but the flattened value it returns can no longer
say which part was the body — and `@module` and `@defm` must know. A
`with`-seeded construction is therefore a runtime-built body and takes no
module attribution; see Modules.

Underflow against the floor of a constructed unit is reported specially:
the message names the isolation and the seeding remedy, and the error
dict carries `'isolation` naming the constructor. It is the one underflow
whose cause is invisible — the values the caller meant to pass are on
screen and out of reach.

### Bindings

One namespace, one kind of binding: a name binds a body, and reference
always applies it. Values are bound by capturing them in a body.

- `(body) 'name def` binds a word: reference applies the body. The body
  must be a list (a non-list is an error directing to `set`); a list of
  plain data is legal and yields a multi-value constant word.
- `annotation? value 'name set` binds a constant. It is sugar, defined in ecl
  as `swap literal swap def`: the value is captured with `literal`, so the
  published body is `((value) first)`. Reference applies that body and
  pushes exactly the captured value, quotations included — the capture is
  inert, so nothing in it executes or resolves. `v 'name set` is therefore
  observationally `v literal 'name def`, exactly: the sugar synthesizes no
  annotation of its own, while an annotation beneath `v` is preserved for
  `def` to consume. `which` and `see` report the resulting public `def`; an
  unannotated `set` has no effect or documentation, and nothing distinguishes
  it from the corresponding `literal` plus `def` spelling. `set` is
  environment assignment, not a lexical binding form. For ordinary local
  values, prefer stack flow or binder locals.
- Redefinition (`def` or `set` over an existing name) replaces the
  complete binding snapshot: omitting an effect or docstring clears the
  old one. Code holding the old body keeps running it safely.
- `'name unset` and `'name undef` are exact aliases. They remove a binding
  only from the current writable scope and otherwise do nothing. Removing a
  shadow reveals the next binding in the ordinary parent/core lookup chain;
  it never mutates that parent. The name must be unqualified and non-reserved,
  under the same namespace validation as `def`.
- `defp`/`setp` are the private forms, legal only inside a module body
  (see Modules); at top level they are errors.
- Because `set`/`setp` are sugar, their failures are raised by the words
  they call: an underflowing `set` is `'underflow` from `swap`, and a
  non-symbol or reserved name is raised by `def`/`defp`. The error kind is
  unchanged; the trace names `set`/`setp` as the parent.

### Definition annotations

A definition may place one annotation quotation immediately before its body:

```
(body) 'name def
(before -- after) (body) 'name def
(: "Documentation.") (body) 'name def
(before -- after : "Documentation.") (body) 'name def
```

The annotation is ordinary quotation data — no special grammar — and is
recognized only when it contains a top-level word `--` or `:`. Nested
markers and the quoted symbols `'--`/`':` are inert. A recognized
annotation is validated as a whole before the binding publishes: at most
one marker of each kind, `--` before `:`, only words around `--`, and
exactly one string after `:`. A malformed recognized annotation is a
`'domain` error. The quotation adjacent to the name is unconditionally the
body; only the value beneath it is considered for annotation recognition.
`set`/`setp` capture their value with `literal` before `def`/`defp` sees it,
so marker words belonging to the captured value sit nested inside the body
and remain inert. A separate annotation beneath that value is still visible
to `def`/`defp`, giving constants the same optional metadata as words.

Annotations are optional everywhere. Module `def`/`defp` accept the same
four forms as top-level `def`: no annotation, effect only, documentation
only, or both. A top-level effect is reflective metadata only; a module
word's declared effect is a live contract, checked dynamically against the
observed effect when application crosses a module boundary (violation:
`'contract`). An omitted module effect means there is no such check, not
an inferred one, and reflection preserves whether each portion is absent.
This source-language relaxation does not weaken the native ABI, whose
`Call` effect and documentation remain mandatory; the shipped prelude
keeps its stronger repository policy requiring meaningful documentation.

Documentation has canonical form. Publication trims source-only
indentation, folds physical line breaks within prose to spaces, collapses
a paragraph boundary to one blank line, and preserves each Markdown `- `
item on its own logical line with its continuations folded in. `doc`
returns this canonical string, so source formatting cannot change
reflective documentation. Strings anywhere else retain their exact decoded
codepoints.

#### The after row

The after portion of an effect is either **all named slots** or exactly
the token `...`:

```
(result on-ok on-err -- ...) (body) 'case def
```

`...` declares a **fixed before row and a variable after row**: how many
values the word consumes is known, how many it leaves is not. The before
slots are checked at boundaries exactly as today; the after check is
skipped. This is a genuine partial contract, not the absence of one — a
word that would otherwise carry a documentation-only annotation regains
input checking and honest reflection, and `see` renders the annotation
back with `-- ...`.

The grammar is strict: no mixing (`(a -- ... b)` is `'domain`), and the
token never appears in a before row (`(... -- b)` is `'domain`). Named row
variables in the Factor style (`..a`, `..b`) are deferred to the static
checker; `...` is the anonymous row that reads the same way today. The
native ABI is deliberately excluded: a native `complete` requires the
exact output tuple, so `...` in a `Call` effect is a compile error.

The exact names `--`, `:`, and `...` are reserved against binding:
they remain legal word and symbol values and can be built into
annotations at runtime, but cannot be introduced as definitions, values,
locals, module names, aliases, exports, or native entries. Binding attempts are `'domain`;
binder use is a parse error. Longer names containing the same punctuation
remain legal.

### Metaprogramming

There is no macro system. Runtime quotation construction — `literal`,
`compose`, `cons`, and the list words — plus `def` is the metaprogramming
system: a quotation you wrote or `parse` produced is a list, list surgery
builds a new one, `def` rebinds. `parse` turns source text into a quotation.
Parse-time transforms are capped at the binder desugaring and the literal
readers. The material is code you hold, never code a binding holds: no
operation extracts a published body, so metaprogramming cannot reach inside
an existing definition. A quotation built this way has no written-in scope
and so resolves where it is invoked.

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
- The bitwise words `band`, `bor`, `bxor`, `bnot`, `bsl`, and `bsr` are
  *pattern* words, not arithmetic: they read an int as its 64-bit
  two's-complement pattern and are int-only, so a float or a char is
  `'type` rather than a coercion. Because a pattern has no magnitude,
  they never overflow — `bsl` truncates bits off the top where `*` would
  raise. Their `count` operand is the one place they can fail on a value:
  a shift outside `0..63` is `'domain`. They pervade and align dicts like
  every other pervasive word.

## Randomness

Randomness is *counter-based*, not stateful: a generator state is a
two-element list `[key counter]`, and every draw is a pure function of
it. `rand.int`, `rand.ints`, and `rand.float` each take a state and
return the advanced state alongside the result, so a program's draws are
reproducible by construction — running it twice from the same key
produces the same values, and nothing hidden accumulates between units,
tasks, or module loads.

- The mixer is SplitMix64 applied to `key + counter * gamma`. Each draw
  addresses its own counter position rather than stepping a register, so
  `rand.ints` produces the same list whatever order its elements are
  materialized in, and two states that share a key but differ in counter
  do not correlate.
- `rand.entropy` is the only word that reads the host, and the only
  nondeterministic word in the language. A program is reproducible unless
  it explicitly seeds from `rand.entropy`; there is no ambient default seed
  drawn at startup, and no word silently reaches a CSPRNG.
- The `rng` module carries a state so ordinary code need not thread one
  by hand (see The standard library). It is threaded state, not global
  state: the module's own binding holds it, `rng.seed` replaces it, and a
  fresh process starts from the same fixed key.

## Chars and strings

A string is a rank-1 char vector; there is no separate string type. `len`,
`at`, `reverse`, `each`, and every other list word operate on codepoints.
UTF-8 exists only at IO boundaries: source files and `io.prin`/`io.pp` encode
and decode UTF-8, and invalid UTF-8 on input is an error. Char semantics
are codepoint semantics, stated honestly: grapheme segmentation,
normalization, non-ASCII case mapping, and locale collation are not
provided, so composed and decomposed `"café"` have lengths 4 and 5.
Symbols are interned at parse; strings are plain uninterned vectors.

## Modules

A module is a value; a *registration* is a name that owns one. A per-session
registry maps symbols to registrations; files are transport.

Construction and publication are separate operations, so a module can exist
anonymously, be passed as data, and be registered more than once.

- `@module` is `( body -- module )`. It runs the body on a fresh, isolated
  environment and returns an **anonymous immutable module image**: its frozen
  environment, its definitions, and the body's final operand stack as an
  *initial-state template*. It claims no registry name. The body runs
  stack-isolated: it never sees or disturbs the caller's stack.
- `register` is `( module 'module-name -- )`. It validates the canonical name
  and publishes the image under it. Registration is an upsert: a missing name
  creates its registration, and an existing name installs the new image while
  keeping the durable state that registration already owns.
- `@defm` is `( body 'module-name -- )` and is exactly `@module` followed by
  `register`, including the ordering: the body is evaluated before the name is
  validated. It is the source spelling for a module definition.
- `values (body) seed @module` and `values (body) seed 'name @defm` supply
  seeds without disturbing the same isolated construction. The values form the
  body unit's initial stack, in list order; the body may consume, reorder, or
  extend them. The plan keeps the seeds and the body apart, which is what lets
  attribution below name the body exactly.
- **A module value is an opaque capability.** Its `type` is `'module`; it
  prints as the unreadable marker `<module>`; `match?` compares **image
  identity**, so one construction duplicated matches itself and two
  constructions of the same body never match. It cannot be read from source,
  emitted as JSON, or passed through a native word's value or view inputs.
  It exposes no name, address, environment, registration, or state.
- **One image may back several registrations.** They share immutable code and
  definitions and nothing else: each registration owns its own durable state,
  generation currency, aliases, and removal lifetime. Reloading or removing
  one cannot change or retire another.
- Modules are first-class: enumerable, diffable, constructible by building
  the body quotation programmatically, and nameable at a distance — build
  once, choose the name later, or register the same image twice.
- **Module names are validated paths.** A canonical module name is one or
  more nonempty binding-name segments joined by dots: `stats`, `core.utils`,
  and `company.data.csv` are valid; leading, trailing, and doubled dots are
  not. Definition names and aliases remain one unqualified segment. Qualified
  executable names split at their final dot, so `core.utils.f` always means
  module `core.utils`, binding `f`, even when module `core` also exists. Host
  and native factories apply the reader's single scalar-level symbol-segment
  grammar; ASCII or Unicode whitespace, delimiters, malformed UTF-8, and other
  unreadable spellings do not become validated names. Reserved syntax markers
  are interned as syntax only and cannot be minted as binding names through a
  privileged validation mode.
- **The registry slot is the singleton identity of a *name*.** The first
  successful registration of a canonical module name creates its slot; later
  registrations replace only its code generation. Distinct names own
  independent slots even when they were registered from the *same* image.
  A slot owns one immutable snapshot of a durable operand stack per
  session, distinct from its replaceable code generation.
- **The image carries the initial-state template; the slot owns live state.**
  The isolated body's final operand stack becomes the image's initial-state
  template — it is not required to be empty. A first registration of a name
  *copies* that template into the new slot's durable stack, so the same image
  can seed another registration later. A re-registration does not consult the
  template at all and retains the slot's existing durable stack:
  initialization happens once per slot identity, not once per code generation
  and not once per image.
- Construction commits nothing to the registry: a failing body publishes
  neither a value nor a name. Registration commits atomically after the image
  exists; a failed registration — invalid name, alias collision, allocation
  failure, cancellation, or a conflicting state turn — leaves the previous
  directory entry, current generation, and durable state exactly as they were,
  and consumes the module reference it was handed.
- The registry is flat. A module body may register another module, but that
  registration creates an independent module with its own canonical name
  and lifetime; it does not establish lexical nesting or parent ownership.
  Registrations commit independently, so a completed inner registration is
  not rolled back if the registering module's body later fails.
- **Privacy is set at the definition site**: inside a module body, `def`
  and `set` bind public (exported); `defp` and `setp` bind private. Module
  bindings carry the same optional annotations as top-level ones, so a
  module word may be unannotated, documentation-only, effect-only, or
  both; `set`/`setp` publish the bare literal capture. Privacy is
  subtractive — privates are
  absent from the module's public face, not access-checked. Definitions
  made inside the module body's isolated child units (e.g. inside an
  `@attempt`) are dynamic and are never exported.
- **Resolution context comes from the registration a call was resolved
  through**, never from anything recorded at definition time. A definition
  records only its own module-local name; qualified lookup supplies the
  registration, and the activation carries it for its whole lifetime. So an
  image registered as both `left` and `right` executes against whichever name
  the call named — private lookup, same-home dispatch, `within`'s slot,
  diagnostic spelling, and `which` all follow the invoking registration.
  A word reached through a quotation that escaped its module has no invoking
  registration at all: it resolves against the image its words were written
  in, so private lookup and same-home dispatch still hold, while `within` is
  `'domain` and diagnostic spelling is the unqualified local name. Such an
  application *does* cross a module boundary, so a declared effect on that word
  is checked like any other cross-boundary call. Crossing is decided by the home
  the call resolves to differing from the caller's, not by whether the source
  text spells a dotted name — which is why a bare word reached through an
  escaped quotation crosses one and a module's own internal call does not. An
  exported word's body resolves against its module's internal environment and
  then core — never the caller's environment. Publics therefore reach
  privates, and callers cannot perturb a module's behavior by shadowing.
  A module word's body is not reachable as a value: no operation extracts a
  published body, so a module's code cannot be lifted out of the home it
  resolves against.
  The rule has no exceptions, and the chain is the one each binding was
  actually defined in. A primitive or an embedded prelude definition was
  published against core alone, so core alone is its chain: it never resolves
  against a session or a module environment, whichever happens to be
  executing. Every other binding resolves against the scope resolution found
  it in — the session root for a top-level definition, and the child scope
  itself for one made inside an `@attempt`, so siblings defined in the same
  child see each other. There is no case where a binding resolves against a
  chain it was not defined in. So a module exporting a word named like a core one shadows it
  for that module's own callers, never inside the prelude words the module
  calls: `table.where` does not become the `where` that `filter` is written
  against. The same holds for the session, which is what makes shadowing
  predictable rather than retroactive:

      1 wrap                                  -- [1], reaching core's `cons`
      (pop pop 42) 'cons def   1 wrap          -- still [1]
      (pop pop 42) 'cons def   1 [] cons       -- 42, the session's own `cons`
      (pop pop 42) 'cons def   (() cons) 'wrap def   1 wrap    -- 42

  A session `def` shadows a name *for session code*. It does not rewrite what
  an already-evaluated definition means, because that definition's references
  resolve where they were written. Adopting new behavior inside a prelude word
  is redefining that word: the replacement is a session definition, so it
  resolves in the session and shadows the prelude one for session callers.
  Reaching further in is deliberately not available — changing what `filter`'s
  own `where` means requires redefining `filter`.
  Late binding is unaffected. The lookup still happens at call time; what is
  fixed is which chain it happens in. **The sealing extends to quotation
  literals, and it has to.** A quotation literal written inside a body is
  sealed the way the body's own references are: it resolves in the scope its
  text was written in, whoever ends up applying it. `all?` is
  `(|l q| l q each 1 (and) fold)` and `over` is `(swap dup (swap) dip)`, so a
  session `and` or `swap` leaves both alone:

      (pop pop 42) 'and def   [1 1] (1 =) all?      -- 1
      (pop pop 99) 'swap def  1 2 over              -- 1 2 1

  A quotation the session wrote is still session code, so a combinator does
  see the definitions of whoever *wrote* the quotation it was handed:
  `(pop pop 42) '+ def [1 2 3] 0 (+) fold` is 42. The two cases separate
  because the scope travels with the quotation rather than with the
  activation. `all?` hands `each` its caller's `q`, written in the session,
  and hands `fold` its own `(and)`, written in the prelude; each resolves
  where it was written, from the same activation. This is the
  syntactic-closure construction — code paired with the scope its identifiers
  resolve in — and it is why the no-closures rule is stated as *captures no
  values*. Nothing is captured, the lookup still happens at call time, and a
  quotation built at run time by `partial`, `cons`, or `compose` has no
  written-in scope, so it resolves where it is invoked exactly as a plain list
  always has.
  A word written in a module body names *that image*. Reloading publishes a new
  image under the name, so a fresh call through the name runs the new code —
  which is the whole of what redefinition needs to do. Code that already
  exists is not re-pointed: a running body keeps the image it entered, and a
  quotation that escaped one goes on meaning what it meant. This is Forth's
  rule rather than Erlang's, and deliberately: Erlang's version coexistence
  exists to upgrade a live stateful system in place without losing state, and
  ECL has no such need. Redefining at a prompt happens between units, with
  nothing on the stack, so the cases that separate the two designs do not arise
  in the workflow the feature is for.
  An image lives as long as something holds it — a running activation, a
  registration, or a unit that has dispatched a word written in it. That last
  holder is what makes a quotation which escaped its module safe to apply: the
  dispatch retains the image for the rest of the unit, so the scope its words
  resolve against cannot be freed under them by a concurrent reload or
  `unmodule`. Once nothing holds it, applying a quotation written in it is
  `'domain`, never a fallback to core or to the invoking chain, because a
  fallback would silently change what its words mean. Failing at the point of
  use is the point: you learn that the code you are holding belongs to a
  version that is gone, instead of watching it quietly acquire new behavior.
  An *anonymous* image — one built by `@module` and never registered — is the
  same rule with no name involved.
  **Which text is the module's is decided by what the reader produced.** A
  construction body's words name the image, and so do the words of everything
  the reader built inside it, whatever container they sit in — a quotation, a
  list literal, a dict literal. A value assembled at run time is not the
  module's text: its parts already name the scopes they were written in, and
  `@module` and `@defm` leave them alone. That is what makes a quotation
  handed in as a parameter keep the caller's scope, since `with` captures each
  seed with `literal` and a capture is built at run time.
- **An undefined-word failure says which chain it searched.** Its `'data`
  carries `'scope` alongside `'name`: `'session` for the activation's own
  lexical chain over core, `'module` for a module image's definitions over
  core, `'core` for a primitive or prelude definition, whose chain is core
  alone, `'qualified` for a dotted reference resolved through the registry,
  and `'module-value` for a missing public export of a module reached as a
  value — which is not a scope miss at all. A session name being invisible to
  a module and to a prelude word are different failures, and the field is what
  distinguishes them.
- **`invoke` is the only operation that runs a module value's code.**
  `module 'name invoke` calls one public export of an image reached as a value
  rather than through a registered name. A module value is otherwise an
  ordinary opaque value: `register` consumes one and `type` reports `'module`,
  and those are the only other things that accept it. It is the same dispatch a qualified call performs — the
  home is the image, so a public reaches its own privates, and lookup is
  public-only, so a private is as absent as a missing name. What it cannot do
  is open state: an image owns no slot, so `within` inside a handle-called word
  is `'domain` exactly as it is in a construction root. **A nameless module is
  stateless.** A module that needs state returns it — a `new` word handing back
  a value the caller threads through later calls — rather than encapsulating
  it; durable state and `within` remain the province of a registration, which
  is what a canonical name buys.
  The observation words take a *symbol*, so they remain registration-driven:
  `which`, `see`, and `doc` look a name up, and a name is what a
  registration is. A value has none to offer them.
  A nameless image has no canonical spelling either, so a failure inside a
  handle-called word traces its bare local name — `['missing 'boom]` where a
  registered call would say `['missing 'named.boom]`. Borrowing the caller's
  parameter name would read better and claim more than is true.
  Two images exporting the same name may be held and invoked at once, which a
  registry keyed by name cannot represent.
  A stateless module is formally a record of functions, so it is worth saying
  why it is not a dict of quotations. A dict would lose both halves of what a
  module carries: its privates, which are absent from its public face but
  reachable from it, and the home its bodies resolve against. A dict of
  quotations hands out the code and keeps neither: the quotations would be
  values a caller can index, reorder, and re-`def`, and a private would be
  reachable by dissecting a public. The module kind exists to carry that
  environment, and `invoke` is the operation that enters it.
- **Capture is parameterization, and parameterization is the only capture.**
  A construction receives everything it needs on its stack, seeded by a plan
  — `values (body) seed @module`, `values (body) seed 'name @defm` — and
  nothing else crosses the boundary.
  There is no ambient environment between a module's own definitions and core,
  and no construction-time snapshot of one.
  To depend on a session value, pass the value. To depend on behavior, pass a
  quotation you write at the call site — `[(2 *)] ('scale def …) seed 'm @defm`
  — which is the functor discipline: the caller writes the structure it hands
  in. To share a *word* between a session and a module, or between two
  modules, make it a module both parties call. No operation lifts a published
  body out of the home it resolves against, so a word is never the currency; a
  quotation you wrote, or a module you both call, is. Both are ordinary values
  on an ordinary stack, which is why this needs no construction-specific
  mechanism and no new vocabulary.
  Every consequence follows from having nothing to stale. A later top-level
  definition cannot change an existing image, because the image never referred
  to the session. Nested construction needs no special rule, because it
  receives its parameters the same way. Registrations and aliases of one image
  share its definitions, because that is all there is to share. Module text the
  loader executes — an embedded standard module, a file found on `ECL_PATH`, a
  locked package entry — behaves identically to text typed at the session,
  because neither can see a session, so load order is not observable.
  A whole module may be a parameter, which is how a substitutable dependency
  is expressed: pass the image and call it with `invoke`. That keeps the choice
  of implementation with the caller instead of making it a fact about the
  global registry, which is what makes a test double local and two versions of
  one package able to coexist.
  A quotation parameter carries the scope it was written in, so its own
  references are the caller's rather than the module's. With `10 'k set` in
  scope, `[(k *)] ('scale def ( -- n ) (4 scale) 'go def) seed 'm @defm` makes
  `m.scale` multiply by ten, and the module needs no parameter for `k`. That is
  what a functor argument should do: the caller supplies the behavior, and the
  behavior means what it meant where it was written.
  Purity comes from the unit-constructor boundary, not from transitivity. The
  *construction body* is not an ordinary application — `@module` and `@defm`
  run it in the image's own chain whatever scope its text was written in, so a
  bare `k` inside the body is undefined however recently the session defined
  one. The module still cannot reach the session, and everything still arrives
  as a parameter. A label decides one thing only: where a handed-in
  quotation's own words resolve once the module applies it.
- **A word resolves in the scope its text was written in.** The scope is
  carried by the word itself, not by the quotation containing it, so it
  survives every operation that moves code around: `cat` and `compose` splice
  tokens from two sources into one list and each token keeps the scope it was
  written in. A module word may hand `(private-helper)` to `each` and the
  private still resolves, because the literal was written inside the module;
  a module word may accept `(bump)` from its caller and that `bump` resolves in
  the caller, because the caller wrote it; and both hold when the stdlib splices
  the caller's quotation into a plan's seeds. Neither depends on which
  activation launched the combinator. A word with no written-in scope — one a
  host built, or one appearing in an error trace — resolves where it is invoked.
  Reading is what assigns a scope, so `load` and `parse` both give the words
  they produce the scope of the unit that asked for them: `"foo bar" parse call`
  means what typing `(foo bar)` there would mean.
  There is no exception for the `@` words. An `@attempt` child's parent is the
  enclosing scope, so a word written outside still resolves through the chain
  while one defined inside the child is found first. `@module` and `@defm`
  differ only because an image's scope has no parent: they stamp the
  construction body with the image's scope, which is why a bare session name
  inside a construction body is undefined while a quotation handed in as a
  *seed* — a separate value, never inside the body — keeps the caller's.
  What a word *defines* — `def`, `set`, `setp` — still lands in the invoking
  context, which is how `setp` inside a module body binds a module private.
  `def`-ing a quotation therefore makes the *binding* local without re-siting
  the quotation's *references*: they stay where the text was written.
  Resolution moved; definition placement did not.
- **Module text is exactly what the reader wrote inside the designated body.**
  Two independent facts decide attribution, and both are required. First, the
  constructor's input identifies the exact body value, separately from its
  seeds — which is what `seed` preserves and `with` destroys. Second, the body
  must carry reader-text lineage. Every word occurrence in the reader-built
  subtree rooted at such a body is copied with the new image's scope, descending
  through nested quotations, list literals, and dict literals alike.
  Lineage survives only the interpreter's scope-only construction rewrite. That
  rewrite copies, and the copy is the same reader text with different scopes on
  its words, so a later constructor may re-stamp that exact rewritten body to
  its own image — which is what makes a construction nested inside a
  construction body resolve against its own image rather than the enclosing one.
  Ordinary runtime reconstruction loses the lineage. `cat`, `compose`, `cons`,
  `append`, `raze`, slicing, reversal, `with`, and every other generic
  reconstruction produce values with none, so a body built that way is stamped
  nowhere and is not descended into: it is not module text merely because its
  parts came from the reader, and reader lineage carried by nested fragments
  grants no admission through a root that has none. So `7 'k set ((k) 'geta)
  (def) cat 'm @defm` leaves `k` naming the session, and `m.geta` is `7`;
  wrapping that same runtime-built body in a plan changes only its initial
  stack, never its attribution.
  Seeds are never traversed or stamped, whatever they contain. Nothing about
  archive-wide membership, a coinciding source range, or the operation history
  of a runtime list is a substitute for lineage, and no operation grants lineage
  to a value chosen by its caller.
- **`within` is the explicit stack boundary.** `within` runs a quotation
  against a private draft of the home module's durable stack rather than
  the ambient caller stack. It is legal only while executing a published
  word whose definition-site home is a live module: session top level, a
  construction root (an image being built has no registration, and its body
  operates on its construction stack directly), a word reached through
  `invoke` (an image reached as a value has no registration either, so it owns
  no slot), a word reached through a quotation that escaped its module (the
  quotation carries the image its words were written in, not a registration a
  call was resolved through, so there is no slot to target — and for an image
  registered under several names there is no fact of the matter about which
  slot it would be), and a body extracted and redefined elsewhere are all
  `'domain`. Such a word never targets the *caller's* slot: `within`'s
  authority comes from the definition-site home, so a module that hands out a
  quotation over its own privates hands out no write at all.
  There is no module-handle-targeted form. Inputs cross the boundary only because
  the word body captures them explicitly with `partial` or `with`.
  Semantically `within` is the module-scoped transactional counterpart of
  `infra`: `infra` takes a supplied list as its temporary stack, `within`
  selects the invoking word's durable home-module stack.
- **`without` is the explicit outward boundary.** Inside an active
  `within` quotation, `without` pops the draft's top value and appends it
  to a pending output sequence; elsewhere it is `'domain`, and on an empty
  draft it is `'underflow`. Multiple outward values reach the caller in
  invocation order. A value remains in the durable stack and is also
  returned only when the quotation duplicates it before `without`; values
  captured with `partial` or `with` stay in state unless the quotation
  consumes or moves them outward.
- **Each `within` application is the transaction.** Success publishes the
  remaining draft as the new durable stack exactly once and then transfers
  the pending outputs to the caller through a window reserved before
  publication, so no allocation failure can commit state without
  delivering every output. Error, cancellation, allocation failure,
  contract failure, and `without` underflow discard both the draft and the
  pending outputs and publish nothing. A later failure in the enclosing
  word or unit does not roll back a `within` application that already
  returned, matching the existing rule that unit stack rollback does not
  undo completed environment or IO effects.
- **`within` applications are serialized scheduler work.** One fair
  per-slot arbiter orders them in arrival order, holding no lock while ECL
  code runs and permitting ordinary bounded scheduler yields. Parking
  (`await`, deadline waits, task joins, `exit`), a nested `within`, and an
  application homed in another module are all `'domain` before parking or
  acquiring a second slot, so no self- or cross-module deadlock shape is
  reachable. Ordinary calls, including read-only calls into other modules,
  remain available inside the quotation.
- Re-registering a module heals all callers immediately: module words
  resolve through the registry, and each application pins one registry
  generation for the whole body — no mixed-generation execution.
- **Slot lifetime is an owned capability.** Every published generation owns a
  non-retargetable slot lease for its whole lifetime. Resolution retains an
  operation lease before dropping the directory snapshot that supplied the
  slot entry, and `within`, reload, and removal retain that witness across
  their complete check/use interval.
  Removal does not wait for old generation pins, but retired slot storage is
  not reusable until all such leases, the arbiter, and old directory snapshots
  have drained. A removed generation can therefore observe only its original
  closed slot, never an unrelated module that later reuses registry capacity.
- **Hot reload preserves the stack.** Re-registration constructs a new code
  generation while retaining the slot and its durable stack, taking an
  ordinary place in the slot's arbiter order: every `within` application
  queued before it runs against the old generation and finishes first, and
  every later one runs against the new one, so no application straddles
  the swap. A quiescent slot — the sequential common case — commits
  immediately. Once a replacement representation is current, code from a
  superseded generation may keep running but may no longer publish state:
  its `within` is `'domain`. A re-registration initiated from inside *any*
  state application is `'domain` before any wait: a unit holds at most one
  slot's turn, and waiting for a second is the same deadlock shape a nested
  `within` is. Failed
  registration changes neither code nor state. Stack-layout evolution is
  an explicit userland protocol: replacement code must understand the
  retained representation and may migrate it with an ordinary first
  `within`; the runtime neither inspects nor names positions in the stack.
- **Removal completes the lifecycle.** `unmodule` accepts a module name; an
  alias canonicalizes through the registry to the same slot. An unregistered name is
  `'undefined-word`, and removal from inside any state application is
  `'domain`, like re-registration. It
  closes new resolution, calls, and `within` applications, waits for
  queued and active drafts through the same arbiter order, removes every
  alias targeting the slot in the same
  publish, then retires the code generation and every value on the durable
  stack through bounded work. Once the close is published, ownership of the
  remaining retirement is transferred to scheduler work before cancellation
  can unwind the initiating unit; post-close cancellation cannot strand a
  closed slot. Concurrent resolution observes either the
  live module or `'undefined-word` once close begins, never a half-removed
  entry. Session shutdown consumes the same `live -> closing -> retired`
  protocol, and settled memory across repeated construct/remove/name-reuse
  cycles is bounded by peak simultaneously live state and slot leases rather
  than by registration history.
- Module state is process-local: there is no persistence across process
  restart, and the native ABI exposes no module-state capability, so an
  `.eclmod` word can neither observe an internal module home nor reach a durable
  stack.
- **Surface**: `import` consumes a qualified original and a bare binding name,
  then publishes exactly that one binding in the current environment — which
  inside a module body means the image, publicly, on the same terms `def`
  binds there. The
  binding is a late-bound forwarding definition whose effect and documentation
  are copied from the original. Naming a binding that already exists replaces
  only that binding; importing never splices an entire module or emits shadow
  notices. Dotted words split at their final dot and give qualified access with
  no import. `qualify` validates a module-name symbol and an unqualified
  binding-name symbol and constructs the corresponding executable word;
  `execute` applies that word through ordinary late-bound dispatch, preserving
  its module home, private lookup, annotations, tracing, native/builtin path,
  cancellation, and `within` authority. If the qualified word is cold, that
  same dispatch loads its module and resumes the constructed word directly;
  it never requires a prior import or literal qualified call. `alias` registers a short registry
  name; aliases and module
  names may not collide in either direction. `which` shows any name's
  resolution.
- **Loading**: the first qualified reference (`stats.mean`) to an unregistered
  module — including an original named by `import` —
  consults the embedded standard library first, then searches each
  `ECL_PATH` entry in order, trying `stats.ecl` and then `stats.eclmod`;
  the first existing candidate is authoritative, including its errors.
  Embedded names therefore always win: a `csv.ecl` on the search path
  cannot silently replace the stdlib `csv`, and in-session shadowing or
  explicit `@defm` registration remain the way to override one. Every
  module is addressable by qualified name with no ceremony; an explicit
  `import` supplies a chosen bare spelling for one word.
  Every qualified-name operation triggers the same load when needed:
  execution, `doc`, `see`, `which`, and qualified completion do not
  depend on whether an earlier operation happened to register the module.
  Completion loads only the module; it neither executes an export nor imports
  one into session scope. A misspelled dotted word costs one bounded search
  before raising `'undefined-word`. Two units racing the first
  reference to one module converge on a single published module; only a
  unit re-entering its own in-progress load is a `'domain` cycle. A loaded
  `.ecl` file registers a module as an ordinary side effect of running;
  `load` replays any file as one unit in the calling session. Loading succeeds
  only when the requested canonical name is actually registered, whichever
  spelling the file used: a file that constructs an anonymous image and never
  registers it fails with the ordinary loader error.

### Native modules

A `<name>.eclmod` is a precompiled native module: one artifact is one
module, whose complete word table validates and publishes atomically — an
artifact cannot partially register. Its canonical name must equal the
requested name. Native words are ordinary module words: they carry a
  mandatory effect and nonempty documentation, participate in `import`, dotted
  access, `doc`, `which`, and `see` (which display the native origin), and
their calls are transactional — a failing native call leaves the stack
unchanged. A native word can raise only the kinds `'type`, `'shape`,
`'conform`, `'overflow`, `'domain`, `'parse`, `'io`, or `'user`; the
runtime alone raises the rest. Native modules are neither reloaded nor
unloaded within a session.

Opening a shared library executes arbitrary machine code before ecl can
inspect it, so every directory on an `ECL_PATH` used for native loading is
a trusted-code boundary.

## The standard library

The exhaustive core and module word list lives in
[`STDLIB.md`](STDLIB.md). This section specifies the semantic conventions that
tie those ordinary modules into the language.

Twenty modules ship inside the binary. They are ordinary modules — registered,
enumerable, shadowable — and they load lazily on the first qualified mention of
their name, whether that is a bare `str.upper` or `'str.upper 'upper import`. Resolution consults
the embedded manifest before `ECL_PATH`, so a stray `csv.ecl` on the search
path cannot silently replace a stdlib name; in-session shadowing and explicit
`@defm` registration remain the documented overrides. All twenty resolve with no
`ECL_PATH` set and no filesystem access at all.

Three transports back them, chosen per module rather than uniformly:
embedded ECL source (`dict`, `error`, `result`, `str`, `table`, `rng`, and the
eight `pkg.*` modules), a linked first-party
native descriptor published through the same contract as an external
extension (`csv`), and builtin word tables published under a module name
(`io`, `json`, `http`, `archive`, `pkg.store`).
The last is reserved for authority the native SDK deliberately withholds — an
allocator, TLS, sockets — which is why `json` and `http` are not SDK modules
and `csv` is.

### error

Errors remain ordinary immutable dictionaries. `error.new` starts one from its
required kind symbol; `error.with-message` and `error.with-data` return updated
values without raising. `error.valid?` recognizes the same typed fields as
`raise`: required symbol `'kind`, optional string `'msg`, optional symbol
`'word`, optional list-of-symbols `'trace`, and optional dict `'data`. Other
diagnostic keys are permitted. `error.kind?` and `error.kind-in?` inspect a
validated error without repeating raw dictionary plumbing.

This module owns data construction and inspection only. `raise`, `fail`,
`assert`, and `@attempt` remain core because they are control effects rather
than error values.

- `error.new` `( kind -- error )`
- `error.with-message` `( error message -- error )`
- `error.with-data` `( error data -- error )`
- `error.valid?` `( value -- bool )`
- `error.kind?` `( error kind -- bool )`
- `error.kind-in?` `( error kinds -- bool )`

### result

Over the same `{'ok values}` / `{'err error}` shape `@attempt` produces. A
success payload is always a list standing for a stack, never one privileged
scalar. Every word rejects a malformed tagged result *before* invoking any
quotation it was given.

Every word that *interprets* an envelope lives here — that is the boundary.
The words that *produce* an error — `raise`, `fail`, `assert` — stay core,
because an error dict in flight is not a result: it becomes one only when
`@attempt` or `await` reifies it.

- `result.ok` `( values -- result )`, `result.err` `( error -- result )`
- `result.ok?` / `result.err?` `( result -- bool )`
- `result.or-raise` `( result -- values )` — the success payload, or the
  captured error dict re-raised unchanged. (`result.or-raise call` unpacks
  the values onto the stack.)
- `result.or-else` `( result fallback -- value )` — the success payload, or
  the fallback value.
- `result.and-then` `( result quotation -- result )` — seeds the success
  stack through `seed @attempt`; an existing failure is returned unchanged.
  There is no separate `result.map`: `@attempt`'s automatic `{'ok [...]}`
  wrapping collapses the functor map and the monadic bind into one word on
  the success side. The distinction survives only on the failure side, which
  is why that side carries both `map-err` and `recover`.
- `result.map-err` `( result quotation -- result )` — replaces a failure's
  error dict with what its `( error -- error )` quotation returns, never
  leaving the failure arm.
- `result.recover` `( result quotation -- result )` — seeds the error dict as
  one value; `result.recover-kinds` `( result kinds quotation -- result )`
  does so only for a listed kind and leaves every other result unchanged.
- `result.either` `( result on-ok on-err -- ... )` — exhaustive eliminator;
  neither branch is isolated.
- `result.all` `( results -- result )` — the leftmost failure unchanged, or
  one success holding every success stack in input order.
- `result.partition` `( results -- successes errors )` — both in input order,
  without re-raising.

### str

ASCII-only case mapping per the character model: a non-ASCII scalar passes
through untouched, and codepoint count is preserved. Its exports are `str.upper`,
`str.lower`, `str.trim`, `str.trim-left`, `str.trim-right`, `str.starts?`,
`str.ends?`, `str.contains?`, `str.index-of` (`'domain` when absent),
`str.replace`, `str.repeat`, `str.pad-left`, `str.pad-right`, and `str.str?`.

`str.str?` is the recognizer every boundary that accepts text needs, and it
lives here rather than in core because it is derived: a string is a rank-1 char
vector, so the test is a `'list` whose every element is a `'char`. It answers 1
for the empty string — which is also the empty list, the two being one value —
and 0 rather than raising for every other kind. `type` reports `'list` for every
list, specialized or not, so this is the honest form of the question.

### archive

Binary package archives cross the language boundary as **byte lists**: ordinary
ECL lists whose items are integers in `0..255`. Strings are Unicode values and
are never accepted or coerced at this boundary; hashing and extraction consume
each integer as exactly one octet in list order.

Byte lists have no distinct language-level type. List construction may store an
all-`0..255` integer list in a packed one-byte leaf, and host producers may build
that representation directly. Indexing, equality, printing, reflection, and
all other language operations still observe ordinary integers. A mutation that
introduces an integer outside `0..255` transparently widens the list to the
ordinary integer representation. Whether packed storage is present is never
observable program behavior.

`archive.sha256` `( bytes -- lowercase-hex )` returns the standard SHA-256
digest as exactly 64 lowercase hexadecimal characters. It is pure and does not
require host I/O.

`archive.unpack-tgz` `( bytes destination -- regular-file-paths )` validates a
gzip-compressed tar archive and extracts it beneath a previously absent
destination. It accepts ordinary ustar regular-file and directory entries,
per-entry PAX `path` and `size` records, and GNU long-name records. Other PAX
metadata may not change a member's path, size, or kind. The result lists only
regular-file paths, normalized with `/` separators and in archive order;
directory entries are omitted.

Extraction is contained and fail-closed. Member names must be valid UTF-8,
relative, nonempty after normalization, and contain no empty, `.` or `..`
component. Absolute names, platform-rooted names, duplicate normalized paths,
links, devices, FIFOs, unsupported member kinds, malformed gzip/tar/PAX data,
and checksum or size disagreement are `'domain`. The uncompressed tar stream
may contain at most 1,073,741,824 bytes and at most 100,000 regular-file or
directory members; exceeding either ceiling is `'domain`.

The destination must not exist. The extractor creates a unique
`.ecl-unpack-*` sibling staging directory, creates files exclusively, records
every created path, and removes that staging tree in bounded reverse-order work
on every pre-commit failure or cancellation. Only after the complete archive
has validated and all handles are closed does one same-parent rename publish
the staging tree as the destination. Concurrent calls may perform independent
staging work, but at most one can publish; the others raise `'io` reporting
that the destination exists. An existing destination is never overwritten,
merged, or inspected as though it were a completed cache entry.

A non-list byte container or non-string destination is `'type`. A non-integer
byte item or an integer outside `0..255` is `'domain` carrying its zero-based
`'index`. Missing host I/O, filesystem denial, exclusive-create failure,
staging cleanup failure, and commit failure are `'io` carrying the relevant
`'path`. No failure publishes a partial destination or opens a member path
outside the staging root.

### io

Observable text I/O lives here: `io.pp`, `io.prin`, `io.print`, `io.inspect`,
`io.debug`, `io.stack`, `io.stdin`, `io.slurp`, `io.spit`, and `io.lines`. A qualified
reference or an explicit import such as `'io.print 'print import` makes the
boundary explicit. Core `str` canonically renders any value *as a string
value* without performing I/O.

### csv

`csv.parse` `( string -- rows )` and `csv.emit` `( rows -- string )`,
RFC 4180 and text-preserving. Parsing accepts CRLF or LF record endings,
quoted commas and newlines, and doubled-quote escapes; it preserves empty
fields and record widths and returns every field as a string, with no header
interpretation, delimiter sniffing, or scalar inference. Emission is
canonical CRLF-terminated output quoting exactly the fields that require it.
Empty input is an empty record list. Malformed quoting is `'parse`, non-list
rows and non-string cells are `'type`, and a zero-field row is `'shape`.

### json

`json.parse` `( string -- value )` and `json.emit` `( value -- string )` per
RFC 8259. Integral in-range numbers become ints and everything else numeric
becomes a float; objects become dicts with string keys and arrays become
lists. **`null`, `true`, and `false` become the ordinary symbols `'null`,
`'true`, and `'false`** — data, not language nil and not language booleans,
which is what lets a document round-trip. Emission requires string or symbol
dict keys (`'type` otherwise) and rejects any other symbol.

### table

A table is a validated ordinary column dictionary, never a new runtime kind:
a nonempty insertion-ordered dict whose keys are unique nonempty strings and
whose values are lists sharing one length. Zero rows are legal; zero columns
never. Core reflection stays honest — `type` reports `'dict`, and
`dict.keys`/`at`/`put`/`match?` behave as they do for any dict — so a core
operation can produce an invalid candidate, which the next `table.*` boundary
rejects rather than repairing.

- construction: `from-columns`, `from-rows`, `from-header-rows`,
  `from-records`
- conversion: `rows`, `header-rows` (schema-preserving, zero rows included),
  `records` (necessarily schema-less when empty)
- inspection: `valid?`, `names`, `height`, `column`
- transformation: `cast`, `select`, `rename`, `with-column`, `where`
- analysis: `group-by`, `aggregate`, `inner-join`, `left-join-with`

`table.valid?` answers 0 only for a convention mismatch; cancellation and
allocation failure still propagate. Failures follow the frozen kinds:
non-dicts, non-string names, non-list columns, and invalid masks or spec
members are `'type`; zero-column schemas, unequal column lengths, and
width mismatches are `'shape`; missing, empty, or duplicate names, schema
disagreement, join and rename collisions, and incomplete fills are
`'domain`; an aggregation quotation of the wrong shape is `'contract`.

Joins are stable equijoins on `[left-name right-name]` pairs. Duplicate keys
expand to the full many-to-many product in left-row order and, within one
left row, right-row order. Results carry every left column in its original
order followed by the right non-key columns in right order.
`table.left-join-with` emits one row for an unmatched left row and requires a
fill dict covering exactly every appended right column — it never invents a
value.

### http

Client only. `http.get` `( url headers -- response )`, `http.get-bytes`
`( url headers -- response )`, and `http.post`
`( url headers body -- response )`, with `{}` for no headers, return
`{'status int, 'headers dict, 'body value}`. `get` and `post` materialize
`'body` as a string. `get-bytes` follows the same request, redirect, response-
header, status, and content-decoding rules but materializes the resulting
octets directly as an ordinary integer byte list; it never passes them through
Unicode conversion. "Bytes" here means the representation after HTTP content
decoding, not transfer framing or a compressed wire representation. A refused
connection, TLS failure, unparseable url, or protocol error is `'io` carrying
the url in `'path`; a non-2xx status is an ordinary value, not an error.

A `Session.Host` may carry an optional TLS trust override consisting of an
absolute CA-file path plus a fixed verification timestamp. In that mode the
HTTP client loads only that CA file and verifies at that timestamp; it does not
scan system roots or read the wall clock. A null override preserves system
roots and current-time verification. This is explicit host configuration for
hermetic HTTPS tests, not an ECL value or a process environment switch.

**The request blocks the calling unit's worker thread.** That is the one
documented first-party exception to cooperative scheduling: a `@each`
over N urls at N workers runs at most N concurrent requests, and at one
worker it serializes. v1 imposes no request deadline, so an unresponsive
server occupies its worker until the host gives up. Both change with the
future `Offload` capability without changing this value-level API.

### rng

Threaded generator state over the counter-based kernels, so ordinary code
draws without carrying a `[key counter]` list by hand (see Randomness).
The module's binding holds one state; each word reads it, draws, and
stores the advanced state back.

- `rng.seed` `( key -- )` — rekey and reset the counter. Every later draw
  is a function of this key.
- `rng.int` `( bound -- result )`, `rng.ints` `( count bound -- results )`.
- `rng.float` `( -- result )` — one uniform float in `[0, 1)`.
- `rng.deal` `( count pool -- results )` — `count` distinct values below
  `pool`, drawn without replacement. Selection sampling, so the sample is
  unbiased rather than a filtered sequence of independent draws; `count`
  above `pool` is `'domain`.
- `rng.shuffle` `( values -- values )` — a uniform permutation, defined as
  `deal` over the list's own length.

A fresh process starts from a fixed key, so a program using `rng` and
never calling `rng.seed` is fully reproducible. Seeding from `rand.entropy` is
the explicit opt out.

### Package modules

The package formats are data (see Packages). Eight ordinary source modules
divide value operations and orchestration by responsibility: `pkg.version`,
`pkg.name`, `pkg.data`, `pkg.manifest`, `pkg.lock`, `pkg.mvs`, `pkg.sync`, and
`pkg.cli`. There is no root `pkg` facade. The first six are pure: every word
takes and returns text or values and none reaches a host capability. `pkg.sync`
is the explicit network/filesystem orchestration boundary and composes those
pure modules with `http`, `archive`, and the narrow builtin `pkg.store`
capability. `pkg.cli` is the line-oriented command adapter invoked by `ecl pkg`.

- versions: `pkg.version.less?` `( left right -- bool )`, `pkg.version.max`
  `( versions -- version )`
- manifest: `pkg.manifest.read` `( text -- manifest )`,
  `pkg.manifest.validate` `( candidate -- manifest )`, `pkg.manifest.write`
  `( manifest -- text )`
- lock: `pkg.lock.read` `( text -- lock )`, `pkg.lock.write`
  `( lock -- text )`, `pkg.lock.tree` `( lock -- text )`, and `pkg.lock.why`
  `( lock module -- text )`; `pkg.lock.vendor` `( lock -- lock )` selects the
  one project-local store mode
- resolution: `pkg.mvs.resolve` `( root-manifest manifests -- lock )`
- names: `pkg.name.owns?` `( package-name module-name -- bool )`
- store derivation: `pkg.sync.cache-root` `( -- store-root )`,
  `pkg.sync.store-key` `( package requirement -- key )`,
  `pkg.sync.store-path` `( store package requirement -- path )`,
  `pkg.sync.store-keys` `( lock -- keys )`, and `pkg.sync.store-root`
  `( lock project-root -- store-root )`
- synchronization: `pkg.sync.requirement`
  `( package version url -- requirement )`, `pkg.sync.run`
  `( root-manifest project-root -- lock )`, `pkg.sync.run-offline`
  `( root-manifest project-root -- lock )`, and `pkg.sync.verify`
  `( lock project-root -- count )`
- CLI adapters: `pkg.cli.init`, `add`, `sync`, `sync-offline`, `tree`, `why`,
  `verify`, `vendor`, and `gc`; `src/main.zig` supplies their validated argv
  shapes and the nominal project root where required

The builtin `pkg.store` module exposes only the package mutations ordinary ECL
cannot express safely: `inspect`, `install`, `present?`, `verify`, `read-seal`,
`write-lock`, and `gc`. `read-seal` returns bytes only after package-and-hash
verification. `gc` derives the shared cache root from the Session environment
and accepts store keys rather than a path. The module does not expose raw
directories, handles, generic rename, recursive delete, or a caller-selected
garbage-collection root.

`pkg.manifest.validate` returns its argument unchanged or raises; it is not a
`valid?`-style predicate. Failures follow the frozen kinds and introduce no
user kind: unreadable text is `'parse`; text that is not exactly one form, and
an empty `pkg.version.max` list, are `'shape`; a wrong value kind is `'type`; and
everything inside a legal type but outside the grammar — an undeclared key, an
unsupported `'format`, a malformed name, version, hash, or URL, a
self-requirement, an ownership collision, a word value anywhere — is
`'domain`.

`resolve` returns a lock value directly. It raises the ordinary structured
ECL error on failure; it does not return a `result` envelope. A wrong root or
manifest-catalog container is `'type`. Malformed graph data, a missing
manifest, a hash conflict, a selected-prefix collision, and a requirement
cycle are `'domain`.

## Packages

A project declares its dependencies in `ecl.pkg`, and resolution derives
`ecl.lock` from it. Both files are ECL data: read with `parse` and **never
evaluated**, so resolving a dependency graph cannot run code from a
dependency. Importing stays by qualified name — `'foo.bar.baz 'baz import`
never mentions a file, a URL, or a version — and a checkout plus a lock reproduces the same module
images on any machine.

The `pkg.manifest`, `pkg.lock`, `pkg.version`, and `pkg.name` modules read,
validate, order, and write these values (see The standard library). Those
format operations are pure. `pkg.sync.run` is the explicit network and
filesystem boundary that derives and publishes a lock; ordinary evaluation
reads a lock and never fetches or writes one.

### Versions

A version is a **string**, always:

```
version     :=  core ( "-" prerelease )?
core        :=  num "." num "." num
num         :=  "0" | [1-9] [0-9]*
prerelease  :=  ident ( "." ident )*
ident       :=  [0-9A-Za-z-]+
```

A numeric `ident` — one whose every character is a digit — may not carry a
leading zero. **Build metadata is not in the grammar**: a `+` anywhere makes
the spelling malformed rather than being parsed and discarded.

The string requirement is not a convention. A bare `1.2.3` reads as the
*word* `1.2.3` — an executable reference — so an unquoted version in a
manifest is malformed by construction rather than by rule.

Precedence is Semantic Versioning 2.0.0 §11, and it is a strict total order
over what the grammar admits:

- Compare `major`, then `minor`, then `patch`, numerically.
- On equal cores, a version carrying a prerelease is below the same core
  without one.
- Otherwise compare prereleases identifier by identifier from the left: a
  numeric identifier is below an alphanumeric one, two numeric identifiers
  compare numerically, and two alphanumeric identifiers compare in codepoint
  order — the ordering `cmp` already gives strings.
- When every shared identifier is equal, the shorter prerelease is below the
  longer one.

Anything outside the grammar is an error, not an incomparable value, so there
is no partial order to reason about.

Minimal version selection takes the maximum of *declared* minimums and never
enumerates available versions, so every selected version is one some manifest
wrote down. A prerelease is therefore selected only when it was declared; no
separate rule is needed to prevent it.

### The manifest

`ecl.pkg` holds exactly one dict form. It is found by walking up from the
process working directory toward the filesystem root: the first one found is
the project root, and `ecl.lock` is read from beside it and never from a
different directory. There is no repository-boundary stop and no environment
override. The walk costs one directory probe per level — bounded by depth,
paid once per session — and no `ecl.pkg` anywhere up the chain means there is
no lock at all.

```
{'format 1
 'name "my.proj"
 'version "0.1.0"
 'requires
 {"foo" {'version "1.2.0"
         'url "https://example.com/foo-1.2.0.tar.gz"
         'hash "sha256-<64 lowercase hex digits>"}}}
```

- `'format` is the int 1. An unrecognized value is `'domain` rather than a
  best-effort read: more than one reader consumes these files, so all of them
  must agree on when to stop reading.
- `'name` is this package's canonical name, `'version` is its own version, and
  `'requires` maps a required canonical name to a requirement.
- A requirement is exactly `'version` — the declared *minimum* — plus `'url`
  and `'hash`. The URL must begin `https://`: a tarball over HTTPS is the only
  transport, and a git dependency is a codeload tarball URL.
- Every key is declared. An undeclared key at any level is `'domain`, so a
  misspelling is an error rather than an entry that is silently ignored.
- A requirement may not name the manifest's own `'name`, and no two
  requirement names may stand in the ownership relation below.
- `#` comments are permitted, and nothing that rewrites the file preserves
  them.

**Inertness is a property of the format, not of the reader.** A manifest may
hold ints, floats, chars, symbols, strings, lists, and dicts; a **word** value
anywhere in it is `'domain`. A quotation is an ordinary list and is legal as
data — what is forbidden is the executable reference, which is the thing an
evaluated manifest would run.

### Canonical names and prefix ownership

A canonical package name is one or more segments joined by `.`, each matching
`[a-z] [a-z0-9-]*`. Every package name is therefore a legal module name by
construction.

Package `foo` may publish exactly the modules `foo` and `foo.<rest>` and
nothing else. Ownership continues only across a `.` boundary: `foo` owns
`foo.bar` and does not own `foobar`. With no registry to police publication,
prefix ownership is what polices namespaces instead — and it is what keeps a
lock small enough for prefix matching to be cheap.

### Resolution

`pkg.mvs.resolve` takes a validated root manifest and a catalog of already-read
dependency manifests. The catalog is nested by exact package version:

```
{"foo" {"1.2.0" <foo 1.2.0 manifest>
        "1.5.0" <foo 1.5.0 manifest>}
 "bar" {"2.0.0" <bar 2.0.0 manifest>}}
```

Each outer key is a canonical package name. Each inner key is a version, and
the manifest stored there has that same `'name` and `'version`. The root is
passed separately and does not appear in the lock's `'packages` map.

Resolution implements minimal version selection over the exact
package-version requirement graph. Starting from the root's requirements, it
visits every reachable `(name, version)` node and its requirements. It then
keeps the greatest reachable version of each package name under
`pkg.version.less?`. Catalog entries that no reachable requirement names are not
candidates, are not validated, and cannot affect either the lock or an error.
An active-path repeat is a requirement cycle and is rejected; this is a
deliberate restriction of the otherwise cycle-tolerant MVS graph traversal.

The returned lock uses the format below. `'root` is the root manifest's name.
`'packages` contains one selected requirement value per dependency name.
`'requires` contains the root and every selected package as requirers, each
mapped to the minimum versions in its manifest. Every selected version is at
least every recorded minimum, and the complete value satisfies the same
validation as `pkg.lock.read` and `pkg.lock.write`.

Traversal and diagnostics do not depend on dict insertion order. Requirements
are considered in canonical name/version/requirer order. If equal
name/version declarations have the same hash but different URLs, the
lexicographically least URL is recorded; the content hash, not its mirror, is
the artifact identity. Different hashes for one name/version are a hard
conflict. Selected prefix-collision pairs and conflicting declarations are
reported in package-name order. A cycle reports the sorted distinct package
names in the cycle. When more than one malformed or missing edge exists, the
least edge in canonical order is reported.

Resolver errors use the frozen kinds and carry the following `'data` fields:

- malformed reachable version: exact message `a reachable package version is
  malformed`; fields `'package`, `'required-package`, `'version`
- missing manifest: exact message `pkg.mvs.resolve is missing a declared
  manifest`; fields `'package`, `'required-package`, `'version`
- hash conflict: exact message `one package version has conflicting hashes`;
  fields `'package`, `'version`, `'left-package`, `'left-hash`,
  `'right-package`, `'right-hash`
- selected-prefix collision: exact message `selected packages have overlapping
  prefixes`; fields `'left-package`, `'right-package`
- requirement cycle: exact message `the package requirement graph has a
  cycle`; field `'packages`

Wrong root or catalog containers retain their exact type diagnostics: `a
manifest is a dict` and `pkg.mvs.resolve expects a manifest catalog dict`.
Catalog identity mismatch is `a catalog manifest must match its name and
version keys`. Every graph diagnostic names the responsible package and, where
an edge is responsible, the requiring package and conflicting requirement.

Adding a requirement whose exact node is already reachable and whose minimum
is already met does not change `'packages`. It does change `'requires`, which
records the new declaration under its requirer; selection stability is not a
claim that the whole lock value is byte-identical.

### The lock

`ecl.lock` holds exactly one dict form. It is derived rather than recorded:
deleting it and resolving again reproduces it.

```
{'format 1
 'root "my.proj"
 'packages
 {"bar" {'version "0.3.0" 'url "https://…" 'hash "sha256-…"}
  "foo" {'version "1.2.0" 'url "https://…" 'hash "sha256-…"}}
 'requires
 {"foo" {"bar" "0.3.0"}
  "my.proj" {"foo" "1.2.0"}}}
```

A cache-backed lock has exactly those four keys. A vendored lock adds exactly
`'store 'vendor` between `'root` and `'packages` in canonical output. No other
store value is legal, and the value is a symbol rather than a path: the mode
derives the fixed `<project-root>/vendor` directory, so lock data cannot grant
filesystem authority or escape the discovered project root.

- `'packages` is the selection: one entry per canonical name, carrying the
  selected version and the URL and hash it was declared with.
- `'requires` is keyed by the **requiring** package — the root under its own
  `'name` — and maps each name that package required to the minimum it
  declared. Under minimal version selection every one of those maps agrees
  with `'packages` today. The table is per-package from this first version
  anyway: it is the retrofit door for admitting two versions of one name later
  without a format break.
- The version selected for a name is never below a minimum recorded for that
  name. A lock that violates this is malformed.
- Entries in `'packages`, in `'requires`, and in each inner requirement map
  stand in ascending `cmp` order of their name keys.
- Optional `'store` is exactly the symbol `'vendor`. Absence selects the shared
  cache. No URL, absolute path, relative path, or environment variable may
  appear in this field.

The lock is machine-owned, so comments in it are not preserved and its layout
is canonical rather than free: a newline precedes each top-level key and each
entry of `'packages` and `'requires`, everything below an entry stays on one
line, every scalar is in `str`'s canonical spelling, and the text ends with a
newline because a lock is a file. A reader that ignores
whitespace paired with a writer that is layout-exact is what makes the round
trip a fixed point — reading a canonical lock and writing it back reproduces
its bytes — and it keeps one dependency change a one-line diff.

### Runtime lock tier

Ordinary CLI evaluation opts a Session into project discovery from the
process working directory. Embedders do so explicitly with the borrowed
`Host.project_start` capability; its default is absent, so a library Session
never reads ambient project state merely because its caller happens to run
inside an ECL project. With host filesystem access and a start path, Session
initialization walks upward once, stops at the first `ecl.pkg`, and reads only
the sibling `ecl.lock`. No marker, no sibling lock, no host filesystem access,
or no project-start capability means that the lock tier is absent.

The Session owns one immutable result of that discovery for the complete
lifetime of all its Units. A valid format-1 lock becomes an opaque observation
capability carried in inherited context. A malformed or unreadable sibling
lock is also remembered rather than reread: embedded modules remain usable,
and the first non-embedded lookup reports the invalid project lock as a
structured error before consulting `ECL_PATH`.

Cold module resolution has exactly three tiers:

1. the embedded standard-library manifest;
2. the Session's valid lock, using the longest package name that owns the
   requested dotted module name;
3. `ECL_PATH`, only when no locked package owns the name.

A locked selection names the immutable `<name>-<version>-<hex>` directory
below. A cache lock prefixes that key with the environment-selected shared
cache. A vendored lock prefixes it with the fixed `<project-root>/vendor`
directory and does not consult `ECL_CACHE`, `XDG_CACHE_HOME`, or `HOME`. The
source candidate inside that directory is the requested module's **full
canonical name** plus `.ecl`: package `foo` resolves module `foo.bar` at
`foo.bar.ecl`, never `bar.ecl`. This is the same root-level layout accepted by
package inspection and installation.

Package ownership is authoritative. Once a lock prefix matches, a missing
store directory reports the package and tells the user to run `ecl pkg sync`;
a present store entry missing the requested source reports both module and
package. Neither failure falls through to `ECL_PATH`. Runtime resolution never
calls HTTP or TLS, fetches or installs an artifact, writes the lock, or admits
an `.eclmod` package candidate. Synchronization remains the only network and
package-mutation boundary.

Runtime lock-resolution diagnostics have exact stable message templates:

- absent selected entry: “locked package `<package>` is missing from the
  package store; run `ecl pkg sync`”;
- cache store unavailable: “locked package `<package>` has no package store;
  set ECL_CACHE, XDG_CACHE_HOME, or HOME before running `ecl pkg sync`”;
- failed selected-entry probe: “cannot inspect locked package `<package>` in
  the package store: `<host-error>`; run `ecl pkg sync`”;
- selected path is not a real directory: “locked package `<package>` is not a
  real package-store directory; run `ecl pkg sync`”;
- source absent within a present selected entry: “locked module `<module>` is
  absent from package `<package>`”.

The package and module placeholders are the canonical names from the validated
lock and the original qualified request. The first four are `'io`; the last
is `'undefined-word`. Invalid lock discovery is also `'io` and prefixes its
owned detail with “invalid project lock `<path>`:”. None falls through to
`ECL_PATH`.

The lock snapshot is immutable across concurrent Units. `AutoLoadDriver`
acquires the existing loading lease and rechecks for a racing winner before it
starts the bounded longest-prefix cursor. Lock scanning, candidate
construction, and filesystem transfer remain poll-budgeted, and all state
held across polls carries explicit heap ownership. Thus locked loading keeps
the existing cycle detection, single-publication, and scheduler arbitration
protocol rather than adding a parallel loader.

### Hashes and the store

A hash is the literal `sha256-` followed by exactly 64 lowercase hex digits.
The store entry for a selection is the directory named
`<name>-<version>-<hex>`, where `<hex>` is those digits without the prefix —
the same `name-version-hash` shape a content-addressed package cache
conventionally uses. A hash mismatch is a hard failure and never a warning: a
moved tag changes the content hash and fails rather than silently changing
what a build means.

The store root is selected from the Session's immutable environment snapshot,
never by reading the ambient process environment during evaluation:

1. a present, nonempty `ECL_CACHE` is the complete store root;
2. otherwise a present, nonempty `XDG_CACHE_HOME` selects
   `$XDG_CACHE_HOME/ecl/pkg`;
3. otherwise a present, nonempty `HOME` selects `$HOME/.cache/ecl/pkg`;
4. if all three are absent or empty, synchronization fails with `'io` before
   creating a path.

An empty variable is treated as absent; it never names the current directory.
Each canonical store-key path is immutable. `pkg.store.present?`
`( destination -- bool )` returns 0 only when the path is absent and 1 only
for a real directory. A symlink, non-directory node, access denial, or other
probe failure is `'io` carrying `'path`. A present entry is read locally and
is never re-fetched or overwritten by sync.

### Vendoring and cache collection

`ecl pkg vendor` requires a discovered project and a valid lock. For each
selection it derives the source root from that lock, streams and rehashes the
entry's reserved `.ecl-package.tgz`, and passes the resulting exact byte list
through the ordinary package installer at
`<project-root>/vendor/<store-key>`. An already-present vendor entry is
verified and never overwritten. Only after every selected vendor entry is
present does the command atomically rewrite the lock with `'store 'vendor`.
Failure preserves the prior lock; a partially completed run may leave valid
immutable vendor entries for the next run to reuse. Repeating the command is
idempotent. A vendored lock makes ordinary resolution and `ecl pkg verify`
independent of the network and shared cache.

`ecl pkg gc <lock-file> [lock-file ...]` requires at least one explicitly
named lock. It parses every file without evaluation, unions their canonical
selected store keys, and invokes `pkg.store.gc` with keys rather than a path.
The builtin derives the shared cache root from the same captured environment
precedence above. It preserves every retained key, symlink, non-directory, and
unknown child name. A real directory whose basename is a canonical store key
and is absent from the union is renamed within the cache to a private
`.ecl-gc-*` name, then walked and deleted one entry per bounded scheduler
advance without following links. Interrupted private names are recognized and
finished by the next collection. The reported count is the number of live
store entries detached during this invocation, not recovered private names.

### Package archives

A package artifact is one gzip-compressed tar byte list whose normalized
members obey M3's archive limits and hostile-input rules plus all of these
package rules:

- exactly one regular file named `ecl.pkg` occurs at the archive root;
- `ecl.pkg` is valid UTF-8 and parses as a format-1 manifest;
- directories and ordinary package-data files are permitted, but links and
  special nodes remain forbidden by the archive contract;
- a file ending in `.eclmod` anywhere is forbidden because v1 packages are
  source-only;
- every file ending in `.ecl` is at the archive root, its filename stem is a
  canonical module name, and `pkg.name.owns?` accepts the manifest package
  name and that stem.

Thus package `foo` may contain `foo.ecl` and `foo.bar.ecl`, never `bar.ecl` or
`nested/foo.ecl`. Installation never evaluates a manifest or package source.

`pkg.store.inspect` `( bytes package-name -- manifest-text )` performs the
complete bounded gzip/tar and package-layout scan without creating a
destination. It returns the sole root manifest's exact UTF-8 text. The caller
parses that text with `pkg.manifest.read` and checks its exact name/version
identity before any installation.

`pkg.store.install`
`( bytes package-name destination -- regular-file-paths )` repeats the same
archive and package-policy validation at the mutation sink, then extracts to a
unique sibling staging directory and publishes only by an absent-destination
rename. It returns normalized regular-file paths only after commit. The
destination is never overwritten or merged. Concurrent installers may both
stage, but at most one publishes. Both the pre-flight and commit conflict
return `'io` with `'destination-exists 1` in error data; a caller may re-run
`present?` and accept the immutable winner only for that condition. Cancellation,
allocation failure, malformed input, and filesystem failure remove private
staging and expose no partial destination.

`pkg.store.verify` `( destination package-name hash -- )` streams the reserved
archive seal and requires its SHA-256 to equal the lock hash.
`pkg.store.read-seal` `( destination package-name hash -- bytes )` performs
the identical package-named verification and then materializes the exact seal
as an ordinary integer byte list. It is the only filesystem-to-archive-byte
bridge and exists so vendoring can reuse `pkg.store.install`; it cannot read an
arbitrary file beneath the entry.

`pkg.store.write-lock` `( text path -- )` writes through a unique sibling
temporary file and replaces the named regular file with one same-parent atomic
rename. Encoding and writes are bounded scheduler work. On cancellation,
allocation failure, or filesystem failure the temporary is removed and an
existing lock remains byte-for-byte unchanged; when no lock existed, none is
published. A symlink or non-regular existing target is refused rather than
followed.

`pkg.store.write-new` `( text path -- )` uses the same bounded temporary-file
protocol but publishes with a non-replacing same-parent rename. It is the
manifest-creation boundary: a destination created after the initial probe wins
the race, the temporary is retired, and the existing bytes are untouched. Its
diagnostics name the supplied project-file path rather than assuming a
particular filename.

The eight `pkg.store` words documented here are the complete package
filesystem authority. ECL receives no generic recursive-delete, copy, rename,
or caller-rooted garbage-collection word as a side effect of package support.

### Synchronization

`pkg.sync.run` `( root-manifest project-root -- lock )` validates its root and
uses `project-root` only to place `ecl.lock`; walking upward to discover the
root belongs to the CLI layer. It executes two deterministic passes.

The discovery pass walks exact `(name, version)` requirements in canonical
order and builds the complete catalog required by `pkg.mvs.resolve`. For each
node it derives the store key from the declaration's name, version, and hash:

- when that exact entry is present, it reads `<entry>/ecl.pkg`, validates the
  manifest, and requires its name and version to equal the requested node;
- otherwise it calls `http.get-bytes`, requires status in `200..299`, computes
  `sha256-` plus `archive.sha256` of the returned body, and compares that value
  with the declaration **before** calling `pkg.store.inspect`;
- after a matching hash, it inspects and parses the archive manifest, requires
  exact name/version identity, inserts the exact node into the catalog, and
  traverses its requirements.

A non-success HTTP response is `'io` carrying `'package`, `'url`, and
`'status`. A hash mismatch is `'domain` carrying `'package`,
`'declared-hash`, and `'actual-hash`. A manifest identity mismatch is
`'domain` carrying the requested and actual names and versions. Archive-policy
errors additionally carry the package and offending member when one exists.
None of these discovery failures calls install or lock publication.

After `pkg.mvs.resolve` returns a validated lock, the installation pass visits
the selected package names in canonical order. It skips a present entry.
Every missing selection is fetched again, status-checked, hashed, inspected,
identity-checked, and passed to `pkg.store.install`; the repeated verification
keeps the publication sink independent of discovery state. A racing
destination-exists result is success only when `present?` immediately confirms
a real immutable directory.

The two passes are deliberate. MVS needs manifests from reachable exact
versions it may not select, while the store contains only selected versions.
Re-fetching a selected cold artifact bounds retained archive memory to one
body and avoids adding a temporary spool plus deletion authority. On a later
sync every exact node already present is read locally and never re-fetched,
but an absent reachable candidate that remains unselected may be fetched again
because its manifest can still contribute graph edges. Fully offline
resolution is the separate `sync --offline` contract.

Before discovery, sync reads only `<project-root>/ecl.lock`, where
`project-root` is its explicit argument. A valid vendored lock selects that
same project's fixed `vendor` store and retains `'store 'vendor` on the
resolved lock. An absent or invalid current lock selects cache mode, preserving
sync as the supported way to regenerate corrupt lock bytes. Ambient Session
project discovery never selects the synchronization target or its mode.

Only after every selected entry is present does sync render the lock once with
`pkg.lock.write` and call `pkg.store.write-lock` for
`<project-root>/ecl.lock`. It then returns the validated lock value. Deleting
that lock and running sync against unchanged inputs reproduces its bytes.
Failure preserves a prior lock and publishes no new lock. Verified immutable
entries successfully installed before a later failure may remain: the lock is
the project transaction boundary, while content-addressed cache population is
safe and reusable.

### Package CLI

`ecl pkg` is a fixed CLI dispatcher over the ordinary `pkg.*` modules. It does
not parse manifests, resolve graphs, hash archives, or render locks in Zig.
Every command other than `init` uses the same upward `ecl.pkg` discovery seam
as Session startup. `init` acts only on the working directory and refuses to
replace an existing manifest.

- `init [name]` derives the package name from the working-directory basename
  when omitted, accepts an explicit canonical override, and atomically creates
  a format-1 manifest at version `0.1.0` without replacing a racing file. An
  invalid name diagnostic carries both the attempted name and project path and
  explains the override form.
- `add <name> <version> <url>` downloads and validates that exact package,
  derives its `sha256-` declaration, and raises the root minimum to the given
  version through an atomic manifest replacement. The manifest dictionary's
  insertion order is retained. Comments cannot survive a rewrite because
  `pkg.manifest.read` deliberately returns inert values rather than a concrete
  syntax tree.
- `sync` performs ordinary synchronization. `sync --offline` discovers every
  exact manifest from immutable store entries and never opens a network
  request; an absent entry is an error naming the package.
- `tree` prints the lock root followed by dependency edges ordered first by
  requirer and then by required package. `why <module>` applies the same
  package-prefix ownership rule as runtime lookup and prints one deterministic
  root-to-owner path.
- `verify` streams the sealed archive retained inside every selected immutable
  store entry and compares its SHA-256 with the lock declaration. It never
  reaches the network. Missing seals and mismatches identify the package.

Successful command output is stable, line-oriented text. Usage failures are
ordinary CLI diagnostics; package and I/O failures remain structured ECL error
values rendered by the existing process boundary.

## Errors

Errors are crash-only. There is no try/catch and no handler quotation: an
error propagates until the enclosing unit dies, and the transactional
stack makes that death clean. Failure is observed from outside, as data,
at one explicit boundary word: `@attempt` (and its concurrent form,
`@spawn`/`await`). The REPL is the implicit top-level boundary; a script's
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

A completion-time source-word effect violation reports the opening delimiter
of the deepest reader-built quotation selected by ordinary tail control in
that checked activation. The checked body is the initial location, so a word
with no such selection still points to its body. An empty quotation points to
its opening `(`; it does not need a first token. Non-tail helper calls and
isolated or inline application iterations do not replace this location, so an
element quotation is not mistaken for a source branch and iteration cost does
not acquire provenance allocation or reference-count traffic per element.
This does not hide an application's own contract failure. Within one
application, dynamically applied tail-control quotations replace that
application's location. A guard predicate is disposable observation and does
not replace the enclosing selection; after restoration, the selected `cond`
action or true `while` body replaces it at the preserved boundary, and tail
control inside that action may refine it further. A new iteration starts a
fresh boundary. The error reports the deepest such quotation's opening
delimiter and preserves its element index, falling back to the application
quotation when no dynamic selection occurred. If the selected tail or failing
application quotation was assembled at runtime, all three source fields remain
absent rather than falling back to a less-specific or invented position.

Resolving those source fields is strict O(1) in the number of sources archived
after the selected quotation and in pointer-hash collisions. Diagnostic
materialization uses the selected code header's direct session identity; it
does not scan session history to discover which span table owns the header.
That identity is session-local: the archive also verifies exact header
membership and the archive-owned construction namespace before reading the
indexed entry. Only the archive's opaque issuer can assign an identity to a
header built in that namespace; a generic heap owner supplies no such
authority. Absorption validates all candidate headers before reserving or
assigning identities and rejects a namespace mismatch without consuming its
inputs. Once validation and fallible index-page allocation complete, the
archive adopts the root and source record before exposing any index slot; a
cancelled partial assignment therefore retains stable location storage, and
teardown reports whether the caller or archive owns the artifacts. A quotation
transferred from a different Session therefore has no
source fields when merely looked up in the receiving Session, even when its
numeric identity collides with a local quotation; attempting to publish that
foreign construction into the receiving archive is an invariant error.

The core kinds are a closed set: `'underflow`, `'undefined-word`, `'type`,
`'shape`, `'conform`, `'overflow`, `'domain`, `'contract`, `'parse`,
`'io`, `'cancelled`, `'timeout`, `'user`. User kinds are any other symbol.
`raise` throws a dict; `fail` is sugar for raising
`{'kind 'user 'msg msg}`.

`(q) @attempt` runs a self-contained quotation as a new unit on an isolated
substack and always pushes exactly one result value: `{'ok (values)}`
or `{'err <error dict>}`. Uniform arity is what makes reified failure safe
in a stack language: a failure never shares a stack with the code
observing it. A result is an ordinary dict, so raw `at`/`has?` reach into
it directly; the named vocabulary that validates the envelope first —
`result.ok?`, `result.or-raise`, `result.or-else` and the rest — is the
`result` module (see The standard library). Errors are plain immutable data
and cross task boundaries unchanged.

## Concurrency

Concurrency is structured tasks — futures with enforced lifetime — over
share-nothing units. Immutability makes sharing safe without copying.

- `@spawn` `( unit-input -- task )` runs a quotation, or a plan's body seeded
  by its values (the `@attempt` contract: an unseeded quotation takes its inputs
  via `seed`/`partial`/environment, never the ambient stack), on its own
  isolated substack, concurrently.
- `await` `( task -- result )` parks the current unit until the task
  completes and delivers the same `{'ok …}`/`{'err …}` result shape as
  `@attempt`. It is idempotent — the result is cached — so task handles
  are observationally value-like. **`@attempt` is observationally
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
- `@each` `( l q -- l' )` applies the quotation to every element
  concurrently, enforcing exactly one result per element, and returns
  results in input order. After the leftmost failure it cancels the
  remaining elements, waits for quiescence, and re-raises that failure —
  parallel failure is deterministic. Elements are guaranteed no
  cross-element rendezvous: they may run fully serially, so a program
  whose elements must run concurrently to make progress is incorrect.

**Structured lifetime.** A dying unit cancels its unawaited tasks — "a
failed unit leaves nothing" extends to processes. Dropped handles are
cancelled at scope end; there are no detached daemons. The session is the
root scope. `tasks` lists pending descendant tasks in `@spawn` preorder.

**Determinism.** Await order is program order, so `await-all` results and
`@each`'s leftmost-error rule are schedule-invariant. Nondeterminism
enters only where chosen (`await-any`) and in IO interleaving across
concurrent tasks; within one task IO is ordered. Sequential combinators
(`each`, `for`, `fold`) guarantee left-to-right order, so IO inside them
is well-defined.

**Process exit.** `exit` belongs to the root unit outside `@attempt`: a
call from a descendant task or inside `@attempt` raises a catchable
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
- `io.pp` and the REPL stack display are best-effort human layout: the same
  delimiters and atom spellings, with the rows of rectangular matrices
  (and one enclosing group axis) separated by newline-plus-indentation.
  Their output carries no round-trip guarantee. A specialized numeric or
  symbol list longer than 256 elements displays as `[<N-values-elided>]`; a
  generic list does so as `(<N-values-elided>)`; and a character list longer
  than 256 elements displays as `"<N-characters-elided>"`. Elision happens
  before matrix-shape scanning or child rendering, keeping ordinary terminal
  probes bounded. Only `str` is canonical and never elides.
- In display layout, a dictionary stays compact when it is a small scalar
  record. A dictionary with more than three pairs, a nested dictionary, or a
  matrix-valued key or value prints one pair per indented line. Nested
  dictionaries apply the same rule recursively. Flat vector fields stay
  compact. Canonical `str` output is always compact and unaffected by this
  display choice.
- `io.stack` uses that same per-value display layout but prints each visible
  stack slot as its own bottom-up indexed block: `[0]` is the bottom of the
  visible operand window and the largest index is its top. Continuation lines
  align after the index prefix. This vertical diagnostic layout is distinct
  from the denser side-by-side REPL display.
- The stack display keeps stack order left to right whatever a value's
  height. Each value occupies the rectangle its own layout needs, and the
  rectangles sit side by side sharing a bottom row, so a matrix grows the
  display upward instead of stacking its neighbours vertically. Padding is
  counted in bytes, matching the column arithmetic of the row breaks above,
  and no row is padded past its last value. The display is not wrapped to
  the terminal: width is a measured fact the display has no access to.
- Dictionaries preserve insertion order in both compact and multiline display.

Printing at unit end: script files and `load` print only explicitly
(`io.pp`/`io.prin`); `-e`, stdin, and calculator invocations print the final
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
  preceding a body and `'name def`/`defp` is refilled paragraph-aware (semantics
  unchanged — `doc` canonicalization already ignores soft wrapping).
- Every structurally literal definition block is introduced by a navigation
  comment: `### def <name>` for `def`/`set`, and `### defp <name>` for
  `defp`/`setp`. It is preceded by exactly one empty line (omitted at the start
  of a file or container).
  Existing `# def`/`### def`/`# defp`/`### defp` comments are canonicalized
  from the structural terminator rather than trusted; recognition is purely
  structural — never evaluation — and is disabled for words directly
  contained by dict literals.
