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

#### Chapter 1

##### Domains

> This model is normative for the closed value-kind universe; immutable scalar and aggregate content; whole-value matching; dictionary key identity; recursive readability; and hash congruence. It abstracts over concrete storage, float encoding, source grammar, printing, pervasion, and the operations that construct or consume values. 

`Value`.

`ValueType`.

##### Rules

> There are nine value kinds.

**value-type** *value*: `Value` ⇒ `ValueType`.

**int-type** ⇒ `ValueType`.

**float-type** ⇒ `ValueType`.

**char-type** ⇒ `ValueType`.

**symbol-type** ⇒ `ValueType`.

**list-type** ⇒ `ValueType`.

**dict-type** ⇒ `ValueType`.

**task-type** ⇒ `ValueType`.

**port-type** ⇒ `ValueType`.

**address-type** ⇒ `ValueType`.

**kind-name** *kind*: `ValueType` ⇒ `String`.

---

> The value-kind universe is closed: every value has one of these nine kinds.

**value-type** *value* = **int-type** ∨ **value-type** *value* = **float-type** ∨ **value-type** *value* = **char-type** ∨ **value-type** *value* = **symbol-type** ∨ **value-type** *value* = **list-type** ∨ **value-type** *value* = **dict-type** ∨ **value-type** *value* = **task-type** ∨ **value-type** *value* = **port-type** ∨ **value-type** *value* = **address-type**.

> `kind-name` is the name `type` reports for a kind. The nine names differ, so the kinds are distinct and the total `value-type` rule assigns exactly one kind to every value.

**kind-name** **int-type** = "int" ∧ **kind-name** **float-type** = "float" ∧ **kind-name** **char-type** = "char" ∧ **kind-name** **symbol-type** = "symbol" ∧ **kind-name** **list-type** = "list" ∧ **kind-name** **dict-type** = "dict" ∧ **kind-name** **task-type** = "task" ∧ **kind-name** **port-type** = "port" ∧ **kind-name** **address-type** = "address".

#### Chapter 2

##### Domains

> Scalar payloads and aggregate contents determine value identity within their respective kinds. Numeric magnitude separately determines mathematical matching across int and float, so distinct float payloads such as positive and negative zero may still match. A list's contents are finite and ordered. A dictionary maps keys to values, and whole-value matching is its key identity. The model says nothing of how many entries a dictionary holds or in what order. 

`NumericMagnitude`.

`FloatPayload`.

##### Rules

**int-payload** *value*: `Value`, **value-type** *value* = **int-type** ⇒ `Int`.

**float-payload** *value*: `Value`, **value-type** *value* = **float-type** ⇒ `FloatPayload`.

**char-codepoint** *value*: `Value`, **value-type** *value* = **char-type** ⇒ `Nat0`.

**symbol-spelling** *value*: `Value`, **value-type** *value* = **symbol-type** ⇒ `String`.

**list-length** *value*: `Value`, **value-type** *value* = **list-type** ⇒ `Nat0`.

**list-element** *value*: `Value`, *index*: `Nat`, **value-type** *value* = **list-type**, *index* ≤ **list-length** *value* ⇒ `Value`.

**address-mailbox** *value*: `Value`, **value-type** *value* = **address-type** ⇒ `Value`.

**dict-has-key?** *dictionary*: `Value`, *key*: `Value`, **value-type** *dictionary* = **dict-type** ⇒ `Bool`.

**dict-value-for-key** *dictionary*: `Value`, *key*: `Value`, **value-type** *dictionary* = **dict-type**, **dict-has-key?** *dictionary* *key* ⇒ `Value`.

**numeric-value?** *value*: `Value` ⇒ `Bool`.

**numeric-magnitude** *value*: `Value`, **numeric-value?** *value* ⇒ `NumericMagnitude`.

**boolean-value?** *value*: `Value` ⇒ `Bool`.

**string-value?** *value*: `Value` ⇒ `Bool`.

**readable?** *value*: `Value` ⇒ `Bool`.

**value-hash** *value*: `Value` ⇒ `Int`.

---

> Numbers are exactly the int and float values.

**numeric-value?** *value* ↔ **value-type** *value* = **int-type** ∨ **value-type** *value* = **float-type**.

> An int's payload is a signed 64-bit integer.

**int-payload** *value* ≥ 0 - 2147483648 · 4294967296 ∧ **int-payload** *value* ≤ 2147483648 · 4294967296 - 1.

> A char's payload is one Unicode scalar value.

**char-codepoint** *value* ≤ 1114111 ∧ ¬(**char-codepoint** *value* ≥ 55296 ∧ **char-codepoint** *value* ≤ 57343).

> Scalar payloads determine value identity within each scalar kind.

**int-payload** *left* = **int-payload** *right* → *left* = *right*.

**float-payload** *left* = **float-payload** *right* → *left* = *right*.

**char-codepoint** *left* = **char-codepoint** *right* → *left* = *right*.

**symbol-spelling** *left* = **symbol-spelling** *right* → *left* = *right*.

> A list is a finite ordered sequence. Its length and positional elements determine its value identity.

**list-length** *left* = **list-length** *right* ∧ (∀ *index*: `Nat`, *index* ≤ **list-length** *left* · **list-element** *left* *index* = **list-element** *right* *index*) → *left* = *right*.

> Booleans are exactly the int values 0 and 1.

**boolean-value?** *value* → **value-type** *value* = **int-type**.

**value-type** *value* = **int-type** → (**boolean-value?** *value* ↔ **int-payload** *value* = 0 ∨ **int-payload** *value* = 1).

> A string is exactly a list whose elements are all chars. The empty list is therefore both a string and any other role compatible with empty list data.

**string-value?** *value* ↔ **value-type** *value* = **list-type** ∧ (∀ *index*: `Nat`, *index* ≤ **list-length** *value* · **value-type** (**list-element** *value* *index*) = **char-type**).

> Whole-value matching is reflexive.

**matches?** *value* *value*.

> Whole-value matching is symmetric.

**matches?** *left* *right* → **matches?** *right* *left*.

> Whole-value matching is transitive.

∀ *first*: `Value`, *second*: `Value`, *third*: `Value`, **matches?** *first* *second*, **matches?** *second* *third* · **matches?** *first* *third*.

> Values match only as numbers across the two numeric kinds, or within the same non-numeric kind.

**matches?** *left* *right* → **numeric-value?** *left* ∧ **numeric-value?** *right* ∨ **value-type** *left* = **char-type** ∧ **value-type** *right* = **char-type** ∨ **value-type** *left* = **symbol-type** ∧ **value-type** *right* = **symbol-type** ∨ **value-type** *left* = **list-type** ∧ **value-type** *right* = **list-type** ∨ **value-type** *left* = **dict-type** ∧ **value-type** *right* = **dict-type** ∨ **value-type** *left* = **task-type** ∧ **value-type** *right* = **task-type** ∨ **value-type** *left* = **port-type** ∧ **value-type** *right* = **port-type** ∨ **value-type** *left* = **address-type** ∧ **value-type** *right* = **address-type**.

> Numeric matching is exact mathematical-value equality across int and float.

**numeric-value?** *left* ∧ **numeric-value?** *right* → (**matches?** *left* *right* ↔ **numeric-magnitude** *left* = **numeric-magnitude** *right*).

> Equal int magnitudes are exactly equal int payloads.

**value-type** *left* = **int-type** ∧ **value-type** *right* = **int-type** → (**numeric-magnitude** *left* = **numeric-magnitude** *right* ↔ **int-payload** *left* = **int-payload** *right*).

> Chars and symbols match exactly when their scalar contents match.

**value-type** *left* = **char-type** ∧ **value-type** *right* = **char-type** → (**matches?** *left* *right* ↔ **char-codepoint** *left* = **char-codepoint** *right*).

**value-type** *left* = **symbol-type** ∧ **value-type** *right* = **symbol-type** → (**matches?** *left* *right* ↔ **symbol-spelling** *left* = **symbol-spelling** *right*).

> Lists match recursively and positionally.

**value-type** *left* = **list-type** ∧ **value-type** *right* = **list-type** → (**matches?** *left* *right* ↔ **list-length** *left* = **list-length** *right* ∧ (∀ *index*: `Nat`, *index* ≤ **list-length** *left* · **matches?** (**list-element** *left* *index*) (**list-element** *right* *index*))).

> Whole-value matching is dictionary-key identity.

∀ *dictionary*: `Value`, *key*: `Value`, *other*: `Value`, **value-type** *dictionary* = **dict-type**, **dict-has-key?** *dictionary* *key*, **matches?** *key* *other* · **dict-has-key?** *dictionary* *other*.

