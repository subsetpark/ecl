<!-- Generated from design/SPEC.src.md; edit the source fragments, not this file. -->

# ecl — language specification

## Status, scope, and conformance

This document defines the syntax and semantics of the ECL language. The
language is defined independently of any implementation representation,
interpreter architecture, host interface, or distribution. The shipped ECL
interpreter is the reference implementation, not the definition of the
language.

This is a staged rewrite of the language report. Only material incorporated
into this document has been reviewed under its present structure. Untouched
core-language text from the former monolithic specification is preserved in
[`LEGACY_LANGUAGE.md`](LEGACY_LANGUAGE.md); untouched environment and tooling
text is preserved separately in
[`LEGACY_ENVIRONMENT.md`](LEGACY_ENVIRONMENT.md). Neither legacy file is
assembled into this report or represents a decision affirmed by the current
specification work.

ECL has three distinct fields of conformance:

- An **ECL language implementation** conforms to this document. It provides
  the source language, values, evaluation, bindings, units and errors,
  modules, and tasks specified here.
- An **ECL standard environment** is a conforming language implementation
  that also provides the vocabulary specified by [`STDLIB.md`](STDLIB.md).
  When a named word is a semantic primitive of the language, this document is
  the authority for its spelling and behavior and `STDLIB.md` indexes that
  definition rather than restating it.
- An **ECL distribution or toolchain** may additionally provide a command,
  module transports, native extensions, packages, a formatter, and other host
  facilities. Those facilities are not language semantics unless this
  document explicitly says otherwise.

[`INTERPRETER.md`](INTERPRETER.md) describes one implementation of these
semantics, and [`PERFORMANCE.md`](PERFORMANCE.md) states implementation and
distribution guarantees. Neither document may alter language behavior defined
here.

A named operation is a **semantic primitive** when its canonical spelling
creates or consumes a language capability, establishes a semantic boundary,
accesses state unavailable to ordinary ECL composition, or defines a protocol
on which other operations depend. Its complete behavior belongs here even if
a particular interpreter implements it in ECL. Whether an operation is native
code is not relevant to this classification. `STDLIB.md` remains the
exhaustive vocabulary index for both semantic primitives and library words.

The key words **must**, **must not**, **should**, **should not**, and **may**
are normative. An implementation limit is a documented finite bound permitted
by this specification. Unspecified behavior is behavior for which this
specification deliberately imposes no choice; it is not permission to violate
any otherwise applicable rule. Examples and the language overview are
non-normative unless explicitly identified as normative.

### Formal models

A linked Pantagruel model is normative only within the abstraction boundary
declared by that model. Its domains, rules, actions, invariants, and initial
state are normative within that boundary; behavior it deliberately omits is
governed by this prose. A finite model-checking bound is verification
machinery, not an ECL implementation limit. A contradiction between prose and
a formal model is a specification defect and must not be resolved by silently
preferring either account.

Formal actions use guards to define the states and inputs for which their
transitions are valid. Models do not enumerate every invalid invocation as an
error-labelled no-op; error kinds and unchanged-state requirements outside an
action's guard remain specified in prose. A failure is modeled as an explicit
action when failure itself changes modeled state, such as aborting an active
transaction while preserving its durable and caller stacks.

Action parameters identify either inputs supplied by ECL execution or existing
semantic entities whose transition the action records; they need not denote
first-class ECL values. A fact derived from modeled state is expressed as the
product of a rule rather than repeated as an independent parameter. Fresh
runtime identities such as slots, generations, calls, and transactions are
selected existentially from unused domain atoms by the transition that creates
them. A later action that changes one of those existing entities takes that
entity as a parameter.

## Language overview

*This section is non-normative.*

ECL is a homoiconic concatenative array language. A program is a sequence of
values evaluated from left to right against an operand stack. Evaluating a
word resolves and invokes its binding; evaluating any other value pushes that
value. Words consume operands from the right-hand, top end of the stack and
append their results there.

A quotation is a list used as a program. Lists are also ECL's general ordered
aggregate, so code and data have the same value representation and can be
built, inspected, and transformed by the same operations. Concatenating two
programs composes their stack transformations. Many scalar operations pervade
lists and dictionaries recursively, giving the same language an array
interpretation.

Values are immutable. Bindings associate names with executable bodies and may
be replaced without mutating either the old body or values that refer to its
name. Reader-authored word occurrences retain where their names are to be
looked up, but lookup remains late: they retain a scope, not a resolved
binding.

A unit is the boundary of failure and operand-stack rollback. Modules separate
immutable code images from named registrations; a registration owns the
durable operand stack used by stateful module operations. Tasks execute
isolated units under structured concurrency.

## Notation and terminology

In a stack effect `( before -- after )`, the top of the operand stack is at
the right. Names in an effect describe positions, not runtime variables. `S`
denotes an operand-stack sequence, `P` and `Q` denote program sequences, and
σ denotes the execution state other than the operand stack.

The primary evaluation judgment is big-step:

```text
⟨P, S, σ⟩ ⇓ success(S′, σ′)
⟨P, S, σ⟩ ⇓ failure(error, S_partial, σ′)
```

Evaluation therefore takes a program, an operand stack, and execution state
and produces either a new stack and state or an error with the partial stack
and surviving state at the point of failure. A unit applies the separate
rollback rule in [Units and the transactional stack](#units-and-the-transactional-stack).
Small-step rules may use the term *configuration* for a tuple containing
remaining control and execution state, but configuration is not an additional
ECL value or source-language concept.

If `P Q` denotes sequence concatenation, sequential evaluation obeys the Joy
composition law wherever the left side succeeds:

```text
⟦P Q⟧ = ⟦Q⟧ ∘ ⟦P⟧
```

A **form** is a grammatical source construct. Reading a form produces an ECL
**value**, possibly with semantic metadata. A **word** is an executable value
whose identity is its kind and spelling. A **word occurrence** is a stored
word together with any resolution and provenance metadata assigned to that
occurrence. A **quotation** is a list applied as a program. A **binding**
associates a name with an executable body and metadata; it is not a value. A
**scope** is a binding map with a fixed parent. An **activation** is one
invocation of a binding. A **module image** is an immutable module value; a
**registration** is the durable named slot through which an image may be
published and invoked.

## Source language

The grammar in this chapter is the single authoritative grammar for ECL
source. Later sections may quote productions for explanation but do not define
a second grammar.

### Source text

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

### Tokens

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

### Forms

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
  canonical value shape; see Printing.)
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

## Values and external representations

The value-kind universe is closed. Every ECL value has exactly one of these
ten kinds:

```text
int  float  char  symbol  word  list  dict  task  module  unit-plan
```

A conforming implementation may choose any representation for these kinds but
must not expose another kind through `type`, matching, hashing, ordering,
printing, or an ECL-facing native interface. Adding a first-class kind is a
language extension. Booleans are restricted integer values; strings,
quotations, vectors, matrices, and arrays are roles played by lists; errors
and results are dictionaries; and bindings are not values.

Values are observationally immutable: a value's kind and content never
change. Operations on lists and dictionaries produce values; storage reuse is
not observable language behavior. `def` and `set` replace bindings rather than
mutating values. A task is an immutable capability identifying an externally
evolving task, and module images and unit plans are immutable. Storage
specialization, copy-on-write strategies, and amortized bounds are
implementation or performance concerns.

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
  symbols print quoted. A word value's entire identity is its kind and
  spelling. Resolution and provenance metadata belong to a stored occurrence,
  not to the word value.
- **list** — the one aggregate: a finite ordered sequence of values. A
  quotation, a vector, and a row of a matrix are all lists. A homogeneous
  list of atoms *is* a vector — `(1 2 3)` and `[1 2 3]` are the same
  value. There is no rank-carrying array type: a matrix is a list of
  equal-length lists, and rank is depth, not an intrinsic property.
  Ragged data (a list of lists of unequal length) is legal. A string is a
  list of chars.
- **dict** — an insertion-ordered map. Any value is a legal key
  (immutability makes every value hashable); symbols are the idiom. Key
  identity is whole-value `match?` identity. Insertion order is preserved
  by storage, iteration, and printing, but ignored by equality: two dicts
  with the same key–value pairs in different orders are equal.
- **task** — a handle to a concurrent unit of work (see Concurrency).
  Tasks are runtime capabilities bound to their session: `match?` and
  hashing use handle identity, and a task prints as `<task:N>`, which the
  reader rejects. A task value cannot be forged from text.
