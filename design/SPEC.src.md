<!-- include:generated-preamble -->
# ecl — language specification

## Status, scope, and conformance

This document defines the syntax and semantics of the ECL language. The
language is defined independently of any implementation representation,
interpreter architecture, host interface, or distribution. This document
defines the language; the shipped ECL interpreter is its reference
implementation.

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
governed by this prose. A finite model-checking bound serves only the
verification machinery and imposes no ECL implementation limit. A contradiction between prose and
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
looked up, while lookup remains late: they retain a scope and resolve the
binding at execution time.

A unit is the boundary of failure and operand-stack rollback. Modules separate
immutable code images from named registrations; a registration owns the
durable operand stack used by stateful module operations. Tasks execute
isolated units under structured concurrency.

## Notation and terminology

In a stack effect `( before -- after )`, the top of the operand stack is at
the right. Names in an effect describe positions and introduce no runtime variables. `S`
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
     required on both sides of `.` — `.5` and `5.` therefore lex as words.
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
only); any other escape is a parse error. A string uses the rank-1 char-vector
role of a list.

The exact form `<...>` is reserved as an unparseable runtime display marker
wherever an atom may occur. The same bytes inside a string literal are ordinary
character data.

### Forms

```ebnf
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
  one there is an error whose message identifies `partial` as construction of
  a reusable capturing quotation. The sugar does not involve `set`; locals and
  environment assignment are unrelated mechanisms.

## Values and external representations

<!-- include:value-model -->

### Representation and language roles

A conforming implementation may choose any representation for values but must
not expose an additional kind through `type`, matching, hashing, ordering,
printing, or an ECL-facing native interface. Adding a first-class kind is a
language extension. Bindings are not values.

Operations on lists and dictionaries produce values; storage reuse is not
observable language behavior. `def` and `set` replace bindings rather than
mutating values. Storage specialization, copy-on-write strategies, and
amortized bounds are implementation or performance concerns.

Float values use IEEE 754 binary64, excluding NaN; `inf` and `-inf` are
ordinary values. Integer overflow is an error, never wrapping or promotion.
See Numbers.

A bare word in code and a quoted symbol are distinct source atoms: `(dup)
first` yields the word `dup`, while `'dup` yields the symbol. Words print bare
and symbols print quoted. Resolution and provenance metadata belong to stored
word occurrences rather than their values.

A quotation, vector, and matrix row are list roles. A homogeneous list of
atoms *is* a vector—`(1 2 3)` and `[1 2 3]` are the same value. There is no
rank-carrying array type: a matrix is a list of equal-length lists, rank is
depth rather than intrinsic data, and ragged lists remain legal.

Dictionary insertion order is preserved by storage, iteration, and printing.
A task is a runtime capability bound to its session and prints as `<task:N>`.
A module is an opaque immutable image and prints as `<module>`. A port is an
opaque, identity-bearing capability for a host endpoint and prints as
`<port:N>`. Task, module, and port displays are rejected by the reader. Port
identity is observable only through ordinary whole-value matching and hashing;
no conforming operation may recover an operating-system descriptor, process
identifier, or implementation pointer from one.

### Readable representations and display

A **diagnostic display** is human-facing text without a read-back guarantee.
An operation may produce display text for every value, but any print/read
guarantee applies only to the formally defined readable subset. Reader
provenance, resolution metadata, and reader lineage need not be reproduced by
that round trip.

Printing never exposes storage specialization. A non-string list uses `[...]`
when its value has canonical array shape—a homogeneous flat vector or a
rectangular nesting of such vectors—and `(...)` otherwise. Both delimiters
read as the same list kind. Thus `(1 2 3)` prints as `[1 2 3]`, while the
ragged result of `[[1 2] [3]] 10 *` prints as `([10 20] [30])`. Strings use
quoted string syntax.

<!-- include:printing-model -->

