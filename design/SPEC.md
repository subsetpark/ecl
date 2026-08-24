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
`'float`, `'char`, `'symbol`, `'word`, `'list`, `'dict`, or `'task`.
There is no public module-handle value kind.

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
unit it makes. `@attempt`, `@spawn`, `@module`, and `@defm` seed nothing, so
their quotations must be self-contained: their effect is `( -- ... )` and
inputs arrive via `literal`/`partial`/`compose`/`with` or environment
names, never the ambient stack. `@each` seeds each child with exactly its
element. `register` is not marked: it publishes an already-constructed
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

`@` is an ordinary word character, not reader-reserved: a user's `@retry`
lexes and defines normally. The convention is enforced for first-party
vocabulary by the source audit and is the recommended spelling for any
user-defined word that wraps its quotation in a unit.

#### Seeding a unit

There are no `-with` words. A unit constructor is seeded by composition
over `with`, which captures every element of a values list inertly and in
order:

    values (q) with @attempt
    values (q) with @spawn
    list values (q) with @each          ( element deepest in each child )
    values (body) with @module
    values (body) with 'name @defm

One composition scales to every unit constructor, including ones users
write, with no companion-word obligation. Any future phrase-level fast
path for these idioms must preserve the composition observationally.

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
it. `rand-int`, `rand-ints`, and `rand-float` each take a state and
return the advanced state alongside the result, so a program's draws are
reproducible by construction — running it twice from the same key
produces the same values, and nothing hidden accumulates between units,
tasks, or module loads.

- The mixer is SplitMix64 applied to `key + counter * gamma`. Each draw
  addresses its own counter position rather than stepping a register, so
  `rand-ints` produces the same list whatever order its elements are
  materialized in, and two states that share a key but differ in counter
  do not correlate.
- `entropy` is the only word that reads the host, and the only
  nondeterministic word in the language. A program is reproducible unless
  it explicitly seeds from `entropy`; there is no ambient default seed
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
- `values (body) with @module` and `values (body) with 'name @defm` capture
  every value inertly and in order before running the same isolated
  construction. The values form the body unit's initial stack; the body may
  consume, reorder, or extend them.
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
  diagnostic spelling, and `which` all follow the invoking registration. An
  exported word's body resolves against its module's internal environment and
  then core — never the caller's environment. Publics therefore reach
  privates, and callers cannot perturb a module's behavior by shadowing.
  A module word's body is still a plain list: `'stats.stdev body` is data,
  and re-`def`ing that list elsewhere loses the private context.
  The rule has no exceptions. A binding with no module home — a primitive
  or an embedded prelude definition — resolves against the lexical chain it
  was defined in, the session root over core, and not against whatever
  environment happens to be executing. So a module exporting a word named
  like a core one shadows it for that module's own callers, never inside the
  prelude words the module calls: `table.where` does not become the `where`
  that `filter` is written against. Late binding is unaffected — the lookup
  still happens at call time, which is why redefining `cons` at the session
  level still changes `wrap`.
- **A quotation resolves where its invoker runs, because a quotation is
  plain data.** Passing a quotation into a combinator therefore keeps the
  caller's chain: a module word may hand `(private-helper)` to `each` and
  the private still resolves. What a word *defines* — `def`, `set`, `setp` —
  also lands in the invoking context, which is how `setp` inside a module
  body binds a module private. Only a word's own references are lexical.
- **`within` is the explicit stack boundary.** `within` runs a quotation
  against a private draft of the home module's durable stack rather than
  the ambient caller stack. It is legal only while executing a published
  word whose definition-site home is a live module: session top level, a
  construction root (an image being built has no registration, and its body
  operates on its construction stack directly),
  and a body extracted and redefined elsewhere are all `'domain`. There is
  no module-handle-targeted form. Inputs cross the boundary only because
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
  then publishes exactly that one binding in the current environment. The
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
  execution, `body`, `doc`, `see`, `which`, and qualified completion do not
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

Sixteen modules ship inside the binary. They are ordinary modules — registered,
enumerable, shadowable — and they load lazily on the first qualified mention of
their name, whether that is a bare `str.upper` or `'str.upper 'upper import`. Resolution consults
the embedded manifest before `ECL_PATH`, so a stray `csv.ecl` on the search
path cannot silently replace a stdlib name; in-session shadowing and explicit
`@defm` registration remain the documented overrides. All sixteen resolve with no
`ECL_PATH` set and no filesystem access at all.

Three transports back them, chosen per module rather than uniformly:
embedded ECL source (`error`, `result`, `str`, `table`, `rng`, and the six `pkg.*` modules), a linked first-party
native descriptor published through the same contract as an external
extension (`csv`), and builtin word tables published under a module name
(`io`, `json`, `http`, `archive`).
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
  stack through `with @attempt`; an existing failure is returned unchanged.
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
`keys`/`at`/`put`/`match?` behave as they do for any dict — so a core
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
never calling `rng.seed` is fully reproducible. Seeding from `entropy` is
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
- failed selected-entry probe: “cannot inspect locked package `<package>` in
  the package store: `<host-error>`; run `ecl pkg sync`”;
- selected path is not a real directory: “locked package `<package>` is not a
  real package-store directory; run `ecl pkg sync`”;
- source absent within a present selected entry: “locked module `<module>` is
  absent from package `<package>`”.

The package and module placeholders are the canonical names from the validated
lock and the original qualified request. The first three are `'io`; the last
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
stage, but at most one publishes; after a destination-exists result, a caller
may re-run `present?` and accept the immutable winner. Cancellation,
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

The seven `pkg.store` words documented below are the complete package
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

- `init` derives a canonical package name from the working-directory basename
  and creates a format-1 manifest at version `0.1.0`.
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

- `@spawn` `( q -- task )` runs a self-contained quotation (the `@attempt`
  contract: inputs via `partial`/environment, never the ambient stack) on
  its own isolated substack, concurrently.
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

---

