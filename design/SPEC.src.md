<!-- Generated from design/SPEC.src.md; make changes in the source fragments. -->
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

## Language overview

ECL is a homoiconic concatenative array language. A program is a sequence of
values evaluated from left to right against an operand stack. Evaluating a word
resolves and invokes its binding; evaluating any other value pushes that value.
Words consume operands from the top of the stack and push their results
there.

A quotation is a list used as a program. Lists are also ECL's general ordered
aggregate, so code and data have the same value representation and can be
built, inspected, and transformed by the same operations. Concatenating two
programs composes their stack transformations. Many scalar operations pervade
lists and dictionaries recursively, giving the same language an array
interpretation.

Values are immutable. Bindings associate names with executable bodies and may
be replaced without mutating either the old body or values that refer to its
name. Word occurrences retain the scope their names are resolved in. Each word
is resolved in its own scope when it is reached, so a replacement reaches every
later call, including calls from code defined before it.

A unit is the boundary of failure and operand-stack rollback. Modules register
immutable code images under global names. Tasks execute isolated units under
structured concurrency, and a task's mailbox is the only state outside a unit's
own stack.

## Notation and terminology

In a stack effect `( before -- after )`, the top of the operand stack is at the
right. Names in an effect describe positions and introduce no runtime
variables. 

A **form** is a grammatical source construct. Reading a form produces an ECL
**value**, possibly with semantic metadata. A **word** is an executable value
whose identity is its kind and spelling. A **word occurrence** is a stored word
together with any resolution and provenance metadata assigned to that
occurrence. A **quotation** is a list applied as a program. A **binding**
associates a name with an executable body and metadata. A **scope** is a
binding map with a fixed parent. An **activation** is one invocation of a
binding. A **module image** is the immutable code and definitions `@defm`
constructs; a **registration** is the named slot through which an image is
published and invoked.

## Source language

The grammar in this chapter is the single authoritative grammar for ECL source.
Later sections may quote productions for explanation but do not define a second
grammar.

### Source text

- Source is UTF-8. Invalid UTF-8 is a `` `parse `` error.
- `#` begins a comment that runs to end of line, outside strings. Shebang
  lines are therefore comments.
- Tokens are separated by whitespace: Unicode whitespace, plus comma —
  `,` is whitespace, so pasted `[1, 2, 3]` reads as `[1 2 3]`.
- `;` is reserved: a parse error outside strings and comments.
- `|` is a reserved delimiter: legal only as the locals markers
  immediately after `(` or `[` (see Forms); anywhere else it is a parse
  error.
- Every reader-produced token carries provenance (source name, line,
  column), which surfaces in error dicts when known.

### Tokens

The token kinds are the six delimiters `( ) [ ] { }`, string literals, and
*atoms*: maximal runs of non-whitespace, non-delimiter, non-reserved
characters. An atom is classified whole-token, in this order:

1. **Number** — the entire token parses as a number, else it is not one
   (`2x` and `1+` are words; `-3` is a number; `-` is a word).
   - int64: optional `+`/`-` sign, then decimal digits with optional `_`
     separators strictly between digits (1_000_000), or `0x` followed by
     hex digits. `_` is not permitted in hex literals. A literal outside
     the int64 range is a parse error.
   - float64: `digits . digits` with an optional exponent (`e`/`E`,
     optional sign), or `digits` followed by an exponent. Digits are
     required on both sides of `.` — `.5` and `5.` therefore lex as words.
     `_` is not permitted in float literals. Decimal values round to the
     nearest float64, with ties to even, including subnormals and signed
     zero on underflow. A literal that overflows float64 is a parse error.
   - The whole tokens `inf`, `+inf`, and `-inf` are float literals (they
     are numbers, so the names leave the word namespace). NaN has no
     literal; NaN values do not exist (see Numbers).
2. **Char** — `\` followed by one character (\a), one of the
   names `\space`, `\tab`, `\newline`, or `\u{...}` with one to six hex
   digits naming a Unicode scalar value (surrogate halves and values above
   U+10FFFF are parse errors).
3. **Quote** — `` ` `` followed by a symbol. It reads as one quoted occurrence
   of that symbol, which run pushes the symbol: `` `foo `` and `(foo) first`
   push the same value. 
   `` ` `` is reserved token-initially and banned inside symbols.
4. **Symbol** — anything else. A symbol pushes nothing by itself: when the
   list it occurs in is run, it is resolved by lookup and executed.

**Symbols** are one or more segments joined by `.`. The last `.` in a symbol
separates a module name on the left from the word on the right; module names
can include more dots, which have no additional meaning. 

Symbols with spaces in them can be constructed by wrapping the whole spelling
in single quotes.

**Strings** constructed with double quotes, and may span newlines. Raw
newlines, indentation, and blank lines inside the quotes are literal; there is
no triple-quoted, dedented, or margin-stripped form. The escapes are `\\`
for backslash, `\"` for double quote, `\n` for newline, `\t` for tab, and
`\u{...}` for a Unicode scalar value given by one to six hex digits. Any other
escape, or a malformed Unicode escape, is a parse error.