∀ *dictionary*: `Value`, *key*: `Value`, *other*: `Value`, **value-type** *dictionary* = **dict-type**, **dict-has-key?** *dictionary* *key*, **matches?** *key* *other* · **dict-value-for-key** *dictionary* *key* = **dict-value-for-key** *dictionary* *other*.

> Dictionaries match exactly when they have the same keys and the values under each key match.

**value-type** *left* = **dict-type** ∧ **value-type** *right* = **dict-type** → (**matches?** *left* *right* ↔ (∀ *key*: `Value` · **dict-has-key?** *left* *key* ↔ **dict-has-key?** *right* *key*) ∧ (∀ *key*: `Value`, **dict-has-key?** *left* *key*, **dict-has-key?** *right* *key* · **matches?** (**dict-value-for-key** *left* *key*) (**dict-value-for-key** *right* *key*))).

> A task value only matches itself.

**value-type** *left* = **task-type** ∧ **value-type** *right* = **task-type** → (**matches?** *left* *right* ↔ *left* = *right*).

> A port value only matches itself.

**value-type** *left* = **port-type** ∧ **value-type** *right* = **port-type** → (**matches?** *left* *right* ↔ *left* = *right*).

> An address names the mailbox of one task capability.

**value-type** (**address-mailbox** *value*) = **task-type**.

> Address values match when they correspond to the same task.

**value-type** *left* = **address-type** ∧ **value-type** *right* = **address-type** → (**matches?** *left* *right* ↔ **address-mailbox** *left* = **address-mailbox** *right*).

> Scalar source kinds have readable representations.

**value-type** *value* = **int-type** ∨ **value-type** *value* = **float-type** ∨ **value-type** *value* = **char-type** ∨ **value-type** *value* = **symbol-type** → **readable?** *value*.

> Task, port, and address values have diagnostic displays but no readable representations.

**value-type** *value* = **task-type** ∨ **value-type** *value* = **port-type** ∨ **value-type** *value* = **address-type** → ¬**readable?** *value*.

> A list is readable exactly when all its elements are readable.

**value-type** *value* = **list-type** → (**readable?** *value* ↔ (∀ *index*: `Nat`, *index* ≤ **list-length** *value* · **readable?** (**list-element** *value* *index*))).

> A dictionary is readable exactly when all its keys and values are readable.

**value-type** *value* = **dict-type** → (**readable?** *value* ↔ (∀ *key*: `Value`, **dict-has-key?** *value* *key* · **readable?** *key* ∧ **readable?** (**dict-value-for-key** *value* *key*))).

> Hashing is congruent with whole-value matching.

**matches?** *left*
*right* → **value-hash** *left* = **value-hash** *right*.

#### Chapter 3

##### Rules

> `matches?` is the equivalence exposed by `match?` and used for dictionary-key identity. Lists match recursively by position. Dictionaries match by their key-value pairs. Task and port values match only themselves. Resolution context, source spans, provenance, and storage identity are absent from these rules and therefore cannot affect matching or hashing.

**matches?** *left*: `Value`, *right*: `Value` ⇒ `Bool`.



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

**Imports:** ECL_VALUES

#### Chapter 1

##### Rules

> ECL errors are ordinary values with the dictionary kind. An error has a required symbol at `'kind`; when present, `'msg` is a string, `'word` is a symbol, `'trace` is a list of symbols, and `'data` is a dictionary. Other diagnostic and kind-specific fields are permitted. The predicates here classify immutable values independently of execution state.

**error-value?** *value*: `Value` ⇒ `Bool`.

**kind-field-valid?** *value*: `Value` ⇒ `Bool`.

**message-field-valid?** *value*: `Value` ⇒ `Bool`.

**word-field-valid?** *value*: `Value` ⇒ `Bool`.

**trace-field-valid?** *value*: `Value` ⇒ `Bool`.

**data-field-valid?** *value*: `Value` ⇒ `Bool`.

**symbol-list-value?** *value*: `Value` ⇒ `Bool`.

**kind-field** ⇒ `Value`.

**message-field** ⇒ `Value`.

**word-field** ⇒ `Value`.

**trace-field** ⇒ `Value`.

**data-field** ⇒ `Value`.

---

> The five schema keys are symbols with these exact spellings.

**value-type** **kind-field** = **symbol-type** ∧ **symbol-spelling** **kind-field** = "kind" ∧ **value-type** **message-field** = **symbol-type** ∧ **symbol-spelling** **message-field** = "msg" ∧ **value-type** **word-field** = **symbol-type** ∧ **symbol-spelling** **word-field** = "word" ∧ **value-type** **trace-field** = **symbol-type** ∧ **symbol-spelling** **trace-field** = "trace" ∧ **value-type** **data-field** = **symbol-type** ∧ **symbol-spelling** **data-field** = "data".

> A trace is a list containing only symbols. The empty list is a valid trace.

**symbol-list-value?** *value* ↔ **value-type** *value* = **list-type** ∧ (∀ *index*: `Nat`, *index* ≤ **list-length** *value* · **value-type** (**list-element** *value* *index*) = **symbol-type**).

> Non-dictionaries cannot satisfy any error-schema field predicate.

**value-type** *value* ≠ **dict-type** → ¬**kind-field-valid?** *value* ∧ ¬**message-field-valid?** *value* ∧ ¬**word-field-valid?** *value* ∧ ¬**trace-field-valid?** *value* ∧ ¬**data-field-valid?** *value*.

> The `'kind` field is required and its value is a symbol.

¬**dict-has-key?** *value* **kind-field** → ¬**kind-field-valid?** *value*.

**value-type** *value* = **dict-type** ∧ **dict-has-key?** *value* **kind-field** → (**kind-field-valid?** *value* ↔ **value-type** (**dict-value-for-key** *value* **kind-field**) = **symbol-type**).

> The `'msg` field is optional and, when present, is a string.

¬**dict-has-key?** *value* **message-field** → **message-field-valid?** *value*.

**value-type** *value* = **dict-type** ∧ **dict-has-key?** *value* **message-field** → (**message-field-valid?** *value* ↔ **string-value?** (**dict-value-for-key** *value* **message-field**)).

> The `'word` field is optional and, when present, is a symbol.

¬**dict-has-key?** *value* **word-field** → **word-field-valid?** *value*.

**value-type** *value* = **dict-type** ∧ **dict-has-key?** *value* **word-field** → (**word-field-valid?** *value* ↔ **value-type** (**dict-value-for-key** *value* **word-field**) = **symbol-type**).

> The `'trace` field is optional and, when present, is a list of symbols.

¬**dict-has-key?** *value* **trace-field** → **trace-field-valid?** *value*.

**value-type** *value* = **dict-type** ∧ **dict-has-key?** *value* **trace-field** → (**trace-field-valid?** *value* ↔ **symbol-list-value?** (**dict-value-for-key** *value* **trace-field**)).

> The `'data` field is optional and, when present, is a dictionary.

¬**dict-has-key?** *value* **data-field** → **data-field-valid?** *value*.

**value-type** *value* = **dict-type** ∧ **dict-has-key?** *value* **data-field** → (**data-field-valid?** *value* ↔ **value-type** (**dict-value-for-key** *value* **data-field**) = **dict-type**).

> A value is an error exactly when it is a dictionary satisfying every field rule above. Fields outside this schema do not affect validity.

**error-value?** *value* ↔ **value-type** *value* = **dict-type** ∧ **kind-field-valid?** *value* ∧ **message-field-valid?** *value* ∧ **word-field-valid?** *value* ∧ **trace-field-valid?** *value* ∧ **data-field-valid?** *value*.

#### Chapter 2

##### Rules