# Word reference

Every public binding below ships in the core image or embedded standard
library, one entry per word. Prelude and core come first; standard-library
modules then appear by module name, with each section's words ordered by
codepoint — the language's own string ordering (`cmp`) — so symbol-spelled
words precede letter-spelled ones. An entry gives the
word's stack effect as declared in the implementation — `doc` and `see`
return the same effect and documentation — followed by its semantics.
Conventions:

- Words marked **pervasive** follow the Pervasion section.
- "Equivalent to `…`" names a word defined in ecl itself; the definition
  is normative and `body` returns it.
- Words applying quotations are marked *inline* or *unit constructor*
  (see Application contexts); a unit constructor states the contract
  required of its quotation, enforced at each application.
- An effect ending in `...` declares a fixed before row and a variable
  after row (see Definition annotations) and is the word's real declared
  effect. A typographic `…` *inside* an effect is an informal picture, not
  a declaration.
- Indexing is 0-based throughout: `range` counts from 0, `at` indexes
  from 0, `where` and `grade` produce 0-based indices, and `find` returns
  the length on a miss.
- Booleans are the ints 0 and 1; a word requiring a boolean rejects every
  other value.
- Predicate words end in `?`. Symbolic comparisons (`=`, `<>`, `<`, `<=`,
  `>`, `>=`) and the boolean combinators `and`, `or`, and `not` keep their
  conventional spellings.

## Prelude and core

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
across int and float. Whole-value equality is `match?`.

### >
`( x y -- bool )` — **Pervasive.** Descending comparison, producing 0/1
masks.

### >=
`( x y -- bool )` — **Pervasive.** Greater-than-or-equal. Equivalent to
`< not`.

### @attempt
`( quotation -- result )` — *Unit constructor.* Run a self-contained
quotation (contract `( -- ... )`; inputs via `literal`/`partial`/`with`)
as a new unit on an isolated substack. Always pushes exactly one result:
`{'ok (values)}` with the successful stack values as a list, or
`{'err <error dict>}`.

Observationally `@spawn await` — same result shape, same error protocol,
same self-contained-quotation contract — differing only in scheduling.
That identity is what makes the isolation non-arbitrary rather than an
implementation accident. Seed it with `values (q) with @attempt`. See
Errors.

### @defm
`( body 'module-name -- )` — *Unit constructor.* Exactly `@module` followed
by `register`: run the body on a fresh environment, then validate the
canonical module path and register the resulting image under it. The body is
evaluated before the name is validated, so the two spellings agree on every
observable outcome.

The name is last, matching `def` and `set`: the bound name sits nearest
the binder. Seeded registration is therefore `values (body) with 'name
@defm`, with the name riding above the composition and no shuffle at
all. See Modules.

### @each
`( sequence quotation -- results )` — *Unit constructor*, one fresh unit
per element, contract `( a -- b )` enforced per element. Concurrent
`each`: ordered results, leftmost failure re-raised after cancelling and
quiescing the remainder. Each child's stack is seeded with exactly its
element; `list values (q) with @each` adds shared values beneath it. See
Concurrency.

### @module
`( body -- module )` — *Unit constructor.* Run the body on a fresh
environment and return the resulting anonymous immutable module image. No
registry name is claimed and no name is validated. The body's final operand
stack becomes the image's initial-state template. Seed it with `values (body)
with @module`. See Modules.

### @spawn
`( quotation -- task )` — *Unit constructor*, contract `( -- ... )`
(inputs via `partial`/`with`, never the ambient stack). Run a
self-contained quotation concurrently in a child task. Seed it with
`values (q) with @spawn`. See Concurrency.

### abs
`( x -- y )` — **Pervasive.** Absolute value. Defined in ecl (see
`'abs body`).

### alias
`( 'short 'module-name -- )` — Register an unqualified short registry name
for a canonical, possibly dotted module name.
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

### assert
`( bool error -- )` — Raise an error dict unless the condition is the boolean
1, discarding the dict when it holds. Defined in ecl.

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

### band
`( x y -- z )` — **Pervasive.** Bitwise and over the two's-complement bit
patterns of ints. Non-int leaves are `'type`.

### bi
`( x p q -- ... )` — *Inline.* Apply two quotations to the same input,
first `p`, then `q`. Equivalent to `(keep) dip call`.

### bi2
`( x y p q -- ... )` — *Inline.* Binary cleave: apply each of two
quotations to the same pair of inputs. Equivalent to
`(|x y p q| x y p call x y q call)`.

### bnot
`( x -- y )` — **Pervasive.** Invert every bit. `bnot bnot` is identity;
`0 bnot` is `-1`.

### body
`( 'name -- quotation )` — Return the stored body of a resolved word, as
a plain list. Total over everything defined in ecl, constants included: a
name bound by `set` returns its capture body `((value) first)`. Host
builtins and native words have no ecl body and are `'type`.

### bor
`( x y -- z )` — **Pervasive.** Bitwise or. See `band`.

### both
`( x y q -- ... )` — *Inline.* Apply one quotation independently to two
values, `x` first. Equivalent to `(|x y q| x q call y q call)`.

### bsl
`( x count -- y )` — **Pervasive.** Shift the bit pattern left by `count`
places, truncating bits shifted off the top rather than raising
`'overflow`: `maxint 1 bsl` is `-2`. A `count` outside `0..63` is
`'domain`.

### bsr
`( x count -- y )` — **Pervasive.** Shift the bit pattern right by
`count` places, filling zeros from the top. The shift is logical, not
arithmetic: `-1 1 bsr` is `maxint`, not `-1`. A `count` outside `0..63`
is `'domain`.

### bxor
`( x y -- z )` — **Pervasive.** Bitwise exclusive or. On 0/1 masks `<>`
does the same job on any leaf type; `bxor` is for whole patterns.

### call
`( q -- ... )` — *Inline.* Run a quotation on the current stack. A data
list pushes its elements.

