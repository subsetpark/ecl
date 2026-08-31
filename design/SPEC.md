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
  one there is an error whose message identifies `partial` as construction of
  a reusable capturing quotation. The sugar does not involve `set`; locals and
  environment assignment are unrelated mechanisms.

## Values and external representations

#### Chapter 1

##### Domains

> This model is normative for the closed value-kind universe; immutable scalar and aggregate content; whole-value matching; dictionary key uniqueness; recursive readability; and hash congruence. It abstracts over concrete storage, float encoding, source grammar, printing, pervasion, and the operations that construct or consume values.  Every ECL value has exactly one of the language's nine kinds. Its kind is an immutable fact: it does not belong to an action context. Boolean, string, quotation, vector, matrix, array, error, and result are roles played by these values rather than additional kinds.

`Value`.

`ValueType`.

##### Rules

**value-type** *value*: `Value` ⇒ `ValueType`.

**int-type** ⇒ `ValueType`.

**float-type** ⇒ `ValueType`.

**char-type** ⇒ `ValueType`.

**symbol-type** ⇒ `ValueType`.

**word-type** ⇒ `ValueType`.

**list-type** ⇒ `ValueType`.

**dict-type** ⇒ `ValueType`.

**task-type** ⇒ `ValueType`.

**module-type** ⇒ `ValueType`.

---

> The value-kind universe is closed: every value has one of these nine kinds.

∀ *value*: `Value` · **value-type** *value* = **int-type** ∨ **value-type** *value* = **float-type** ∨ **value-type** *value* = **char-type** ∨ **value-type** *value* = **symbol-type** ∨ **value-type** *value* = **word-type** ∨ **value-type** *value* = **list-type** ∨ **value-type** *value* = **dict-type** ∨ **value-type** *value* = **task-type** ∨ **value-type** *value* = **module-type**.

> The nine kind names are distinct, so the total `value-type` rule assigns exactly one kind to every value.

**int-type** ≠ **float-type** ∧ **int-type** ≠ **char-type** ∧ **int-type** ≠ **symbol-type** ∧ **int-type** ≠ **word-type** ∧ **int-type** ≠ **list-type** ∧ **int-type** ≠ **dict-type** ∧ **int-type** ≠ **task-type** ∧ **int-type** ≠ **module-type** ∧ **float-type** ≠ **char-type** ∧ **float-type** ≠ **symbol-type** ∧ **float-type** ≠ **word-type** ∧ **float-type** ≠ **list-type** ∧ **float-type** ≠ **dict-type** ∧ **float-type** ≠ **task-type** ∧ **float-type** ≠ **module-type** ∧ **char-type** ≠ **symbol-type** ∧ **char-type** ≠ **word-type** ∧ **char-type** ≠ **list-type** ∧ **char-type** ≠ **dict-type** ∧ **char-type** ≠ **task-type** ∧ **char-type** ≠ **module-type** ∧ **symbol-type** ≠ **word-type** ∧ **symbol-type** ≠ **list-type** ∧ **symbol-type** ≠ **dict-type** ∧ **symbol-type** ≠ **task-type** ∧ **symbol-type** ≠ **module-type** ∧ **word-type** ≠ **list-type** ∧ **word-type** ≠ **dict-type** ∧ **word-type** ≠ **task-type** ∧ **word-type** ≠ **module-type** ∧ **list-type** ≠ **dict-type** ∧ **list-type** ≠ **task-type** ∧ **list-type** ≠ **module-type** ∧ **dict-type** ≠ **task-type** ∧ **dict-type** ≠ **module-type** ∧ **task-type** ≠ **module-type**.

#### Chapter 2

##### Domains

> Scalar payloads and aggregate contents determine value identity within their respective kinds. Numeric magnitude separately determines mathematical matching across int and float, so distinct float payloads such as positive and negative zero may still match. A list's contents are finite and ordered. A dictionary's entries are finite and insertion-ordered, while its keys are unique under whole-value matching.  `matches?` is the equivalence exposed by `match?` and used for dictionary-key identity. Lists match recursively by position. Dictionaries match by their key-value pairs regardless of insertion order. Task and module values match only themselves. Resolution context, reader lineage, provenance, and storage identity are absent from these rules and therefore cannot affect matching or hashing.

`NumericMagnitude`.

`FloatPayload`.

##### Rules

**int-payload** *value*: `Value`, **value-type** *value* = **int-type** ⇒ `Int`.

**float-payload** *value*: `Value`, **value-type** *value* = **float-type** ⇒ `FloatPayload`.

**char-codepoint** *value*: `Value`, **value-type** *value* = **char-type** ⇒ `Nat0`.

**symbol-spelling** *value*: `Value`, **value-type** *value* = **symbol-type** ⇒ `String`.

**word-spelling** *value*: `Value`, **value-type** *value* = **word-type** ⇒ `String`.

**list-length** *value*: `Value`, **value-type** *value* = **list-type** ⇒ `Nat0`.

**list-element** *value*: `Value`, *index*: `Nat`, **value-type** *value* = **list-type**, *index* ≤ **list-length** *value* ⇒ `Value`.

**dict-length** *value*: `Value`, **value-type** *value* = **dict-type** ⇒ `Nat0`.

**dict-key-at-index** *value*: `Value`, *index*: `Nat`, **value-type** *value* = **dict-type**, *index* ≤ **dict-length** *value* ⇒ `Value`.

**dict-value-at-index** *value*: `Value`, *index*: `Nat`, **value-type** *value* = **dict-type**, *index* ≤ **dict-length** *value* ⇒ `Value`.

**dict-has-key?** *dictionary*: `Value`, *key*: `Value`, **value-type** *dictionary* = **dict-type** ⇒ `Bool`.

**dict-value-for-key** *dictionary*: `Value`, *key*: `Value`, **value-type** *dictionary* = **dict-type**, **dict-has-key?** *dictionary* *key* ⇒ `Value`.

**numeric-value?** *value*: `Value` ⇒ `Bool`.

**numeric-magnitude** *value*: `Value`, **numeric-value?** *value* ⇒ `NumericMagnitude`.

**boolean-value?** *value*: `Value` ⇒ `Bool`.

**string-value?** *value*: `Value` ⇒ `Bool`.

**matches?** *left*: `Value`, *right*: `Value` ⇒ `Bool`.

**readable?** *value*: `Value` ⇒ `Bool`.

**value-hash** *value*: `Value` ⇒ `Int`.

---

> Numbers are exactly the int and float values.

∀ *value*: `Value` · **numeric-value?** *value* ↔ **value-type** *value* = **int-type** ∨ **value-type** *value* = **float-type**.

> An int's payload is a signed 64-bit integer.

∀ *value*: `Value`, **value-type** *value* = **int-type** · **int-payload** *value* ≥ 0 - 2147483648 · 4294967296 ∧ **int-payload** *value* ≤ 2147483648 · 4294967296 - 1.

> A char's payload is one Unicode scalar value.

∀ *value*: `Value`, **value-type** *value* = **char-type** · **char-codepoint** *value* ≤ 1114111 ∧ ¬(**char-codepoint** *value* ≥ 55296 ∧ **char-codepoint** *value* ≤ 57343).

> Scalar payloads determine value identity within each scalar kind.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **int-type**, **value-type** *right* = **int-type**, **int-payload** *left* = **int-payload** *right* · *left* = *right*.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **float-type**, **value-type** *right* = **float-type**, **float-payload** *left* = **float-payload** *right* · *left* = *right*.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **char-type**, **value-type** *right* = **char-type**, **char-codepoint** *left* = **char-codepoint** *right* · *left* = *right*.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **symbol-type**, **value-type** *right* = **symbol-type**, **symbol-spelling** *left* = **symbol-spelling** *right* · *left* = *right*.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **word-type**, **value-type** *right* = **word-type**, **word-spelling** *left* = **word-spelling** *right* · *left* = *right*.

> A list is a finite ordered sequence. Its length and positional elements determine its value identity.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **list-type**, **value-type** *right* = **list-type**, **list-length** *left* = **list-length** *right*, (∀ *index*: `Nat`, *index* ≤ **list-length** *left* · **list-element** *left* *index* = **list-element** *right* *index*) · *left* = *right*.

> A dictionary is insertion ordered. Its length and positional key-value entries determine its value identity, including insertion order.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **dict-type**, **value-type** *right* = **dict-type**, **dict-length** *left* = **dict-length** *right*, (∀ *index*: `Nat`, *index* ≤ **dict-length** *left* · **dict-key-at-index** *left* *index* = **dict-key-at-index** *right* *index* ∧ **dict-value-at-index** *left* *index* = **dict-value-at-index** *right* *index*) · *left* = *right*.

> Booleans are exactly the int values 0 and 1.

∀ *value*: `Value` · **boolean-value?** *value* ↔ **value-type** *value* = **int-type** ∧ (**int-payload** *value* = 0 ∨ **int-payload** *value* = 1).