- **module** — an opaque immutable module image (see Modules). Module values
  compare and hash by image identity. A module prints diagnostically as
  `<module>` and cannot be forged from text.
- **unit-plan** — a sealed pair of seed values and a construction body,
  built only by `seed` and consumed only by a unit constructor. Like a
  task it is opaque: `match?` and hashing use plan identity, it prints as
  `<unit-plan>`, which the reader rejects, and it cannot be called,
  concatenated, indexed, serialized, or passed to a native word. It is an
  ordinary first-class value for everything else — `dup`, `pop`, storage,
  selection, and passage between words.

### Readable representations and display

A **readable representation** is source text which reads to a structurally
matching value. Integers, floats, characters, symbols, words, lists, and
dictionaries are source-denotable. A list or dictionary has a readable
representation only when every value it contains does. Reader provenance,
resolution metadata, and reader lineage need not be reproduced: they do not
participate in structural matching.

A **diagnostic display** is human-facing text without a read-back guarantee.
The displays for tasks, modules, and unit plans are diagnostic displays, not
external representations. An aggregate containing any such value is likewise
not round-trippable. An operation may produce display text for every value,
but any print/read guarantee applies only to the readable subset.

### Equality and ordering

ECL defines whole-value equivalence independently of the operation exposing
it. `match?` returns its boolean result, dictionary keys use it as key
identity, and hashing must be congruent with it.

- Lists are equivalent recursively and positionally.
- Dictionaries are equivalent when they contain equivalent key–value pairs,
  irrespective of insertion order.
- Numbers are equivalent by mathematical value across `int` and `float`:
  `2` and `2.0` are equivalent, as are `0.0` and `-0.0`. Mixed numeric
  comparison is exact; it does not first round an integer to binary64.
- Tasks, modules, and unit plans are equivalent only when they have the same
  capability identity.
- Resolution context, reader lineage, and provenance do not participate in
  equivalence or hashing. Consequently, two matching quotations may behave
  differently when applied. Matching is structural data equivalence, not
  behavioral equivalence.

`=` is instead pervasive equality: it descends aggregate structure and
produces a scalar boolean or boolean mask (see Pervasion). For example,
`[1 2] [1 2] =` is `[1 1]`, while `[1 2] [1 2] match?` is `1`.

- `cmp` is a three-way total ordering (−1/0/1) on numbers, chars (by
  codepoint), and strings (codepoint-lexicographic). Anything else,
  including cross-kind pairs, is a `'type` error. `grade` orders by
  exactly this ordering.
- Booleans are the ints 0 and 1. Words that require a boolean reject
  every other value, including other ints.

## Core evaluation

Evaluation processes a program sequence from left to right. Evaluating a word
occurrence resolves and invokes it. Evaluating any other value appends that
value to the operand stack. Applying a quotation evaluates the quotation's
values as a program; a quotation containing no words therefore pushes its
elements in order.

Ordinary word evaluation is one observable operation:

1. Determine the occurrence's effective resolution scope.
2. Resolve its spelling to a binding in that scope.
3. Establish the binding's activation context.
4. Evaluate the binding's executable body.

Resolution does not produce a binding or callable value on the operand stack.
Bindings are not first-class, and ordinary word reference always invokes.
Reflection operations inspect binding metadata through separate mechanisms.

Lookup is late. A word occurrence's resolution metadata selects a scope, not
a binding, body, value, or module generation. The binding is looked up each
time the occurrence executes, so replacing a binding in a mutable selected
scope affects existing code. A module image's scope is immutable after
construction; replacing an image in a registration does not retarget words
belonging to the former image. Attempting to resolve through a retired selected
scope is a `'domain` error, never a fallback to another scope.

The reader annotates each word occurrence with its current scope. Moving,
copying, concatenating, or splicing values preserves each occurrence's own
annotation, so one quotation may contain words from several scopes. A
quotation consequently has no single resolution scope. A word occurrence
created without reader context has no scope annotation and resolves in the
invoking activation's resolution context.

A reader-produced aggregate may separately retain **reader lineage**, which
records that the aggregate and its reader-built descendants came from a
particular source construction. Reader lineage supports attribution and the
module-body re-scoping rule; it is not an AST, a captured environment, or a
quotation-wide resolution scope. Runtime aggregate reconstruction does not
acquire reader lineage. Resolution context, reader lineage, and provenance are
semantic metadata on stored occurrences and aggregates, but none is part of
value identity.

ECL therefore has syntactic closure without value capture: reader-authored
identifiers retain their lookup scopes, while quotation values capture no
bindings or ordinary values. An unannotated runtime-created word retains the
dynamic behavior described above.

Tail calls are guaranteed: through word calls, `if`, and every
combinator's tail position, iteration and tail recursion run in constant
space and never exhaust a host call stack.

### Units and the transactional stack

Ordinary evaluation may consume operands and perform effects before it fails;
its failure outcome therefore includes the partial operand stack and the
surviving execution state at the point of failure.

The *unit* is the granularity of operand-stack rollback. If `S_entry` is its
entry stack, unit execution has the relation:

```text
run-unit(P, S_entry, σ) = success(S_result, σ′)
run-unit(P, S_entry, σ) = failure(error, S_entry, σ′)
```

On failure, the evaluator's partial stack is discarded and the entry stack is
restored. Environment writes, I/O, and other permitted non-stack effects
performed before failure survive. A unit boundary may additionally cancel
child tasks as specified by the concurrency semantics. The unit is not a
transaction over the whole execution state.

Units are delimited by the reader or by semantic unit constructors:

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
  are `call`, `dip`, `keep`, `bi`, `tri`, `bi2`, `tri2`, `both`, `if`, `when`,
  `unless`, `case`, and `times`.
- **Checkpointed inline guards**: `cond`, `while`, and `linrec` test quotations run
  in the current scope against a retained operand-stack checkpoint. A test
  may consume, rearrange, or add values; its top value must be a 0/1 boolean,
  and its complete operand result is discarded before control continues from
  the checkpoint. Environment writes, IO, and other non-stack effects are
  inline and therefore survive.
- **Isolated**: the quotation runs on a fresh substack per application,
  seeded with its declared inputs, and its result count is checked
  against the contract. The isolated words are `each`, `zip-with`, `for`,
  `fold`, `scan`, `update`, `stencil`, `unfold`, `infra`, `@attempt`, `@spawn`,
  `@each`, `@module`, and `@defm`.

Every isolated combinator states the stack effect it requires of its
quotation argument (given per word in the reference). The contract is
checked dynamically at each application; a violation is an immediate
`'contract` error naming the element and the observed effect.

### Explicit linear recursion

`linrec` has the ambient-row effect
`( predicate base pre post -- ... )`; all four parameters must be quotations.
It applies them inline on the current operand stack, using this recursion
scheme:

```text
predicate true  -> base
predicate false -> pre; linrec; post
```

At every descent, `predicate` uses the checkpointed inline-guard protocol
above. The predicate runs destructively in the invoking scope, its top result
must be exactly 0 or 1, and the complete operand checkpoint is restored before
either branch begins. On 1, `base` runs from that restored state. On 0, `pre`
runs from it, the recursive descent begins from `pre`'s resulting stack, and
`post` runs after that descent returns. Consequently the four applications
share ambient stack state intentionally; none has an isolated quotation
contract. Fewer than four operands is `'underflow`, a non-quotation parameter
is `'type`, and a missing or non-boolean predicate result follows the ordinary
guard `'underflow`/`'type` behavior.

Each nonterminal descent leaves one explicit `post` continuation in the frame
machine. General `linrec` therefore uses live continuation storage
proportional to recursion depth; it does not recurse on the host stack and it
does not promise constant space when `post` is empty. Predicate snapshot and
restore, recursive setup, cancellation, failure unwind, and value retirement
remain bounded scheduler work. Existing `while` and `unfold` are the
constant-continuation choices for iterative and tail-recursive shapes.

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

#### The `*name*` spelling convention

Leading and trailing `*` mark a value dynamically supplied by the current
execution context rather than consumed from the operand stack. `*file*`
returns the source name attached to its currently executing reader-authored
occurrence; a definition therefore keeps reporting the file that authored its
body when another file calls it. Runtime-assembled code has no source
provenance, so `*file*` is `'domain` there rather than falling back to its
caller. `*module*` returns the canonical registration selected by the current
module activation. The stars are ordinary word characters, not reader syntax,
and the convention applies to shipped vocabulary rather than reserving the
spelling from user definitions.

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