`io.pp` and the REPL use a best-effort display layout with canonical atom
spellings and delimiters. Rows of rectangular matrices, plus one enclosing
group axis, are separated by newline and indentation. A displayed non-string
list longer than 256 elements becomes `[<N-values-elided>]` or
`(<N-values-elided>)` according to its delimiter. A displayed string longer
than 256 characters becomes `"<N-characters-elided>"`. Elision occurs before
matrix-shape scanning or child rendering. Canonical `str` output never elides.

A displayed dictionary remains compact when it has at most three pairs and
contains no nested dictionary or matrix-valued key or value. Every other
dictionary uses one pair per indented line, applying the same choice
recursively. Flat vector fields remain compact. Canonical `str` output is
always compact.

`io.stack` applies the same per-value display layout and emits each visible
operand slot as a bottom-up indexed block. `[0]` is the bottom of the visible
window and the largest index is its top; continuation lines align after the
index prefix. The denser REPL layout instead keeps stack order from left to
right and places each value's rectangle beside its neighbors on a shared
bottom row. Padding is measured in bytes and ends with each row's last value.
Neither layout wraps to terminal width.

### Equality and ordering

`match?` exposes the model's whole-value equivalence. Numeric magnitude maps
binary64 values to their exact mathematical values: `2` matches `2.0`, and
`0.0` matches `-0.0`; a mixed comparison does not first round an integer to
binary64. Matching specifies structural data equivalence, so two matching
quotations may nevertheless behave differently when applied.

`=` is instead pervasive equality: it descends aggregate structure and
produces a scalar boolean or boolean mask (see Pervasion). For example,
`[1 2] [1 2] =` is `[1 1]`, while `[1 2] [1 2] match?` is `1`.

- `cmp` is a three-way total ordering (−1/0/1) on numbers, chars (by
  codepoint), and strings (codepoint-lexicographic). Anything else,
  including cross-kind pairs, is a `'type` error. `grade` orders by
  exactly this ordering.
- Words that require a boolean reject every value outside the formally defined
  Boolean role, including other ints.

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

Lookup is late. A word occurrence's resolution metadata selects only a scope.
Each execution looks up the binding in that scope; the occurrence retains no
binding, body, value, or module generation. Replacing a binding in a mutable selected
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

Tail calls are guaranteed: through word calls, `if`, and every combinator's
documented tail position, iteration and tail recursion run in constant space
and never exhaust a host call stack. General `linrec` retains one explicit
recursion level per nonterminal descent, even when `post` is empty, so its live
storage is proportional to recursion depth rather than constant.

### Errors

Errors are crash-only. There is no try/catch or handler quotation: an error
propagates until the enclosing unit dies. `raise` initiates that propagation
from an error value, and `fail` is sugar for raising an error whose kind is
`'user` and whose message is the supplied string.

Failure is observed as data only outside an explicit boundary: `@attempt`, or
the concurrent `@spawn`/`await` path, returns `{'ok (values)}` after success or
`{'err error}` after failure. Each envelope is an ordinary dictionary and is
the boundary's only result value. The REPL is the implicit top-level boundary;
a script's boundary is the process.

Source-position and other diagnostic fields appear when known. Absence is
represented by an absent field, never by a nil value. Runtime-assembled code
has no source position by construction, and no host exception or host stack
frame is exposed as ECL error data.

A completion-time source-word effect violation identifies the opening
delimiter of the deepest reader-built quotation selected by ordinary tail
control in that checked activation. The checked body supplies the initial
location. An empty selected quotation identifies its opening `(`.

Non-tail helper calls and isolated or inline application iterations preserve
that location. An application's own contract failure retains its separate
application boundary; dynamically applied tail-control quotations within the
application may replace that boundary's selected location. Guard predicates
are disposable observations. After guard restoration, the selected `cond`
action or true `while` body replaces the enclosing selection, and tail control
inside that action may refine it. Each iteration starts with a fresh boundary.

The error reports the deepest selected quotation's opening delimiter and
preserves its element index, falling back to the application quotation when
no dynamic selection occurred. When that quotation was assembled at runtime,
all source fields are absent; attribution never falls back to a less-specific
location or invents one.