### cancel
`( task -- )` — Request cancellation; the task's result becomes
`{'err {'kind 'cancelled …}}`. No-op when already terminal.

### case
`( x clauses -- ... )` — *Inline.* The clause list is flat, nonempty, and
odd: `[key action … else]`. Keys are inert data — any value, never
executed, duplicates legal with the first `match?` result of 1 winning;
every action and the else must be a quotation, validated before any
comparison. The first key for which `match?` returns 1 selects its action.
Defined in ecl (see `'case body`).

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
**not** pervasive — `cmp` is to `<` what `match?` is to `=`. Domain:
numbers (exact across int/float), chars by codepoint, strings
codepoint-lexicographic; anything else, including cross-kind pairs, is
`'type`. `cmp` exists because the subtraction idiom is unsafe for
ordering: `-` errors on int64 overflow where an ordering must be total.

### compose
`( left right -- quotation )` — Concatenate two quotations in execution
order.

### cond
`( clauses -- ... )` — *Inline.* The clause list is flat, nonempty, and
odd: `[test action … else]`, all quotations. The whole list is validated
before the first test runs (empty or even lists are `'shape`; a non-list
or non-quotation member is `'type`). Every test runs against the operand
stack checkpoint taken after the clause list is consumed. Tests may inspect
that stack destructively; only their top result is interpreted, and it must
be a 0/1 boolean. The complete test result is then discarded. The first true
test selects its action; otherwise the final else runs, in either case from
the original checkpoint. Stack rollback does not roll back environment or IO
effects performed by tests.

### cons
`( value list -- list )` — Raw structural prepend. On data,
`1 [2 3] cons` is `[1 2 3]`. On code it inserts a form: a prepended word
executes when the result is called, so `cons` is not safe partial
application — that is `partial`.

### converge
`( value quotation -- value )` — *Isolated*, unary contract `( a -- a )`.
Return the last value before repeated application reaches a fixed point or
returns to the initial value. Equivalent to `converges last`.

### converges
`( value quotation -- list )` — *Isolated*, unary contract `( a -- a )`.
Return the initial value and successive applications until the next value
is structurally equal to either the initial or immediately preceding value;
the repeated boundary value is not appended. Defined in ecl over `unfold`.

### cos
`( x -- y )` — **Pervasive.** Cosine; float transcendental.

### def
`( annotation? body 'name -- )` — Bind a quotation to a public word, with
optional effect and documentation metadata. See Definition annotations
for the annotation forms and validation; see Modules for module-context
requirements.

### defp
`( annotation? body 'name -- )` — Bind a private module word, with
optional effect and documentation metadata. A top-level `defp` is an
error.

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

### each-prior
`( list seed quotation -- list )` — *Isolated*, contract
`( current prior -- result )`. Apply left-to-right, using the explicit seed
as the predecessor of the first element. Thus
`[12 13 11] 10 (-) each-prior` is `[2 1 -2]`. Defined in ecl over
`zip-with`.

### empty?
`( sequence -- bool )` — 1 when the sequence has no elements. Equivalent
to `len 0 =`.

### entropy
`( -- result )` — Read one int of entropy from the host. The only
nondeterministic word in the language; see Randomness. Requires the host
IO capability, and is `'io` without it.

### execute
`( word -- ... )` — Resolve and apply a word value late through the ordinary
word-dispatch path, exactly as if that word appeared in executable position.
Non-words are `'type`; missing words are `'undefined-word`. Module homes,
private resolution, annotations, tracing, builtins, native calls,
cancellation, and `within` authority are preserved.

### exit
`( status -- )` — Root-only outside `@attempt` (`'domain` otherwise):
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
returns 1 from `match?` against the needle, or the sequence length on a
miss. Defined in ecl.

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

### fold1
`( list quotation -- value )` — *Isolated*, contract `( acc a -- acc )`.
Reduce a nonempty list left-to-right from its first element. The explicit
accumulator form `fold` is required for an empty list. Defined in ecl.

### for
`( list quotation -- )` — *Isolated*, contract `( a -- )`. The ordered
effect loop: left-to-right, collects nothing.

### format
`( values template -- string )` — Interpolate a list of values into the
template's `{}` positional placeholders. A string contributes its contents;
every other value contributes its canonical `str`. `{{` and `}}` are literal
braces. `["Ada" 2] "name={} n={}" format` is `"name=Ada n=2"`. Apply
`str` explicitly before `format` when a string's quoted source representation
is wanted.

### getenv
`( name -- string )` — The value of an environment variable, read from an
immutable snapshot taken once at session start. An unset variable is an
error, never a blank: absence is absence, and `@attempt`/`or-else` is the
defaulting idiom. Absent host IO is `'io`.

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
`( bool then else -- ... )` — *Inline.* Run `then` when the condition is 1,
`else` when it is 0; any other condition value is `'type`.

### in?
`( value list -- bool )` — Membership. Pervades over the sought value —
the left operand, never the list — down to its atoms; each atom is then
tested by whole-value `match?` against the list's top-level elements, so
the result takes the sought value's shape: `[2 5] [1 2 3] in?` is
`[1 0]`. The list is only ever read one level deep, and a list operand
is decomposed before any comparison, so `in?` cannot ask whether a
sublist is an element: `[1 1] [[0 0] [1 1]] in?` is `[0 0]`, two atom
searches, not a `0` answer about `[1 1]`. Use `([1 1] match?) any?` for
that.

### import
`( 'original 'binding -- )` — Bind one qualified module word under an
unqualified local name: `'str.upper 'upper import` makes `upper` mean `str.upper`. The
binding dispatches through the module, so an imported word resolves against its
own home exactly as the qualified spelling does. Shadowing an existing binding
is allowed — it is the documented way to patch one — but it takes naming the
word, so it cannot happen by accident. The new binding preserves the
original's effect and documentation; `body` reflects its one-word forwarding
quotation. An unqualified original or a qualified binding is `'domain`.