## Bindings and scope

### Scope chains

A scope is a local binding map with a fixed parent. Unqualified resolution
searches locally and then follows that parent chain. The complete scope shapes
are:

```text
core          (no parent)
session   → core
child     → enclosing scope
module image → core
```

Session-authored code may therefore shadow core definitions. A child unit may
define names visible to code authored or dynamically resolved in that child.
A module image sees its own public and private bindings followed by core and
never sees the invoking session. Core and prelude definitions resolve in core.
Parentage does not change after scope creation. Qualified registry resolution
is a separate mechanism, not an edge in a scope chain.

Resolution scope and module home are independent parts of an activation.
Resolution scope determines where a word's spelling is looked up. Module home
determines privacy and registration-owned authority. Homeless helpers preserve
their caller's module home; dispatch into a module changes home according to
the module rules without changing the resolution annotation carried by
caller-supplied words.

### Binding model

There is one namespace and one binding kind. A name binds an executable body
plus metadata, and reference always invokes the body. Values are bound by
capturing them in bodies. Public and private definitions differ in visibility,
not invocation semantics. Native and builtin definitions may have different
representations but expose the same binding model.

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
  `def` to consume. `which` reports the resulting public `def`, while `see`
  prints its literal-capture body, preceded by the annotation when one is
  present; an unannotated `set` has no effect or documentation, and nothing
  distinguishes it from the corresponding `literal` plus `def` spelling. `set` is
  environment assignment, not a lexical binding form. For ordinary local
  values, prefer stack flow or binder locals.
- Redefinition (`def` or `set` over an existing name) replaces the
  complete binding snapshot: omitting an effect or docstring clears the
  old one. Code holding the old body keeps running it safely.
- `see` prints the resolved binding's combined annotation, when present,
  followed by its body through the standard source formatter. It omits the
  navigation header, name, and `def`/`defp` terminator; `which` reports binding
  and effect metadata, and `doc` returns documentation.
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
input checking and honest reflection, and `which` and `see` render the effect
with `-- ...`.

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
an existing definition. Runtime list construction grants neither a
quotation-wide scope nor reader lineage. Existing word occurrences retain
their individual scope annotations; a newly created unannotated word resolves
in the activation that invokes it.

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

Selection operations use the same recursive shape rule on their selector
rather than on the collection value. For a list collection, `at`, `put`, and
`update` descend a nested list selector to integer leaves. `at` preserves the
selector shape, `put` conforms a replacement value to it with atom extension,
and `update` applies its unary quotation at each leaf in left-to-right order.
For a dictionary, the selector is always one atomic whole-value key, even when
that key is a list. The `dict.at` and `dict.update` adapters supply the distinct
operation of traversing an outer list of such whole keys.

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

### Operations and values

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
  `register`, including failure and effect order. The body is evaluated before
  the name is validated or publication is attempted. If construction fails,
  registration is not attempted. If construction succeeds and registration
  fails, completed external construction effects survive under ordinary unit
  semantics. `@defm` introduces no transaction spanning both operations. It
  is the source spelling for a module definition.
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

### Formal module model

The Pantagruel source is
[`formal/modules.pant`](formal/modules.pant). Its documentation and checked
formulae are rendered here as one normative text.

#### Checked model

##### Contexts

**`Calls`**, **`Images`**, **`Registry`**, **`Transactions`**, **`WithinCommit`**

#### Chapter 1

##### Domains

`RegistryName`, `BindingName`

##### Action

> This model is normative for module-image availability; registry names, slots, aliases, generations, and publication; abstract definitions and visibility; call contexts and generation pins; the ordered durable, draft, pending-output, and ambient stacks; and atomic completion or abortion of `within` transactions.  It deliberately abstracts over source spelling and name validation, construction-body evaluation, concrete and nested values, error construction and propagation, task and unit ownership, scheduling and fairness, and storage reclamation. The surrounding language specification governs those subjects. Begin and complete actions expose semantic concurrency boundaries; they are not ECL words. Contexts, including `WithinCommit`, grant formal write authority and do not denote runtime values or additional language state.  A qualified call resolves a registry name and public binding and pins the slot's current generation in one atomic action. Resolution before replacement or removal retains the selected generation; resolution afterward observes only the replacement or the absence of the registration. Explicit qualification always performs this fresh registry dispatch, including when it names the caller's own registration.

**`Calls`** ↝ Begin qualified call *module-name*: `RegistryName`, *binding-name*: `BindingName`.

---

**canonical?** *module-name* ∨ **alias?** *module-name*.

∃ *call*: `Call`, *slot*: `Slot`, *generation*: `Generation`, *image*: `Image`, *definition*: `Definition`, ¬**call-created?** *call*, *slot* = **slot-of** *module-name*, **slot-live?** *slot*, *generation* = **current-generation** *slot*, *image* = **generation-image** *generation*, **binding-present?** *image* *binding-name*, *definition* = **definition-at** *image* *binding-name*, **public?** *definition* · **call-created?**′ *call* ∧ **call-active?**′ *call* ∧ **registered-call?**′ *call* ∧ **call-generation**′ *call* = *generation* ∧ **call-slot**′ *call* = *slot* ∧ **call-image**′ *call* = *image* ∧ **call-definition**′ *call* = *definition* ∧ (∀ *other*: `Call`, *other* ≠ *call* · **call-created?**′ *other* = **call-created?** *other* ∧ **call-active?**′ *other* = **call-active?** *other* ∧ **registered-call?**′ *other* = **registered-call?** *other* ∧ **call-generation**′ *other* = **call-generation** *other* ∧ **call-slot**′ *other* = **call-slot** *other* ∧ **call-image**′ *other* = **call-image** *other* ∧ **call-definition**′ *other* = **call-definition** *other*).

∀ *call*: `Call` · **ambient-depth**′ *call* = **ambient-depth** *call*.

∀ *call*: `Call`, *position*: `Nat` · **ambient-value**′ *call* *position* = **ambient-value** *call* *position*.

#### Chapter 2

##### Domains

> The model distinguishes immutable module images, durable registration slots, and publication generations. One image may be published into several slots; every successful publication creates a distinct generation. A live slot has exactly one canonical name, zero or more direct aliases, one current non-retired generation, and one durable stack. The image supplies only the initial stack template used when a fresh slot is created.  Definitions and initial templates are immutable background relations. Each definition belongs to one image and binding name, binding names are unique within an image, and visibility controls which call actions may select it. The model begins with no constructed or value-held images, created or live slots, occupied names, published generations, calls, or transactions. Domain atoms are possibilities rather than initially existing language values.  Retirement is monotonic: replacement or removal retires the former current generation and no retired generation becomes current again. Active calls retain their selected images and, for registered calls, their generations. An active transaction belongs to one active registered call and its still current live slot. At most one transaction may belong to a call or slot.

`Call`.

`Slot`.

`Generation`.

`Image`.

`Definition`.

`Transaction`.

`Value`.

`WordOccurrence`.

##### Rules

{**`Calls`**} **call-active?** *call*: `Call` ⇒ `Bool`.

{**`Calls`**} **call-created?** *call*: `Call` ⇒ `Bool`.

{**`Calls`**} **registered-call?** *call*: `Call` ⇒ `Bool`.

{**`Calls`**} **call-generation** *call*: `Call` ⇒ `Generation`.

{**`Calls`**} **call-slot** *call*: `Call` ⇒ `Slot`.

{**`Calls`**} **call-image** *call*: `Call` ⇒ `Image`.

{**`Calls`**} **call-definition** *call*: `Call` ⇒ `Definition`.

{**`Calls`**, **`WithinCommit`**} **ambient-depth** *call*: `Call` ⇒ `Nat0`.

{**`Calls`**, **`WithinCommit`**} **ambient-value** *call*: `Call`, *position*: `Nat` ⇒ `Value`.

**invoked-image** *invocation*: `Call` ⇒ `Image`.

**occurrence-name** *occurrence*: `WordOccurrence` ⇒ `BindingName`.

**occurrence-image** *occurrence*: `WordOccurrence` ⇒ `Image`.

{**`Images`**} **constructed?** *image*: `Image` ⇒ `Bool`.

{**`Images`**} **value-held?** *image*: `Image` ⇒ `Bool`.

{**`Registry`**} **canonical?** *name*: `RegistryName` ⇒ `Bool`.

{**`Registry`**} **alias?** *name*: `RegistryName` ⇒ `Bool`.