<!-- include:error-model -->

### Units and the transactional stack

Ordinary evaluation may consume operands and perform effects before it fails;
its failure outcome therefore includes the partial operand stack and the
surviving execution state at the point of failure.

<!-- include:unit-model -->

Environment writes, I/O, and other permitted non-stack effects performed
before unit failure survive. A unit boundary may additionally cancel child
tasks as specified by the concurrency semantics. A unit is not a transaction
over the whole execution state.

#### Unit delimiters

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

A leading `@` marks those words that apply their quotation **in a fresh unit**
— one unit per application for `@each`. There are five: `@attempt`, `@spawn`,
`@each`, `@module`, and `@defm`. Each takes an explicit seed-values list and a
body quotation as separate operands. An empty seed list is written `[]`; no
constructor reads the ambient stack across its unit boundary. `@each` also
places the iterated element deepest in each child stack, beneath the shared
seed values. `register` is not marked: it publishes an already-constructed
module value and takes no quotation.

Words that are isolated but *not* marked, with their reasons:

- `each`, `zip-with`, `fold`, `scan`, `stencil`, `unfold`, `for` — they
  apply in the **same** unit, on a substack, and are implicitly fed their
  elements, windows, or states.
- `infra` and `within` — they apply on an explicitly named *other* stack.
- `import`, `load`, `unmodule`, `register` — they construct, publish, or retire
  without taking a quotation.
- `await`, `await-all`, `await-any`, `await-for`, `cancel`, `tasks` —
  they consume tasks rather than making them.

`@` is an ordinary word character that the reader does not reserve: a user's
`@retry` lexes and defines normally. The convention is enforced for first-party
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
module activation. The stars are ordinary word characters with no reader
meaning, and the convention applies to shipped vocabulary without reserving
the spelling from user definitions.

#### Seeding a unit

Every unit constructor receives its seed values and exact body separately:

```ecl
values (q) @attempt
values (q) @spawn
list values (q) @each          ( element deepest in each child )
values (body) @module
values (body) 'name @defm
```

Both `values` and the body must be lists. The new unit's operand stack is
initialized from the values list in list order, and then the body runs. `[]`
is the explicit no-seed operand. Seeds are inert stack values and contribute no
code to the body: even when a seed is itself a reader-built quotation, none of
its contents
is part of the construction body's text. `@each` puts the iterated element
deepest in each child stack, beneath the shared seeds.

Keeping the two operands separate is what makes seeding compatible with module
text: `@module` and `@defm` know exactly which list is the construction body.
Generic quotation-building operations such as `with` may still produce a body,
but a runtime-built body has no reader lineage and therefore takes no module
attribution; see Modules.

Underflow against the floor of a constructed unit is reported specially:
the message names the isolation and the constructor's values operand, and the
error dict carries `'isolation` naming the constructor. It does not prescribe
`partial` or `with`: those construct a different, reusable quotation rather
than pass arguments through this boundary. It is the one underflow
whose cause is invisible — the values the caller meant to pass are on
screen and out of reach.

## Bindings and scope

### Scope chains

A scope is a local binding map with a fixed parent. Unqualified resolution
searches locally and then follows that parent chain. The complete scope shapes
are:

```text
core           (no parent)
session      → core
child        → enclosing scope
module image → core
```

Session-authored code may therefore shadow core definitions. A child unit may
define names visible to code authored or dynamically resolved in that child.
A module image sees its own public and private bindings followed by core and
never sees the invoking session. Core and prelude definitions resolve in core.
Parentage does not change after scope creation.