> The core error-kind taxonomy is closed. Every other symbol remains available as a user-defined error kind; being outside this predicate does not make a symbol invalid in an error's `'kind` field.

**core-error-kind?** *value*: `Value` ⇒ `Bool`.

**underflow-error-kind** ⇒ `Value`.

**undefined-word-error-kind** ⇒ `Value`.

**type-error-kind** ⇒ `Value`.

**shape-error-kind** ⇒ `Value`.

**conform-error-kind** ⇒ `Value`.

**overflow-error-kind** ⇒ `Value`.

**domain-error-kind** ⇒ `Value`.

**contract-error-kind** ⇒ `Value`.

**parse-error-kind** ⇒ `Value`.

**io-error-kind** ⇒ `Value`.

**cancelled-error-kind** ⇒ `Value`.

**timeout-error-kind** ⇒ `Value`.

**user-error-kind** ⇒ `Value`.

---

> Each core error kind is the symbol with the corresponding source spelling.

**value-type** **underflow-error-kind** = **symbol-type** ∧ **symbol-spelling** **underflow-error-kind** = "underflow" ∧ **value-type** **undefined-word-error-kind** = **symbol-type** ∧ **symbol-spelling** **undefined-word-error-kind** = "undefined-word" ∧ **value-type** **type-error-kind** = **symbol-type** ∧ **symbol-spelling** **type-error-kind** = "type" ∧ **value-type** **shape-error-kind** = **symbol-type** ∧ **symbol-spelling** **shape-error-kind** = "shape" ∧ **value-type** **conform-error-kind** = **symbol-type** ∧ **symbol-spelling** **conform-error-kind** = "conform" ∧ **value-type** **overflow-error-kind** = **symbol-type** ∧ **symbol-spelling** **overflow-error-kind** = "overflow" ∧ **value-type** **domain-error-kind** = **symbol-type** ∧ **symbol-spelling** **domain-error-kind** = "domain" ∧ **value-type** **contract-error-kind** = **symbol-type** ∧ **symbol-spelling** **contract-error-kind** = "contract" ∧ **value-type** **parse-error-kind** = **symbol-type** ∧ **symbol-spelling** **parse-error-kind** = "parse" ∧ **value-type** **io-error-kind** = **symbol-type** ∧ **symbol-spelling** **io-error-kind** = "io" ∧ **value-type** **cancelled-error-kind** = **symbol-type** ∧ **symbol-spelling** **cancelled-error-kind** = "cancelled" ∧ **value-type** **timeout-error-kind** = **symbol-type** ∧ **symbol-spelling** **timeout-error-kind** = "timeout" ∧ **value-type** **user-error-kind** = **symbol-type** ∧ **symbol-spelling** **user-error-kind** = "user".

> No other value is a core error kind.

**core-error-kind?** *value* ↔ *value* = **underflow-error-kind** ∨ *value* = **undefined-word-error-kind** ∨ *value* = **type-error-kind** ∨ *value* = **shape-error-kind** ∨ *value* = **conform-error-kind** ∨ *value* = **overflow-error-kind** ∨ *value* = **domain-error-kind** ∨ *value* = **contract-error-kind** ∨ *value* = **parse-error-kind** ∨ *value* = **io-error-kind** ∨ *value* = **cancelled-error-kind** ∨ *value* = **timeout-error-kind** ∨ *value* = **user-error-kind**.

#### Chapter 3

##### Rules

> Results are ordinary values with the dictionary kind. A successful result has exactly one `'ok` entry carrying the ordered values left on the successful unit stack. A failed result has exactly one `'err` entry carrying an error value. No value is both forms.

**result-value?** *value*: `Value` ⇒ `Bool`.

**successful-result-value?** *value*: `Value` ⇒ `Bool`.

**failed-result-value?** *value*: `Value` ⇒ `Bool`.

**successful-result-values** *value*: `Value` ⇒ `Value`.

**failed-result-error** *value*: `Value` ⇒ `Value`.

**ok-field** ⇒ `Value`.

**err-field** ⇒ `Value`.

---

> Result tags are symbols with the source spellings `ok` and `err`.

**value-type** **ok-field** = **symbol-type** ∧ **symbol-spelling** **ok-field** = "ok" ∧ **value-type** **err-field** = **symbol-type** ∧ **symbol-spelling** **err-field** = "err".

> A successful result is exactly a one-entry dictionary tagged `'ok` whose payload is a list of successful stack values.

**successful-result-value?** *value* → **value-type** *value* = **dict-type**.

**value-type** *value* = **dict-type** ∧ **successful-result-value?** *value* → **dict-has-key?** *value* **ok-field**.

**value-type** *value* = **dict-type** ∧ **dict-has-key?** *value* **ok-field** → (**successful-result-value?** *value* ↔ (∀ *key*: `Value`, **dict-has-key?** *value* *key* · **matches?** *key* **ok-field**) ∧ **value-type** (**dict-value-for-key** *value* **ok-field**) = **list-type**).

> A failed result is exactly a one-entry dictionary tagged `'err` whose payload satisfies the error schema.

**failed-result-value?** *value* → **value-type** *value* = **dict-type**.

**value-type** *value* = **dict-type** ∧ **failed-result-value?** *value* → **dict-has-key?** *value* **err-field**.

**value-type** *value* = **dict-type** ∧ **dict-has-key?** *value* **err-field** → (**failed-result-value?** *value* ↔ (∀ *key*: `Value`, **dict-has-key?** *value* *key* · **matches?** *key* **err-field**) ∧ **error-value?** (**dict-value-for-key** *value* **err-field**)).

> The payload accessors expose the successful values list or failed error after the corresponding result form has been established.

**successful-result-value?** *value* → **successful-result-values** *value* = **dict-value-for-key** *value* **ok-field**.

**failed-result-value?** *value* → **failed-result-error** *value* = **dict-value-for-key** *value* **err-field**.

> Results are exactly the successful and failed forms.

**result-value?** *value* ↔ **successful-result-value?** *value* ∨ **failed-result-value?** *value*.

> The two result forms are disjoint.

**successful-result-value?** *value* → ¬**failed-result-value?** *value*.

#### Chapter 4

##### Rules

> Cancellation and timeout errors are classified by their required `'kind` field. They retain the ordinary error schema, including any optional or kind-specific diagnostic fields. Their result forms are ordinary failed result envelopes. A timeout result is an observation only; it is not the target task's terminal result.

**cancelled-error?** *value*: `Value` ⇒ `Bool`.

**timeout-error?** *value*: `Value` ⇒ `Bool`.

**cancelled-result?** *value*: `Value` ⇒ `Bool`.

**timeout-result?** *value*: `Value` ⇒ `Bool`.

---

> Cancellation and timeout errors are exactly the errors of the corresponding core kind.

**cancelled-error?** *value* → **error-value?** *value*.

**error-value?** *value* → (**cancelled-error?** *value* ↔ **dict-value-for-key** *value* **kind-field** = **cancelled-error-kind**).

**timeout-error?** *value* → **error-value?** *value*.

**error-value?** *value* → (**timeout-error?** *value* ↔ **dict-value-for-key** *value*
**kind-field** = **timeout-error-kind**).

> Cancellation and timeout results contain errors of the corresponding kind.

**cancelled-result?** *value* ↔ **failed-result-value?** *value* ∧ **cancelled-error?** (**failed-result-error** *value*).

**timeout-result?** *value* ↔ **failed-result-value?** *value* ∧ **timeout-error?** (**failed-result-error** *value*).



### Units and the transactional stack

Ordinary evaluation may consume operands and perform effects before it fails;
its failure outcome therefore includes the partial operand stack and the
surviving execution state at the point of failure.

**Imports:** ECL_ERRORS

##### Contexts

**`Units`**, **`Nesting`**

#### Chapter 1

##### Action

> This model is normative for the lifecycle of a general ECL unit: successful completion with an ordered result stack, failure with an error, and the strict nesting of units opened inside another.  It deliberately abstracts over evaluation steps, name resolution, concrete values and error dictionaries, environment writes, I/O, randomness, and all other non-stack effects. The surrounding language specification governs those subjects and requires that unit failure does not roll back effects already performed. The model also omits the code a unit runs, the stack it begins on, launch and observation policy, task identity, task trees, scheduling, awaiting, deadlines, cancellation causes, and reclamation. In particular, cancellation reaches this model only as an evaluator-supplied failure error, while a waiting operation's timeout does not alter the target unit.  `@attempt` begins a unit, waits synchronously for one terminal transition, and reifies that outcome. `@spawn` begins the same kind of unit and returns a task capability immediately; `task.await` later reifies the attached unit's terminal outcome through the same mapping. The two therefore agree on result envelope and failure mapping. They differ in ownership: `@spawn` creates a task, which owns the tasks spawned inside it, while `@attempt` is a stack transaction that owns nothing, so tasks spawned inside it belong to the enclosing task or the session root. Task lifetime, ownership, and waiting behavior are governed by the concurrency model.  `Begin unit` starts a unit with no parent. Submissions and unit constructors differ in how they expose the eventual outcome; those policies do not change unit execution semantics. A unit that running code opens inside another unit, such as `@attempt`, `@load`, and module construction, begins through `Begin nested unit`.

**`Units`** ↝ Begin unit.

---

> Beginning a unit selects one identity that has never begun and makes it active.

∃ *unit*: `Unit`, ¬**unit-active?** *unit*, ¬**unit-succeeded?** *unit*, ¬**unit-failed?** *unit* · **unit-active?**′ *unit* ∧ ¬**unit-succeeded?**′ *unit* ∧ ¬**unit-failed?**′ *unit* ∧ (∀ *other*: `Unit`, *other* ≠ *unit* · **unit-active?**′ *other* = **unit-active?** *other* ∧ **unit-succeeded?**′ *other* = **unit-succeeded?** *other* ∧ **unit-failed?**′ *other* = **unit-failed?** *other* ∧ **unit-stack**′ *other* = **unit-stack** *other* ∧ **unit-error**′ *other* = **unit-error** *other*).