{**`Registry`**} **slot-of** *name*: `RegistryName` ⇒ `Slot`.

{**`Registry`**} **slot-created?** *slot*: `Slot` ⇒ `Bool`.

{**`Registry`**} **slot-live?** *slot*: `Slot` ⇒ `Bool`.

{**`Registry`**} **current-generation** *slot*: `Slot` ⇒ `Generation`.

{**`Registry`**} **generation-published?** *generation*: `Generation` ⇒ `Bool`.

{**`Registry`**} **generation-retired?** *generation*: `Generation` ⇒ `Bool`.

{**`Registry`**} **generation-slot** *generation*: `Generation` ⇒ `Slot`.

{**`Registry`**} **generation-image** *generation*: `Generation` ⇒ `Image`.

{**`Registry`**, **`WithinCommit`**} **durable-depth** *slot*: `Slot` ⇒ `Nat0`.

{**`Registry`**, **`WithinCommit`**} **durable-value** *slot*: `Slot`, *position*: `Nat` ⇒ `Value`.

{**`Transactions`**, **`WithinCommit`**} **transaction-active?** *transaction*: `Transaction` ⇒ `Bool`.

{**`Transactions`**} **transaction-created?** *transaction*: `Transaction` ⇒ `Bool`.

{**`Transactions`**} **transaction-call** *transaction*: `Transaction` ⇒ `Call`.

{**`Transactions`**} **transaction-slot** *transaction*: `Transaction` ⇒ `Slot`.

{**`Transactions`**} **transaction-generation** *transaction*: `Transaction` ⇒ `Generation`.

{**`Transactions`**, **`WithinCommit`**} **draft-depth** *transaction*: `Transaction` ⇒ `Nat0`.

{**`Transactions`**} **draft-value** *transaction*: `Transaction`, *position*: `Nat` ⇒ `Value`.

{**`Transactions`**, **`WithinCommit`**} **pending-depth** *transaction*: `Transaction` ⇒ `Nat0`.

{**`Transactions`**} **pending-value** *transaction*: `Transaction`, *position*: `Nat` ⇒ `Value`.

**binding-present?** *image*: `Image`, *name*: `BindingName` ⇒ `Bool`.

**definition-at** *image*: `Image`, *name*: `BindingName` ⇒ `Definition`.

**definition-image** *definition*: `Definition` ⇒ `Image`.

**definition-name** *definition*: `Definition` ⇒ `BindingName`.

**public?** *definition*: `Definition` ⇒ `Bool`.

**initial-depth** *image*: `Image` ⇒ `Nat0`.

**initial-value** *image*: `Image`, *position*: `Nat` ⇒ `Value`.

---

∀ *image*: `Image`, *name*: `BindingName`, **binding-present?** *image* *name* · **definition-image** (**definition-at** *image* *name*) = *image* ∧ **definition-name** (**definition-at** *image* *name*) = *name*.

∀ *left*: `Definition`, *right*: `Definition`, **definition-image** *left* = **definition-image** *right*, **definition-name** *left* = **definition-name** *right* · *left* = *right*.

initially ∀ *image*: `Image`, *name*: `BindingName`, **binding-present?** *image* *name* · **definition-image** (**definition-at** *image* *name*) = *image* ∧ **definition-name** (**definition-at** *image* *name*) = *name*.

initially ∀ *left*: `Definition`, *right*: `Definition`, **definition-image** *left* = **definition-image** *right*, **definition-name** *left* = **definition-name** *right* · *left* = *right*.

∀ *registry-name*: `RegistryName` · ¬(**canonical?** *registry-name* ∧ **alias?** *registry-name*).

∀ *registry-name*: `RegistryName`, (**canonical?** *registry-name* ∨ **alias?** *registry-name*) · **slot-live?** (**slot-of** *registry-name*).

∀ *slot*: `Slot`, **slot-live?** *slot* · **slot-created?** *slot*.

∀ *slot*: `Slot`, **slot-live?** *slot* · #(each *registry-name*: `RegistryName`, **canonical?** *registry-name* ∧ **slot-of** *registry-name* = *slot* · *registry-name*) = 1.

∀ *slot*: `Slot`, **slot-live?** *slot* · **generation-published?** (**current-generation** *slot*) ∧ ¬**generation-retired?** (**current-generation** *slot*) ∧ **generation-slot** (**current-generation** *slot*) = *slot*.

∀ *generation*: `Generation`, **generation-published?** *generation* · **constructed?** (**generation-image** *generation*).

∀ *image*: `Image`, **value-held?** *image* · **constructed?** *image*.

∀ *generation*: `Generation`, **generation-retired?** *generation* · **generation-published?** *generation*.

∀ *generation*: `Generation`, **generation-published?** *generation*, ¬**generation-retired?** *generation* · **slot-live?** (**generation-slot** *generation*) ∧ **current-generation** (**generation-slot** *generation*) = *generation*.

∀ *call*: `Call`, **call-active?** *call* · **call-created?** *call*.

∀ *call*: `Call`, **call-active?** *call* · **constructed?** (**call-image** *call*) ∧ **definition-image** (**call-definition** *call*) = **call-image** *call*.

∀ *call*: `Call`, **call-active?** *call*, **registered-call?** *call* · **generation-published?** (**call-generation** *call*) ∧ **generation-slot** (**call-generation** *call*) = **call-slot** *call* ∧ **generation-image** (**call-generation** *call*) = **call-image** *call*.

∀ *transaction*: `Transaction`, **transaction-active?** *transaction* · **transaction-created?** *transaction*.

∀ *transaction*: `Transaction`, **transaction-active?** *transaction* · **call-active?** (**transaction-call** *transaction*) ∧ **registered-call?** (**transaction-call** *transaction*) ∧ **transaction-slot** *transaction* = **call-slot** (**transaction-call** *transaction*) ∧ **transaction-generation** *transaction* = **call-generation** (**transaction-call** *transaction*) ∧ **slot-live?** (**transaction-slot** *transaction*) ∧ **current-generation** (**transaction-slot** *transaction*) = **transaction-generation** *transaction*.

∀ *left*: `Transaction`, *right*: `Transaction`, **transaction-active?** *left*, **transaction-active?** *right*, **transaction-call** *left* = **transaction-call** *right* · *left* = *right*.

∀ *left*: `Transaction`, *right*: `Transaction`, **transaction-active?** *left*, **transaction-active?** *right*, **transaction-slot** *left* = **transaction-slot** *right* · *left* = *right*.

initially ∀ *image*: `Image` · ¬**constructed?** *image* ∧ ¬**value-held?** *image*.

initially ∀ *registry-name*: `RegistryName` · ¬**canonical?** *registry-name* ∧ ¬**alias?** *registry-name*.

initially ∀ *slot*: `Slot` · ¬**slot-created?** *slot* ∧ ¬**slot-live?** *slot*.

initially ∀ *generation*: `Generation` · ¬**generation-published?** *generation* ∧ ¬**generation-retired?** *generation*.

initially ∀ *call*: `Call` · ¬**call-created?** *call* ∧ ¬**call-active?** *call*.

initially ∀ *transaction*: `Transaction` · ¬**transaction-created?** *transaction* ∧ ¬**transaction-active?** *transaction*.

#### Chapter 3

##### Action

> `Construct image` allocates a fresh image identity and establishes its first module-value owner. Its immutable definition map and initial stack template already exist as background relations. Construction creates no name, slot, alias, or generation. Failure before this transition changes no modeled state; evaluation of the body and any external effects are outside this abstraction.

**`Images`** ↝ Construct image.

---

∃ *image*: `Image`, ¬**constructed?** *image* · **constructed?**′ *image* ∧ **value-held?**′ *image* ∧ (∀ *other*: `Image`, *other* ≠ *image* · **constructed?**′ *other* = **constructed?** *other* ∧ **value-held?**′ *other* = **value-held?** *other*).

#### Chapter 4

##### Action

> Image availability follows semantic ownership rather than reclamation mechanics. `value-held?` records that at least one reachable module value owns the image, not a reference count. `Release last value owner` clears that fact only when the final such owner disappears. The action models reachability and is not an ECL operation. Current generations and active calls are the other image owners; scoped words and quotations are not.

**`Images`** ↝ Release last value owner *image*: `Image`, **constructed?** *image*, **value-held?** *image*.

---

¬**value-held?**′ *image* ∧ (∀ *other*: `Image`, *other* ≠ *image* · **value-held?**′ *other* = **value-held?** *other*).