### infra
`( list quotation -- list )` — *Isolated*, contract unconstrained. Run
the quotation with the list's elements as the entire substack; the
substack that remains is the result list.

### iterations
`( value count quotation -- list )` — *Isolated*, unary contract
`( a -- a )`. Return the initial value followed by `count` successive
applications. `count` must be a nonnegative int, and a zero count returns a
singleton list. Defined in ecl over `scan`.

### join
`( strings separator -- string )` — Join a list of strings with a
separator string.

### keep
`( x q -- … x )` — *Inline.* Apply a quotation to a value, then restore
the value on top of the quotation's results. Equivalent to
`over (call) dip`.

### keys
`( dict -- keys )` — Keys in insertion order.

### keys-exactly?
`( candidate declared -- bool )` — 1 when a dict has exactly the keys in
`declared`, in any order. Defined in ecl.

### last
`( sequence -- value )` — Final element of a nonempty sequence.
Equivalent to `dup len 1 - at`.

### len
`( list -- count )` — Top-level element count; works on any list,
including ragged data.

### lex-cmp
`( left right comparator -- order )` — Lexicographically compare two
sequences with an inline `( left-element right-element -- order )`
comparator. Stop at the first nonzero result; when the shared prefix is
equal, compare sequence lengths. Defined in ecl.

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

### match?
`( left right -- bool )` — Whole-value structural equality; **not**
pervasive. `[1 2] [1 2] =` is `[1 1]`; `[1 2] [1 2] match?` is `1`.

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

### neg
`( x -- y )` — **Pervasive.** Negation. Equivalent to `-1 *`.

### nip
`( x y -- y )` — Discard the value beneath the top. Equivalent to
`swap pop`.

### not
`( bool -- bool )` — **Pervasive.** Invert 0/1 values.

### or
`( x y -- bool )` — **Pervasive.** Boolean disjunction on 0/1 values.
Both operands are already evaluated — there is no short-circuiting.
Defined in ecl.

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

### prod
`( sequence -- product )` — Product of a numeric sequence; 1 when empty.
Equivalent to `1 (*) fold`.

### put
`( collection key value -- collection )` — Functional update of a list
index or dict key, producing a new value.

### qualify
`( 'module-name 'binding-name -- qualified-word )` — Validate a canonical
module path and one unqualified, non-reserved binding segment, then construct
their qualified executable word directly from the interned components. It
does not parse source or grant module-state/lifecycle authority; use `execute`
to invoke the result dynamically.

### raise
`( error -- )` — Raise a language error from an error dict.

### rand-float
`( state -- state result )` — Draw one uniform float in `[0, 1)` and
return the advanced state. See Randomness.

### rand-int
`( state bound -- state result )` — Draw one uniform int in `[0, bound)`
and return the advanced state. A `bound` below 1 is `'domain`. The draw
is unbiased: candidates in the incomplete top range are rejected rather
than folded.

### rand-ints
`( state count bound -- state results )` — Draw `count` uniform ints in
`[0, bound)` as a list, returning the state advanced by `count`. Each
element is the draw at its own counter position, so the list does not
depend on the order in which it was built.

### range
`( bound -- list )` — The ints `[0 1 … bound-1]`; the bound must be a
nonnegative int.

### raze
`( list -- list )` — Flatten one level. Flat-map is `each raze`.

### register
`( module 'module-name -- )` — Validate a canonical module path and publish a
module value under it. A missing name creates its registration and copies the
image's initial-state template into the new durable stack; an existing name
installs the new image and retains that registration's durable stack. One
image may be registered under any number of names, each with independent
state and lifetime. See Modules.

### reshape
`( list shape -- list )` — Cycle the data into the exact nested-list
shape; a zero axis must be final.

### rest
`( list -- list )` — All but the first element of a nonempty list.

### reverse
`( list -- list )` — Reverse top-level element order. Defined in ecl as
an index permutation.

### rotate
`( list count -- list )` — Rotate top-level element order left by a
count, wrapping cyclically; a negative count rotates right, counts
beyond the length wrap, and the empty list is returned unchanged.
Defined in ecl as a modular index permutation (the K lineage's
composed form; APL/J make dyadic reverse a primitive).

### round
`( x -- integer )` — **Pervasive.** Round to nearest; the result is
int64, `'overflow` outside its range.

### scan
`( list accumulator quotation -- list )` — *Isolated*, contract
`( acc a -- acc )`. Like `fold` but returns every intermediate
accumulator; same length as the input.

### scan1
`( list quotation -- list )` — *Isolated*, contract `( acc a -- acc )`.
Return a nonempty list's first element followed by the intermediate
accumulators from reducing its remainder. Defined in ecl over `scan`.

### see
`( 'name -- )` — Print a re-readable definition through the standard source
formatter, including its width-aware layout and matching `### def` or
`### defp` navigation header when the reflected form is an ordinary source
definition. The definition has one combined annotation, omitting each portion
that was not supplied. What
prints is what is stored: a name bound by `set` prints its capture body ending
in `'name def`, with no annotation, not the `set` spelling that produced it.
Reader-built bodies retain a shared slice of their source unit, so head binders
print with their authored local names even though execution uses the lowered
`_ll`/`_gl`/`_dl` quotation. Runtime-constructed bodies without source
provenance fall back to their canonical value form. Native and module origins
are displayed.

### set
`( annotation? value 'name -- )` — Bind a value as a constant word in the current
environment. Reference applies the constant's body and pushes the exact
captured value, quotations included. Defined in ecl as
`swap literal swap def`, so `v 'name set` is observationally
`v literal 'name def`: the stored body is `((v) first)`. An optional
annotation beneath `v` is published as the constant's metadata; marker words
inside `v` are nested by `literal` and remain captured data.

### setp
`( annotation? value 'name -- )` — Bind a private module constant. Defined in ecl as
`swap literal swap defp`. A top-level `setp` is an error, raised by the
`defp` it calls.

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