> A string is exactly a list whose elements are all chars. The empty list is therefore both a string and any other role compatible with empty list data.

∀ *value*: `Value` · **string-value?** *value* ↔ **value-type** *value* = **list-type** ∧ (∀ *index*: `Nat`, *index* ≤ **list-length** *value* · **value-type** (**list-element** *value* *index*) = **char-type**).

> Whole-value matching is reflexive.

∀ *value*: `Value` · **matches?** *value* *value*.

> Whole-value matching is symmetric.

∀ *left*: `Value`, *right*: `Value`, **matches?** *left* *right* · **matches?** *right* *left*.

> Whole-value matching is transitive.

∀ *first*: `Value`, *second*: `Value`, *third*: `Value`, **matches?** *first* *second*, **matches?** *second* *third* · **matches?** *first* *third*.

> Values match only as numbers across the two numeric kinds, or within the same non-numeric kind.

∀ *left*: `Value`, *right*: `Value`, **matches?** *left* *right* · **numeric-value?** *left* ∧ **numeric-value?** *right* ∨ **value-type** *left* = **char-type** ∧ **value-type** *right* = **char-type** ∨ **value-type** *left* = **symbol-type** ∧ **value-type** *right* = **symbol-type** ∨ **value-type** *left* = **word-type** ∧ **value-type** *right* = **word-type** ∨ **value-type** *left* = **list-type** ∧ **value-type** *right* = **list-type** ∨ **value-type** *left* = **dict-type** ∧ **value-type** *right* = **dict-type** ∨ **value-type** *left* = **task-type** ∧ **value-type** *right* = **task-type** ∨ **value-type** *left* = **module-type** ∧ **value-type** *right* = **module-type**.

> Numeric matching is exact mathematical-value equality across int and float.

∀ *left*: `Value`, *right*: `Value`, **numeric-value?** *left*, **numeric-value?** *right* · **matches?** *left* *right* ↔ **numeric-magnitude** *left* = **numeric-magnitude** *right*.

> Equal int magnitudes are exactly equal int payloads.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **int-type**, **value-type** *right* = **int-type** · **numeric-magnitude** *left* = **numeric-magnitude** *right* ↔ **int-payload** *left* = **int-payload** *right*.

> Chars, symbols, and words match exactly when their scalar contents match.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **char-type**, **value-type** *right* = **char-type** · **matches?** *left* *right* ↔ **char-codepoint** *left* = **char-codepoint** *right*.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **symbol-type**, **value-type** *right* = **symbol-type** · **matches?** *left* *right* ↔ **symbol-spelling** *left* = **symbol-spelling** *right*.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **word-type**, **value-type** *right* = **word-type** · **matches?** *left* *right* ↔ **word-spelling** *left* = **word-spelling** *right*.

> Lists match recursively and positionally.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **list-type**, **value-type** *right* = **list-type** · **matches?** *left* *right* ↔ **list-length** *left* = **list-length** *right* ∧ (∀ *index*: `Nat`, *index* ≤ **list-length** *left* · **matches?** (**list-element** *left* *index*) (**list-element** *right* *index*)).

> Dictionary keys are unique under whole-value matching.

∀ *dictionary*: `Value`, *left-index*: `Nat`, *right-index*: `Nat`, **value-type** *dictionary* = **dict-type**, *left-index* ≤ **dict-length** *dictionary*, *right-index* ≤ **dict-length** *dictionary*, **matches?** (**dict-key-at-index** *dictionary* *left-index*) (**dict-key-at-index** *dictionary* *right-index*) · *left-index* = *right-index*.

> A dictionary has a key exactly when one insertion position carries a matching key.

∀ *dictionary*: `Value`, *key*: `Value`, **value-type** *dictionary* = **dict-type** · **dict-has-key?** *dictionary* *key* ↔ (∃ *index*: `Nat`, *index* ≤ **dict-length** *dictionary* · **matches?** *key* (**dict-key-at-index** *dictionary* *index*)).

> Lookup by a present key returns the value at its unique matching position.

∀ *dictionary*: `Value`, *key*: `Value`, *index*: `Nat`, **value-type** *dictionary* = **dict-type**, **dict-has-key?** *dictionary* *key*, *index* ≤ **dict-length** *dictionary*, **matches?** *key* (**dict-key-at-index** *dictionary* *index*) · **dict-value-for-key** *dictionary* *key* = **dict-value-at-index** *dictionary* *index*.

> Dictionaries match recursively by key-value pairs, irrespective of insertion order.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **dict-type**, **value-type** *right* = **dict-type** · **matches?** *left* *right* ↔ **dict-length** *left* = **dict-length** *right* ∧ (∀ *left-index*: `Nat`, *left-index* ≤ **dict-length** *left* · ∃ *right-index*: `Nat`, *right-index* ≤ **dict-length** *right* · **matches?** (**dict-key-at-index** *left* *left-index*) (**dict-key-at-index** *right* *right-index*) ∧ **matches?** (**dict-value-at-index** *left* *left-index*) (**dict-value-at-index** *right* *right-index*)).

> Task values match only by capability identity.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **task-type**, **value-type** *right* = **task-type** · **matches?** *left* *right* ↔ *left* = *right*.

> Module values match only by image identity.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **module-type**, **value-type** *right* = **module-type** · **matches?** *left* *right* ↔ *left* = *right*.

> Scalar source kinds have readable representations.

∀ *value*: `Value`, (**value-type** *value* = **int-type** ∨ **value-type** *value* = **float-type** ∨ **value-type** *value* = **char-type** ∨ **value-type** *value* = **symbol-type** ∨ **value-type** *value* = **word-type**) · **readable?** *value*.

> Task and module values have diagnostic displays but no readable representations.

∀ *value*: `Value`, (**value-type** *value* = **task-type** ∨ **value-type** *value* = **module-type**) · ¬**readable?** *value*.

> A list is readable exactly when all its elements are readable.

∀ *value*: `Value`, **value-type** *value* = **list-type** · **readable?** *value* ↔ (∀ *index*: `Nat`, *index* ≤ **list-length** *value* · **readable?** (**list-element** *value* *index*)).

> A dictionary is readable exactly when all its keys and values are readable.

∀ *value*: `Value`, **value-type** *value* = **dict-type** · **readable?** *value* ↔ (∀ *index*: `Nat`, *index* ≤ **dict-length** *value* · **readable?** (**dict-key-at-index** *value* *index*) ∧ **readable?** (**dict-value-at-index** *value* *index*)).

> Hashing is congruent with whole-value matching.

∀ *left*: `Value`, *right*: `Value`, **matches?** *left*
*right* · **value-hash** *left* = **value-hash** *right*.



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
A module is an opaque immutable image and prints as `<module>`. Those task and
module displays are rejected by the reader.

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

**Imports:** ECL_VALUES

#### Chapter 1

##### Rules

> This model is normative for canonical rendering, its read-back guarantee, and display elision. It abstracts over concrete atom spellings, escapes, delimiters, whitespace, indentation, stack layout, terminal width, and the reader's treatment of source containing more or less than one value. The surrounding language specification governs those subjects.  `canonical-render` is the string produced by `str` for one value. Canonical output is always a compact single line and never contains a display-elision marker. For every recursively readable value, that string is readable as one value and the result matches the original value. Task and module values, and aggregates containing them, retain diagnostic canonical displays without a read-back guarantee.

**canonical-render** *value*: `Value` ⇒ `String`.

**source-readable-as-one?** *source*: `String` ⇒ `Bool`.

**read-one** *source*: `String`, **source-readable-as-one?** *source* ⇒ `Value`.

**single-line?** *text*: `String` ⇒ `Bool`.

**contains-elision-marker?** *text*: `String` ⇒ `Bool`.

---

> Every canonical rendering is single-line and free of display elision.

∀ *value*: `Value` · **single-line?** (**canonical-render** *value*) ∧ ¬**contains-elision-marker?** (**canonical-render** *value*).

> Canonical rendering of every readable value is readable as one value.

∀ *value*: `Value`, **readable?** *value* · **source-readable-as-one?** (**canonical-render** *value*).

> Reading a readable value's canonical rendering produces a structurally matching value.

∀ *value*: `Value`, **readable?** *value*, **source-readable-as-one?** (**canonical-render** *value*) · **matches?** (**read-one** (**canonical-render** *value*)) *value*.

> Dictionary rendering preserves insertion order across canonical read-back: each read entry matches the original key and value at the same position.

∀ *value*: `Value`, **value-type** *value* = **dict-type**, **readable?** *value*, **source-readable-as-one?** (**canonical-render** *value*) · **value-type** (**read-one** (**canonical-render** *value*)) = **dict-type** ∧ **dict-length** (**read-one** (**canonical-render** *value*)) = **dict-length** *value*.