∀ *image*: `Image` · **constructed?**′ *image* = **constructed?** *image*.

#### Chapter 5

##### Action

> `Register` is an ordered upsert. Publishing under a missing canonical name creates a fresh slot initialized from the image's initial template. Publishing under an existing canonical name preserves that slot and its complete durable stack. Every successful registration publishes a fresh generation and retires the previous current generation, even when both generations contain the same image. It cannot interleave with an active transaction on the selected slot or be performed by a call that owns an active transaction.

**`Registry`** ↝ Register *image*: `Image`, *module-name*: `RegistryName`, **constructed?** *image*, **value-held?** *image*, ¬**alias?** *module-name*.

---

∃ *caller*: `Call`, *slot*: `Slot`, *generation*: `Generation`, **call-active?** *caller*, #(each *transaction*: `Transaction`, **transaction-active?** *transaction* ∧ **transaction-call** *transaction* = *caller* · *transaction*) = 0, (**canonical?** *module-name* ∧ *slot* = **slot-of** *module-name* ∨ ¬**canonical?** *module-name* ∧ ¬**slot-created?** *slot*), #(each *transaction*: `Transaction`, **transaction-active?** *transaction* ∧ **transaction-slot** *transaction* = *slot* · *transaction*) = 0, ¬**generation-published?** *generation* · **canonical?**′ *module-name* ∧ ¬**alias?**′ *module-name* ∧ **slot-of**′ *module-name* = *slot* ∧ (∀ *other-name*: `RegistryName`, *other-name* ≠ *module-name* · **canonical?**′ *other-name* = **canonical?** *other-name* ∧ **alias?**′ *other-name* = **alias?** *other-name* ∧ **slot-of**′ *other-name* = **slot-of** *other-name*) ∧ **slot-created?**′ *slot* ∧ **slot-live?**′ *slot* ∧ **current-generation**′ *slot* = *generation* ∧ (∀ *other-slot*: `Slot`, *other-slot* ≠ *slot* · **slot-created?**′ *other-slot* = **slot-created?** *other-slot* ∧ **slot-live?**′ *other-slot* = **slot-live?** *other-slot* ∧ **current-generation**′ *other-slot* = **current-generation** *other-slot*) ∧ **generation-published?**′ *generation* ∧ ¬**generation-retired?**′ *generation* ∧ **generation-slot**′ *generation* = *slot* ∧ **generation-image**′ *generation* = *image* ∧ (∀ *other-generation*: `Generation`, *other-generation* ≠ *generation* · **generation-published?**′ *other-generation* = **generation-published?** *other-generation* ∧ **generation-retired?**′ *other-generation* = (**generation-retired?** *other-generation* ∨ **canonical?** *module-name* ∧ *other-generation* = **current-generation** *slot*) ∧ **generation-slot**′ *other-generation* = **generation-slot** *other-generation* ∧ **generation-image**′ *other-generation* = **generation-image** *other-generation*) ∧ (**canonical?** *module-name* → **durable-depth**′ *slot* = **durable-depth** *slot*) ∧ (¬**canonical?** *module-name* → **durable-depth**′ *slot* = **initial-depth** *image*) ∧ (∀ *position*: `Nat` · (**canonical?** *module-name* → **durable-value**′ *slot* *position* = **durable-value** *slot* *position*) ∧ (¬**canonical?** *module-name* → **durable-value**′ *slot* *position* = **initial-value** *image* *position*)) ∧ (∀ *other-slot*: `Slot`, *other-slot* ≠ *slot* · **durable-depth**′ *other-slot* = **durable-depth** *other-slot* ∧ (∀ *position*: `Nat` · **durable-value**′ *other-slot* *position* = **durable-value** *other-slot* *position*)).

#### Chapter 6

##### Action

> `Add alias` resolves either kind of occupied target name and stores a direct reference to its live slot; semantic alias chains do not exist. The alias shares the slot's current generation, durable stack, serialization, and lifetime. Canonical and alias names form one disjoint namespace, and an occupied name cannot be repointed. Registry mutation is unavailable to a call that owns an active transaction.

**`Registry`** ↝ Add alias *alias-name*: `RegistryName`, *target-name*: `RegistryName`, ¬**canonical?** *alias-name*, ¬**alias?** *alias-name*, (**canonical?** *target-name* ∨ **alias?** *target-name*).

---

∃ *caller*: `Call`, **call-active?** *caller*, #(each *transaction*: `Transaction`, **transaction-active?** *transaction* ∧ **transaction-call** *transaction* = *caller* · *transaction*) = 0 · ¬**canonical?**′ *alias-name* ∧ **alias?**′ *alias-name* ∧ **slot-of**′ *alias-name* = **slot-of** *target-name* ∧ (∀ *other-name*: `RegistryName`, *other-name* ≠ *alias-name* · **canonical?**′ *other-name* = **canonical?** *other-name* ∧ **alias?**′ *other-name* = **alias?** *other-name* ∧ **slot-of**′ *other-name* = **slot-of** *other-name*) ∧ (∀ *slot*: `Slot` · **slot-created?**′ *slot* = **slot-created?** *slot* ∧ **slot-live?**′ *slot* = **slot-live?** *slot* ∧ **current-generation**′ *slot* = **current-generation** *slot* ∧ **durable-depth**′ *slot* = **durable-depth** *slot* ∧ (∀ *position*: `Nat` · **durable-value**′ *slot* *position* = **durable-value** *slot* *position*)) ∧ (∀ *generation*: `Generation` · **generation-published?**′ *generation* = **generation-published?** *generation* ∧ **generation-retired?**′ *generation* = **generation-retired?** *generation* ∧ **generation-slot**′ *generation* = **generation-slot** *generation* ∧ **generation-image**′ *generation* = **generation-image** *generation*).

#### Chapter 7

##### Action

> `Remove` resolves a canonical name or alias to its slot, then atomically closes that slot, removes its canonical name and every alias, retires its current generation, and discards its durable stack. Removal does not end already active calls, whose pins remain valid, but those calls cannot start a new transaction after closure. A later registration of the same spelling must allocate a fresh slot. Removal cannot interleave with a transaction on the slot or be performed by a call that owns an active transaction.

**`Registry`** ↝ Remove *module-name*: `RegistryName`, (**canonical?** *module-name* ∨ **alias?** *module-name*).

---

∃ *caller*: `Call`, *slot*: `Slot`, **call-active?** *caller*, #(each *transaction*: `Transaction`, **transaction-active?** *transaction* ∧ **transaction-call** *transaction* = *caller* · *transaction*) = 0, *slot* = **slot-of** *module-name*, #(each *transaction*: `Transaction`, **transaction-active?** *transaction* ∧ **transaction-slot** *transaction* = *slot* · *transaction*) = 0 · (∀ *registry-name*: `RegistryName` · **canonical?**′ *registry-name* = (**canonical?** *registry-name* ∧ **slot-of** *registry-name* ≠ *slot*) ∧ **alias?**′ *registry-name* = (**alias?** *registry-name* ∧ **slot-of** *registry-name* ≠ *slot*) ∧ **slot-of**′ *registry-name* = **slot-of** *registry-name*) ∧ **slot-created?**′ *slot* = **slot-created?** *slot* ∧ ¬**slot-live?**′ *slot* ∧ **current-generation**′ *slot* = **current-generation** *slot* ∧ **durable-depth**′ *slot* = 0 ∧ (∀ *position*: `Nat` · **durable-value**′ *slot* *position* = **durable-value** *slot* *position*) ∧ (∀ *other-slot*: `Slot`, *other-slot* ≠ *slot* · **slot-created?**′ *other-slot* = **slot-created?** *other-slot* ∧ **slot-live?**′ *other-slot* = **slot-live?** *other-slot* ∧ **current-generation**′ *other-slot* = **current-generation** *other-slot* ∧ **durable-depth**′ *other-slot* = **durable-depth** *other-slot* ∧ (∀ *position*: `Nat` · **durable-value**′ *other-slot* *position* = **durable-value** *other-slot* *position*)) ∧ (∀ *generation*: `Generation` · **generation-published?**′ *generation* = **generation-published?** *generation* ∧ **generation-retired?**′ *generation* = (**generation-retired?** *generation* ∨ *generation* = **current-generation** *slot*) ∧ **generation-slot**′ *generation* = **generation-slot** *generation* ∧ **generation-image**′ *generation* = **generation-image** *generation*).

#### Chapter 8

##### Action