### split
`( string separator -- parts )` — Split a string at every occurrence of a
separator string; the parts are strings. An empty separator splits the input
into one single-codepoint string per Unicode scalar, with no empty boundary
parts; splitting an empty string this way returns an empty list.

### sqrt
`( x -- y )` — **Pervasive.** Square root. `'domain` on negative inputs
(the result would be NaN).

### stencil
`( list width quotation -- list )` — *Isolated*, contract
`( window -- result )`. Apply to each overlapping window of a positive int
width, left-to-right. A width larger than the input returns `()` without
applying the quotation; zero and negative widths are `'domain`. The result
has `max(len-width+1, 0)` elements.

### str
`( value -- string )` — The canonical printed representation; carries the
round-trip guarantee (see Printing): reading it back yields the same
value, task handles excepted.

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
`( n q -- ... )` — *Inline.* Run the quotation `n` times; `n` must be a
nonnegative int. Tail-call optimized.

### to-dict
`( keys values -- dict )` — Dict from two conforming lists; duplicate
keys error.

### tri
`( x p q r -- ... )` — *Inline.* Apply three quotations to the same input
in order. Equivalent to `((keep) dip keep) dip call`.

### type
`( value -- type )` — Return the value's kind as a symbol: one of `'int`,
`'float`, `'char`, `'symbol`, `'word`, `'list`, `'dict`, or `'task`.

### unappend
`( list -- initial last )` — Split a nonempty list into its initial
elements and last element. Equivalent to `reverse uncons reverse swap`.

### uncons
`( list -- first rest )` — Split a nonempty list into first element and
remainder. Equivalent to `dup first swap rest`.

### unfold
`( state predicate step -- state list )` — *Isolated*. Before every step,
apply the predicate under contract `( state -- bool )`. When it returns 0,
return the current state and all generated items. When it returns 1, apply
the step under contract `( state -- state item )`, append the item, and
continue from the returned state. The predicate is therefore always checked
before the first step, and a false initial predicate returns the initial
state and `()`.

### unless
`( bool else -- ... )` — *Inline.* Run the quotation when the condition
is 0. Equivalent to `() swap if`.

### unmodule
`( 'module-name -- )` — Close, quiesce, and retire the module currently
registered under a canonical name or unqualified alias, resolved exactly as
ordinary registry lookup resolves it. An unregistered name is `'undefined-word`. Removal strips
every alias targeting the slot in the same publish and is `'domain` when
initiated from inside any state application, since a unit holds at most one
slot's turn. See Modules.

### vals
`( dict -- values )` — Values in insertion order. Defined in ecl.

### when
`( bool then -- ... )` — *Inline.* Run the quotation when the condition
is 1. Equivalent to `() if`.

### where
`( counts -- indices )` — Expand a list of nonnegative ints into each
index replicated its count times. A 0/1 mask is the common case, yielding
the positions of 1s: `[0 1 1 0] where` is `[1 2]`.

### which
`( 'name -- )` — Print where a name resolves (module home, shadowing),
its kind (`def`, `primitive`, or `native`), visibility, and declared
effect when one was supplied. Constants report `def` with no effect, like
every other unannotated ecl definition.

### while
`( cond body -- ... )` — *Inline.* At the start of each iteration, retain an
operand-stack checkpoint and run `cond` against it. The condition may inspect
the stack destructively; its top result must be a 0/1 boolean, and its complete
stack result is discarded. On 1, run `body` from the checkpoint and use the
body's result as the next iteration's checkpoint. On 0, restore the checkpoint
and exit. Environment and IO effects from the condition survive. Tail-call
optimized.

### while-values
`( value predicate step -- list )` — *Isolated*, contracts
`( state -- bool )` and `( state -- state )`. Return the initial value and
successive states through the first state for which the predicate is false.
Defined in ecl over `unfold`.

### windows
`( list width -- windows )` — Return every overlapping window of a positive
width. Equivalent to `() stencil`.

### with
`( values quotation -- quotation )` — Capture every element of a list as
an inert input to a quotation, preserving order. Calling the result starts
with the list's elements as separate stack values. Defined in ecl as
`((literal) each) dip append raze`.

### within
`( quotation -- ... )` — Run the quotation against a
private draft of the home module's durable stack, then publish the
remaining draft as that stack and deliver whatever `without` moved
outward, in invocation order. Legal only in a published word whose
definition-site home is a live, current module generation; everywhere else
it is `'domain`. Parking, nesting, and a second module's slot are
`'domain`. Any failure publishes nothing. See Modules.

### without
`( -- )` — Move the draft's top value onto the pending outputs of the
active `within` application. `'domain` outside one, `'underflow` on an
empty draft. Outputs reach the caller only if the application publishes.

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

## archive

### sha256
`( bytes -- lowercase-hex )` — Return the SHA-256 digest of an integer byte
list. Every item must be an integer in `0..255`; strings are not byte vectors
and are not coerced.

### unpack-tgz
`( bytes destination -- regular-file-paths )` — Validate and atomically unpack
a gzip-compressed tar byte list beneath a previously absent destination.
Return normalized regular-file paths in archive order. Unsafe, linked,
special, duplicate, malformed, or over-limit members are `'domain`; invalid
byte items are `'domain`; wrong container kinds are `'type`; unavailable host
I/O and filesystem or destination conflicts are `'io`. Failure never publishes
a partial destination. See The standard library / `archive` for the complete
format, limit, containment, and publication contract.

## csv

### emit
`( rows -- text )` — Render rows of string fields as canonical,
CRLF-terminated RFC 4180 text, quoting exactly the fields that require it.
Non-list rows and non-string cells are `'type`; a zero-field row is `'shape`.

### parse
`( text -- rows )` — Parse RFC 4180 comma-separated text into rows whose
fields are all strings. Accept CRLF or LF records, quoted commas and newlines,
and doubled-quote escapes; preserve empty fields and record widths. Malformed
quoting is `'parse`.