#### Chapter 2

##### Domains

> A unit that has begun is in exactly one phase: active, successfully completed, or failed. One in no phase has not begun. `unit-stack` is the evaluator-supplied result of a successful unit and `unit-error` the error of a failed one. Intermediate evaluator stacks are outside the abstraction.

`Unit`.

##### Rules

{**`Units`**} **unit-active?** *unit*: `Unit` ⇒ `Bool`.

{**`Units`**} **unit-succeeded?** *unit*: `Unit` ⇒ `Bool`.

{**`Units`**} **unit-failed?** *unit*: `Unit` ⇒ `Bool`.

{**`Units`**} **unit-stack** *unit*: `Unit`, **unit-succeeded?** *unit* ⇒ `Value`.

{**`Units`**} **unit-error** *unit*: `Unit`, **unit-failed?** *unit* ⇒ `Value`.

> Nesting is fixed when a unit begins. A unit without a parent is a submission's or a task's; its failure is observed by the Session or through `task.await`, never by another unit.

{**`Nesting`**} **unit-nested?** *unit*: `Unit` ⇒ `Bool`.

{**`Nesting`**} **unit-parent** *unit*: `Unit` ⇒ `Unit`.

{**`Nesting`**} **unit-reifying?** *unit*: `Unit` ⇒ `Bool`.

---

> A unit is in at most one phase.

**unit-active?** *unit* → ¬**unit-succeeded?** *unit* ∧ ¬**unit-failed?** *unit*.

**unit-succeeded?** *unit* → ¬**unit-failed?** *unit*.

> A successfully completed unit exposes a list: its result stack.

**unit-succeeded?** *unit* → **value-type** (**unit-stack** *unit*) = **list-type**.

> A failed unit carries an error value and exposes no stack.

**unit-failed?** *unit* → **error-value?** (**unit-error** *unit*).

> Only a unit that has begun is nested, inside another unit that has begun.

**unit-nested?** *unit* → (**unit-active?** *unit* ∨ **unit-succeeded?** *unit* ∨ **unit-failed?** *unit*) ∧ (**unit-active?** (**unit-parent** *unit*) ∨ **unit-succeeded?** (**unit-parent** *unit*) ∨ **unit-failed?** (**unit-parent** *unit*)) ∧ **unit-parent** *unit* ≠ *unit*.

> Units nest strictly: the parent of an active nested unit is active.

**unit-active?** *unit* ∧ **unit-nested?** *unit* → **unit-active?** (**unit-parent** *unit*).

> A parent succeeds only if every failure nested in it was reified and was not a cancellation.

**unit-nested?** *unit* ∧ **unit-failed?** *unit* ∧ **unit-succeeded?** (**unit-parent** *unit*) → **unit-reifying?** *unit* ∧ ¬**cancelled-error?** (**unit-error** *unit*).

> Initially no unit has begun or is nested.

initially ∀ *candidate*: `Unit` · ¬**unit-active?** *candidate* ∧ ¬**unit-succeeded?** *candidate* ∧ ¬**unit-failed?** *candidate* ∧ ¬**unit-nested?** *candidate*.

#### Chapter 3

##### Action

> `Complete unit successfully` accepts the result produced by the omitted evaluator, makes the active unit terminal, and retains that result as the unit's result stack. The evaluator supplies the result; it is not chosen by the ECL operation that launched the unit.

**`Units`** ↝ Complete unit successfully *unit*: `Unit`, *result*: `Value`, **unit-active?** *unit*, **value-type** *result* = **list-type**, (∀ *child*: `Unit`, **unit-nested?** *child*, **unit-parent** *child* = *unit* · ¬**unit-active?** *child*), (∀ *child*: `Unit`, **unit-nested?** *child*, **unit-parent** *child* = *unit*, **unit-failed?** *child* · **unit-reifying?** *child* ∧ ¬**cancelled-error?** (**unit-error** *child*)).

---

> Successful completion makes the unit terminal and exposes the evaluator's complete result stack.

¬**unit-active?**′ *unit*.

**unit-succeeded?**′ *unit*.

¬**unit-failed?**′ *unit*.

**unit-stack**′ *unit* = *result*.

∀ *other*: `Unit`, *other* ≠ *unit* · **unit-active?**′ *other* = **unit-active?** *other* ∧ **unit-succeeded?**′ *other* = **unit-succeeded?** *other* ∧ **unit-failed?**′ *other* = **unit-failed?** *other* ∧ **unit-stack**′ *other* = **unit-stack** *other* ∧ **unit-error**′ *other* = **unit-error** *other*.

#### Chapter 4

##### Action

> `Complete unit with failure` accepts the error produced by the evaluator or by a facility such as concurrency cancellation. Errors are ordinary ECL values satisfying the imported `error-value?` schema. Completion makes the active unit terminal and records the error value. The evaluator's partial stack is neither retained nor exposed. Every error kind follows this same unit transition; causes and concrete error data are outside the model.

**`Units`** ↝ Complete unit with failure *unit*: `Unit`, *error*: `Value`, **unit-active?** *unit*, **error-value?** *error*, (∀ *child*: `Unit`, **unit-nested?** *child*, **unit-parent** *child* = *unit* · ¬**unit-active?** *child*).

---

> Failure makes the unit terminal and records the evaluator-supplied error.

¬**unit-active?**′ *unit*.

¬**unit-succeeded?**′ *unit*.

**unit-failed?**′ *unit*.

**unit-error**′ *unit* = *error*.

∀ *other*: `Unit`, *other* ≠ *unit* · **unit-active?**′ *other* = **unit-active?** *other* ∧ **unit-succeeded?**′ *other* = **unit-succeeded?** *other* ∧ **unit-failed?**′ *other* = **unit-failed?** *other* ∧ **unit-stack**′ *other* = **unit-stack** *other* ∧ **unit-error**′ *other* = **unit-error** *other*.

#### Chapter 5

##### Action

> `Begin nested unit` opens a unit inside an active parent unit. Units nest strictly: a parent cannot become terminal while a unit nested in it is active. A reifying nested unit, as `@attempt` opens, turns its failure into data its parent continues with. Any other nested failure propagates, so its parent cannot succeed. Cancellation is never reified: a nested unit failed by a cancellation error prevents its parent's success whatever boundary opened it, so cancellation fails every unit of the cancelled task or root from the innermost out.

**`Units`**, **`Nesting`** ↝ Begin nested unit *parent*: `Unit`, **unit-active?** *parent*.

---

> Beginning a nested unit is beginning a unit that also records its parent. Whether its boundary reifies failure is the opener's choice, which the model leaves open here and holds fixed afterwards.

∃ *unit*: `Unit`, ¬**unit-active?** *unit*, ¬**unit-succeeded?** *unit*, ¬**unit-failed?** *unit* · **unit-active?**′ *unit* ∧ ¬**unit-succeeded?**′ *unit* ∧ ¬**unit-failed?**′ *unit* ∧ **unit-nested?**′ *unit* ∧ **unit-parent**′ *unit* = *parent* ∧ (∀ *other*: `Unit`, *other* ≠ *unit* · **unit-active?**′ *other* = **unit-active?** *other* ∧ **unit-succeeded?**′ *other* = **unit-succeeded?** *other* ∧ **unit-failed?**′ *other* = **unit-failed?** *other* ∧ **unit-stack**′ *other* = **unit-stack** *other* ∧ **unit-error**′ *other* = **unit-error** *other* ∧ **unit-nested?**′ *other* = **unit-nested?** *other* ∧ **unit-parent**′ *other* = **unit-parent** *other* ∧ **unit-reifying?**′ *other* = **unit-reifying?** *other*).



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

**Imports:** ECL_VALUES

##### Contexts

**`Calls`**, **`Construction`**, **`Registry`**

#### Chapter 1

##### Domains

`RegistryName`, `BindingName`

##### Action

> This model is normative for registry names, aliases, generations, and publication, including the construction of the images they publish; abstract definitions and visibility; and call contexts. Modules are pure code: a registration carries no operand stack and no state of its own, and a generation is nothing but an image published under a name.  It deliberately abstracts over source spelling and name validation, construction-body evaluation (including the refusal of a body that leaves values on its stack), concrete and nested values, error construction and propagation, task and unit ownership, scheduling and fairness, and storage reclamation. The surrounding language specification governs those subjects. Begin and complete actions expose semantic concurrency boundaries; they are not ECL words. Contexts grant formal write authority and do not denote runtime values or additional language state. An `InvocationContext` is either the top-level evaluator or identifies the exact active call performing a registry mutation.  A qualified call selects a registry name's current image and a public binding in it in one atomic action, when the call begins, so code written before a replacement reaches the replacement at its next call. Explicit lookup performs the same fresh selection each time it runs.