> `Begin image call` invokes a public binding through a module value. The invocation pins the image directly and has no registration, slot, or generation context. The image must still have a module-value owner when the call begins.

**`Calls`** ↝ Begin image call *binding-name*: `BindingName`.

---

∃ *callee*: `Call`, *image*: `Image`, *definition*: `Definition`, ¬**call-created?** *callee*, *image* = **invoked-image** *callee*, **constructed?** *image*, **value-held?** *image*, **binding-present?** *image* *binding-name*, *definition* = **definition-at** *image* *binding-name*, **public?** *definition* · **call-created?**′ *callee* ∧ **call-active?**′ *callee* ∧ ¬**registered-call?**′ *callee* ∧ **call-generation**′ *callee* = **call-generation** *callee* ∧ **call-slot**′ *callee* = **call-slot** *callee* ∧ **call-image**′ *callee* = *image* ∧ **call-definition**′ *callee* = *definition* ∧ (∀ *other*: `Call`, *other* ≠ *callee* · **call-created?**′ *other* = **call-created?** *other* ∧ **call-active?**′ *other* = **call-active?** *other* ∧ **registered-call?**′ *other* = **registered-call?** *other* ∧ **call-generation**′ *other* = **call-generation** *other* ∧ **call-slot**′ *other* = **call-slot** *other* ∧ **call-image**′ *other* = **call-image** *other* ∧ **call-definition**′ *other* = **call-definition** *other*) ∧ (∀ *call*: `Call` · **ambient-depth**′ *call* = **ambient-depth** *call* ∧ (∀ *position*: `Nat` · **ambient-value**′ *call* *position* = **ambient-value** *call* *position*)).

#### Chapter 9

##### Action

> `Begin scoped call` resolves the name stored in a word occurrence against the image stored in that occurrence. A quotation or word occurrence owns this scope but does not cache a definition or generation. The image must still be available through a module value, a current generation, or another active call. Same-image dispatch from a registered caller preserves its pinned slot and generation; other scoped dispatch has no registration context. Private definitions are therefore available to same-image scoped resolution without becoming publicly invocable.

**`Calls`** ↝ Begin scoped call *binding-name*: `BindingName`.

---