## error

Errors are ordinary dictionaries. Construction and inspection do not raise
unless an operation's own input violates its contract; control effects remain
core words.

### kind-in?
`( error kinds -- bool )` — Validate an error and a list of kind symbols, then
return 1 when the error's kind occurs in the list.

### kind?
`( error kind -- bool )` — Validate both inputs and return 1 when the error has
the supplied kind.

### new
`( kind -- error )` — Build `{'kind kind}` from a symbol.

### valid?
`( value -- bool )` — Return 1 when a value has a required symbol `'kind` and
well-typed optional `'msg`, `'word`, `'trace`, and `'data` fields. Extra fields
are allowed.

### with-data
`( error data -- error )` — Validate both dictionaries and return the error
with `'data` set to `data`.

### with-message
`( error message -- error )` — Validate the error and string message and return
the error with `'msg` set to `message`.

## http

### get
`( url headers -- response )` — Fetch a URL with caller-supplied headers;
use `{}` for none. Return `{'status int, 'headers dict, 'body string}`. A
transport or protocol failure is `'io` carrying the URL in `'path`; a non-2xx
status is an ordinary response.

### get-bytes
`( url headers -- response )` — Perform the same GET as `get`, including
redirects and content decoding, but return `'body` as the exact ordered octets
in an ordinary integer byte list. Status and headers retain the same types.
This is the binary ingress used for archives; no byte is decoded to or encoded
from a Unicode character before hashing.

### post
`( url headers body -- response )` — Post a body with caller-supplied headers
and return the same response shape and errors as `get`.

## io

### debug
`( value label -- value )` — Write the string label, `": "`, and the value's
pretty-printed representation plus newline, leaving the value on the stack.
Semantically `io.prin ": " io.prin io.inspect`; a non-string label is the
same `'type` failure as `io.prin`.

### inspect
`( value -- value )` — Pretty-print a value while leaving it on the stack;
the pipeline probe. Semantically `dup io.pp`.

### lines
`( path -- lines )` — Read one UTF-8 file and split it at newline characters.
Semantically `io.slurp "\n" split`.

### pp
`( value -- )` — Pretty-print any value plus newline in the display layout of
Printing. Best-effort: huge leaves may be elided, so there is no round-trip
guarantee. Use core `str` for canonical rendering.

### prin
`( string -- )` — Write a string's characters as UTF-8 without adding a
newline. Non-string is `'type`.

### print
`( string -- )` — Write a string followed by a newline. Semantically
`io.prin "\n" io.prin`.

### slurp
`( path -- string )` — Read one whole UTF-8 file. A missing or unreadable file,
invalid UTF-8, or absent host I/O raises `'io` carrying the offending `'path`.

### spit
`( string path -- )` — Write one file, truncating and replacing it. There is
no temporary file and no rename, so a failure part-way through can leave a
partial file; it raises `'io` carrying the offending `'path`.

### stack
Stack-polymorphic; leaves the operand stack unchanged. Print each value in the
currently visible operand window as a bottom-up indexed display block. `[0]`
is the bottom and the largest index is the top; continuation lines align after
the prefix. An isolated quotation sees only values above its isolation floor.
An empty visible window writes nothing. Rendering is best-effort and may use
the same multiline dictionary, array, and elision layout as `io.pp`.

### stdin
`( -- string )` — Read the whole standard input stream once. Legal where stdin
carries data (`-e` and script-file modes); `'io` where stdin is the program
source or when it has already been read.

## json

### emit
`( value -- text )` — Render an ECL value as RFC 8259 JSON. Dict keys must be
strings or symbols; the only emitted symbol values are `'null`, `'true`, and
`'false`.

### parse
`( text -- value )` — Parse RFC 8259 JSON. Objects become string-keyed dicts,
arrays become lists, in-range integral numbers become ints, and other numbers
become floats. JSON null and booleans become the ordinary symbols `'null`,
`'true`, and `'false`.

## pkg.data

Pure structural helpers shared by the package-format modules.

### assert-inert-entry
`( pair -- )` — Discard an inert dict entry, or raise `'domain` with its key
when its value recursively contains an executable word.

### read-one
`( text -- form )` — Parse exactly one form without evaluating it. Unreadable
text is `'parse`; zero or multiple forms are `'shape`.

### sorted-entries
`( dict -- pairs )` — Return a dict's entries in ascending key order.

## pkg.name

### valid?
`( value -- bool )` — Test the canonical dot-joined lowercase package-name
grammar without raising.

### hash?
`( value -- bool )` — Test for `sha256-` followed by exactly 64 lowercase
hexadecimal digits.

### url?
`( value -- bool )` — Test for a nonempty HTTPS URL.

### owns?
`( package-name module-name -- bool )` — Return 1 when a package owns a module
name: the name itself, or a name continuing after a `.` boundary. `foo` owns
`foo.bar` and does not own `foobar`. A non-string is `'type`; a malformed
canonical name is `'domain`.

### collides?
`( names -- bool )` — Return 1 when any two canonical names overlap under
`pkg.name.owns?`.

## pkg.version

### validate
`( candidate -- parts )` — Validate a package version and return its core
fields and prerelease identifiers. A non-string is `'type`; a spelling outside
the supported SemVer grammar is `'domain`.

### less?
`( left right -- bool )` — Return 1 when the left version precedes the right
under Semantic Versioning 2.0.0 §11. Both operands are validated.

### max
`( versions -- version )` — Return the greatest member of a nonempty list of
version strings. The empty list is `'shape`; a non-list or non-string member is
`'type`; every member is validated before comparison.

## pkg.manifest

### validate-requirement
`( requirement -- requirement )` — Validate and return one exact version, URL,
and hash declaration.

### validate
`( candidate -- manifest )` — Return a manifest unchanged, or raise. A non-dict
is `'type`; an undeclared key, unsupported format, malformed name, version,
hash, or URL, self-requirement, ownership collision, or executable word value
is `'domain`.