∀ *value*: `Value`, *index*: `Nat`, **value-type** *value* = **dict-type**, **readable?** *value*, **source-readable-as-one?** (**canonical-render** *value*), **value-type** (**read-one** (**canonical-render** *value*)) = **dict-type**, *index* ≤ **dict-length** *value* · **matches?** (**dict-key-at-index** (**read-one** (**canonical-render** *value*)) *index*) (**dict-key-at-index** *value* *index*) ∧ **matches?** (**dict-value-at-index** (**read-one** (**canonical-render** *value*)) *index*) (**dict-value-at-index** *value* *index*).

#### Chapter 2

##### Rules

> `display-render` is the best-effort text used for a single value by `io.pp` and by stack displays. A list longer than 256 elements is replaced as a whole by a count-bearing marker before its children are rendered. The same rule applies recursively inside lists and dictionaries. Canonical rendering remains unaffected.

**display-render** *value*: `Value` ⇒ `String`.

**display-contains-elision?** *value*: `Value` ⇒ `Bool`.

---

> Scalar and capability values contain no nested display elision.

∀ *value*: `Value`, (**value-type** *value* = **int-type** ∨ **value-type** *value* = **float-type** ∨ **value-type** *value* = **char-type** ∨ **value-type** *value* = **symbol-type** ∨ **value-type** *value* = **word-type** ∨ **value-type** *value* = **task-type** ∨ **value-type** *value* = **module-type**) · ¬**display-contains-elision?** *value*.

> A displayed list contains elision exactly when it exceeds 256 elements, or when an unelided child recursively contains elision.

∀ *value*: `Value`, **value-type** *value* = **list-type** · **display-contains-elision?** *value* ↔ **list-length** *value* > 256 ∨ **list-length** *value* ≤ 256 ∧ (∃ *index*: `Nat`, *index* ≤ **list-length** *value* · **display-contains-elision?** (**list-element** *value* *index*)).

> A displayed dictionary contains elision exactly when one of its rendered keys or values recursively contains elision.

∀ *value*: `Value`, **value-type** *value* = **dict-type** · **display-contains-elision?** *value* ↔ (∃ *index*: `Nat`, *index* ≤ **dict-length** *value* · **display-contains-elision?** (**dict-key-at-index** *value* *index*) ∨ **display-contains-elision?** (**dict-value-at-index** *value*
*index*)).

> Display text contains an elision marker exactly when recursive value rendering elides some list.

∀ *value*: `Value` · **contains-elision-marker?** (**display-render** *value*) ↔ **display-contains-elision?** *value*.



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

Tail calls are guaranteed: through word calls, `if`, and every
combinator's tail position, iteration and tail recursion run in constant
space and never exhaust a host call stack.

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

∀ *value*: `Value` · **symbol-list-value?** *value* ↔ **value-type** *value* = **list-type** ∧ (∀ *index*: `Nat`, *index* ≤ **list-length** *value* · **value-type** (**list-element** *value* *index*) = **symbol-type**).

> Non-dictionaries cannot satisfy any error-schema field predicate.

∀ *value*: `Value`, **value-type** *value* ≠ **dict-type** · ¬**kind-field-valid?** *value* ∧ ¬**message-field-valid?** *value* ∧ ¬**word-field-valid?** *value* ∧ ¬**trace-field-valid?** *value* ∧ ¬**data-field-valid?** *value*.

> The `'kind` field is required and its value is a symbol.

∀ *value*: `Value`, **value-type** *value* = **dict-type**, ¬**dict-has-key?** *value* **kind-field** · ¬**kind-field-valid?** *value*.

∀ *value*: `Value`, **value-type** *value* = **dict-type**, **dict-has-key?** *value* **kind-field** · **kind-field-valid?** *value* ↔ **value-type** (**dict-value-for-key** *value* **kind-field**) = **symbol-type**.

> The `'msg` field is optional and, when present, is a string.

∀ *value*: `Value`, **value-type** *value* = **dict-type**, ¬**dict-has-key?** *value* **message-field** · **message-field-valid?** *value*.

∀ *value*: `Value`, **value-type** *value* = **dict-type**, **dict-has-key?** *value* **message-field** · **message-field-valid?** *value* ↔ **string-value?** (**dict-value-for-key** *value* **message-field**).

> The `'word` field is optional and, when present, is a symbol.

∀ *value*: `Value`, **value-type** *value* = **dict-type**, ¬**dict-has-key?** *value* **word-field** · **word-field-valid?** *value*.

∀ *value*: `Value`, **value-type** *value* = **dict-type**, **dict-has-key?** *value* **word-field** · **word-field-valid?** *value* ↔ **value-type** (**dict-value-for-key** *value* **word-field**) = **symbol-type**.

> The `'trace` field is optional and, when present, is a list of symbols.

∀ *value*: `Value`, **value-type** *value* = **dict-type**, ¬**dict-has-key?** *value* **trace-field** · **trace-field-valid?** *value*.

∀ *value*: `Value`, **value-type** *value* = **dict-type**, **dict-has-key?** *value* **trace-field** · **trace-field-valid?** *value* ↔ **symbol-list-value?** (**dict-value-for-key** *value* **trace-field**).

> The `'data` field is optional and, when present, is a dictionary.

∀ *value*: `Value`, **value-type** *value* = **dict-type**, ¬**dict-has-key?** *value* **data-field** · **data-field-valid?** *value*.

∀ *value*: `Value`, **value-type** *value* = **dict-type**, **dict-has-key?** *value* **data-field** · **data-field-valid?** *value* ↔ **value-type** (**dict-value-for-key** *value* **data-field**) = **dict-type**.

> A value is an error exactly when it is a dictionary satisfying every field rule above. Fields outside this schema do not affect validity.

∀ *value*: `Value` · **error-value?** *value* ↔ **value-type** *value* = **dict-type** ∧ **kind-field-valid?** *value* ∧ **message-field-valid?** *value* ∧ **word-field-valid?** *value* ∧ **trace-field-valid?** *value* ∧ **data-field-valid?** *value*.

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

∀ *value*: `Value` · **core-error-kind?** *value* ↔ *value* = **underflow-error-kind** ∨ *value* = **undefined-word-error-kind** ∨ *value* = **type-error-kind** ∨ *value* = **shape-error-kind** ∨ *value* = **conform-error-kind** ∨ *value* = **overflow-error-kind** ∨ *value* = **domain-error-kind** ∨ *value* = **contract-error-kind** ∨ *value* = **parse-error-kind** ∨ *value* = **io-error-kind** ∨ *value* = **cancelled-error-kind** ∨ *value* = **timeout-error-kind** ∨ *value* = **user-error-kind**.

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

∀ *value*: `Value` · **successful-result-value?** *value* ↔ **value-type** *value* = **dict-type** ∧ **dict-length** *value* = 1 ∧ **dict-has-key?** *value* **ok-field** ∧ **value-type** (**dict-value-for-key** *value* **ok-field**) = **list-type**.

> A failed result is exactly a one-entry dictionary tagged `'err` whose payload satisfies the error schema.

∀ *value*: `Value` · **failed-result-value?** *value* ↔ **value-type** *value* = **dict-type** ∧ **dict-length** *value* = 1 ∧ **dict-has-key?** *value* **err-field** ∧ **error-value?** (**dict-value-for-key** *value* **err-field**).

> The payload accessors expose the successful values list or failed error after the corresponding result form has been established.

∀ *value*: `Value`, **successful-result-value?** *value* · **successful-result-values** *value* = **dict-value-for-key** *value* **ok-field**.

∀ *value*: `Value`, **failed-result-value?** *value* · **failed-result-error** *value* = **dict-value-for-key** *value* **err-field**.

> Results are exactly the successful and failed forms.

∀ *value*: `Value` · **result-value?** *value* ↔ **successful-result-value?** *value* ∨ **failed-result-value?** *value*.

> The two result forms are disjoint.

∀ *value*: `Value`, **successful-result-value?** *value* · ¬**failed-result-value?** *value*.

#### Chapter 4

##### Rules

> Cancellation and timeout errors are classified by their required `'kind` field. They retain the ordinary error schema, including any optional or kind-specific diagnostic fields. Their result forms are ordinary failed result envelopes. A timeout result is an observation only; it is not the target task's terminal result.

**cancelled-error?** *value*: `Value` ⇒ `Bool`.

**timeout-error?** *value*: `Value` ⇒ `Bool`.

**cancelled-result?** *value*: `Value` ⇒ `Bool`.

**timeout-result?** *value*: `Value` ⇒ `Bool`.

---

> Cancellation and timeout errors have the corresponding core kind.

∀ *value*: `Value` · **cancelled-error?** *value* ↔ **error-value?** *value* ∧ **dict-value-for-key** *value* **kind-field** = **cancelled-error-kind**.

∀ *value*: `Value` · **timeout-error?** *value* ↔ **error-value?** *value* ∧ **dict-value-for-key** *value*
**kind-field** = **timeout-error-kind**.

> Cancellation and timeout results contain errors of the corresponding kind.