∃ *caller*: `Call`, *occurrence*: `WordOccurrence`, *image*: `Image`, *definition*: `Definition`, *callee*: `Call`, **call-active?** *caller*, **occurrence-name** *occurrence* = *binding-name*, *image* = **occurrence-image** *occurrence*, **constructed?** *image*, (**value-held?** *image* ∨ #(each *slot*: `Slot`, **slot-live?** *slot* ∧ **generation-image** (**current-generation** *slot*) = *image* · *slot*) > 0 ∨ #(each *owner*: `Call`, **call-active?** *owner* ∧ **call-image** *owner* = *image* · *owner*) > 0), **binding-present?** *image* *binding-name*, *definition* = **definition-at** *image* *binding-name*, ¬**call-created?** *callee* · **call-created?**′ *callee* ∧ **call-active?**′ *callee* ∧ **registered-call?**′ *callee* = (**registered-call?** *caller* ∧ **call-image** *caller* = *image*) ∧ (**registered-call?** *caller* ∧ **call-image** *caller* = *image* → **call-generation**′ *callee* = **call-generation** *caller* ∧ **call-slot**′ *callee* = **call-slot** *caller*) ∧ (¬(**registered-call?** *caller* ∧ **call-image** *caller* = *image*) → **call-generation**′ *callee* = **call-generation** *callee* ∧ **call-slot**′ *callee* = **call-slot** *callee*) ∧ **call-image**′ *callee* = *image* ∧ **call-definition**′ *callee* = *definition* ∧ (∀ *other*: `Call`, *other* ≠ *callee* · **call-created?**′ *other* = **call-created?** *other* ∧ **call-active?**′ *other* = **call-active?** *other* ∧ **registered-call?**′ *other* = **registered-call?** *other* ∧ **call-generation**′ *other* = **call-generation** *other* ∧ **call-slot**′ *other* = **call-slot** *other* ∧ **call-image**′ *other* = **call-image** *other* ∧ **call-definition**′ *other* = **call-definition** *other*) ∧ (∀ *call*: `Call` · **ambient-depth**′ *call* = **ambient-depth** *call* ∧ (∀ *position*: `Nat` · **ambient-value**′ *call* *position* = **ambient-value** *call* *position*)).

#### Chapter 10

##### Action

> `Complete call` releases the call's image and generation pins after its invocation has completed and no transaction belongs to it. Calls are split into begin and complete actions only to express publication concurrency; the prose-level invocation remains one language operation.

**`Calls`** ↝ Complete call *completed*: `Call`, **call-active?** *completed*, #(each *transaction*: `Transaction`, **transaction-active?** *transaction* ∧ **transaction-call** *transaction* = *completed* · *transaction*) = 0.

---

**call-created?**′ *completed* = **call-created?** *completed* ∧ ¬**call-active?**′ *completed* ∧ **registered-call?**′ *completed* = **registered-call?** *completed* ∧ **call-generation**′ *completed* = **call-generation** *completed* ∧ **call-slot**′ *completed* = **call-slot** *completed* ∧ **call-image**′ *completed* = **call-image** *completed* ∧ **call-definition**′ *completed* = **call-definition** *completed* ∧ **ambient-depth**′ *completed* = 0 ∧ (∀ *position*: `Nat` · **ambient-value**′ *completed* *position* = **ambient-value** *completed* *position*) ∧ (∀ *other*: `Call`, *other* ≠ *completed* · **call-created?**′ *other* = **call-created?** *other* ∧ **call-active?**′ *other* = **call-active?** *other* ∧ **registered-call?**′ *other* = **registered-call?** *other* ∧ **call-generation**′ *other* = **call-generation** *other* ∧ **call-slot**′ *other* = **call-slot** *other* ∧ **call-image**′ *other* = **call-image** *other* ∧ **call-definition**′ *other* = **call-definition** *other* ∧ **ambient-depth**′ *other* = **ambient-depth** *other* ∧ (∀ *position*: `Nat` · **ambient-value**′ *other* *position* = **ambient-value** *other* *position*)).

#### Chapter 11

##### Action

> `Begin within` requires an active registered call whose pinned generation is still current in a live slot. It allocates one transaction, copies the slot's durable stack into a private ordered draft, and begins with no pending outputs. It is unavailable for anonymous or homeless calls, for a retired or closed registration, while the caller already owns a transaction, or while another transaction owns the slot. Thus transactions never nest and are serialized per slot.

**`Transactions`** ↝ Begin within *caller*: `Call`, **call-active?** *caller*, **registered-call?** *caller*, **slot-live?** (**call-slot** *caller*), **current-generation** (**call-slot** *caller*) = **call-generation** *caller*, #(each *active*: `Transaction`, **transaction-active?** *active* ∧ **transaction-call** *active* = *caller* · *active*) = 0, #(each *active*: `Transaction`, **transaction-active?** *active* ∧ **transaction-slot** *active* = **call-slot** *caller* · *active*) = 0.

---

∃ *slot*: `Slot`, *generation*: `Generation`, *transaction*: `Transaction`, *slot* = **call-slot** *caller*, *generation* = **call-generation** *caller*, ¬**transaction-created?** *transaction* · **transaction-created?**′ *transaction* ∧ **transaction-active?**′ *transaction* ∧ **transaction-call**′ *transaction* = *caller* ∧ **transaction-slot**′ *transaction* = *slot* ∧ **transaction-generation**′ *transaction* = *generation* ∧ **draft-depth**′ *transaction* = **durable-depth** *slot* ∧ (∀ *position*: `Nat` · **draft-value**′ *transaction* *position* = **durable-value** *slot* *position*) ∧ **pending-depth**′ *transaction* = 0 ∧ (∀ *position*: `Nat` · **pending-value**′ *transaction* *position* = **pending-value** *transaction* *position*) ∧ (∀ *other*: `Transaction`, *other* ≠ *transaction* · **transaction-created?**′ *other* = **transaction-created?** *other* ∧ **transaction-active?**′ *other* = **transaction-active?** *other* ∧ **transaction-call**′ *other* = **transaction-call** *other* ∧ **transaction-slot**′ *other* = **transaction-slot** *other* ∧ **transaction-generation**′ *other* = **transaction-generation** *other* ∧ **draft-depth**′ *other* = **draft-depth** *other* ∧ **pending-depth**′ *other* = **pending-depth** *other* ∧ (∀ *position*: `Nat` · **draft-value**′ *other* *position* = **draft-value** *other* *position* ∧ **pending-value**′ *other* *position* = **pending-value** *other* *position*)).

#### Chapter 12

##### Action

> `Without` removes the top value from a nonempty draft and appends it to the transaction's pending-output sequence. The sequence preserves invocation order. The guard makes the action unavailable outside an active transaction or on an empty draft; the prose specification assigns the corresponding ECL errors.

**`Transactions`** ↝ Without *transaction*: `Transaction`, **transaction-active?** *transaction*, **draft-depth** *transaction* > 0.

---

∃ *top*: `Nat`, *destination*: `Nat`, *top* = **draft-depth** *transaction*, *destination* = **pending-depth** *transaction* + 1 · **transaction-created?**′ *transaction* = **transaction-created?** *transaction* ∧ **transaction-active?**′ *transaction* = **transaction-active?** *transaction* ∧ **transaction-call**′ *transaction* = **transaction-call** *transaction* ∧ **transaction-slot**′ *transaction* = **transaction-slot** *transaction* ∧ **transaction-generation**′ *transaction* = **transaction-generation** *transaction* ∧ **draft-depth**′ *transaction* = **draft-depth** *transaction* - 1 ∧ (∀ *position*: `Nat` · **draft-value**′ *transaction* *position* = **draft-value** *transaction* *position*) ∧ **pending-depth**′ *transaction* = **pending-depth** *transaction* + 1 ∧ **pending-value**′ *transaction* *destination* = **draft-value** *transaction* *top* ∧ (∀ *position*: `Nat`, *position* ≠ *destination* · **pending-value**′ *transaction* *position* = **pending-value** *transaction* *position*) ∧ (∀ *other*: `Transaction`, *other* ≠ *transaction* · **transaction-created?**′ *other* = **transaction-created?** *other* ∧ **transaction-active?**′ *other* = **transaction-active?** *other* ∧ **transaction-call**′ *other* = **transaction-call** *other* ∧ **transaction-slot**′ *other* = **transaction-slot** *other* ∧ **transaction-generation**′ *other* = **transaction-generation** *other* ∧ **draft-depth**′ *other* = **draft-depth** *other* ∧ **pending-depth**′ *other* = **pending-depth** *other* ∧ (∀ *position*: `Nat` · **draft-value**′ *other* *position* = **draft-value** *other* *position* ∧ **pending-value**′ *other* *position* = **pending-value** *other* *position*)).

#### Chapter 13

##### Action

> `Commit within` is one atomic publication. The complete remaining draft replaces the slot's durable stack, and all pending outputs append to the caller's ambient stack in order. Neither stack exposes an intermediate state. The transaction then becomes inactive and relinquishes its private stacks.

**`WithinCommit`** ↝ Commit within *transaction*: `Transaction`, **transaction-active?** *transaction*.

---

∃ *caller*: `Call`, *slot*: `Slot`, *caller* = **transaction-call** *transaction*, *slot* = **transaction-slot** *transaction* · ¬**transaction-active?**′ *transaction* ∧ **draft-depth**′ *transaction* = 0 ∧ **pending-depth**′ *transaction* = 0 ∧ (∀ *other*: `Transaction`, *other* ≠ *transaction* · **transaction-active?**′ *other* = **transaction-active?** *other* ∧ **draft-depth**′ *other* = **draft-depth** *other* ∧ **pending-depth**′ *other* = **pending-depth** *other*) ∧ **durable-depth**′ *slot* = **draft-depth** *transaction* ∧ (∀ *position*: `Nat` · **durable-value**′ *slot* *position* = **draft-value** *transaction* *position*) ∧ (∀ *other-slot*: `Slot`, *other-slot* ≠ *slot* · **durable-depth**′ *other-slot* = **durable-depth** *other-slot* ∧ (∀ *position*: `Nat` · **durable-value**′ *other-slot* *position* = **durable-value** *other-slot* *position*)) ∧ **ambient-depth**′ *caller* = **ambient-depth** *caller* + **pending-depth** *transaction* ∧ (∀ *position*: `Nat`, *position* ≤ **ambient-depth** *caller* · **ambient-value**′ *caller* *position* = **ambient-value** *caller* *position*) ∧ (∀ *source*: `Nat`, *source* ≤ **pending-depth** *transaction* · ∃ *destination*: `Nat`, *destination* = **ambient-depth** *caller* + *source* · **ambient-value**′ *caller* *destination* = **pending-value** *transaction* *source*) ∧ (∀ *position*: `Nat`, *position* > **ambient-depth** *caller* + **pending-depth** *transaction* · **ambient-value**′ *caller* *position* = **ambient-value** *caller* *position*) ∧ (∀ *other-call*: `Call`, *other-call* ≠ *caller* · **ambient-depth**′ *other-call* = **ambient-depth** *other-call* ∧ (∀ *position*: `Nat` · **ambient-value**′ *other-call* *position* = **ambient-value** *other-call* *position*)).

#### Chapter 14

##### Action

> `Abort within` makes the transaction inactive and discards its draft and pending outputs without changing the durable or ambient stack. Effects not represented by those stacks lie outside the transaction and are not rolled back.

**`Transactions`** ↝ Abort within *transaction*: `Transaction`, **transaction-active?** *transaction*.

---

¬**transaction-active?**′ *transaction* ∧ **transaction-created?**′ *transaction* = **transaction-created?** *transaction* ∧ **transaction-call**′ *transaction* = **transaction-call** *transaction* ∧ **transaction-slot**′ *transaction* = **transaction-slot** *transaction* ∧ **transaction-generation**′ *transaction* = **transaction-generation** *transaction* ∧ **draft-depth**′ *transaction* = 0 ∧ **pending-depth**′ *transaction* = 0 ∧ (∀ *position*: `Nat` · **draft-value**′ *transaction* *position* = **draft-value** *transaction* *position* ∧ **pending-value**′ *transaction* *position* = **pending-value** *transaction* *position*).

∀ *other*: `Transaction`, *other* ≠ *transaction* · **transaction-active?**′ *other* = **transaction-active?** *other* ∧ **transaction-created?**′ *other* = **transaction-created?** *other* ∧ **transaction-call**′ *other* = **transaction-call** *other* ∧ **transaction-slot**′ *other* = **transaction-slot** *other* ∧ **transaction-generation**′ *other* = **transaction-generation** *other* ∧ **draft-depth**′ *other* = **draft-depth** *other* ∧ **pending-depth**′ *other* = **pending-depth** *other* ∧ (∀ *position*: `Nat` · **draft-value**′ *other* *position* = **draft-value** *other* *position* ∧ **pending-value**′ *other* *position* = **pending-value** *other*
*position*).



### Construction and definitions

- **Construction uses ordinary unit rollback.** Its scope, bindings, and draft
  initial-state stack are provisional. On failure they are discarded and no
  module value is produced. I/O, completed registry publications, and other
  external effects performed by the body are not rolled back; child tasks are
  cancelled by the ordinary failing-unit rule. Registration commits atomically
  only after an image exists. A failed registration leaves the previous
  directory entry, current generation, and durable state exactly as they were.
- The registry is flat. A module body may register another module, but that
  registration creates an independent module with its own canonical name
  and lifetime; it does not establish lexical nesting or parent ownership.
  Registrations commit independently, so a completed inner registration
  remains published if the outer construction body later fails.
- **Privacy is set at the definition site**: inside a module body, `def`
  and `set` bind public (exported); `defp` and `setp` bind private. Module
  bindings carry the same optional annotations as top-level ones, so a
  module word may be unannotated, documentation-only, effect-only, or
  both; `set`/`setp` publish the bare literal capture. Privacy is
  subtractive — privates are
  absent from the module's public face, not access-checked. Definitions
  made inside the module body's isolated child units (e.g. inside an
  `@attempt`) are dynamic and are never exported.
- **Tests are a distinct module-owned namespace.**
  `annotation? (body) 'name test` accepts the same optional effect and
  documentation forms as `def`, but only while the exact direct construction
  body of `@module` or `@defm` is executing. A nested quotation, child unit,
  or top-level use is `'domain`. Test names may equal public or private word
  names because catalog entries never enter local lookup, qualified lookup,
  imports, `words`, reflection, or module invocation. Application Sessions
  still validate placement, annotations, names, and bodies, then discard the
  declaration without retaining it or checking test-name uniqueness. Test
  Sessions retain the catalog; duplicate test names in one test image are
  `'domain`.