**`Calls`** ↝ Begin qualified call *module-name*: `RegistryName`, *binding-name*: `BindingName`.

---

**module?** *module-name* ∨ **alias?** *module-name*.

∃ *call*: `Call`, *image*: `Image`, *definition*: `Definition`, ¬**call-created?** *call*, *image* = **image-of** *module-name*, **binding-present?** *image* *binding-name*, *definition* = **definition-at** *image* *binding-name*, **public?** *definition* · **call-created?**′ *call* ∧ **call-active?**′ *call* ∧ **call-image**′ *call* = *image* ∧ **call-definition**′ *call* = *definition* ∧ (∀ *other*: `Call`, *other* ≠ *call* · **call-created?**′ *other* = **call-created?** *other* ∧ **call-active?**′ *other* = **call-active?** *other* ∧ **call-image**′ *other* = **call-image** *other* ∧ **call-definition**′ *other* = **call-definition** *other*).

#### Chapter 2

##### Domains

> The model has one kind of module object: an immutable image, published under one module name as one generation. Reload publishes a new image under the same name and retires the previous one. No action removes a registration. A name is live while it maps to a published, non-retired image, which is that name's current generation. A live module name has zero or more direct aliases.  Definitions are immutable background relations. Each definition belongs to one image and binding name, binding names are unique within an image, and visibility controls which call actions may select it. The model begins with no constructed images, occupied names, published generations, or calls. Domain atoms are possibilities rather than initially existing language values.  Retirement is monotonic: replacement retires the former current image and no retired image becomes current again. A retired image stays published, so unqualified words whose occurrences retain it as their scope keep their meaning; qualified words select the current registration, and aliases follow it on later lookup.

`Call`.

`Image`.

`Definition`.

`WordOccurrence`.

`InvocationContext`.

##### Rules

{**`Calls`**} **call-active?** *call*: `Call` ⇒ `Bool`.

{**`Calls`**} **call-created?** *call*: `Call` ⇒ `Bool`.

{**`Calls`**} **call-image** *call*: `Call` ⇒ `Image`.

{**`Calls`**} **call-definition** *call*: `Call` ⇒ `Definition`.

**occurrence-name** *occurrence*: `WordOccurrence` ⇒ `BindingName`.

**occurrence-image** *occurrence*: `WordOccurrence` ⇒ `Image`.

**call-invocation?** *invoker*: `InvocationContext` ⇒ `Bool`.

**invocation-call** *invoker*: `InvocationContext` ⇒ `Call`.

{**`Construction`**} **constructed?** *image*: `Image` ⇒ `Bool`.

{**`Registry`**} **module?** *name*: `RegistryName` ⇒ `Bool`.

{**`Registry`**} **alias?** *name*: `RegistryName` ⇒ `Bool`.

{**`Registry`**} **image-of** *name*: `RegistryName` ⇒ `Image`.

{**`Registry`**} **image-published?** *image*: `Image` ⇒ `Bool`.

{**`Registry`**} **image-retired?** *image*: `Image` ⇒ `Bool`.

{**`Registry`**} **image-name** *image*: `Image` ⇒ `RegistryName`.

**binding-present?** *image*: `Image`, *name*: `BindingName` ⇒ `Bool`.

**definition-at** *image*: `Image`, *name*: `BindingName` ⇒ `Definition`.

**definition-image** *definition*: `Definition` ⇒ `Image`.

**definition-name** *definition*: `Definition` ⇒ `BindingName`.

**public?** *definition*: `Definition` ⇒ `Bool`.

---

∀ *image*: `Image`, *name*: `BindingName`, **binding-present?** *image* *name* · **definition-image** (**definition-at** *image* *name*) = *image* ∧ **definition-name** (**definition-at** *image* *name*) = *name*.

∀ *left*: `Definition`, *right*: `Definition`, **definition-image** *left* = **definition-image** *right*, **definition-name** *left* = **definition-name** *right* · *left* = *right*.

initially ∀ *image*: `Image`, *name*: `BindingName`, **binding-present?** *image* *name* · **definition-image** (**definition-at** *image* *name*) = *image* ∧ **definition-name** (**definition-at** *image* *name*) = *name*.

initially ∀ *left*: `Definition`, *right*: `Definition`, **definition-image** *left* = **definition-image** *right*, **definition-name** *left* = **definition-name** *right* · *left* = *right*.

∀ *registry-name*: `RegistryName` · ¬(**module?** *registry-name* ∧ **alias?** *registry-name*).

> A live name maps to its current generation.

∀ *registry-name*: `RegistryName`, (**module?** *registry-name* ∨ **alias?** *registry-name*) · **image-published?** (**image-of** *registry-name*) ∧ ¬**image-retired?** (**image-of** *registry-name*).

∀ *registry-name*: `RegistryName`, **module?** *registry-name* · **image-name** (**image-of** *registry-name*) = *registry-name*.

> An alias resolves to the current image of a live module name.

∀ *registry-name*: `RegistryName`, **alias?** *registry-name* · **module?** (**image-name** (**image-of** *registry-name*)) ∧ **image-of** (**image-name** (**image-of** *registry-name*)) = **image-of** *registry-name*.

**image-published?** *image* → **constructed?** *image*.

> An image exists only as a published generation: no program can hold one any other way.

**constructed?** *image* → **image-published?** *image*.

**image-retired?** *image* → **image-published?** *image*.

> A published image that is not retired is current under its own name.

**image-published?** *image* ∧ ¬**image-retired?** *image* → **module?** (**image-name** *image*) ∧ **image-of** (**image-name** *image*) = *image*.

**call-active?** *call* → **call-created?** *call*.

**call-active?** *call* → **constructed?** (**call-image** *call*) ∧ **definition-image** (**call-definition** *call*) = **call-image** *call*.

initially ∀ *image*: `Image` · ¬**constructed?** *image* ∧ ¬**image-published?** *image* ∧ ¬**image-retired?** *image*.

initially ∀ *registry-name*: `RegistryName` · ¬**module?** *registry-name* ∧ ¬**alias?** *registry-name*.

initially ∀ *call*: `Call` · ¬**call-created?** *call* ∧ ¬**call-active?** *call*.

∃ *invoker*: `InvocationContext` · ¬**call-invocation?** *invoker*.

initially ∃ *invoker*: `InvocationContext` · ¬**call-invocation?** *invoker*.

#### Chapter 3

##### Action

> `Register` is `@defm`'s publication: it constructs a fresh image and publishes it in one step, because no program can observe an image between the two. It is an ordered upsert. Publishing under a missing module name creates the registration; publishing under an existing module name retires that name's current image, and every alias of the name resolves to the new image from then on. Nothing else carries over. The supplied invocation context is the top-level evaluator or the exact call performing the mutation.

**`Registry`**, **`Construction`** ↝ Register *invoker*: `InvocationContext`, *image*: `Image`, *module-name*: `RegistryName`, ¬**constructed?** *image*, ¬**alias?** *module-name*.

---

**module?**′ *module-name* ∧ ¬**alias?**′ *module-name* ∧ **image-of**′ *module-name* = *image* ∧ (∀ *other-name*: `RegistryName`, *other-name* ≠ *module-name* · **module?**′ *other-name* = **module?** *other-name* ∧ **alias?**′ *other-name* = **alias?** *other-name* ∧ (**module?** *module-name* ∧ **alias?** *other-name* ∧ **image-of** *other-name* = **image-of** *module-name* → **image-of**′ *other-name* = *image*) ∧ (¬(**module?** *module-name* ∧ **alias?** *other-name* ∧ **image-of** *other-name* = **image-of** *module-name*) → **image-of**′ *other-name* = **image-of** *other-name*)) ∧ **image-published?**′ *image* ∧ ¬**image-retired?**′ *image* ∧ **image-name**′ *image* = *module-name* ∧ **constructed?**′ *image* ∧ (∀ *other-image*: `Image`, *other-image* ≠ *image* · **constructed?**′ *other-image* = **constructed?** *other-image* ∧ **image-published?**′ *other-image* = **image-published?** *other-image* ∧ **image-retired?**′ *other-image* = (**image-retired?** *other-image* ∨ **module?** *module-name* ∧ *other-image* = **image-of** *module-name*) ∧ **image-name**′ *other-image* = **image-name** *other-image*).

#### Chapter 4

##### Action

> `Add alias` resolves either kind of occupied target name and stores a direct reference to its current image; semantic alias chains do not exist. The alias follows the module name through reload. Module and alias names form one disjoint namespace, and an occupied name cannot be repointed. The supplied invocation context is the top-level evaluator or the exact call performing the mutation.