∀ *value*: `Value` · **cancelled-result?** *value* ↔ **failed-result-value?** *value* ∧ **cancelled-error?** (**failed-result-error** *value*).

∀ *value*: `Value` · **timeout-result?** *value* ↔ **failed-result-value?** *value* ∧ **timeout-error?** (**failed-result-error** *value*).



### Units and the transactional stack

Ordinary evaluation may consume operands and perform effects before it fails;
its failure outcome therefore includes the partial operand stack and the
surviving execution state at the point of failure.

**Imports:** ECL_ERRORS

##### Contexts

**`Units`**

#### Chapter 1

##### Action

> This model is normative for the lifecycle of a general ECL unit; its ordered entry and body values; successful completion with an ordered result stack; and failure with an error and restoration of the entry stack.  It deliberately abstracts over evaluation steps, name resolution, concrete values and error dictionaries, environment writes, I/O, randomness, and all other non-stack effects. The surrounding language specification governs those subjects and requires that unit failure does not roll back effects already performed. The model also omits launch and observation policy, task identity, task trees, scheduling, awaiting, deadlines, cancellation causes, and reclamation. In particular, cancellation reaches this model only as an evaluator-supplied failure error, while a waiting operation's timeout does not alter the target unit.  `@attempt` begins a unit, waits synchronously for one terminal transition, and reifies that outcome. `@spawn` begins the same kind of unit and returns a task capability immediately; `await` later reifies the attached unit's terminal outcome through the same mapping. Thus `@attempt` is observationally equivalent to `@spawn await`, while task lifetime and waiting behavior remain outside this model.  `Begin unit` receives the complete entry-stack list and exact quotation body as separate ECL list values. It selects one never-before-created unit identity, records those inputs unchanged, and makes that unit active. Reader-delimited units, `load`, and isolated unit constructors differ in how they supply these inputs and expose the eventual outcome; those policies do not change unit execution semantics.

**`Units`** ↝ Begin unit *entry*: `Value`, *body*: `Value`, **value-type** *entry* = **list-type**, **value-type** *body* = **list-type**.

---

> Beginning a unit selects one never-before-created identity, records its exact entry stack and body, and makes it active with the entry stack installed.

∃ *unit*: `Unit`, ¬**unit-created?** *unit* · **unit-created?**′ *unit* ∧ **unit-active?**′ *unit* ∧ ¬**unit-succeeded?**′ *unit* ∧ ¬**unit-failed?**′ *unit* ∧ **unit-entry**′ *unit* = *entry* ∧ **unit-body**′ *unit* = *body* ∧ **unit-stack**′ *unit* = *entry* ∧ **unit-error**′ *unit* = **unit-error** *unit* ∧ (∀ *other*: `Unit`, *other* ≠ *unit* · **unit-created?**′ *other* = **unit-created?** *other* ∧ **unit-active?**′ *other* = **unit-active?** *other* ∧ **unit-succeeded?**′ *other* = **unit-succeeded?** *other* ∧ **unit-failed?**′ *other* = **unit-failed?** *other* ∧ **unit-entry**′ *other* = **unit-entry** *other* ∧ **unit-body**′ *other* = **unit-body** *other* ∧ **unit-stack**′ *other* = **unit-stack** *other* ∧ **unit-error**′ *other* = **unit-error** *other*).

#### Chapter 2

##### Domains

> A created unit is in exactly one phase: active, successfully completed, or failed. Entry and body remain fixed after creation. `unit-stack` denotes the stack at the modeled boundary: it begins as the entry stack and becomes the evaluator-supplied result on success. Intermediate evaluator stacks are outside the abstraction.

`Unit`.

##### Rules

{**`Units`**} **unit-created?** *unit*: `Unit` ⇒ `Bool`.

{**`Units`**} **unit-active?** *unit*: `Unit` ⇒ `Bool`.

{**`Units`**} **unit-succeeded?** *unit*: `Unit` ⇒ `Bool`.

{**`Units`**} **unit-failed?** *unit*: `Unit` ⇒ `Bool`.

{**`Units`**} **unit-entry** *unit*: `Unit` ⇒ `Value`.

{**`Units`**} **unit-body** *unit*: `Unit` ⇒ `Value`.

{**`Units`**} **unit-stack** *unit*: `Unit` ⇒ `Value`.

{**`Units`**} **unit-error** *unit*: `Unit` ⇒ `Value`.

---

> An active unit is created and is neither successful nor failed.

∀ *candidate*: `Unit`, **unit-active?** *candidate* · **unit-created?** *candidate* ∧ ¬**unit-succeeded?** *candidate* ∧ ¬**unit-failed?** *candidate*.

> A successfully completed unit is created and is no longer active or failed.

∀ *candidate*: `Unit`, **unit-succeeded?** *candidate* · **unit-created?** *candidate* ∧ ¬**unit-active?** *candidate* ∧ ¬**unit-failed?** *candidate*.

> A failed unit is created and terminal, carries an error value, and exposes its restored entry stack rather than the evaluator's partial stack.

∀ *candidate*: `Unit`, **unit-failed?** *candidate* · **unit-created?** *candidate* ∧ ¬**unit-active?** *candidate* ∧ ¬**unit-succeeded?** *candidate* ∧ **unit-stack** *candidate* = **unit-entry** *candidate* ∧ **error-value?** (**unit-error** *candidate*).

> Every created unit is in exactly one of the three lifecycle phases.

∀ *candidate*: `Unit`, **unit-created?** *candidate* · **unit-active?** *candidate* ∨ **unit-succeeded?** *candidate* ∨ **unit-failed?** *candidate*.

> Every created unit retains list values for its entry stack, quotation body, and exposed stack.

∀ *candidate*: `Unit`, **unit-created?** *candidate* · **value-type** (**unit-entry** *candidate*) = **list-type** ∧ **value-type** (**unit-body** *candidate*) = **list-type** ∧ **value-type** (**unit-stack** *candidate*) = **list-type**.

> Initially no unit identity has been created or entered a lifecycle phase.

initially ∀ *candidate*: `Unit` · ¬**unit-created?** *candidate* ∧ ¬**unit-active?** *candidate* ∧ ¬**unit-succeeded?** *candidate* ∧ ¬**unit-failed?** *candidate*.

#### Chapter 3

##### Action

> `Complete unit successfully` accepts the result produced by the omitted evaluator, makes the active unit terminal, and retains that result as the unit's terminal stack. The evaluator supplies the result; it is not chosen by the ECL operation that launched the unit.

**`Units`** ↝ Complete unit successfully *unit*: `Unit`, *result*: `Value`, **unit-created?** *unit*, **unit-active?** *unit*, **value-type** *result* = **list-type**.

---

> Successful completion makes the unit terminal and exposes the evaluator's complete result stack without changing its entry stack or body.

**unit-created?**′ *unit*.

¬**unit-active?**′ *unit*.

**unit-succeeded?**′ *unit*.

¬**unit-failed?**′ *unit*.

**unit-entry**′ *unit* = **unit-entry** *unit*.

**unit-body**′ *unit* = **unit-body** *unit*.

**unit-stack**′ *unit* = *result*.

**unit-error**′ *unit* = **unit-error** *unit*.

∀ *other*: `Unit`, *other* ≠ *unit* · **unit-created?**′ *other* = **unit-created?** *other* ∧ **unit-active?**′ *other* = **unit-active?** *other* ∧ **unit-succeeded?**′ *other* = **unit-succeeded?** *other* ∧ **unit-failed?**′ *other* = **unit-failed?** *other* ∧ **unit-entry**′ *other* = **unit-entry** *other* ∧ **unit-body**′ *other* = **unit-body** *other* ∧ **unit-stack**′ *other* = **unit-stack** *other* ∧ **unit-error**′ *other* = **unit-error** *other*.

#### Chapter 4

##### Action

> `Complete unit with failure` accepts the error produced by the evaluator or by a facility such as concurrency cancellation. Errors are ordinary ECL values satisfying the imported `error-value?` schema. Completion makes the active unit terminal, records the error value, and restores the complete entry stack. The evaluator's partial stack is neither retained nor exposed. Every error kind follows this same unit transition; causes and concrete error data are outside the model.

**`Units`** ↝ Complete unit with failure *unit*: `Unit`, *error*: `Value`, **unit-created?** *unit*, **unit-active?** *unit*, **error-value?** *error*.

---

> Failure makes the unit terminal, records the evaluator-supplied error, and restores the complete entry stack. The partial evaluator stack is not retained or exposed.

**unit-created?**′ *unit*.

¬**unit-active?**′ *unit*.

¬**unit-succeeded?**′ *unit*.

**unit-failed?**′ *unit*.

**unit-entry**′ *unit* = **unit-entry** *unit*.

**unit-body**′ *unit* = **unit-body** *unit*.

**unit-stack**′ *unit* = **unit-entry** *unit*.

**unit-error**′ *unit* = *error*.