`core` is a reserved qualifier, not a registration. A qualified word whose
module segment is exactly `core` resolves its binding segment in core alone,
skipping every session, child, and image scope, so a shadowed core definition
remains reachable: after `(2 *) 'dup def`, `core.dup` is still the primitive.
Only public core bindings resolve this way; a missing or private name is
`'undefined-word` with `'scope 'core`. `'core 'dup qualify` constructs the same
word. `import`, `alias`, and `unmodule` observe registrations only and do not
accept `core`.

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
  observationally `v literal 'name def`: the sugar synthesizes no
  annotation of its own, while an annotation beneath `v` is preserved for
  `def` to consume. `which` reports the resulting public `def`, while `see`
  prints its literal-capture body, preceded by the annotation when one is
  present; an unannotated `set` has no effect or documentation, and nothing
  distinguishes it from the corresponding `literal` plus `def` spelling. `set`
  assigns the environment and introduces no lexical binding. For ordinary local
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

```ecl
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
`'contract`). An omitted module effect means there is no such check.
This source-language relaxation does not weaken the native ABI, whose
`Call` effect and documentation remain mandatory; the shipped prelude
keeps its stronger repository policy requiring meaningful documentation.

Documentation has canonical form. Publication trims source-only
indentation, folds physical line breaks within prose to spaces, collapses
a paragraph boundary to one blank line, and preserves each `-`-prefixed
Markdown item on its own logical line with its continuations folded in. `doc`
returns this canonical string, so source formatting cannot change
reflective documentation. Strings anywhere else retain their exact decoded
codepoints.

#### The after row

The after portion of an effect is either **all named slots** or exactly
the token `...`:

```ecl
(result on-ok on-err -- ...) (body) 'case def
```

`...` declares a **fixed before row and a variable after row**: how many
values the word consumes is known, how many it leaves is not. The before
slots are checked at boundaries exactly as today; the after check is
skipped. This remains a genuine partial contract: a
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

Selection operations use the same recursive shape rule on their selector
rather than on the collection value. For a list collection, `at`, `put`, and
`update` descend a nested list selector to integer leaves. `at` preserves the
selector shape, `put` conforms a replacement value to it with atom extension,
and `update` applies its unary quotation at each leaf in left-to-right order.

For a dictionary, the selector is always one atomic whole-value key, even when
that key is a list. The `dict.at` and `dict.update` adapters supply the distinct
operation of traversing an outer list of such whole keys.

## Numbers

- Arithmetic on int64 that overflows is an `'overflow` error — no wrapping, no
  promotion to float or bignum. Scalar and array arithmetic behave identically.
- `/` is float division. `div` is checked integer division. Division by zero is
  `'domain`.
- `inf` and `-inf` are values and propagate through arithmetic IEEE-style when
  an *operand* is non-finite. Producing a non-finite result from finite inputs
  is `'overflow` (e.g. `0 log`, float overflow). Any operation whose IEEE
  result would be NaN is `'domain` (e.g. `-1 log`, `inf -inf +`). NaN therefore
  never exists.
- `floor`, `ceil`, and `round` return int64 (`'overflow` when the result
  exceeds the range): their results are indices and mask material, and int-ness
  keeps integer pipelines integer. `pow` returns float.
- `str` output for numbers round-trips (see Printing); float equality is
  numeric everywhere (see Equality).
- The bitwise words `band`, `bor`, `bxor`, `bnot`, `bsl`, and `bsr` read an int
  as its 64-bit two's-complement pattern and are int-only, so a float or a char
  is `'type` rather than a coercion. They never overflow — `bsl` truncates bits
  off the top where `*` would raise. Their `count` operand is the one place
  they can fail on a value: a shift outside `0..63` is `'domain`. They pervade
  and align dicts like every other pervasive word.

## Randomness

Randomness is *counter-based*: a generator state is a two-element list `[key
counter]`, and every draw is a pure function of it. `rand.int`, `rand.ints`,
and `rand.float` each take a state and return the advanced state alongside the
result, so a program's draws are reproducible by construction — running it
twice from the same key produces the same values, and nothing hidden
accumulates between units, tasks, or module loads.

- `rand.entropy` is the only word that reads the host, and the only
  nondeterministic word in the language. A program is reproducible unless
  it explicitly seeds from `rand.entropy`; there is no ambient default seed
  drawn at startup, and no word silently reaches a CSPRNG.