### read
`( text -- manifest )` — Parse one form with `pkg.data.read-one`, validate it,
and never evaluate it.

### write
`( manifest -- text )` — Validate a manifest and render its stable one-line
form with a terminal newline, preserving requirement dictionary insertion
order.

## pkg.lock

### validate
`( candidate -- lock )` — Return a lock unchanged after checking its grammar,
root provenance, selected packages, recorded minimums, and satisfaction.

### read
`( text -- lock )` — Parse one form without evaluation and validate it.

### vendor
`( lock -- lock )` — Validate a lock and return it with the closed
`'store 'vendor` mode. No path is accepted or produced.

### write
`( lock -- text )` — Validate a lock and render its canonical sorted layout,
including the terminal newline.

### tree
`( lock -- text )` — Render the root and one canonical line per recorded
dependency edge, ordered by requiring package and required package.

### why
`( lock module -- text )` — Render one deterministic root-to-owner path for a
canonical qualified module. An unowned or unreachable module is `'domain`
carrying the requested module where applicable.

## pkg.mvs

### resolve
`( root-manifest manifests -- lock )` — Resolve the reachable exact-version
requirement graph by minimal version selection. `manifests` maps package names
to exact-version manifest maps. Return a validated lock, or raise a structured
error for malformed input, conflicting hashes, a selected-prefix collision, a
requirement cycle, or a missing manifest. It reaches no filesystem, network,
or evaluation capability.

## pkg.store

Host-backed package archive and publication capabilities. Every traversal,
write, rollback, and output materialization advances through bounded scheduler
work; no word exposes a host handle or generic filesystem mutation.

### inspect
`( bytes package-name -- manifest-text )` — Validate one tgz as a v1
source-only package owned by `package-name` without creating a filesystem
destination. Return the sole root `ecl.pkg` as exact UTF-8 text.

### install
`( bytes package-name destination -- regular-file-paths )` — Repeat complete
package validation and atomically publish the archive at a previously absent
destination. Return normalized regular-file paths only after commit; failure
never exposes a partial destination.

### present?
`( destination -- bool )` — Return 0 for an absent path and 1 for a real
directory. A symlink, non-directory, inaccessible path, or unavailable host
I/O is `'io`.

### verify
`( destination package-name hash -- )` — Stream the installed package's
reserved archive seal and require its SHA-256 to equal `hash`. Failures name
the package and carry the destination path for host-I/O errors.

### read-seal
`( destination package-name hash -- bytes )` — Perform the same streamed seal
verification as `verify`, then return its exact octets as an ordinary integer
byte list. It never reads a caller-selected child filename.

### write-lock
`( text path -- )` — Atomically replace a regular lock file through a unique
sibling temporary. Failure preserves the prior file or absence.

### gc
`( retained-store-keys -- removed-count )` — Derive the shared cache root from
the captured environment, preserve the supplied canonical keys and every
unknown cache node, and remove other canonical real-directory entries through
bounded detach/walk/delete phases. A non-list, non-string key, or malformed
store key is `'type` or `'domain`; unavailable cache selection and filesystem
failures are `'io`.

## pkg.sync

### cache-root
`( -- store-root )` — Select the shared package cache from captured
`ECL_CACHE`, `XDG_CACHE_HOME`, then `HOME`, treating empty values as absent.

### store-key
`( package requirement -- key )` — Derive the canonical
`<name>-<version>-<hex>` basename from a validated selection.

### store-path
`( store package requirement -- path )` — Join a store root and canonical key.

### store-keys
`( lock -- keys )` — Validate a lock and return its selected canonical keys in
package-name order.

### store-root
`( lock project-root -- store-root )` — Return `<project-root>/vendor` for a
vendored lock; otherwise return `cache-root`.

### requirement
`( package version url -- requirement )` — Fetch and inspect one exact HTTPS
package archive and return its validated version, URL, and computed hash
declaration.

### verify
`( lock project-root -- count )` — Verify every selected seal at the lock's
cache or vendor root and return the selection count.

### run
`( root-manifest project-root -- lock )` — Discover and hash-check the complete
exact transitive manifest graph, resolve it with `pkg.mvs.resolve`, fetch and
atomically install only selected missing store entries, then atomically write
the canonical `ecl.lock` beneath `project-root`. Return the validated lock.
See Packages / Synchronization for cache selection, two-pass fetch, error, and
partial-success contracts.

### run-offline
`( root-manifest project-root -- lock )` — Perform the same discovery,
resolution, installation check, and atomic lock write using only present
shared-cache entries. An absent exact entry is `'io` naming its package and
destination; no request is opened.

## pkg.cli

The CLI module is an ordinary line-oriented adapter. `src/main.zig` validates
argv shapes and supplies an absolute nominal project root to every command
except `gc`; these words return no stack output and print one stable line on
success.

- `init ( arguments -- )` creates `ecl.pkg` and prints `initialized ecl.pkg for
  <name>`.
- `add ( arguments -- )` records one exact fetched requirement and prints
  `added <name> <version>`.
- `sync` and `sync-offline` `( arguments -- )` print `synced <count> packages`.
- `tree` and `why` `( arguments -- )` print `pkg.lock.tree` and
  `pkg.lock.why` output unchanged.
- `verify ( arguments -- )` prints `verified <count> packages`.
- `vendor ( arguments -- )` populates the fixed vendor store, atomically marks
  the lock vendored, and prints `vendored <count> packages`.
- `gc ( lock-paths -- )` unions at least one named lock and prints `removed
  <count> packages`.

## result

Every entry validates its result envelope before invoking a caller quotation.
A success payload is always a list representing a stack.

### all
`( results -- result )` — Return the leftmost failure unchanged, or one
success whose value is the list of success stacks in input order.

### and-then
`( result quotation -- result )` — Seed a success payload onto an isolated
stack and run the quotation through `with @attempt`; return an existing
failure unchanged.