∀ *other*: `Unit`, *other* ≠ *unit* · **unit-created?**′ *other* = **unit-created?** *other* ∧ **unit-active?**′ *other* = **unit-active?** *other* ∧ **unit-succeeded?**′ *other* = **unit-succeeded?** *other* ∧ **unit-failed?**′ *other* = **unit-failed?** *other* ∧ **unit-entry**′ *other* = **unit-entry** *other* ∧ **unit-body**′ *other* = **unit-body** *other* ∧ **unit-stack**′ *other* = **unit-stack** *other* ∧ **unit-error**′ *other* = **unit-error** *other*.



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

    values (q) @attempt
    values (q) @spawn
    list values (q) @each          ( element deepest in each child )
    values (body) @module
    values (body) 'name @defm

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
`'contract`). An omitted module effect means there is no such check.
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
  module `core.utils`, binding `f`, even when module `core` also exists. Host
  and native factories apply the reader's single scalar-level symbol-segment
  grammar; ASCII or Unicode whitespace, delimiters, malformed UTF-8, and other
  unreadable spellings do not become validated names. Reserved syntax markers
  are interned as syntax only and cannot be minted as binding names through a
  privileged validation mode.

**Imports:** ECL_VALUES

##### Contexts

**`Calls`**, **`Images`**, **`Registry`**, **`Transactions`**, **`WithinCommit`**

#### Chapter 1

##### Domains

`RegistryName`, `BindingName`

##### Action

> This model is normative for module-image availability; registry names, slots, aliases, generations, and publication; abstract definitions and visibility; call contexts and generation pins; the ordered durable, draft, pending-output, and ambient stacks; and atomic completion or abortion of `within` transactions.  It deliberately abstracts over source spelling and name validation, construction-body evaluation, concrete and nested values, error construction and propagation, task and unit ownership, scheduling and fairness, and storage reclamation. The surrounding language specification governs those subjects. Begin and complete actions expose semantic concurrency boundaries; they are not ECL words. Contexts, including `WithinCommit`, grant formal write authority and do not denote runtime values or additional language state. An `InvocationContext` is either the top-level evaluator or identifies the exact active call performing a registry mutation.  A qualified call resolves a registry name and public binding and pins the slot's current generation in one atomic action. Resolution before replacement or removal retains the selected generation; resolution afterward observes only the replacement or the absence of the registration. Explicit qualification always performs this fresh registry dispatch, including when it names the caller's own registration.

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

`WordOccurrence`.

`InvocationContext`.

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

**occurrence-name** *occurrence*: `WordOccurrence` ⇒ `BindingName`.

**occurrence-image** *occurrence*: `WordOccurrence` ⇒ `Image`.

**call-invocation?** *invoker*: `InvocationContext` ⇒ `Bool`.

**invocation-call** *invoker*: `InvocationContext` ⇒ `Call`.

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

∃ *invoker*: `InvocationContext` · ¬**call-invocation?** *invoker*.

initially ∃ *invoker*: `InvocationContext` · ¬**call-invocation?** *invoker*.

#### Chapter 3

##### Action

> `Construct image` allocates a fresh image identity and establishes its first module-value owner. Its immutable definition map and initial stack template already exist as background relations. Construction creates no name, slot, alias, or generation. Failure before this transition changes no modeled state; evaluation of the body and any external effects are outside this abstraction.

**`Images`** ↝ Construct image.

---

∃ *image*: `Image`, ¬**constructed?** *image* · **constructed?**′ *image* ∧ **value-held?**′ *image* ∧ (∀ *other*: `Image`, *other* ≠ *image* · **constructed?**′ *other* = **constructed?** *other* ∧ **value-held?**′ *other* = **value-held?** *other*).

#### Chapter 4

##### Action

> Image availability follows semantic ownership rather than reclamation mechanics. `value-held?` records the Boolean fact that at least one reachable module value owns the image; the model contains no reference count. `Release last value owner` clears that fact only when the final such owner disappears. The action models reachability and is not an ECL operation. Current generations and active calls are the other image owners; scoped words and quotations are not.

**`Images`** ↝ Release last value owner *image*: `Image`, **constructed?** *image*, **value-held?** *image*.

---

¬**value-held?**′ *image* ∧ (∀ *other*: `Image`, *other* ≠ *image* · **value-held?**′ *other* = **value-held?** *other*).

∀ *image*: `Image` · **constructed?**′ *image* = **constructed?** *image*.

#### Chapter 5

##### Action

> `Register` is an ordered upsert. Publishing under a missing canonical name creates a fresh slot initialized from the image's initial template. Publishing under an existing canonical name preserves that slot and its complete durable stack. Every successful registration publishes a fresh generation and retires the previous current generation, even when both generations contain the same image. It cannot interleave with an active transaction on the selected slot or be performed by a call that owns an active transaction. The supplied invocation context is the top-level evaluator or the exact call performing the mutation.

**`Registry`** ↝ Register *invoker*: `InvocationContext`, *image*: `Image`, *module-name*: `RegistryName`, **constructed?** *image*, **value-held?** *image*, ¬**alias?** *module-name*.

---