**`Registry`** ↝ Add alias *invoker*: `InvocationContext`, *alias-name*: `RegistryName`, *target-name*: `RegistryName`, ¬**module?** *alias-name*, ¬**alias?** *alias-name*, (**module?** *target-name* ∨ **alias?** *target-name*).

---

¬**module?**′ *alias-name* ∧ **alias?**′ *alias-name* ∧ **image-of**′ *alias-name* = **image-of** *target-name* ∧ (∀ *other-name*: `RegistryName`, *other-name* ≠ *alias-name* · **module?**′ *other-name* = **module?** *other-name* ∧ **alias?**′ *other-name* = **alias?** *other-name* ∧ **image-of**′ *other-name* = **image-of** *other-name*) ∧ (∀ *image*: `Image` · **image-published?**′ *image* = **image-published?** *image* ∧ **image-retired?**′ *image* = **image-retired?** *image* ∧ **image-name**′ *image* = **image-name** *image*).

#### Chapter 5

##### Action

> `Begin scoped call` resolves the name stored in a word occurrence against the image stored in that occurrence. A quotation or word occurrence owns this scope but does not cache a definition. The image must have been published; a retired image still answers. Private definitions are available to same-image scoped resolution without becoming publicly invocable.

**`Calls`** ↝ Begin scoped call *caller*: `Call`, *occurrence*: `WordOccurrence`, *binding-name*: `BindingName`, **call-active?** *caller*, **occurrence-name** *occurrence* = *binding-name*.

---

∃ *image*: `Image`, *definition*: `Definition`, *callee*: `Call`, *image* = **occurrence-image** *occurrence*, **constructed?** *image*, **image-published?** *image*, **binding-present?** *image* *binding-name*, *definition* = **definition-at** *image*
*binding-name*, (**public?** *definition* ∨ **call-image** *caller* = **definition-image** *definition*), ¬**call-created?** *callee* · **call-created?**′ *callee* ∧ **call-active?**′ *callee* ∧ **call-image**′ *callee* = *image* ∧ **call-definition**′ *callee* = *definition* ∧ (∀ *other*: `Call`, *other* ≠ *callee* · **call-created?**′ *other* = **call-created?** *other* ∧ **call-active?**′ *other* = **call-active?** *other* ∧ **call-image**′ *other* = **call-image** *other* ∧ **call-definition**′ *other* = **call-definition** *other*).

#### Chapter 6

##### Action

> `Complete call` ends the call after its invocation has completed. Calls are split into begin and complete actions only to express publication concurrency; the prose-level invocation remains one language operation.

**`Calls`** ↝ Complete call *completed*: `Call`, **call-active?** *completed*.

---

**call-created?**′ *completed* = **call-created?** *completed* ∧ ¬**call-active?**′ *completed* ∧ **call-image**′ *completed* = **call-image** *completed* ∧ **call-definition**′ *completed* = **call-definition** *completed* ∧ (∀ *other*: `Call`, *other* ≠ *completed* · **call-created?**′ *other* = **call-created?** *other* ∧ **call-active?**′ *other* = **call-active?** *other* ∧ **call-image**′ *other* = **call-image** *other* ∧ **call-definition**′ *other* = **call-definition** *other*).



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

**Imports:** ECL_UNITS

##### Contexts

**`Concurrency`**, **`Mailboxes`**

#### Chapter 1

##### Domains

> This model is normative for structured task identity, attachment to the general unit lifecycle, task ownership, cached terminal results, observation by `task.await`, deadline expiry, cancellation, the requirement that a task quiesce the tasks it owns before its attached unit becomes terminal, and the lifecycle of the messages a task's mailbox holds.  It abstracts over evaluator steps, scheduling policy, elapsed time, I/O interleaving, handle storage and lexical scope, and the selection algorithms used by `task.await-any`, sequential awaits, and `@each`. The surrounding language specification governs those operations. A conforming scheduler may run runnable tasks serially; the model promises lifetime and result semantics, without promising simultaneous progress or fairness. Task capabilities are immutable ECL values and may be shared. The mutable evaluation state of each task remains confined to its attached unit.  Task scopes exist at two places: the session root and each spawned task. A spawn is owned by the task whose attached unit is executing it, or by the session root when no task is executing. Nested units, such as `@attempt`, `@load`, and module construction, are stack transactions and never owners: a task spawned inside one belongs to the enclosing scope and is unaffected by that unit's success or failure. The session root closes only at `exit` or session end, which this model leaves outside its actions.  A created task permanently names one attached unit and is owned either by the session root or by one other task. Its capability is an ECL value of the task kind. No two task identities attach to the same unit or expose the same capability value. `task-owner` is meaningful only for a task that is not root-owned; every proposition that reads it is guarded accordingly.

`Task`.

> Every task owns one mailbox, open exactly while its attached unit is active. A message is created by `task.send` addressed to one task and is queued until that task receives it or its mailbox closes. Message payloads, capacity and parking, per-sender order, and the handle check on send are governed by the surrounding specification; the model carries only existence, target, and the queued/received/discarded lifecycle.

`Message`.

##### Rules

{**`Concurrency`**} **task-created?** *task*: `Task` ⇒ `Bool`.

{**`Concurrency`**} **task-unit** *task*: `Task` ⇒ `Unit`.

{**`Concurrency`**} **root-owned?** *task*: `Task` ⇒ `Bool`.

{**`Concurrency`**} **task-owner** *task*: `Task` ⇒ `Task`.

**task-capability** *task*: `Task` ⇒ `Value`.

{**`Mailboxes`**} **message-created?** *message*: `Message` ⇒ `Bool`.

{**`Mailboxes`**} **message-target** *message*: `Message` ⇒ `Task`.

{**`Mailboxes`**} **received?** *message*: `Message` ⇒ `Bool`.

{**`Mailboxes`**} **discarded?** *message*: `Message` ⇒ `Bool`.

---

> Every created task has a task-valued capability and attaches to a unit that has begun. A task not owned by the root is owned by a distinct created task.

**task-created?** *task* → **value-type** (**task-capability** *task*) = **task-type** ∧ (**unit-active?** (**task-unit** *task*) ∨ **unit-succeeded?** (**task-unit** *task*) ∨ **unit-failed?** (**task-unit** *task*)).

**task-created?** *task* ∧ ¬**root-owned?** *task* → **task-created?** (**task-owner** *task*) ∧ **task-owner** *task* ≠ *task*.

> Attached units are unique to their task identities.

∀ *left*: `Task`, *right*: `Task`, **task-created?** *left*, **task-created?** *right*, **task-unit** *left* = **task-unit** *right* · *left* = *right*.

> Created tasks have distinct capability values.

∀ *left*: `Task`, *right*: `Task`, **task-created?** *left*, **task-created?** *right*, **task-capability** *left* = **task-capability** *right* · *left* = *right*.

> A created message addresses a created task and is in at most one terminal state. A message is queued when it is created and neither received nor discarded; a queued message's target is still active, because closing a mailbox discards everything it holds.

**message-created?** *message* → **task-created?** (**message-target** *message*) ∧ ¬(**received?** *message* ∧ **discarded?** *message*).

**message-created?** *message* ∧ ¬**received?** *message* ∧ ¬**discarded?** *message* → **unit-active?** (**task-unit** (**message-target** *message*)).

> Initially no task identity or message has been created.

initially ∀ *task*: `Task` · ¬**task-created?** *task*.

initially ∀ *message*: `Message` · ¬**message-created?** *message*.

#### Chapter 2

##### Action

> `Spawn task under task` and `Spawn task under root` are the formal `@spawn` boundary. The action chooses both a fresh task identity and a fresh unit identity, attaches them permanently, and records the owning task or the session root.

**`Units`**, **`Concurrency`** ↝ Spawn task under task *owner*: `Task`, **task-created?** *owner*, **unit-active?** (**task-unit** *owner*), ¬**unit-succeeded?** (**task-unit** *owner*), ¬**unit-failed?** (**task-unit** *owner*).

---

> Spawning creates one task and one attached active unit. Both identities are fresh, the owner is recorded, and all previously created task and unit state is preserved.