- A test-built module image freezes its definitions, initial-state template,
  and test catalog together; an application-built image has an empty catalog.
  Registration publishes that image as one generation:
  reload replaces code and tests atomically while preserving slot state;
  removal removes both; aliases never create another suite; and registering
  one image under two canonical names creates two independently discoverable
  suites with independent registration state.
- **Test discovery and execution form a closed Session mode.** Ordinary
  Sessions reject `tests` and `@test` with `'domain`. A test Session's `tests`
  returns canonical registrations once each, sorted by module then test name,
  as dictionaries containing symbol fields `'module` and `'name` plus any
  declared `'effect` and `'doc`. Descriptors contain no body, private name,
  generation handle, state handle, or executable capability.
- `descriptor @test` validates and late-binds the descriptor against the
  current canonical registration. A present test runs in a fresh isolated
  Unit under that generation's private home and real durable registration
  state. It returns exactly `{'ok (values)}` or `{'err error}`; a removed or
  replaced-away test is a reified missing-test error. The runner's operand
  stack never seeds the test, state mutations persist between invocations in
  the Session, and Session teardown destroys that state. External effects are
  not transactional or rolled back.
- **`ecl test` delegates framework policy to ECL.** The command requires a
  valid lock-backed root project, enumerates and loads only modules exported
  by its root package catalog, then calls the public qualified runner selected
  by `--runner` (default `test.default.run`). Tokens after `--` are ordinary
  `args`. Successful completion is status 0; `exit` selects the requested
  status; project, load, resolve, or runner failures are command failures.
  The default runner is sequential and deterministic, reports every result,
  continues after ordinary failures, and exits 1 when any test failed.
- `*module*`, `within`, and every other slot-dependent operation use only the
  registration context established by actual dispatch; they never infer one
  from image identity. Missing authority becomes a `'domain` error only when
  such an operation is reached, so anonymous stateless code and private calls
  remain valid. An application through escaped module-authored code still
  crosses a module boundary for effect checking, despite having no slot. An
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
  because each word occurrence carries its own scope rather than inheriting
  one from the quotation or activation. `all?` hands `each` its caller's `q`,
  whose words were written in the session, and hands `fold` its own `(and)`,
  whose word was written in the prelude; each resolves where its occurrence
  was written from the same activation. Splicing or rearranging quotations
  preserves the annotations on their existing word occurrences. Only a word
  created without reader context is unannotated and resolves dynamically in
  its invoking activation.
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
  Applying a word whose scoped image is no longer available is `'domain`, never
  a fallback to core, the invoking chain, or a newer registered generation.
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
  against the current registration's durable stack rather than the ambient
  operand stack. It requires a
  `registered(generation, slot, image)` invocation context. A construction root, anonymous
  `invoke`, escaped module quotation, or session activation has no slot and
  raises `'domain` if it reaches `within`. The operation never infers a slot
  from an image or targets some caller's slot. Homeless helpers and same-image
  calls preserve an existing registered context; dispatch into another image
  replaces it according to the ordinary invocation rules. There is no
  module-value-targeted form. Inputs cross the boundary only when the invoking
  code captures them explicitly with `partial` or `with`. Semantically,
  `within` is the module-state counterpart of `infra`: `infra` names a supplied
  list as a temporary stack, while `within` selects the active registration's
  durable stack.
- **`without` is the explicit outward boundary.** Inside an active
  `within` quotation, `without` moves its top value outward; elsewhere it is
  `'domain`, and on an empty stack it is `'underflow`. A value remains in the
  durable stack and is also returned only when the quotation duplicates it
  before `without`; captured values stay in state unless the quotation consumes
  or moves them outward.
- I/O and other effects performed by a failing `within` quotation are not
  rolled back. A later failure in the enclosing word or unit does not roll back
  a transaction that already returned.
- Concurrent `within` attempts have no specified FIFO order or fairness
  policy. Transactions on distinct slots and activity unrelated to a
  registration's durable stack may proceed concurrently.
- **A `within` transaction cannot wait on another ECL task.** `await`,
  `await-all`, `await-any`, `await-for`, and any other task-waiting operation
  raise `'domain` while a `within` transaction is active, even if the requested
  result is already available. The error occurs before consuming a task or
  registering a wait. An implementation may preempt or internally suspend the
  executing task for scheduling or I/O without changing the semantics: the
  transaction retains exclusive use of its slot until it succeeds or fails,
  while unrelated tasks and other registration slots may continue.
- **`within` transactions do not nest.** If a `within` transaction is active,
  reaching another `within` raises `'domain` before inspecting or acquiring
  its target slot. This applies to the same slot, an alias of that slot, and a
  different module's slot alike. Ordinary calls into the same or another
  module remain legal; a call fails on this ground only if it reaches another
  `within`.
- **A `within` transaction cannot mutate the module registry.** `register`,
  `unmodule`, `alias`, and any other primitive registry mutation raise
  `'domain` while a transaction is active. The error occurs before that
  operation consumes its operands, resolves a target registration, or
  publishes any registry change. A derived sequence may perform earlier
  operations before it reaches the prohibited mutation: in particular,
  `@defm` may complete its `@module` phase before `register` raises. A
  transaction therefore holds authority over exactly its already-selected
  slot and cannot acquire registration authority over another slot as a side
  effect.
- **Slot lifetime is an owned capability.** Every published generation owns a
  non-retargetable slot lease for its whole lifetime. Resolution retains an
  operation lease before dropping the directory snapshot that supplied the
  slot entry, and `within`, reload, and removal retain that witness across
  their complete check/use interval.
  Removal does not wait for old generation pins, but retired slot storage is
  not reusable until all such leases, the arbiter, and old directory snapshots
  have drained. A removed generation can therefore observe only its original
  closed slot, never an unrelated module that later reuses registry capacity.
- Failed registration changes neither code nor state. Stack-layout evolution
  is an explicit user protocol: replacement code must understand the retained
  representation and may migrate it with an ordinary `within`; ECL neither
  inspects nor names positions in the stack.
- `unmodule` accepts a canonical name or alias. An unregistered name is
  `'undefined-word`; attempting removal during a `within` transaction is
  `'domain` under the general registry-mutation rule. An already-dispatched
  call may finish after removal, but attempting a new `within` from its retired
  generation is `'domain`.
- Module state is process-local: there is no persistence across process
  restart, and the native ABI exposes no module-state capability, so an
  `.eclmod` word can neither observe an internal module home nor reach a durable
  stack.
- **Surface**: `import` consumes a module-name symbol and a list of attribute
  symbols, then publishes those attributes under their own names in the current
  environment — which inside a module body means the image, publicly, on the
  same terms `def` binds there. It validates every symbol and resolves every
  public attribute against one pinned module generation before publishing the
  first binding. A missing or private attribute is `'undefined-word` and
  publishes none of the request; malformed operand and name domains are
  `'type` and `'domain`, respectively. Each binding is a late-bound forwarding
  definition whose effect and documentation are copied from the original.
  Naming a binding that already exists replaces only that binding; importing
  selected names never splices an entire module or emits shadow notices.
  Dotted words split at their final dot and give qualified access with
  no import. `qualify` validates a module-name symbol and an unqualified
  binding-name symbol and constructs the corresponding executable word;
  `execute` applies that word through ordinary late-bound dispatch, preserving
  its module home, private lookup, annotations, tracing, native/builtin path,
  cancellation, and `within` authority. `alias` registers a short registry
  name; aliases and module
  names may not collide in either direction. `which` shows any name's
  resolution.
- **Qualified resolution observes registrations only.** A qualified name
  splits at its final dot into a module name and a public binding name. The
  module name selects a canonical registration directly or through an alias.
  A missing registration or public binding raises `'undefined-word`.
  Filesystem search, embedded resources, package catalogs, native loading, and
  eager or on-demand acquisition are host facilities outside the language
  semantics. A host may obtain and register an image by any means, but ECL
  programs observe only the resulting registration, never whether a module is
  "loaded" or how it was transported.

## Legacy material

The rewritten report currently ends here. Unreviewed core-language material is
preserved verbatim in [`LEGACY_LANGUAGE.md`](LEGACY_LANGUAGE.md). Material
already identified as belonging to the standard environment, host, packages,
CLI, or formatter is preserved verbatim in
[`LEGACY_ENVIRONMENT.md`](LEGACY_ENVIRONMENT.md). These files are migration
inputs, not hidden continuations of this specification.