(¬**call-invocation?** *invoker* ∨ **call-active?** (**invocation-call** *invoker*) ∧ #(each *transaction*: `Transaction`, **transaction-active?** *transaction* ∧ **transaction-call** *transaction* = **invocation-call** *invoker* · *transaction*) = 0) ∧ (∃ *slot*: `Slot`, *generation*: `Generation`, (**canonical?** *module-name* ∧ *slot* = **slot-of** *module-name* ∨ ¬**canonical?** *module-name* ∧ ¬**slot-created?** *slot*), #(each *transaction*: `Transaction`, **transaction-active?** *transaction* ∧ **transaction-slot** *transaction* = *slot* · *transaction*) = 0, ¬**generation-published?** *generation* · **canonical?**′ *module-name* ∧ ¬**alias?**′ *module-name* ∧ **slot-of**′ *module-name* = *slot* ∧ (∀ *other-name*: `RegistryName`, *other-name* ≠ *module-name* · **canonical?**′ *other-name* = **canonical?** *other-name* ∧ **alias?**′ *other-name* = **alias?** *other-name* ∧ **slot-of**′ *other-name* = **slot-of** *other-name*) ∧ **slot-created?**′ *slot* ∧ **slot-live?**′ *slot* ∧ **current-generation**′ *slot* = *generation* ∧ (∀ *other-slot*: `Slot`, *other-slot* ≠ *slot* · **slot-created?**′ *other-slot* = **slot-created?** *other-slot* ∧ **slot-live?**′ *other-slot* = **slot-live?** *other-slot* ∧ **current-generation**′ *other-slot* = **current-generation** *other-slot*) ∧ **generation-published?**′ *generation* ∧ ¬**generation-retired?**′ *generation* ∧ **generation-slot**′ *generation* = *slot* ∧ **generation-image**′ *generation* = *image* ∧ (∀ *other-generation*: `Generation`, *other-generation* ≠ *generation* · **generation-published?**′ *other-generation* = **generation-published?** *other-generation* ∧ **generation-retired?**′ *other-generation* = (**generation-retired?** *other-generation* ∨ **canonical?** *module-name* ∧ *other-generation* = **current-generation** *slot*) ∧ **generation-slot**′ *other-generation* = **generation-slot** *other-generation* ∧ **generation-image**′ *other-generation* = **generation-image** *other-generation*) ∧ (**canonical?** *module-name* → **durable-depth**′ *slot* = **durable-depth** *slot*) ∧ (¬**canonical?** *module-name* → **durable-depth**′ *slot* = **initial-depth** *image*) ∧ (∀ *position*: `Nat` · (**canonical?** *module-name* → **durable-value**′ *slot* *position* = **durable-value** *slot* *position*) ∧ (¬**canonical?** *module-name* → **durable-value**′ *slot* *position* = **initial-value** *image* *position*)) ∧ (∀ *other-slot*: `Slot`, *other-slot* ≠ *slot* · **durable-depth**′ *other-slot* = **durable-depth** *other-slot* ∧ (∀ *position*: `Nat` · **durable-value**′ *other-slot* *position* = **durable-value** *other-slot* *position*))).

#### Chapter 6

##### Action

> `Add alias` resolves either kind of occupied target name and stores a direct reference to its live slot; semantic alias chains do not exist. The alias shares the slot's current generation, durable stack, serialization, and lifetime. Canonical and alias names form one disjoint namespace, and an occupied name cannot be repointed. Registry mutation is unavailable to a call that owns an active transaction. The supplied invocation context is the top-level evaluator or the exact call performing the mutation.

**`Registry`** ↝ Add alias *invoker*: `InvocationContext`, *alias-name*: `RegistryName`, *target-name*: `RegistryName`, ¬**canonical?** *alias-name*, ¬**alias?** *alias-name*, (**canonical?** *target-name* ∨ **alias?** *target-name*).

---

(¬**call-invocation?** *invoker* ∨ **call-active?** (**invocation-call** *invoker*) ∧ #(each *transaction*: `Transaction`, **transaction-active?** *transaction* ∧ **transaction-call** *transaction* = **invocation-call** *invoker* · *transaction*) = 0) ∧ ¬**canonical?**′ *alias-name* ∧ **alias?**′ *alias-name* ∧ **slot-of**′ *alias-name* = **slot-of** *target-name* ∧ (∀ *other-name*: `RegistryName`, *other-name* ≠ *alias-name* · **canonical?**′ *other-name* = **canonical?** *other-name* ∧ **alias?**′ *other-name* = **alias?** *other-name* ∧ **slot-of**′ *other-name* = **slot-of** *other-name*) ∧ (∀ *slot*: `Slot` · **slot-created?**′ *slot* = **slot-created?** *slot* ∧ **slot-live?**′ *slot* = **slot-live?** *slot* ∧ **current-generation**′ *slot* = **current-generation** *slot* ∧ **durable-depth**′ *slot* = **durable-depth** *slot* ∧ (∀ *position*: `Nat` · **durable-value**′ *slot* *position* = **durable-value** *slot* *position*)) ∧ (∀ *generation*: `Generation` · **generation-published?**′ *generation* = **generation-published?** *generation* ∧ **generation-retired?**′ *generation* = **generation-retired?** *generation* ∧ **generation-slot**′ *generation* = **generation-slot** *generation* ∧ **generation-image**′ *generation* = **generation-image** *generation*).

#### Chapter 7

##### Action

> `Remove` resolves a canonical name or alias to its slot, then atomically closes that slot, removes its canonical name and every alias, retires its current generation, and discards its durable stack. Removal does not end already active calls, whose pins remain valid, but those calls cannot start a new transaction after closure. A later registration of the same spelling must allocate a fresh slot. Removal cannot interleave with a transaction on the slot or be performed by a call that owns an active transaction. The supplied invocation context is the top-level evaluator or the exact call performing the mutation.

**`Registry`** ↝ Remove *invoker*: `InvocationContext`, *module-name*: `RegistryName`, (**canonical?** *module-name* ∨ **alias?** *module-name*).

---

(¬**call-invocation?** *invoker* ∨ **call-active?** (**invocation-call** *invoker*) ∧ #(each *transaction*: `Transaction`, **transaction-active?** *transaction* ∧ **transaction-call** *transaction* = **invocation-call** *invoker* · *transaction*) = 0) ∧ (∃ *slot*: `Slot`, *slot* = **slot-of** *module-name*, #(each *transaction*: `Transaction`, **transaction-active?** *transaction* ∧ **transaction-slot** *transaction* = *slot* · *transaction*) = 0 · (∀ *registry-name*: `RegistryName` · **canonical?**′ *registry-name* = (**canonical?** *registry-name* ∧ **slot-of** *registry-name* ≠ *slot*) ∧ **alias?**′ *registry-name* = (**alias?** *registry-name* ∧ **slot-of** *registry-name* ≠ *slot*) ∧ **slot-of**′ *registry-name* = **slot-of** *registry-name*) ∧ **slot-created?**′ *slot* = **slot-created?** *slot* ∧ ¬**slot-live?**′ *slot* ∧ **current-generation**′ *slot* = **current-generation** *slot* ∧ **durable-depth**′ *slot* = 0 ∧ (∀ *position*: `Nat` · **durable-value**′ *slot* *position* = **durable-value** *slot* *position*) ∧ (∀ *other-slot*: `Slot`, *other-slot* ≠ *slot* · **slot-created?**′ *other-slot* = **slot-created?** *other-slot* ∧ **slot-live?**′ *other-slot* = **slot-live?** *other-slot* ∧ **current-generation**′ *other-slot* = **current-generation** *other-slot* ∧ **durable-depth**′ *other-slot* = **durable-depth** *other-slot* ∧ (∀ *position*: `Nat` · **durable-value**′ *other-slot* *position* = **durable-value** *other-slot* *position*)) ∧ (∀ *generation*: `Generation` · **generation-published?**′ *generation* = **generation-published?** *generation* ∧ **generation-retired?**′ *generation* = (**generation-retired?** *generation* ∨ *generation* = **current-generation** *slot*) ∧ **generation-slot**′ *generation* = **generation-slot** *generation* ∧ **generation-image**′ *generation* = **generation-image** *generation*)).

#### Chapter 8

##### Action

> `Begin image call` invokes a public binding through a module value. The invocation pins the image directly and has no registration, slot, or generation context. The image must still have a module-value owner when the call begins.

**`Calls`** ↝ Begin image call *image*: `Image`, *binding-name*: `BindingName`, **constructed?** *image*, **value-held?** *image*.

---

∃ *callee*: `Call`, *definition*: `Definition`, ¬**call-created?** *callee*, **binding-present?** *image* *binding-name*, *definition* = **definition-at** *image* *binding-name*, **public?** *definition* · **call-created?**′ *callee* ∧ **call-active?**′ *callee* ∧ ¬**registered-call?**′ *callee* ∧ **call-generation**′ *callee* = **call-generation** *callee* ∧ **call-slot**′ *callee* = **call-slot** *callee* ∧ **call-image**′ *callee* = *image* ∧ **call-definition**′ *callee* = *definition* ∧ (∀ *other*: `Call`, *other* ≠ *callee* · **call-created?**′ *other* = **call-created?** *other* ∧ **call-active?**′ *other* = **call-active?** *other* ∧ **registered-call?**′ *other* = **registered-call?** *other* ∧ **call-generation**′ *other* = **call-generation** *other* ∧ **call-slot**′ *other* = **call-slot** *other* ∧ **call-image**′ *other* = **call-image** *other* ∧ **call-definition**′ *other* = **call-definition** *other*) ∧ (∀ *call*: `Call` · **ambient-depth**′ *call* = **ambient-depth** *call* ∧ (∀ *position*: `Nat` · **ambient-value**′ *call* *position* = **ambient-value** *call* *position*)).

#### Chapter 9

##### Action

> `Begin scoped call` resolves the name stored in a word occurrence against the image stored in that occurrence. A quotation or word occurrence owns this scope but does not cache a definition or generation. The image must still be available through a module value, a current generation, or another active call. Same-image dispatch from a registered caller preserves its pinned slot and generation; other scoped dispatch has no registration context. Private definitions are therefore available to same-image scoped resolution without becoming publicly invocable.

**`Calls`** ↝ Begin scoped call *caller*: `Call`, *occurrence*: `WordOccurrence`, *binding-name*: `BindingName`, **call-active?** *caller*, **occurrence-name** *occurrence* = *binding-name*.

---

∃ *image*: `Image`, *definition*: `Definition`, *callee*: `Call`, *image* = **occurrence-image** *occurrence*, **constructed?** *image*, (**value-held?** *image* ∨ #(each *slot*: `Slot`, **slot-live?** *slot* ∧ **generation-image** (**current-generation** *slot*) = *image* · *slot*) > 0 ∨ #(each *owner*: `Call`, **call-active?** *owner* ∧ **call-image** *owner* = *image* · *owner*) > 0), **binding-present?** *image* *binding-name*, *definition* = **definition-at** *image* *binding-name*, ¬**call-created?** *callee* · **call-created?**′ *callee* ∧ **call-active?**′ *callee* ∧ **registered-call?**′ *callee* = (**registered-call?** *caller* ∧ **call-image** *caller* = *image*) ∧ (**registered-call?** *caller* ∧ **call-image** *caller* = *image* → **call-generation**′ *callee* = **call-generation** *caller* ∧ **call-slot**′ *callee* = **call-slot** *caller*) ∧ (¬(**registered-call?** *caller* ∧ **call-image** *caller* = *image*) → **call-generation**′ *callee* = **call-generation** *callee* ∧ **call-slot**′ *callee* = **call-slot** *callee*) ∧ **call-image**′ *callee* = *image* ∧ **call-definition**′ *callee* = *definition* ∧ (∀ *other*: `Call`, *other* ≠ *callee* · **call-created?**′ *other* = **call-created?** *other* ∧ **call-active?**′ *other* = **call-active?** *other* ∧ **registered-call?**′ *other* = **registered-call?** *other* ∧ **call-generation**′ *other* = **call-generation** *other* ∧ **call-slot**′ *other* = **call-slot** *other* ∧ **call-image**′ *other* = **call-image** *other* ∧ **call-definition**′ *other* = **call-definition** *other*) ∧ (∀ *call*: `Call` · **ambient-depth**′ *call* = **ambient-depth** *call* ∧ (∀ *position*: `Nat` · **ambient-value**′ *call* *position* = **ambient-value** *call* *position*)).

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

      1 wrap                                  -- [1], reaching core's `cons`
      (pop pop 42) 'cons def   1 wrap          -- still [1]
      (pop pop 42) 'cons def   1 [] cons       -- 42, the session's own `cons`
      (pop pop 42) 'cons def   (() cons) 'wrap def   1 wrap    -- 42

  A session `def` shadows a name *for session code*. Adopting new behavior
  inside a prelude word is redefining that word: the replacement is a session
  definition, so it resolves in the session and shadows the prelude one for
  session callers. Late binding is unaffected. The lookup still happens at call
  time; what is fixed is which chain it happens in. A quotation literal written
  inside a body is sealed the way the body's own references are: it resolves in
  the scope its text was written in, whoever ends up applying it. `all?` is
  `(|l q| l q each 1 (and) fold)` and `over` is `(swap dup (swap) dip)`, but a
  session `and` or `swap` leaves both alone:

      (pop pop 42) 'and def   [1 1] (1 =) all?      -- 1
      (pop pop 99) 'swap def  1 2 over              -- 1 2 1

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
  Modules can be parameterized with anaonymous module handles, enabling a
  simple kind of dependency injection.
  A quotation parameter carries the scope it was written in, so it preserves
  its references on injection into a module. Given:

      10 'k set
      [(k *)] (
               'scale def
               ( -- n ) (4 scale) 'go def) 'm @defm
      m.go                                          -- 40

- **A word resolves in the scope its text was written in.** The word itself
  carries the scope, so it
  survives every operation that moves code around: `cat` and `compose` splice
  tokens from two sources into one list and each token keeps the scope it was
  written in. A module word may hand `(private-helper)` to `each` and the
  private still resolves, because the literal was written inside the module;
  a module word may accept `(bump)` from its caller and that `bump` resolves in
  the caller, because the caller wrote it; and both hold when the stdlib passes
  the caller's quotation as ordinary data.
- **Only a reader-authored body becomes module text.** The constructor identifies
  the body by its operand position; the values operand never participates. The
  body must also carry reader lineage: it came either directly from the reader
  or from construction's own scope-only copy of reader text. Construction then
  copies that body and gives every word in its reader-built subtree the new
  image's scope, including words nested in quotation, list, and dict literals.
  The copy retains its lineage, so a construction nested inside it can scope its
  own body to its own image.

  Generic runtime list operations do not create lineage. A body produced by
  `cat`, `compose`, `cons`, `append`, `raze`, slicing, reversal, `with`, or a
  similar operation keeps the scopes already carried by its parts, but module
  construction does not traverse or re-scope it. Reader-authored fragments do
  not make their runtime-built container reader-authored. For example,
  `7 'k set [] ((k) 'geta) (def) cat 'm @defm` builds the module body at
  runtime. The `k` inside `(k)` keeps its session scope, so `m.geta` resolves
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

## Concurrency

**Imports:** ECL_UNITS

##### Contexts

**`Concurrency`**

#### Chapter 1

##### Action

> This model is normative for structured task identity, attachment to the general unit lifecycle, cached terminal results, observation by `await`, deadline expiry, cancellation, and the requirement that a unit quiesce its task scope before becoming terminal.  It abstracts over evaluator steps, scheduling policy, elapsed time, I/O interleaving, handle storage and lexical scope, and the selection algorithms used by `await-any`, `await-all`, and `@each`. The surrounding language specification governs those operations. A conforming scheduler may run runnable tasks serially; the model promises lifetime and result semantics, without promising simultaneous progress or fairness. Task capabilities are immutable ECL values and may be shared. The mutable evaluation state of each task remains confined to its attached unit.  `Spawn task` is the formal `@spawn` boundary. The explicit values list and quotation body become the attached unit's complete entry stack and body. Ambient operands are absent from the action, so they cannot cross the boundary. The action chooses both a fresh task identity and a fresh unit identity, attaches them permanently, and records the active unit that owns the new task's structured lifetime.

**`Units`**, **`Concurrency`** ↝ Spawn task *owner*: `Unit`, *entry*: `Value`, *body*: `Value`, **unit-created?** *owner*, **unit-active?** *owner*, ¬**unit-succeeded?** *owner*, ¬**unit-failed?** *owner*, **value-type** *entry* = **list-type**, **value-type** *body* = **list-type**.

---

> Spawning creates one task and one attached active unit. Both identities are fresh, and all previously created task and unit state is preserved.

∃ *task*: `Task`, *child*: `Unit`, ¬**task-created?** *task*, ¬**unit-created?** *child* · **task-created?**′ *task* ∧ **task-unit**′ *task* = *child* ∧ **task-owner-unit**′ *task* = *owner* ∧ **value-type** (**task-capability** *task*) = **task-type** ∧ (∀ *existing*: `Task`, **task-created?** *existing* · **task-capability** *task* ≠ **task-capability** *existing*) ∧ **unit-created?**′ *child* ∧ **unit-active?**′ *child* ∧ ¬**unit-succeeded?**′ *child* ∧ ¬**unit-failed?**′ *child* ∧ **unit-entry**′ *child* = *entry* ∧ **unit-body**′ *child* = *body* ∧ **unit-stack**′ *child* = *entry* ∧ **unit-error**′ *child* = **unit-error** *child* ∧ (∀ *other-task*: `Task`, *other-task* ≠ *task* · **task-created?**′ *other-task* = **task-created?** *other-task* ∧ **task-unit**′ *other-task* = **task-unit** *other-task* ∧ **task-owner-unit**′ *other-task* = **task-owner-unit** *other-task*) ∧ (∀ *other-unit*: `Unit`, *other-unit* ≠ *child* · **unit-created?**′ *other-unit* = **unit-created?** *other-unit* ∧ **unit-active?**′ *other-unit* = **unit-active?** *other-unit* ∧ **unit-succeeded?**′ *other-unit* = **unit-succeeded?** *other-unit* ∧ **unit-failed?**′ *other-unit* = **unit-failed?** *other-unit* ∧ **unit-entry**′ *other-unit* = **unit-entry** *other-unit* ∧ **unit-body**′ *other-unit* = **unit-body** *other-unit* ∧ **unit-stack**′ *other-unit* = **unit-stack** *other-unit* ∧ **unit-error**′ *other-unit* = **unit-error** *other-unit*).

#### Chapter 2

##### Domains

> A created task permanently names one attached unit and its owning unit. Its capability is an ECL value of the task kind. No two task identities attach to the same unit or expose the same capability value.

`Task`.

##### Rules

{**`Concurrency`**} **task-created?** *task*: `Task` ⇒ `Bool`.

{**`Concurrency`**} **task-unit** *task*: `Task` ⇒ `Unit`.

{**`Concurrency`**} **task-owner-unit** *task*: `Task` ⇒ `Unit`.

**task-capability** *task*: `Task` ⇒ `Value`.

---

> Every created task has a task-valued capability, attaches to a created unit, and was spawned by a distinct created unit.

∀ *task*: `Task`, **task-created?** *task* · **value-type** (**task-capability** *task*) = **task-type** ∧ **unit-created?** (**task-unit** *task*) ∧ **unit-created?** (**task-owner-unit** *task*) ∧ **task-unit** *task* ≠ **task-owner-unit** *task*.

> Attached units are unique to their task identities.

∀ *left*: `Task`, *right*: `Task`, **task-created?** *left*, **task-created?** *right*, **task-unit** *left* = **task-unit** *right* · *left* = *right*.

> Created tasks have distinct capability values.

∀ *left*: `Task`, *right*: `Task`, **task-created?** *left*, **task-created?** *right*, **task-capability** *left* = **task-capability** *right* · *left* = *right*.

> Initially no task identity has been created.

initially ∀ *task*: `Task` · ¬**task-created?** *task*.

#### Chapter 3

##### Rules

> A task's terminal result is a single immutable ECL value. A successful attached unit yields the exact ordered terminal stack in an `'ok` envelope; a failed attached unit yields its unchanged error value in an `'err` envelope. Because `task-result` is immutable, every observation of a terminal task produces the same value.

**task-result** *task*: `Task` ⇒ `Value`.

---

> Successful tasks have successful result envelopes.

∀ *task*: `Task`, **task-created?** *task*, **unit-succeeded?** (**task-unit** *task*) · **successful-result-value?** (**task-result** *task*).

> The successful result payload is exactly the attached unit's terminal stack list value.

∀ *task*: `Task`, **task-created?** *task*, **unit-succeeded?** (**task-unit** *task*) · **successful-result-values** (**task-result** *task*) = **unit-stack** (**task-unit** *task*).

> Failed tasks have failed result envelopes containing the unit's exact error value.

∀ *task*: `Task`, **task-created?** *task*, **unit-failed?** (**task-unit** *task*) · **failed-result-value?** (**task-result** *task*).

∀ *task*: `Task`, **task-created?** *task*, **unit-failed?** (**task-unit** *task*) · **failed-result-error** (**task-result** *task*) = **unit-error** (**task-unit** *task*).

> A unit may become terminal only after every directly owned task is terminal. Applying the same rule recursively gives structured quiescence for the complete descendant task tree. This is the task-scope part of the rule that a failed unit leaves nothing running.

∀ *owner*: `Unit`, **unit-created?** *owner*, (**unit-succeeded?** *owner* ∨ **unit-failed?** *owner*) · ∀ *task*: `Task`, **task-created?** *task*, **task-owner-unit** *task* = *owner* · **unit-succeeded?** (**task-unit** *task*) ∨ **unit-failed?** (**task-unit** *task*).

#### Chapter 4

##### Action

> `Complete spawned task successfully` is the concurrency-layer use of the general unit success transition. The evaluator supplies the final stack. The attached unit can become terminal only after its own task scope has quiesced.

**`Units`** ↝ Complete spawned task successfully *task*: `Task`, *result*: `Value`, **task-created?** *task*, **unit-active?** (**task-unit** *task*), **value-type** *result* = **list-type**, (∀ *child*: `Task`, **task-created?** *child*, **task-owner-unit** *child* = **task-unit** *task* · **unit-succeeded?** (**task-unit** *child*) ∨ **unit-failed?** (**task-unit** *child*)).

---

**unit-created?**′ (**task-unit** *task*).

¬**unit-active?**′ (**task-unit** *task*).

**unit-succeeded?**′ (**task-unit** *task*).

¬**unit-failed?**′ (**task-unit** *task*).

**unit-entry**′ (**task-unit** *task*) = **unit-entry** (**task-unit** *task*).

**unit-body**′ (**task-unit** *task*) = **unit-body** (**task-unit** *task*).

**unit-stack**′ (**task-unit** *task*) = *result*.

**unit-error**′ (**task-unit** *task*) = **unit-error** (**task-unit** *task*).

**successful-result-value?** (**task-result** *task*).

**successful-result-values** (**task-result** *task*) = *result*.

∀ *other*: `Unit`, *other* ≠ **task-unit** *task* · **unit-created?**′ *other* = **unit-created?** *other* ∧ **unit-active?**′ *other* = **unit-active?** *other* ∧ **unit-succeeded?**′ *other* = **unit-succeeded?** *other* ∧ **unit-failed?**′ *other* = **unit-failed?** *other* ∧ **unit-entry**′ *other* = **unit-entry** *other* ∧ **unit-body**′ *other* = **unit-body** *other* ∧ **unit-stack**′ *other* = **unit-stack** *other* ∧ **unit-error**′ *other* = **unit-error** *other*.

#### Chapter 5

##### Action

> `Complete spawned task with failure` is the concurrency-layer use of the general unit failure transition. The evaluator supplies the error. The attached unit restores its entry stack and becomes terminal after its own task scope has quiesced.

**`Units`** ↝ Complete spawned task with failure *task*: `Task`, *error*: `Value`, **task-created?** *task*, **unit-active?** (**task-unit** *task*), **error-value?** *error*, (∀ *child*: `Task`, **task-created?** *child*, **task-owner-unit** *child* = **task-unit** *task* · **unit-succeeded?** (**task-unit** *child*) ∨ **unit-failed?** (**task-unit** *child*)).

---

**unit-created?**′ (**task-unit** *task*).

¬**unit-active?**′ (**task-unit** *task*).

¬**unit-succeeded?**′ (**task-unit** *task*).

**unit-failed?**′ (**task-unit** *task*).

**unit-entry**′ (**task-unit** *task*) = **unit-entry** (**task-unit** *task*).

**unit-body**′ (**task-unit** *task*) = **unit-body** (**task-unit** *task*).

**unit-stack**′ (**task-unit** *task*) = **unit-entry** (**task-unit** *task*).

**unit-error**′ (**task-unit** *task*) = *error*.

**failed-result-value?** (**task-result** *task*).

**failed-result-error** (**task-result** *task*) = *error*.

∀ *other*: `Unit`, *other* ≠ **task-unit** *task* · **unit-created?**′ *other* = **unit-created?** *other* ∧ **unit-active?**′ *other* = **unit-active?** *other* ∧ **unit-succeeded?**′ *other* = **unit-succeeded?** *other* ∧ **unit-failed?**′ *other* = **unit-failed?** *other* ∧ **unit-entry**′ *other* = **unit-entry** *other* ∧ **unit-body**′ *other* = **unit-body** *other* ∧ **unit-stack**′ *other* = **unit-stack** *other* ∧ **unit-error**′ *other* = **unit-error** *other*.

#### Chapter 6

##### Action

> `Await task` observes only a terminal attached unit and leaves both unit and task state unchanged. It yields `task-result task`; repeating the action is therefore safe and produces the cached result again. Parking and resumption before the terminal observation are scheduling details outside the model.

**`Concurrency`** ↝ Await task *observer*: `Unit`, *task*: `Task`, **unit-created?** *observer*, **unit-active?** *observer*, **task-created?** *task*, (**unit-succeeded?** (**task-unit** *task*) ∨ **unit-failed?** (**task-unit** *task*)).

---

∀ *candidate*: `Task` · **task-created?**′ *candidate* = **task-created?** *candidate* ∧ **task-unit**′ *candidate* = **task-unit** *candidate* ∧ **task-owner-unit**′ *candidate* = **task-owner-unit** *candidate*.

#### Chapter 7

##### Action

> `Await task until deadline expires` is the timeout branch of `await-for`. It is available only while the attached unit is active, yields a value satisfying `timeout-result?`, and leaves the task and attached unit unchanged. A terminal task therefore wins over deadline expiry, including at a zero deadline. Deadline measurement and parking are outside the model.

**`Concurrency`** ↝ Await task until deadline expires *observer*: `Unit`, *task*: `Task`, **unit-created?** *observer*, **unit-active?** *observer*, **task-created?** *task*, **unit-active?** (**task-unit** *task*).

---

∀ *candidate*: `Task` · **task-created?**′ *candidate* = **task-created?** *candidate* ∧ **task-unit**′ *candidate* = **task-unit** *candidate* ∧ **task-owner-unit**′ *candidate* = **task-owner-unit** *candidate*.

#### Chapter 8

##### Action

> `Cancel active task` is ordinary unit failure with a cancellation error. It restores the unit's entry stack and becomes terminal only after the task's own descendants are quiescent.

**`Units`** ↝ Cancel active task *task*: `Task`, *error*: `Value`, **task-created?** *task*, **unit-active?** (**task-unit** *task*), **cancelled-error?** *error*, (∀ *child*: `Task`, **task-created?** *child*, **task-owner-unit** *child* = **task-unit** *task* · **unit-succeeded?** (**task-unit** *child*) ∨ **unit-failed?** (**task-unit** *child*)).

---

**unit-created?**′ (**task-unit** *task*).

¬**unit-active?**′ (**task-unit** *task*).

¬**unit-succeeded?**′ (**task-unit** *task*).

**unit-failed?**′ (**task-unit** *task*).

**unit-entry**′ (**task-unit** *task*) = **unit-entry** (**task-unit** *task*).

**unit-body**′ (**task-unit** *task*) = **unit-body** (**task-unit** *task*).

**unit-stack**′ (**task-unit** *task*) = **unit-entry** (**task-unit** *task*).

**unit-error**′ (**task-unit** *task*) = *error*.

**failed-result-value?** (**task-result** *task*).

**failed-result-error** (**task-result** *task*) = *error*.

∀ *other*: `Unit`, *other* ≠ **task-unit** *task* · **unit-created?**′ *other* = **unit-created?** *other* ∧ **unit-active?**′ *other* = **unit-active?** *other* ∧ **unit-succeeded?**′ *other* = **unit-succeeded?** *other* ∧ **unit-failed?**′ *other* = **unit-failed?** *other* ∧ **unit-entry**′ *other* = **unit-entry** *other* ∧ **unit-body**′ *other* = **unit-body** *other* ∧ **unit-stack**′ *other* = **unit-stack** *other* ∧ **unit-error**′ *other* = **unit-error** *other*.

#### Chapter 9

##### Action

> Cancelling a terminal task is a no-op. Its cached result remains unchanged.

**`Units`** ↝ Cancel terminal task *task*: `Task`, **task-created?** *task*, (**unit-succeeded?** (**task-unit** *task*) ∨ **unit-failed?** (**task-unit** *task*)).

---

∀ *candidate*: `Unit` · **unit-created?**′ *candidate* = **unit-created?** *candidate* ∧ **unit-active?**′ *candidate* = **unit-active?** *candidate* ∧ **unit-succeeded?**′ *candidate* = **unit-succeeded?** *candidate* ∧ **unit-failed?**′ *candidate* = **unit-failed?** *candidate* ∧ **unit-entry**′ *candidate* = **unit-entry** *candidate* ∧ **unit-body**′ *candidate* = **unit-body** *candidate* ∧ **unit-stack**′ *candidate* = **unit-stack** *candidate* ∧ **unit-error**′ *candidate* = **unit-error** *candidate*.



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

## Standard environment

[`ENVIRONMENT.md`](ENVIRONMENT.md) defines the shipped module transports,
host-backed library contracts, project and package system, command-line
interface, and source formatter.