∃ *task*: `Task`, *child*: `Unit`, ¬**task-created?** *task*, ¬**unit-active?** *child*, ¬**unit-succeeded?** *child*, ¬**unit-failed?** *child* · **task-created?**′ *task* ∧ **task-unit**′ *task* = *child* ∧ ¬**root-owned?**′ *task* ∧ **task-owner**′ *task* = *owner* ∧ **value-type** (**task-capability** *task*) = **task-type** ∧ (∀ *existing*: `Task`, **task-created?** *existing* · **task-capability** *task* ≠ **task-capability** *existing*) ∧ **unit-active?**′ *child* ∧ ¬**unit-succeeded?**′ *child* ∧ ¬**unit-failed?**′ *child* ∧ **unit-error**′ *child* = **unit-error** *child* ∧ (∀ *other-task*: `Task`, *other-task* ≠ *task* · **task-created?**′ *other-task* = **task-created?** *other-task* ∧ **task-unit**′ *other-task* = **task-unit** *other-task* ∧ **root-owned?**′ *other-task* = **root-owned?** *other-task*) ∧ (∀ *other-task*: `Task`, *other-task* ≠ *task* · **task-owner**′ *other-task* = **task-owner** *other-task*) ∧ (∀ *other-unit*: `Unit`, *other-unit* ≠ *child* · **unit-active?**′ *other-unit* = **unit-active?** *other-unit* ∧ **unit-succeeded?**′ *other-unit* = **unit-succeeded?** *other-unit* ∧ **unit-failed?**′ *other-unit* = **unit-failed?** *other-unit* ∧ **unit-stack**′ *other-unit* = **unit-stack** *other-unit* ∧ **unit-error**′ *other-unit* = **unit-error** *other-unit*).

#### Chapter 3

##### Action

> `Spawn task under root` is the same boundary when no task is executing: code at the root, including a stack transaction there, spawns into the session root scope.

**`Units`**, **`Concurrency`** ↝ Spawn task under root.

---

∃ *task*: `Task`, *child*: `Unit`, ¬**task-created?** *task*, ¬**unit-active?** *child*, ¬**unit-succeeded?** *child*, ¬**unit-failed?** *child* · **task-created?**′ *task* ∧ **task-unit**′ *task* = *child* ∧ **root-owned?**′ *task* ∧ **value-type** (**task-capability** *task*) = **task-type** ∧ (∀ *existing*: `Task`, **task-created?** *existing* · **task-capability** *task* ≠ **task-capability** *existing*) ∧ **unit-active?**′ *child* ∧ ¬**unit-succeeded?**′ *child* ∧ ¬**unit-failed?**′ *child* ∧ **unit-error**′ *child* = **unit-error** *child* ∧ (∀ *other-task*: `Task`, *other-task* ≠ *task* · **task-created?**′ *other-task* = **task-created?** *other-task* ∧ **task-unit**′ *other-task* = **task-unit** *other-task* ∧ **root-owned?**′ *other-task* = **root-owned?** *other-task*) ∧ (∀ *other-task*: `Task`, *other-task* ≠ *task* · **task-owner**′ *other-task* = **task-owner** *other-task*) ∧ (∀ *other-unit*: `Unit`, *other-unit* ≠ *child* · **unit-active?**′ *other-unit* = **unit-active?** *other-unit* ∧ **unit-succeeded?**′ *other-unit* = **unit-succeeded?** *other-unit* ∧ **unit-failed?**′ *other-unit* = **unit-failed?** *other-unit* ∧ **unit-stack**′ *other-unit* = **unit-stack** *other-unit* ∧ **unit-error**′ *other-unit* = **unit-error** *other-unit*).

#### Chapter 4

##### Rules

> A task's terminal result is a single immutable ECL value. A successful attached unit yields the exact ordered terminal stack in an `'ok` envelope; a failed attached unit yields its unchanged error value in an `'err` envelope. Because `task-result` is immutable, every observation of a terminal task produces the same value.

**task-result** *task*: `Task` ⇒ `Value`.

---

> Successful tasks have successful result envelopes.

**task-created?** *task* ∧ **unit-succeeded?** (**task-unit** *task*) → **successful-result-value?** (**task-result** *task*).

> The successful result payload is the attached unit's terminal stack list value.

**task-created?** *task* ∧ **unit-succeeded?** (**task-unit** *task*) → **successful-result-values** (**task-result** *task*) = **unit-stack** (**task-unit** *task*).

> Failed tasks have failed result envelopes containing the unit's exact error value.

**task-created?** *task* ∧ **unit-failed?** (**task-unit** *task*) → **failed-result-value?** (**task-result** *task*).

**task-created?** *task* ∧ **unit-failed?** (**task-unit** *task*) → **failed-result-error** (**task-result** *task*) = **unit-error** (**task-unit** *task*).

> A task's attached unit may become terminal only after every task it owns is terminal. Applying the same rule recursively gives structured quiescence for the complete descendant task tree. This is the task-scope part of the rule that a failed task leaves nothing running.

∀ *owner*: `Task`, **task-created?** *owner*, (**unit-succeeded?** (**task-unit** *owner*) ∨ **unit-failed?** (**task-unit** *owner*)) · ∀ *task*: `Task`, **task-created?** *task*, ¬**root-owned?** *task*, **task-owner** *task* = *owner* · **unit-succeeded?** (**task-unit** *task*) ∨ **unit-failed?** (**task-unit** *task*).

#### Chapter 5

##### Action

> `Send` is the formal `task.send`: it creates one message addressed to an active task. Sending to a task whose attached unit is terminal fails and creates nothing; the surrounding specification names that failure. Parking under pressure is outside the model.

**`Mailboxes`** ↝ Send *target*: `Task`, **task-created?** *target*, **unit-active?** (**task-unit** *target*).

---

∃ *message*: `Message`, ¬**message-created?** *message* · **message-created?**′ *message* ∧ **message-target**′ *message* = *target* ∧ ¬**received?**′ *message* ∧ ¬**discarded?**′ *message* ∧ (∀ *other*: `Message`, *other* ≠ *message* · **message-created?**′ *other* = **message-created?** *other* ∧ **message-target**′ *other* = **message-target** *other* ∧ **received?**′ *other* = **received?** *other* ∧ **discarded?**′ *other* = **discarded?** *other*).

#### Chapter 6

##### Action

> `Receive` is the formal `task.receive`: the receiving task takes one queued message addressed to it. Which queued message is taken is governed by the surrounding specification's ordering rule.

**`Mailboxes`** ↝ Receive *receiver*: `Task`, *message*: `Message`, **task-created?** *receiver*, **unit-active?** (**task-unit** *receiver*), **message-created?** *message*, **message-target** *message* = *receiver*, ¬**received?** *message*, ¬**discarded?** *message*.

---

**received?**′ *message*.

¬**discarded?**′ *message*.

**message-created?**′ *message*.

**message-target**′ *message* = **message-target** *message*.

∀ *other*: `Message`, *other* ≠ *message* · **message-created?**′ *other* = **message-created?** *other* ∧ **message-target**′ *other* = **message-target** *other* ∧ **received?**′ *other* = **received?** *other* ∧ **discarded?**′ *other* = **discarded?** *other*.

#### Chapter 7

##### Action

> `Complete spawned task successfully` is the concurrency-layer use of the general unit success transition. The evaluator supplies the final stack. The attached unit can become terminal only after its own task scope has quiesced.

**`Units`**, **`Concurrency`**, **`Mailboxes`** ↝ Complete spawned task successfully *task*: `Task`, *result*: `Value`, **task-created?** *task*, **unit-active?** (**task-unit** *task*), **value-type** *result* = **list-type**, (∀ *child*: `Task`, **task-created?** *child*, ¬**root-owned?** *child*, **task-owner** *child* = *task* · **unit-succeeded?** (**task-unit** *child*) ∨ **unit-failed?** (**task-unit** *child*)), (∀ *nested*: `Unit`, **unit-nested?** *nested*, **unit-parent** *nested* = **task-unit** *task* · ¬**unit-active?** *nested* ∧ (¬**unit-failed?** *nested* ∨ **unit-reifying?** *nested* ∧ ¬**cancelled-error?** (**unit-error** *nested*))).

---

¬**unit-active?**′ (**task-unit** *task*).

**unit-succeeded?**′ (**task-unit** *task*).

¬**unit-failed?**′ (**task-unit** *task*).

**unit-stack**′ (**task-unit** *task*) = *result*.

**unit-error**′ (**task-unit** *task*) = **unit-error** (**task-unit** *task*).

**successful-result-value?** (**task-result** *task*).

**successful-result-values** (**task-result** *task*) = *result*.

∀ *other*: `Unit`, *other* ≠ **task-unit** *task* · **unit-active?**′ *other* = **unit-active?** *other* ∧ **unit-succeeded?**′ *other* = **unit-succeeded?** *other* ∧ **unit-failed?**′ *other* = **unit-failed?** *other* ∧ **unit-stack**′ *other* = **unit-stack** *other* ∧ **unit-error**′ *other* = **unit-error** *other*.

∀ *candidate*: `Task` · **task-created?**′ *candidate* = **task-created?** *candidate* ∧ **task-unit**′ *candidate* = **task-unit** *candidate* ∧ **root-owned?**′ *candidate* = **root-owned?** *candidate*.

∀ *candidate*: `Task` · **task-owner**′ *candidate* = **task-owner** *candidate*.