- The `rng` module carries a state so ordinary code need not thread one
  by hand (see The standard library).

## Chars and strings

A string is a rank-1 char vector; there is no separate string type. `len`,
`at`, `reverse`, and list applications of `each` and `for` operate on
codepoints. UTF-8
exists only at IO boundaries: source files and `io.prin`/`io.pp` encode and
decode UTF-8, and invalid UTF-8 on input is an error. Char semantics are
codepoint semantics: grapheme segmentation, normalization, non-ASCII case
mapping, and locale collation are not provided, so composed and decomposed
`"café"` have lengths 4 and 5. Symbols are interned at parse; strings are plain
uninterned vectors.

### Conversions

Conversion between kinds is explicit and names its target. `chars` yields a
value's text content as a string: a string unchanged, a symbol's or word's
spelling, a char as a one-element string, or a byte list decoded as UTF-8. A
byte list is an integer list whose every element is 0 through 255; bytes that
are not valid UTF-8 are `'domain` with `'reason 'invalid-utf8`. `bytes` is the
inverse: it encodes a string as UTF-8 and returns a byte list unchanged. `int`
accepts an int, a string in the integer-literal grammar, or a char, whose
codepoint it returns. `float` accepts a float, an int, or a string in the
numeric-literal grammar. A float is not accepted by `int`: `floor`, `round`,
and `ceil` name the rounding. `char` accepts a char, an int in the Unicode
scalar range, or a one-char string. A string outside the literal grammar is
`'parse`; an int outside the scalar range or a string of the wrong length is
`'domain`; every other operand kind is `'type`. `str` remains the readable
representation and `parse` remains the reader; neither is a conversion.

Symbol conversion is split so that programs cannot grow the interned name
space by accident. `symbol` accepts a symbol or word unchanged and converts a
string only when that spelling is already interned, failing `'domain`
otherwise; every symbol a program can meaningfully compare against was
interned when its source was read, so lookup is the common case. `intern`
accepts the same operands and creates the symbol when the spelling is new.
Both reject a string that is not a valid symbol spelling as `'domain`. The
interned name space grows only through reading source, `parse`, `intern`, and
the module loaders; words that materialize values from external data produce
strings, never symbols.

## Modules

A module is a value; a *registration* is the assignment of a module to a public
name. A per-session registry maps symbols to registrations; files are
transport.

Construction and publication are separate operations, so a module can exist
anonymously, be passed as data, and be registered more than once.

### Operations and values

- `@module` is `( values body -- module )`. It runs the body on a fresh, isolated
  environment and returns an **anonymous immutable module image**: its frozen
  environment, its definitions, and the body's final operand stack as an
  *initial-state template*. It claims no registry name. The body runs
  stack-isolated: it never sees or disturbs the caller's stack.
- `register` is `( module 'module-name -- )`. It validates the canonical name
  and publishes the image under it. Registration is an upsert: a missing name
  creates its registration, and an existing name installs the new image while
  keeping the durable state that registration already owns.
- `@defm` is `( values body 'module-name -- )` and is exactly `@module` followed by
  `register`, including failure and effect order. The body is evaluated before
  the name is validated or publication is attempted. If construction fails,
  registration is not attempted. If construction succeeds and registration
  fails, completed external construction effects survive under ordinary unit
  semantics. `@defm` introduces no transaction spanning both operations. It
  is the source spelling for a module definition.
- `values (body) @module` and `values (body) 'name @defm` initialize the same
  isolated construction. The values form the body unit's initial stack, in list
  order; the body may consume, reorder, or extend them. The separate operands
  let attribution below name the body exactly.
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
  module `core.utils`, binding `f`. The exact name `core` is reserved for the
  core qualifier (see Scope chains): registering a module or an alias under it
  is `'domain`, while `core.utils` stays an ordinary module name. Host
  and native factories apply the reader's single scalar-level symbol-segment
  grammar; ASCII or Unicode whitespace, delimiters, malformed UTF-8, and other
  unreadable spellings do not become validated names. Reserved syntax markers
  are interned as syntax only and cannot be minted as binding names through a
  privileged validation mode.