### either
`( result on-ok on-err -- ... )` — Eliminate a result exhaustively: call the
first quotation with the success list or the second with the error dict.
Neither branch is isolated.

### err
`( error -- result )` — Tag an error dict as a failed result.

### err?
`( result -- bool )` — Return 1 when a well-formed result is a failure.

### map-err
`( result quotation -- result )` — Replace a failure's error dict with the one
its `( error -- error )` quotation returns; leave a success unchanged.

### ok
`( values -- result )` — Tag a list of success values, representing the stack
a successful computation left.

### ok?
`( result -- bool )` — Return 1 when a well-formed result is a success.

### or-else
`( result fallback -- value )` — Return a success payload, or the fallback
value for a failure.

### or-raise
`( result -- values )` — Return a success payload, or re-raise the captured
error dict unchanged.

### partition
`( results -- successes errors )` — Split results into success lists and error
dicts, both in input order, without re-raising.

### recover
`( result quotation -- result )` — Seed a failure's error dict onto an
isolated stack and run the recovery quotation; leave a success unchanged.

### recover-kinds
`( result kinds quotation -- result )` — Recover only when a failure's kind is
one of the listed symbols; leave every other result unchanged.

## rng

These words transact against the module's durable `[key counter]` state. A
fresh process begins with a fixed key; use `entropy rng.seed` to opt into
nondeterminism.

### deal
`( count pool -- results )` — Draw distinct values below `pool` without
replacement. The sample is unbiased; `count > pool` is `'domain`.

### float
`( -- result )` — Draw one uniform float in `[0, 1)`.

### int
`( bound -- result )` — Draw one uniform integer below a positive bound.

### ints
`( count bound -- results )` — Draw a vector of uniform integers below a
positive bound.

### seed
`( key -- )` — Rekey the generator and reset its counter.

### shuffle
`( values -- values )` — Return a uniformly random permutation of a list.

## str

All case and whitespace operations use the ASCII character classes; every
non-ASCII scalar passes through unchanged.

### contains?
`( string needle -- bool )` — Return 1 when a needle occurs anywhere in a
string. The empty needle is present at index zero.

### ends?
`( string suffix -- bool )` — Return 1 when a string ends with a suffix.

### index-of
`( string needle -- index )` — Return the zero-based index of a needle's first
occurrence; return 0 for the empty needle and raise `'domain` when a nonempty
needle is absent.

### lower
`( string -- string )` — Lowercase ASCII letters, leaving every other scalar
unchanged.

### pad-left
`( string width -- string )` — Pad with leading spaces up to a width; return a
longer string unchanged.

### pad-right
`( string width -- string )` — Pad with trailing spaces up to a width; return a
longer string unchanged.

### repeat
`( string count -- string )` — Concatenate a nonnegative number of copies of a
string.

### replace
`( string needle replacement -- string )` — Replace every occurrence of a
needle. An empty needle inserts the replacement between adjacent scalars only,
with no boundary insertion.

### starts?
`( string prefix -- bool )` — Return 1 when a string begins with a prefix.

### str?
`( value -- bool )` — Return 1 when a value is a string: a list whose every
element is a char. The empty string answers 1, and so does the empty list —
they are one value. Never raises.

### trim
`( string -- string )` — Remove ASCII whitespace from both ends.

### trim-left
`( string -- string )` — Remove leading ASCII whitespace.

### trim-right
`( string -- string )` — Remove trailing ASCII whitespace.

### upper
`( string -- string )` — Uppercase ASCII letters, leaving every other scalar
unchanged.

## table

Every operation except `valid?` first validates the ordinary column dict as a
table. See The standard library for the table convention and frozen error
kinds.

### aggregate
`( table names specs -- table )` — Group by `names` and aggregate each group
with `[output input quotation]` triples. Validate the complete specification
before running a quotation; key columns precede aggregate columns.

### cast
`( table spec -- table )` — Coerce named columns with isolated
`( cell -- value )` quotations. Validate the complete specification before
running any quotation and replace the table only after all casts succeed.

### column
`( table name -- column )` — Return one existing named column.

### from-columns
`( columns -- table )` — Return a column dict as a table, raising when it does
not satisfy the convention.

### from-header-rows
`( rows -- table )` — Build a table from rows whose first row contains column
names.

### from-records
`( records -- table )` — Build a table from a nonempty list of dicts sharing
one key set; the first record fixes schema order.

### from-rows
`( names rows -- table )` — Build a table from explicit names and exact-width
rows. An empty row list preserves the named zero-row schema.

### group-by
`( table names -- groups )` — Group row indices by named columns. Keys use
first-occurrence order and indices stay ascending; zero names yields one global
group keyed by the empty list.

### header-rows
`( table -- rows )` — Return data rows prefixed by the column-name row, the
schema-preserving row form.

### height
`( table -- count )` — Return the row count.

### inner-join
`( left right pairs -- table )` — Stable inner equijoin on
`[left-name right-name]` pairs. Duplicate keys expand to the full
many-to-many product in left-row then right-row order.

### left-join-with
`( left right pairs fill -- table )` — Stable left equijoin. `fill` must name
exactly every appended right column used for unmatched rows.

### names
`( table -- names )` — Return column names in schema order.

### records
`( table -- records )` — Return rows as dicts in schema order. An empty result
necessarily loses its schema.

### rename
`( table mapping -- table )` — Rename columns through an ordered old-to-new
mapping while preserving column order; collisions are `'domain`.

### rows
`( table -- rows )` — Return data rows in order.

### select
`( table names -- table )` — Keep named columns in the order given.

### valid?
`( candidate -- bool )` — Return 1 when a candidate satisfies the convention
and 0 for a convention mismatch. Cancellation and allocation failure still
propagate.

### where
`( table mask -- table )` — Keep rows selected by an exact-length 0/1 mask.

### with-column
`( table name column -- table )` — Replace an existing column or append a new
one, keeping the row count exact.