### Forms

```ebnf
program  :=  form*
form     :=  list | dict | atom
list     :=  "(" locals? form* ")"  |  "[" locals? form* "]"
dict     :=  "{" (form form)* "}"
locals   :=  "|" name+ "|"           # names: distinct unqualified symbols
```

- `( )` and `[ ]` construct the same kind of value---a list of the
  enclosed forms. Symbols inside of list literals are *never evaluated*;  the
  forms `(foo)`, `` (`foo) ``, `[foo]` and `` [`foo] `` all produce
  values that evaluate as equal: one-element lists containing the symbol `foo`. 
  (Critically, however, the semantics of `call` on the resulting lists are
  different: unquoting `` (`foo) `` merely pushes the symbol to the stack,
  while unquoting `(foo)` executes the symbol.) 
  The pair choice is free per pair, and **pairs must match**:
  `[1 2 3)` is a parse error. (Printing chooses brackets by
  canonical value shape; see Printing.)
- `{ k v ... }` constructs a dict value. Adjacent top-level forms are paired as
  key and value. As with lists, symbols inside of dict literals are not
  evaluated. An odd form count or a duplicate key is a parse error.
- Locals create temporary, quotation-internal bindings. Any word bound in the
  locals declaration can be used any number of times within the quotation.
  The first name receives the deepest consumed stack value and the last name
  the top value, so `1 2 (|x y| x y -) call` is `-1`.
  Locals do **not** exhibit lexical scoping: a local is not visible inside a
  nested quotation within the declaring body. 

## Values and external representations

<!-- include:values-model -->

### Representation 

Float values use IEEE 754 binary64, excluding NaN; `inf` and `-inf` are
ordinary values. Integer overflow is an error, never wrapping or promotion.
See Numbers.

Symbol quotedness is execution metadata on a symbol value; quoted and unquoted
symbols are the same kind.

A quotation, vector, or matrix row are all represented with a list. While the
interpreter may specialize implementation and operations over homogeneous typed
lists, printing uses canonical value shape rather than storage specialization
(see Readable representations and display). Lists don't have any rank or axis
metadata.

A task is an opaque capability bound to its session and prints as `<task:N>`. A
port is an opaque capability for a host endpoint and prints as `<port:N>`. Task
and port displays are rejected by the reader. Port identity is observable only
through ordinary whole-value matching and hashing; no conforming operation may
recover an operating-system descriptor, process identifier, or implementation
pointer from one.

### Readable representations and display

A **diagnostic display** is human-facing text without a read-back guarantee.
An operation may produce display text for every value, but any print/read
guarantee applies only to the formally defined readable subset. Reader
provenance, resolution metadata, and source spans need not be reproduced by
that round trip.

Printing never exposes storage specialization. A non-string list uses `[...]`
when its value has canonical array shape—a homogeneous flat vector of numbers
or chars, or a rectangular nesting of such vectors—and `(...)` otherwise. A
vector of symbols has a quotation's shape and prints with `(...)` however it
was built, and a quoted occurrence prints as its quote, so `` (`x) `` prints as
`` (`x) ``. Both delimiters read as the same list kind. Thus `(1 2 3)` prints
as `[1 2 3]`, `[dup swap]` prints as `(dup swap)`, and the ragged result of
`[[1 2] [3]] 10 *` prints as `([10 20] [30])`. Strings use quoted string
syntax.

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
  codepoint), and lists, which order lexicographically by their elements' `cmp`
  and then by length; strings are lists of chars. Anything else, including
  cross-kind pairs, is a `` `type `` error, but two lists compare only through
  their first unequal element pair. `grade` orders by this ordering.
- Words that require a boolean reject every value outside the formally defined
  Boolean role, including other ints.

## Core evaluation

Evaluation processes a program sequence from left to right. Evaluating a word
occurrence resolves and invokes it. Evaluating any other value appends that
value to the operand stack. Applying a quotation evaluates the quotation's
values as a program; a quotation containing no words therefore pushes its
elements in order.

Ordinary word evaluation is one observable operation:

1. Resolve the occurrence to its current definition.
2. Establish the definition's activation context.
3. Evaluate the definition's executable body.

Resolution does not produce a binding or callable value on the operand stack.
Bindings are not first-class, and ordinary word reference always invokes.
Reflection operations inspect binding metadata through separate mechanisms.

### Resolution

Every word is resolved when it is reached, in the scope that occurrence was
written in (see [Where a word resolves](#where-a-word-resolves)), against the current definitions and module
registrations. This holds alike for top-level source, for definition bodies,
and for every quotation applied at run time, by `call`, a combinator,
`@attempt`, or as a task's body. A quotation applied at run time is not checked
before it runs: an unresolved word fails at that word, after the forms before
it have run. Nested quotations and quoted words are data and resolve only when
they are themselves applied.

### Definition 

Definitions are introduced with the word `def`, and a definition validates its
body when it is published. Validation records nothing: the body resolves each
word again whenever it runs.

A definition written to the session is published as `def` runs. Every word of
its body outside a nested quotation must already resolve, so the body cannot
refer forward to a later definition, and a misspelled word fails the
definition. A qualified word whose module is not registered yet is the other
exception: its lookup is deferred until the word is reached. The definition's own name, written in the scope it is published
into, is the exception: it calls the definition itself.

A definition written to a module image is staged by the module's construction
body and published when the module is sealed. A module's definitions and
imports are validated together then, so words in one module may refer forward
and recurse mutually. A staged definition is not visible to runtime lookup
before its module is sealed.

A body running when a word it calls is replaced may run the old definition for
earlier calls and the new one for later ones. There is no historical view: a
unit, a task, and an `@attempt` see the definitions current as each word is
reached. Explicit operations on names — `execute`, `doc`, `effect`, `which`,
and `see` — resolve the supplied symbol in its own scope against the current
definitions each time they run. 

A word written in a module image resolves in that image, so code written in an
image keeps reaching that image's definitions after its registration is
replaced, while a qualified name reaches the registration current when it runs.
Executing a word written in an image that was never published and has since
been discarded is a `` `domain `` error.

A reader-produced aggregate may separately retain **source spans**, which
record where the aggregate and its reader-built descendants were read. Spans
support diagnostics and reflection; they are not an AST, a captured
environment, or a quotation-wide resolution scope. Runtime aggregate
reconstruction does not acquire spans. Resolution context, spans, and
provenance are semantic metadata on stored occurrences and aggregates, but
none is part of value identity.

### Errors

Errors are crash-only. There is no try/catch or handler quotation: an error
propagates outward through every unit it reaches until a boundary that
constructs a value from the error. Units nest strictly inside the task or root
that opened them, so a unit cannot end while a unit nested in it is still
running. `raise` initiates that propagation from an error value, and `fail` is
sugar for raising an error whose kind is `` `user `` and whose message is the
supplied string.

Failure is observed as data only outside an explicit boundary: `@attempt`, or
the concurrent `@spawn`/`task.await` path, returns `{ok (values)}` after
success or `{err error}` after failure. Each envelope is an ordinary dictionary
and is the boundary's only result value. The REPL is the implicit top-level
boundary; a script's boundary is the process. Cancellation propagates the same
way but no boundary inside the cancelled task reifies a cancellation error, so
cancelling a task or the root fails every unit it has open, innermost first.

Source-position and other diagnostic fields appear when known. Absence is
represented by an absent field, never by a nil value. Runtime-assembled code
has no source position by construction, and no host exception or host stack
frame is exposed as ECL error data.

An error built from a failure records where it happened. `'data` carries
`'source`, `'line`, and `'col` for the failure's position, and `'sites`, a
list parallel to `'trace` giving each entry's call site as a dictionary of
the same three fields, empty where no position is known. A word whose body
was marked with `helper` is a helper: a failure inside it is positioned at
the call that entered it, and that applies outward through every enclosing
helper, so an assertion reports the code that asserted rather than its own
body. `assert` and `fail` are helpers. A tail call does not keep its caller
in the trace; a word tail-called from a helper's body takes that helper's
call site. A raised dictionary keeps whichever of these fields it already
has.

<!-- include:errors-model -->

### Units and the transactional stack

Ordinary evaluation may consume operands and perform effects before it fails;
its failure outcome therefore includes the partial operand stack and the
surviving execution state at the point of failure.

<!-- include:units-model -->

A failed unit exposes no stack. A failed submission leaves the session's
operand stack as it was before the submission began, and the partial stack of
any other failed unit is discarded with it.

Environment writes, I/O, and other permitted non-stack effects performed
before unit failure survive. A unit boundary may additionally cancel child
tasks as specified by the concurrency semantics. A unit is not a transaction
over the whole execution state.

#### Starting a unit

A *submission* is the source text that is used to start a new top-level unit. 

- **REPL**: one logical line is one submission. The reader continues the line
  (continuation prompt) while a delimiter or string is open, so a submission
  is the complete forms of one possibly-continued line.
  As an important consequence: an error in the REPL rolls back to the state
  before the line.
- **Script file, `-e`, stdin**: the whole source is a single submission. An
  error propagated upward will cause the process to exit.

Inside of running code, unit constructors are the primary way to create bounded
execution contexts:

- **`@attempt` and `@spawn`**: each runs its quotation as a new unit on an
  isolated substack (see Errors, Concurrency).
- **`@load`**: runs a source file as a new unit on an isolated substack. The
  file keeps its caller's authority to define, so a file loaded at the root
  defines into the session, and like a module body it must leave its stack
  empty. Its failure propagates to the enclosing unit.

### Application contexts

Three quotation-application behaviors exist:

- **Inline**: the quotation runs on the current stack. The inline words
  are `call`, `dip`, `dip2`, `dip-n`, `both`, `if`, `when`, `unless`,
  `case`, and `times`, and the action quotations of `cond`, `while`, and
  `linrec`.
- **Paging**: the quotation runs on a substack that starts empty and takes
  operands from beneath as its words need them, so what it consumed is
  exactly what its words required. `above` and `below` then restore those
  values, in their original order, above or below the quotation's results.
  `cleave`, `bi`, and `tri` run each quotation this way from the same
  inputs, hold its results aside, and finally drop the inputs any quotation
  consumed. The test quotations of `cond`, `while`, and `linrec` run this
  way too: a test may consume, rearrange, or add values; its top value must
  be a 0/1 boolean, and its complete result is discarded and the previous stack
  state is restored before control continues. 
- **Isolated**: the quotation runs on a fresh substack per application,
  starting on its declared inputs, and its result count is checked
  against the contract. The isolated words are `each`, `zip-with`, `for`,
  `fold`, `fold1`, `scan`, `lex-cmp-with`, `update`, `stencil`, `unfold`,
  `infra`, `@attempt`, `@spawn`, `@each`, and `@defm`.

Tail calls are guaranteed: through word calls, `if`, and every combinator's
documented tail position, iteration and tail recursion run in constant space
and never exhaust a host call stack.

### Explicit linear recursion

`linrec` has the ambient-row effect `( predicate base pre post -- ... )`; all
four parameters must be quotations. It applies them inline on the current
operand stack, using this recursion scheme:

```text
predicate true  -> base
predicate false -> pre; linrec; post
```

At every descent, `predicate` runs over a paging floor as the application
contexts above describe. Its top result must be 0 or 1. On 1, `base` runs from
the restored state. On 0, `pre` runs from the restored state, the recursive
descent begins from `pre`'s resulting stack, and `post` runs after that descent
returns. Consequently the four applications share ambient stack state
intentionally; none has an isolated quotation contract. Fewer than four
operands is `` `underflow ``, a non-quotation parameter is `` `type ``, and a
missing or non-boolean predicate result follows the ordinary guard ``
`underflow ``/`` `type `` behavior.

#### The `@` spelling convention

A leading `@` marks those words that apply their quotation **in a fresh unit**
— one unit per application for `@each` — and `@load`, which runs a file's
source the same way. No constructor reads the ambient stack across its unit
boundary.

`@` is an ordinary word character that the reader does not reserve. First-party
vocabulary follows the convention, and it is the recommended spelling for any
user-defined word that wraps its quotation in a unit.

#### The `*name*` spelling convention

Leading and trailing `*` mark a value dynamically supplied by the current
execution context rather than consumed from the operand stack. `*file*` returns
the source name attached to its currently executing reader-authored occurrence;
a definition therefore keeps reporting the file that authored its body when
another file calls it. Runtime-assembled code has no source provenance, so
`*file*` is `` `domain `` there rather than falling back to its caller.
`*module*` returns the name of the module whose code is running, the name
`@defm` published it under even when the call came through an alias, including
a construction body that has not yet published; at the root there is no module
and it is `` `domain ``. The stars are ordinary word characters with no reader
meaning, and the convention applies to shipped vocabulary without reserving the
spelling from user definitions.

#### A unit's initial stack

A unit started by `@attempt`, `@spawn`, `@defm`, or `@load` begins on an empty
stack, and one started by `@give` begins on the ports it was given, in list
order. 

## Bindings and scope

### Scopes and names

Definitions live in *scopes*. There are three kinds:

```text
core           frozen; primitives and the prelude
session        → core
module image   → core; sealed at the end of construction
```

Thus: depending on where it was written, a user-defined word is resolved first
either in the top-level session or in a module, and then in both cases in the
core if it's not found. If resolution fails it produces an `` `undefined-word `` 
error (see Core evaluation). Names are introduced and replaced, never
removed. 

Session-authored code may therefore shadow core definitions. A module image
sees its own public and private bindings followed by core and never sees the
invoking session. Core and prelude definitions resolve in core. There are no
other scopes.

`core` is a reserved qualifier. A qualified word whose
module segment is `core` resolves its binding segment in core alone,
skipping the session and every module image, so a shadowed core definition
remains reachable: after ``(2 *) `dup def``, `core.dup` still refers to the
stdlib definition.

Shadowing a core name is allowed but reported. When a `def`, `set`, or `import`
at top level introduces a session name that is also a public core name, a
warning is written to the diagnostic stream. Sealing a module whose definitions
or imports include a public core name writes one warning per such name, naming
the module. Standard-library modules shadow core names deliberately and are not
reported. The binding takes effect either way, and `core.` still reaches the
core word.

Standard-library module names are reserved too. Only the standard library
registers them, so a qualified name under one means the embedded module in
every scope, whether or not it has loaded; an implementation may load it on
first use. `@defm` with a standard-library module name is `` `domain ``, as is
`alias` with one as either the alias or its target. A dotted name below one,
such as `dict.extra`, is an ordinary module name.

Every activation has a **current scope**. A word belonging to a module runs with
that module's image as its current scope; every other word, whether a session
definition, a core primitive, or a prelude word, runs in its caller's scope.
Outside any module word the current scope is the session, or the image under
construction in a module's construction body. The current scope decides where
definition words write, what `*module*` reports, and the scope a symbol built at
run time links to. A core word such as `*module*` written in an escaped
quotation runs in its caller's scope, so it reports the caller's module, or is
`` `domain `` when the current scope is the session.

### Where a word resolves

Every word occurrence resolves first in the scope it was written in, and if
there's no binding in that scope, then in core.

An occurrence gets its scope in one of three ways:

- The reader gives a word the scope its source is read into: the session, or
  core for the prelude.
- `@defm` replaces that scope, for every word in a module body, with the new
  image (see [Construction and definitions](#construction-and-definitions)).
- A symbol built at run time by `qualify`, `symbol`, `intern`, or native code
  takes the current scope of the activation that built it, so a quotation
  assembled from strings resolves where it was assembled, not where it is
  later called. 

Individual words link to their own scopes; thus a quotation could consist of
words which resolve in different contexts. ECL therefore has syntactic closure
without value capture: a word keeps the scope it was written in, while a
quotation value captures no bindings and no ordinary values.

Two consequences follow:

#### Core words can't have their behaviour changed

A primitive or prelude definition was written in core, and thus the words it
invokes are resolved there only. The words *can* be shadowed in session code,
but the shadow will only apply within the session. 

```ecl
  1 wrap                                  
[1] # wrap is defined as (() cons)
  (pop pop 42) `cons def 1 wrap          
[1] # `cons` has been shadowed in session scope, 
    # but wrap was defined in the core and thus retains its semantics
  (pop pop 42) `cons def 1 [] cons
42 # inside the session, `cons` has a new sense
  (pop pop 42) `cons def (() cons) `wrap def 1 wrap    
42 # other words defined in the session scope also pick up the new sense
```

#### Code passed between scopes resolves where it was written 

Any word which takes a quotation can execute the quotation *without* changing
that quotation's semantics, even if the word and the quotation were defined in
different places (eg., in a module and the session, or in the session and in
core...). This is the quality of "syntactic closure": quotation *bindings* are
stable when used as callbacks, even absent of lexical scoping.

### Definition annotations

A definition may place one annotation quotation immediately before its body:

```ecl
(body) `name def
(before -- after) (body) `name def
(: "Documentation.") (body) `name def
(before -- after : "Documentation.") (body) `name def
```

The annotation is ordinary quotation data and is recognized only when it
contains a top-level word `--` or `:`. Nested markers and the quoted symbols ``
`-- ``/`` `: `` are inert. A recognized annotation is validated as a whole
before the binding publishes: at most one marker of each kind, `--` before `:`,
and one string after `:`. A malformed recognized annotation is a `` `domain ``
error. 

Annotations are optional everywhere. Module `def`/`defp` accept the same four
forms as top-level `def`: no annotation, effect only, documentation only, or
both. A top-level effect is reflective metadata only, whereas a module word's
declared effect functions as a runtime arity contract, checked dynamically
against the observed effect when application crosses a module boundary
(violation: `` `contract ``). An omitted module effect means there is no such
check. 

#### Variable rows

The token `...` stands for a variable row: zero or more values whose count
the effect does not fix. Each portion of an effect may hold one `...`, at any
position among its named slots: 

```ecl
(result on-ok on-err -- ...) (body) `case def
(... n -- list) (body) `pack def
(x (... -- ...) -- ... x) (body) `peek def
```

Variable rows can appear on either side of the `--`, and denote that the
word in question either consumes or pushes (respectively) a number of values
not known statically, or variable dependent on runtime behaviour.

These can be combined with ordinary stack effect variables: for instance, `(
... x --- )` denotes that the word expects at least one value on the stack, but
may consume more below it.

#### Quotation slots

An annotation slot is a word or a nested effect. A nested effect describes the
quotation that occupies that position, including an optional label as the
first element:

```ecl
(collection (a -- b) -- collection) (body) `each def
(bool (then: -- ...) (else: -- ...) -- ...) (body) `if def
```

The words `--`, `:`, and `...` are reserved against binding: they remain
legal symbol values and can be built into annotations at runtime, but cannot be
introduced as definitions, values, locals, module names, aliases, exports, or
native entries. Binding attempts are `` `domain ``; use as a local name is a
parse error. Longer names containing the same punctuation remain legal.

## Pervasion and conformability

Scalar arithmetic and comparison words are *pervasive*: they recurse
through nesting to atoms, ragged lists included, by leading-axis pairwise
descent:

- An atom extends to every element of a list: `10 [1 2 3] +` is
  `[11 12 13]`.
- Two lists pair elementwise at each level and recurse; a top-level length
  mismatch is a `` `conform `` error.
- Dicts pervade over their values, preserving keys. A dict with a dict
  aligns by key: matching keys combine, unmatched keys pass through
  unchanged (union with identity fill).

Selection operations use the same recursive shape rule on their selector
rather than on the collection value. For a list collection, `at`, `put`, and
`update` descend a nested list selector to integer leaves. `at` preserves the
selector shape, `put` conforms a replacement value to it with atom extension,
and `update` applies its unary quotation at each leaf in left-to-right order.

For a dictionary, the selector is always one atomic whole-value key, even when
that key is a list. `dict.put` likewise assigns one whole key and value. The
`dict.at`, `dict.at-or`, `dict.update`, `dict.take`, `dict.del`, and
`dict.split` adapters traverse an outer list of whole keys without descending
into those keys.

## Numbers

- Arithmetic on int64 that overflows is an `` `overflow `` error — no wrapping, no
  promotion to float or bignum. Scalar and array arithmetic behave identically.
- `/` is float division. `div` is checked integer division; its division by
  zero is `` `domain ``.
- Float arithmetic follows IEEE 754, so a finite computation may produce
  `inf` or `-inf`: overflow (`1e308 10 *`), poles (`0 log` is `-inf`), and
  division of a nonzero number by zero (`1 0 /` is `inf`, `1 -0.0 /` is
  `-inf`). Any operation whose IEEE result would be NaN is `` `domain `` (e.g.
  `-1 log`, `0 0 /`, `inf -inf +`). NaN therefore never occurs in the
  language.
- `floor`, `ceil`, and `round` return int64 (`` `overflow `` when the result
  exceeds the range): their results are indices and mask material, and int-ness
  keeps integer pipelines integer. `pow` returns float.
- `str` output for numbers round-trips (see Printing); float equality is
  numeric everywhere (see Equality).
- The bitwise words `band`, `bor`, `bxor`, `bnot`, `bsl`, and `bsr` read an int
  as its 64-bit two's-complement pattern and a char as its codepoint; they are
  otherwise int-only, so a float is `` `type `` rather than a coercion. They
  never overflow — `bsl` truncates bits off the top where `*` would raise.
  Their `count` operand is the one place they can fail on a value: a shift
  outside `0..63` is `` `domain ``. They pervade and align dicts like every
  other pervasive word.
- The wrapping words `+%`, `-%`, and `*%` are the integer sum, difference, and
  product modulo 2^64 in two's complement: where `+`, `-`, and `*` raise
  `` `overflow ``, they wrap. They are
  int-only like the bitwise words (a char is its codepoint, a float is
  `` `type ``), and with
  `band` they give arithmetic modulo any power of two up to 2^64.

## Randomness

Randomness is *counter-based*: a generator state is a two-element list `[key
counter]`. `rand.int`, `rand.ints`, and `rand.float` each take a state and
return the advanced state alongside the result.

`rand.entropy` is the only word that reads the host, and the only
nondeterministic word in the language. A program is reproducible unless it
explicitly seeds from `rand.entropy`.

## Chars and strings

A string is a rank-1 char vector; there is no separate string type. `len`,
`at`, `reverse`, and list applications of `each` and `for` operate on
codepoints. UTF-8 exists only at IO boundaries: source files and
`io.prin`/`io.pp` encode and decode UTF-8, and invalid UTF-8 on input is an
error. Char semantics are codepoint semantics: grapheme segmentation,
normalization, non-ASCII case mapping, and locale collation are not provided,
so composed and decomposed `"café"` have lengths 4 and 5. 

### Conversions

Conversion between kinds is explicit. `chars` yields a value's text content as
a string. Bytes that are not valid UTF-8 are `` `domain `` with `` `reason
`invalid-utf8 ``. `bytes` is the inverse: it encodes a string as UTF-8 and
returns a byte list unchanged. `int` accepts an int, a string in the
integer-literal grammar, or a char, whose codepoint it returns. `float` accepts
a float, an int, or a string in the numeric-literal grammar. `char` accepts a
char or a string, returned unchanged, an int in the Unicode scalar range, or a
list of such ints and chars. A string outside the literal grammar is `` `parse
``; an int outside the scalar range is `` `domain ``; every other operand kind
is `` `type ``. `str` remains the readable representation and `parse` remains
the reader; neither is a conversion.

Symbol conversion is split so that programs cannot grow the interned name space
by accident. `symbol` accepts a symbol unchanged and converts a string only
when that spelling is already interned, failing `` `domain `` otherwise.
`intern` accepts the same operands and creates the symbol when the spelling is
new. Both reject a string that is not a valid symbol spelling as `` `domain ``.
The interned name space grows only through reading source, `parse`, `intern`,
and the module loaders; words that materialize values from external data
produce strings, never symbols. A symbol built from a string is the same value
as the symbol read from source, so `"dup" symbol wrap call` executes `dup`.

## Modules

A module is code published under a name: a *registration* assigns an immutable
module image to a public name, and a per-session registry maps symbols to
registrations. Modules are not values. 

### Operations

- `@defm` has the signature ``( annotation? body `module-name -- )``. It
  validates the name before evaluating anything: a non-symbol is `` `type ``; a
  name that is not a valid module path, the reserved name `core`, or a
  standard-library module name is `` `domain ``, and in each case the body
  never runs. With a valid name it runs the body in a fresh, isolated
  environment, freezes the resulting image (its environment and its
  definitions), and publishes that image as the registration's new generation.
  A body that leaves one or more values on its stack is `` `domain `` at
  completion and publishes nothing. A body failure publishes nothing.
- Module annotation never has a stack effect, only a docstring. `` `m
  module-doc `` returns the current generation's documentation---a module
  without documentation, or `` `core ``, is `` `domain ``.

<!-- include:modules-model -->

### Construction and definitions

Inside a module body, `def` and `set` create public bindings, and `defp` and
`setp` create private ones. Module bindings carry the same optional annotations
as top-level ones, so a module word may be unannotated, documentation-only,
effect-only, or both.

Executing a module body constructs a fresh image. `@defm` creates the image,
and sets it as the scope for every word in the body. This is how new,
bounded scopes are created, without introducing lexical scoping. Instead, each
module scope has a simple, two-part resolution path: module words are looked up
first in the module scope, and then in core.

Module namespaces don't nest. A module body may define another module
with `@defm`, but that registration creates an independent module with its
own name and lifetime. Given `` (( ... ) `n @defm ) `m @defm ``, the inner
module is registered under the name `n`, not `m.n`.

### Registering and re-registering

Once a module image is created, it's registered under the name passed to
`@defm`. This isn't atomic, in the sense that construction can succeed and then
registration can fail (for instance, another call can race to register the
name)---but if this occurs the module image shouldn't be observable. 

Rerunning `@defm` with the same name publishes a new module image and re-links
to it from the image registry. Because binding happens within scopes, this
model has two implications:

- Code that's running under the predecessor image continues to resolve within
  itself;
- Code that reaches the module through a qualified name `m.x` is now routed to
  the new image.

The language offers no guarantees about stale images being reaped.

### Imports and qualified names

`import` consumes a module-name symbol and a list of attribute symbols, then
publishes those attributes under the same names in the current environment.

`import` validates every symbol and resolves every public attribute against one
module generation before publishing the first name. A missing or private
attribute is `` `undefined-word ``, malformed operand are `` `type ``, and
malformed name domains are `` `domain ``.

Imports behave like a simple alias (as opposed to capturing or republishing the
actual contents of the aliased word). This makes import cycles theoretically
possible, so they're checked and produce a `` `domain `` error if found.
Because they behave like simple aliases for the qualified word, this also means
that there's no loading-order dependency between modules.

A qualified name looks like `module-name "." word`, where `word` can't contain
any dots but `module-name` can. Core words aren't in their own module, but the
synthetic module-name `core` allows qualified access to that scope. This allows
reference to any core word that's been shadowed in the current scope. 

`qualify` is the way to dynamically construct qualified names at runtime. It canstructs a symbol from any module name symbol (including `core`) and a binding symbol.  

Qualified names can be resolved and executed with `execute`.

`alias` registers a short registry name; aliases and module names may not
collide in either direction. `which` shows any name's resolution.

### Tests

Tests are a distinct module-owned namespace. ``annotation? (body) `name test``
accepts the same optional effect and documentation forms as `def`. Being
defined inside a module, tests can invoke both private public words, but
they're only exposed under `ecl test`.

Test discovery and execution form a closed Session mode. There are two words
that are valid exclusively in a test session: `tests` and `@test`.  

Under the test session, the word `tests` returns test
descriptors---dictionaries containing test metadata---for all tests in all
available modules. The word `@test`, given a test descriptor, runs the test and
returns a result value.

These constitute the minimal language-level apparatus for discovering and
running tests. They can then be called by user-level ECL code to form
arbitrarily complex or expressive test runners. ECL ships with a simple default
test runner at `test.default.run`, and will choose that word as the test runner
if `ecl test` is called without a `--runner` argument.

## Concurrency

<!-- include:concurrency-model -->

### Task ownership and observation

Every task has an *owner*: the task that spawned it, or the session root if it
was spawned outside any task. The *current task* is the task whose body is
running. The session root is not a task. Code running there can still wait on
a task or a port, and the wait blocks that submission. What it spawns or opens
is owned by the root, and `task.pending` reports the root's descendants.
A task's attached unit cannot become terminal while a task it owns is
active: its completion cancels the remaining owned tasks and waits for all
their descendants to quiesce. The session root releases what it owns only at
`exit` or session end. `task.pending` reports pending descendants in
deterministic spawn preorder.

### Spawning and awaiting tasks

`@spawn` is the fundamental concurrency constructor. Given a quotation, it
creates a new task that begins to evaluate that quotation. It immediately
pushes a handle to that task onto its caller's stack.

`@each` spawns one task per element and enforces exactly one result value
from each. It returns results in input order. After the leftmost
failure it cancels the remaining element tasks, waits for quiescence, and
re-raises that failure. Selection of the leftmost failure is independent of
schedule order. 

`task.await` parks the current task or root until its object finishes, and
places a result dictionary on the stack.

`task.await-any` accepts a nonempty task list and returns the selected index and
cached task result. Among tasks terminal when the operation begins, the lowest
input index wins; otherwise the first subsequent completion wins.

`exit` is available only at the root, outside `@attempt`. Elsewhere it
raises `` `domain ``. An allowed exit first cancels and quiesces every task the root
owns, then terminates the process with the supplied status.

### Mailboxes

Inter-process communication is accomplished through *mailboxes*: ordered
message queues that tasks can park on in order to receive messages.

Every running task owns one mailbox. `task.address` and `task.self` return
opaque values of type `address`, which are be consumed as the destination
argument to `task.send`. 

Thus, messages are sent to tasks via `<address> task.send`, and tasks park on
receive with a bare `task.receive` inside of the task body. Mailboxes can
receive any value type *besides* `task`, which is necessary to ensure that a
task's stack can never contain its own handle.

### External ports and processes

A *port* is a value that stands for a resource outside the runtime: a
subprocess, a listener, or a connection. A *byte endpoint* is one readable or
writable stream: a standard stream, an open file, a process pipe, or one
direction of a connection.

#### Ownership

A port is owned by the task that created it, or by the session root.
Ownership governs lifetime, not use: any code holding a port value may operate
on it, and copying, storing, or returning the value does not change the owner.

When an owner ends, its ports accept no new operations and their pending
operations are cancelled. The owner does not finish until every resource it
owns has shut down. A port value that outlives its owner remains a valid
handle to the resource's final state.

Only `@give` transfers ownership, and only code running in a port's owner may
give it. `@give` moves the ports into a child task as it creates that child,
so a port always has exactly one owner.

#### Waiting

A port operation may park the current task, or the root, until the host is
ready. Such a wait is cancelled and timed out exactly as a task wait is, and a
cancelled wait fails only the task, or the root, that was waiting. Input and
output queues are bounded: a writer that outpaces its reader waits rather than
consuming more memory.

#### Byte endpoints

Endpoints carry exact byte lists. Text crosses them only through the `io`
words, which encode and decode UTF-8 at the boundary.

A read returns the bytes available, and `[]` at end of input and on every
later read. One read may be pending per endpoint, and a read may leave bytes
read ahead with the endpoint value. Writes from different tasks are served in
the order they began, and each call's bytes stay contiguous.

`fd.close` closes an endpoint that is its own resource, such as an open file.
Such an endpoint is owned as a port is. An endpoint borrowed from a port
closes with that port.

The standard streams `fd.in`, `fd.out`, and `fd.err` belong to the session
rather than to a task. Every task and the root share the same three values,
nothing closes them, and `@give` does not move them. When standard input is
the program source there is no input device, and `fd.in` raises `` `io ``.

#### Filesystem

Filesystem words take a named directory root and a relative path beneath it.
The command line provides its startup working directory as `` `cwd ``. Every
operation is available on every root, subject to operating-system permissions.
The root itself enforces containment; path manipulation is pure string
computation and proves nothing about it. A mutation either takes effect
atomically or leaves its destination unchanged.

#### Processes

The shipped `proc` module provides subprocess words. A process specification
names an absolute executable path, an argument vector, an optional absolute
working directory, and the child's complete environment. It never denotes a
shell command and never searches `PATH`, and the child inherits no host
environment variable the program did not pass.

A process port has three byte endpoints — stdin, stdout, and stderr — and one
immutable result. The two output streams are independent. Merging them,
decoding text, and framing lines are the program's business.

The result reports how the process ended: exited with a code, signaled,
stopped, or an unknown host status. A nonzero exit code is result data, not an
error. Failures to spawn, pipe, allocate, or clean up, and timeouts and
cancellation, are errors of their ordinary kinds.

Process ports are provided on POSIX hosts. Each child starts in its own
process group; when its owner ends, the group is signaled and the child reaped
before the owner finishes. Descendants that stay in the group are covered; a
child that starts a new session escapes. A host that cannot own a process
tree this way rejects process creation rather than cleaning up one PID.

#### Listeners

Listening takes one local IP literal and a port number, subject to
operating-system restrictions and runtime limits. The address is normalized
before binding and never resolved through a name service. Port number zero
requests an ephemeral one.

A listener is a port, bound and listening before its value is returned. Accept
is its only operation that parks. Its bound address and port number are
readable while it is open. A bind failure is `` `io `` carrying the requested
address, the requested port number, and one reason from a closed vocabulary.

Closing a listener, explicitly or by its owner ending, is idempotent.
Afterwards its address is no longer readable, every pending accept fails, and
the same address and port number may be bound again.

#### Connections

Accepting yields a connection: a port owned by whoever accepted it, not by
the listener's owner. Closing the listener leaves accepted connections open. A
connection not yet accepted stays in the host's backlog; the runtime takes one
only while an accept is pending and a live-connection slot is free.

A connection's two directions are byte endpoints. Both ends' addresses are
readable while it is open. A peer failure is `` `io `` carrying the peer's
address, the peer's port number, and one reason from a closed vocabulary.

An explicit close delivers the bytes already queued and then shuts the socket
down. An owner's end discards them and shuts down at once.

A serving word built over connections runs its handler in a fresh unit per
request, and the handler must leave exactly one result. A request's framing
failure, or its handler's failure or ill-formed result, is data to the serving
word and affects only that request. A serving word runs until it is cancelled
or accept fails fatally. Either ending quiesces its children by the ordinary
ownership rules, and it never closes a listener it did not create.

## Standard environment

[`ENVIRONMENT.md`](ENVIRONMENT.md) defines the shipped module transports,
host-backed library contracts, project and package system, command-line
interface, and source formatter.