<!-- include:module-model -->

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
  subtractive: private definitions are omitted entirely from the module's
  public face. Definitions
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
  calls: `table.where` will shadow bare references to `where` inside of
  `table`, but it will not be invoked by calls to `filter` (which includes
  `where` in its own spelling), even inside of the `table` module. The same
  holds for the session, which is what makes shadowing predictable:

  ```ecl
  1 wrap                                  -- [1], reaching core's `cons`
  (pop pop 42) 'cons def   1 wrap          -- still [1]
  (pop pop 42) 'cons def   1 [] cons       -- 42, the session's own `cons`
  (pop pop 42) 'cons def   (() cons) 'wrap def   1 wrap    -- 42
  ```

  A session `def` shadows a name *for session code*. Adopting new behavior
  inside a prelude word is redefining that word: the replacement is a session
  definition, so it resolves in the session and shadows the prelude one for
  session callers. Late binding is unaffected. The lookup still happens at call
  time; what is fixed is which chain it happens in. A quotation literal written
  inside a body is sealed the way the body's own references are: it resolves in
  the scope its text was written in, whoever ends up applying it. `all?` is
  `(|l q| l q each 1 (and) fold)` and `over` is `(swap dup (swap) dip)`, but a
  session `and` or `swap` leaves both alone:

  ```ecl
  (pop pop 42) 'and def   [1 1] (1 =) all?      -- 1
  (pop pop 99) 'swap def  1 2 over              -- 1 2 1
  ```

  Splicing or rearranging quotations preserves the
  annotations on their existing word occurrences. Only a word created without
  reader context is unannotated and resolves dynamically in its invoking
  activation. Re-registering a module publishes a new image under the module
  name, so a fresh call through the name runs the new code. Already-executed
  code is not re-pointed. Applying a word whose scoped image is no longer
  available is `'domain`. Seed values passed to unit constructors are not part
  of the construction body. Runtime-built captures retain their existing
  word scopes.
- `module 'name invoke` calls one public export of an image reached as a value
  rather than through a registered name. A module value is otherwise an
  ordinary opaque value: `register` consumes one and `type` reports `'module`.
  It is the same dispatch a qualified call performs — the home is the image, so
  a public reaches its own privates, and lookup is public-only, so a private is
  as absent as a missing name. On the other hand, it can't access module
  registration state: module stacks are associated with module names, *not*
  with anonymous module values. `within` inside a handle-called word is
  therefore `'domain` exactly as it is in a construction root.
- Module constructors are parameterized by the seed operand — `values (body)
  @module`, `values (body) 'name @defm` — and nothing else crosses the
  boundary. There is no ambient environment between a module's own definitions
  and core.
  Modules can be parameterized with anonymous module handles, enabling a
  simple kind of dependency injection.
  A quotation parameter carries the scope it was written in, so it preserves
  its references on injection into a module. Given:

  ```ecl
  10 'k set
  [(k *)] (
           'scale def
           ( -- n ) (4 scale) 'go def) 'm @defm
  m.go                                          -- 40
  ```

- **A word resolves in the scope its text was written in.** The word itself
  carries the scope, so it
  survives every operation that moves code around: `cat` and `compose` splice
  tokens from two sources into one list and each token keeps the scope it was
  written in. A module word may hand `(private-helper)` to `each` and the
  private still resolves, because the literal was written inside the module;
  a module word may accept `(bump)` from its caller and that `bump` resolves in
  the caller, because the caller wrote it; and both hold when the stdlib passes
  the caller's quotation as ordinary data.