> Becoming terminal closes the mailbox: every message still queued for this task is discarded, and nothing else about messages changes.

∀ *message*: `Message`, **message-created?** *message*, **message-target** *message* = *task*, ¬**received?** *message* · **discarded?**′ *message*.

∀ *message*: `Message`, ¬(**message-created?** *message* ∧ **message-target** *message* = *task* ∧ ¬**received?** *message*) · **discarded?**′ *message* = **discarded?** *message*.

∀ *message*: `Message` · **message-created?**′ *message* = **message-created?** *message* ∧ **message-target**′ *message* = **message-target** *message* ∧ **received?**′ *message* = **received?** *message*.

#### Chapter 8

##### Action

> `Complete spawned task with failure` is the concurrency-layer use of the general unit failure transition. The evaluator supplies the error. The attached unit becomes terminal after its own task scope has quiesced.

**`Units`**, **`Concurrency`**, **`Mailboxes`** ↝ Complete spawned task with failure *task*: `Task`, *error*: `Value`, **task-created?** *task*, **unit-active?** (**task-unit** *task*), **error-value?** *error*, (∀ *child*: `Task`, **task-created?** *child*, ¬**root-owned?** *child*, **task-owner** *child* = *task* · **unit-succeeded?** (**task-unit** *child*) ∨ **unit-failed?** (**task-unit** *child*)), (∀ *nested*: `Unit`, **unit-nested?** *nested*, **unit-parent** *nested* = **task-unit** *task* · ¬**unit-active?** *nested*).

---

¬**unit-active?**′ (**task-unit** *task*).

¬**unit-succeeded?**′ (**task-unit** *task*).

**unit-failed?**′ (**task-unit** *task*).

**unit-error**′ (**task-unit** *task*) = *error*.

**failed-result-value?** (**task-result** *task*).

**failed-result-error** (**task-result** *task*) = *error*.

∀ *other*: `Unit`, *other* ≠ **task-unit** *task* · **unit-active?**′ *other* = **unit-active?** *other* ∧ **unit-succeeded?**′ *other* = **unit-succeeded?** *other* ∧ **unit-failed?**′ *other* = **unit-failed?** *other* ∧ **unit-stack**′ *other* = **unit-stack** *other* ∧ **unit-error**′ *other* = **unit-error** *other*.

∀ *candidate*: `Task` · **task-created?**′ *candidate* = **task-created?** *candidate* ∧ **task-unit**′ *candidate* = **task-unit** *candidate* ∧ **root-owned?**′ *candidate* = **root-owned?** *candidate*.

∀ *candidate*: `Task` · **task-owner**′ *candidate* = **task-owner** *candidate*.

> Becoming terminal closes the mailbox: every message still queued for this task is discarded, and nothing else about messages changes.

∀ *message*: `Message`, **message-created?** *message*, **message-target** *message* = *task*, ¬**received?** *message* · **discarded?**′ *message*.

∀ *message*: `Message`, ¬(**message-created?** *message* ∧ **message-target** *message* = *task* ∧ ¬**received?** *message*) · **discarded?**′ *message* = **discarded?** *message*.

∀ *message*: `Message` · **message-created?**′ *message* = **message-created?** *message* ∧ **message-target**′ *message* = **message-target** *message* ∧ **received?**′ *message* = **received?** *message*.

#### Chapter 9

##### Action

> `Await task` observes only a terminal attached unit and leaves both unit and task state unchanged. It yields `task-result task`; repeating the action is therefore safe and produces the cached result again. Parking and resumption before the terminal observation are scheduling details outside the model.

**`Concurrency`** ↝ Await task *observer*: `Unit`, *task*: `Task`, **unit-active?** *observer*, **task-created?** *task*, (**unit-succeeded?** (**task-unit** *task*) ∨ **unit-failed?** (**task-unit** *task*)).

---

∀ *candidate*: `Task` · **task-created?**′ *candidate* = **task-created?** *candidate* ∧ **task-unit**′ *candidate* = **task-unit** *candidate* ∧ **root-owned?**′ *candidate* = **root-owned?** *candidate*.

∀ *candidate*: `Task` · **task-owner**′ *candidate* = **task-owner** *candidate*.

#### Chapter 10

##### Action

> `Await task until deadline expires` is the timeout branch of `task.await-for`. It is available only while the attached unit is active, yields a value satisfying `timeout-result?`, and leaves the task and attached unit unchanged. A terminal task therefore wins over deadline expiry, including at a zero deadline. Deadline measurement and parking are outside the model.

**`Concurrency`** ↝ Await task until deadline expires *observer*: `Unit`, *task*: `Task`, **unit-active?** *observer*, **task-created?** *task*, **unit-active?** (**task-unit** *task*).

---

∀ *candidate*: `Task` · **task-created?**′ *candidate* = **task-created?** *candidate* ∧ **task-unit**′ *candidate* = **task-unit** *candidate* ∧ **root-owned?**′ *candidate* = **root-owned?** *candidate*.

∀ *candidate*: `Task` · **task-owner**′ *candidate* = **task-owner** *candidate*.

#### Chapter 11

##### Action

> `Cancel active task` is ordinary unit failure with a cancellation error. The unit becomes terminal only after the task's own descendants are quiescent and every unit nested in its attached unit has failed, which no nested boundary reifies.

**`Units`**, **`Concurrency`**, **`Mailboxes`** ↝ Cancel active task *task*: `Task`, *error*: `Value`, **task-created?** *task*, **unit-active?** (**task-unit** *task*), **cancelled-error?** *error*, (∀ *child*: `Task`, **task-created?** *child*, ¬**root-owned?** *child*, **task-owner** *child* = *task* · **unit-succeeded?** (**task-unit** *child*) ∨ **unit-failed?** (**task-unit** *child*)), (∀ *nested*: `Unit`, **unit-nested?** *nested*, **unit-parent** *nested* = **task-unit** *task* · ¬**unit-active?** *nested*).

---

¬**unit-active?**′ (**task-unit** *task*).

¬**unit-succeeded?**′ (**task-unit** *task*).

**unit-failed?**′ (**task-unit** *task*).

**unit-error**′ (**task-unit** *task*) = *error*.

**failed-result-value?** (**task-result** *task*).

**failed-result-error** (**task-result** *task*) = *error*.

∀ *other*: `Unit`, *other* ≠ **task-unit** *task* · **unit-active?**′ *other* = **unit-active?** *other* ∧ **unit-succeeded?**′ *other* = **unit-succeeded?** *other* ∧ **unit-failed?**′ *other* = **unit-failed?** *other* ∧ **unit-stack**′ *other* = **unit-stack** *other* ∧ **unit-error**′ *other* = **unit-error** *other*.

∀ *candidate*: `Task` · **task-created?**′ *candidate* = **task-created?** *candidate* ∧ **task-unit**′ *candidate* = **task-unit** *candidate* ∧ **root-owned?**′ *candidate* = **root-owned?** *candidate*.

∀ *candidate*: `Task` · **task-owner**′ *candidate* = **task-owner** *candidate*.

> Becoming terminal closes the mailbox: every message still queued for this task is discarded, and nothing else about messages changes.

∀ *message*: `Message`, **message-created?** *message*, **message-target** *message* = *task*, ¬**received?** *message* · **discarded?**′ *message*.

∀ *message*: `Message`, ¬(**message-created?** *message* ∧ **message-target** *message* = *task* ∧ ¬**received?** *message*) · **discarded?**′ *message* = **discarded?** *message*.

∀ *message*: `Message` · **message-created?**′ *message* = **message-created?** *message* ∧ **message-target**′ *message* = **message-target** *message* ∧ **received?**′ *message* = **received?** *message*.

#### Chapter 12

##### Action

> Cancelling a terminal task is a no-op. Its cached result remains unchanged.

**`Units`**, **`Concurrency`** ↝ Cancel terminal task *task*: `Task`, **task-created?** *task*, (**unit-succeeded?** (**task-unit** *task*) ∨ **unit-failed?** (**task-unit** *task*)).

---

∀ *candidate*: `Unit` · **unit-active?**′ *candidate* = **unit-active?** *candidate* ∧ **unit-succeeded?**′ *candidate* = **unit-succeeded?** *candidate* ∧ **unit-failed?**′ *candidate* = **unit-failed?** *candidate* ∧ **unit-stack**′ *candidate* = **unit-stack** *candidate* ∧ **unit-error**′ *candidate* = **unit-error** *candidate*.

∀ *candidate*: `Task` · **task-created?**′ *candidate* = **task-created?** *candidate* ∧ **task-unit**′ *candidate* = **task-unit** *candidate* ∧ **root-owned?**′ *candidate* = **root-owned?** *candidate*.

∀ *candidate*: `Task` · **task-owner**′ *candidate* = **task-owner** *candidate*.



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