- **Only a reader-authored body becomes module text.** The constructor accepts
  any list in the body operand position; the values operand never participates.
  A body carrying lineage from either the reader or construction's own
  scope-only copy of reader text is copied, and every word in its reader-built
  subtree receives the new image's scope, including words nested in quotation,
  list, and dict literals. The copy retains its lineage, so a construction
  nested inside it can scope its own body to its own image.

  Generic runtime list operations do not create lineage. A body produced by
  `cat`, `compose`, `cons`, `append`, `raze`, slicing, reversal, `with`, or a
  similar operation keeps the scopes already carried by its parts, but module
  construction accepts it without traversing or re-scoping it. Reader-authored
  fragments do not make their runtime-built container reader-authored. For
  example, `7 'k set [] ((k) 'geta) (def) cat 'm @defm` builds the module body
  at runtime. The `k` inside `(k)` keeps its session scope, so `m.geta` resolves
  the session's `k` and returns `7`.

  Seed values only initialize the construction stack. They are never traversed
  or re-scoped, and they cannot affect whether the body is module text.
- **`within` is the explicit stack boundary.** `within` runs a quotation
  against the current registration's durable stack rather than the ambient
  operand stack. It requires a
  `registered(generation, slot, image)` invocation context. A construction root, anonymous
  `invoke`, escaped module quotation, or session activation has no slot and
  raises `'domain` if it reaches `within`. The operation never infers a slot
  from an image or targets some caller's slot. Homeless helpers and same-image
  calls preserve an existing registered context; dispatch into another image
  replaces it according to the ordinary invocation rules. Semantically,
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
  no import. `qualify` validates a module-name symbol, which may be `'core`,
  and an unqualified binding-name symbol and constructs the corresponding
  executable word;
  `execute` applies that word through ordinary late-bound dispatch, preserving
  its module home, private lookup, annotations, tracing, native/builtin path,
  cancellation, and `within` authority. `alias` registers a short registry
  name; aliases and module
  names may not collide in either direction. `which` shows any name's
  resolution.
- **Qualified resolution observes registrations only.** A qualified name
  splits at its final dot into a module name and a public binding name. The
  module name selects a canonical registration directly or through an alias,
  except that the reserved module segment `core` selects the core scope (see
  Scope chains) and never consults the registry.
  A missing registration or public binding raises `'undefined-word`.
  Filesystem search, embedded resources, package catalogs, native loading, and
  eager or on-demand acquisition are host facilities outside the language
  semantics. A host may obtain and register an image by any means, but ECL
  programs observe only the resulting registration, never whether a module is
  "loaded" or how it was transported.

## Concurrency

<!-- include:concurrency-model -->

### Task scopes and observation

The unit that spawns a task owns its structured lifetime. A unit cannot finish
while an owned task remains active. Leaving a scope with an active unawaited
task requests cancellation and waits for that task's complete descendant scope
to quiesce. The session is the root task scope. `tasks` reports pending
descendants in deterministic spawn preorder.

`await-any` accepts a nonempty task list and returns the selected index and
cached task result. Among tasks terminal when the operation begins, the lowest
input index wins; otherwise the first subsequent completion wins.

`await-all` is the derived composition `(await) each`. It awaits every input,
returns cached results in input order, preserves failures as data, and does not
cancel siblings.

`@each` starts one isolated unit per element and enforces exactly one result
value from each unit. It returns results in input order. After the leftmost
failure it cancels the remaining element tasks, waits for quiescence, and
re-raises that failure. Selection of the leftmost failure is independent of
schedule order. Element tasks have no simultaneous-progress guarantee; a
program that requires cross-element rendezvous to make progress is invalid.

Await order is program order. Nondeterminism enters through `await-any` and
through I/O interleaving among concurrent tasks. I/O remains ordered within
one task. Sequential combinators including `each`, `for`, and `fold` execute
left to right.

`exit` is available only to the root unit outside `@attempt`. Elsewhere it
raises `'domain`. An allowed exit first cancels and quiesces the root task
scope, then terminates the process with the supplied status.

### External ports and processes

An external port created by a unit belongs to that unit's task scope. The
scope, not the number or location of port values, owns the live external
resource. Closing a scope stops new operations, requests cancellation, and
does not complete until each owned resource has published a terminal state and
released its scope membership. Returning or storing a port cannot detach it or
transfer ownership; a port that outlives its creating scope remains an opaque
handle to terminal state.

Port operations may suspend the current unit on external readiness. Such a
suspension is an ordinary scheduler park: it consumes no worker while waiting,
participates in the same cancellation and deadline arbitration as task waits,
and resumes a bounded continuation. Input and output queues are bounded, so a
producer waits under pressure rather than causing unbounded allocation.

Filesystem access is likewise a host capability. A Session names directory
roots and their permissions when it is constructed, or names none and denies
every filesystem word; evaluated code selects a root by symbol and a canonical
relative path beneath it, and neither a path string nor possession of console
or module-loading services confers any wider authority. Path manipulation is
pure string computation and proves nothing about containment; containment is
enforced at the root's retained directory handle. Filesystem operations are
bounded drivers whose staged mutations either publish atomically or leave the
destination unchanged.

The shipped `proc` module is a host capability, not ambient language power. A
Session without process authority rejects process creation before reaching the
operating system. A process specification names one absolute executable path,
an argument vector, an optional absolute working directory, and an explicit
environment overlay. It never denotes a shell command and never searches
`PATH`. Process streams are byte lists; text encoding, stream merging, and
line framing are user policy.

A process port has stdin, stdout, stderr, and one immutable terminal result.
The output streams remain independent and return an empty byte list only after
stable EOF. Termination is tagged as exited-with-code, signaled, stopped, or an
unknown host status. A nonzero exit code is result data, not an ECL error;
spawn, pipe, policy, timeout, cancellation, allocation, and cleanup failures
remain errors of their corresponding ordinary kinds.

The reference distribution initially provides process ports on POSIX hosts.
Each child starts in a dedicated process group; scope cancellation signals the
group and reaps the direct child before completing. Descendants that inherit
that group are covered, while a hostile child that creates a new session is
outside this portable process-group guarantee. A host without an equivalent
tree-owning backend rejects process authority rather than silently weakening
cleanup to one PID.

Inbound network listening is a fourth host capability with the same shape. A
Session names, when it is constructed, either an exact allowlist of address
and port pairs or an unrestricted grant, or names none and denies every
listen; evaluated code requests one address and port, and possession of host
I/O, filesystem, process, or outbound HTTP authority confers no listen
authority. Addresses are IP literals compared after normalization; they are
never resolved through a name service, so a grant cannot be widened by
resolution. A grant whose port is zero admits only a request for an ephemeral
port. A request the grant does not admit, or made without a grant, is
`'domain` and never reaches the operating system.

A listener is a port. Binding and listening complete before the value is
returned, the value belongs to the creating unit's task scope, and accepting a
connection is the only listener operation that parks. The bound address and
port are observable data; closing a listener, explicitly or through scope
closure, is one idempotent transition after which the address is no longer
observable, every unit parked in accept on it fails, and the same address and
port may be bound again. A host bind failure is `'io` carrying the requested
address, the requested port, and one reason from a closed vocabulary.

A connection is a port too, distinct from a listener and from a process port.
It belongs to the task scope of the unit that accepted it, not to the
listener's scope: closing that scope aborts the connection even while its
value is stored elsewhere, and closing the listener leaves accepted
connections open. A connection not yet accepted stays in the host's backlog;
the runtime takes one only while an accept is outstanding. Reads and writes
park on readiness under the ordinary scheduler rules, are bounded by
host-configured queue capacities, and exchange exact byte lists. One read may
be pending per connection; writes are serialized in arrival order with each
call's bytes contiguous. Explicit close delivers the bytes already queued and
then shuts the socket down; scope closure discards them and shuts down at
once. Both ends' addresses are observable data while the connection is open.
A peer failure is `'io` carrying the peer's address, the peer's port, and one
reason from a closed vocabulary; a cancelled wait fails only the unit that
was parked.

## Standard environment

[`ENVIRONMENT.md`](ENVIRONMENT.md) defines the shipped module transports,
host-backed library contracts, project and package system, command-line
interface, and source formatter.
