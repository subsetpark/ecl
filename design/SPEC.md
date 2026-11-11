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
name. Word occurrences retain the root their names are resolved in. Each word
is resolved in its own root when it is reached, so a replacement reaches every
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

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **int-type**, **value-type** *right* = **int-type**, **int-payload** *left* = **int-payload** *right* · *left* = *right*.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **float-type**, **value-type** *right* = **float-type**, **float-payload** *left* = **float-payload** *right* · *left* = *right*.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **char-type**, **value-type** *right* = **char-type**, **char-codepoint** *left* = **char-codepoint** *right* · *left* = *right*.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **symbol-type**, **value-type** *right* = **symbol-type**, **symbol-spelling** *left* = **symbol-spelling** *right* · *left* = *right*.

> A list is a finite ordered sequence. Its length and positional elements determine its value identity.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **list-type**, **value-type** *right* = **list-type**, **list-length** *left* = **list-length** *right*, (∀ *index*: `Nat`, *index* ≤ **list-length** *left* · **list-element** *left* *index* = **list-element** *right* *index*) · *left* = *right*.

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

∀ *left*: `Value`, *right*: `Value`, **matches?** *left* *right* · **numeric-value?** *left* ∧ **numeric-value?** *right* ∨ **value-type** *left* = **char-type** ∧ **value-type** *right* = **char-type** ∨ **value-type** *left* = **symbol-type** ∧ **value-type** *right* = **symbol-type** ∨ **value-type** *left* = **list-type** ∧ **value-type** *right* = **list-type** ∨ **value-type** *left* = **dict-type** ∧ **value-type** *right* = **dict-type** ∨ **value-type** *left* = **task-type** ∧ **value-type** *right* = **task-type** ∨ **value-type** *left* = **port-type** ∧ **value-type** *right* = **port-type** ∨ **value-type** *left* = **address-type** ∧ **value-type** *right* = **address-type**.

> Numeric matching is exact mathematical-value equality across int and float.

∀ *left*: `Value`, *right*: `Value`, **numeric-value?** *left*, **numeric-value?** *right* · **matches?** *left* *right* ↔ **numeric-magnitude** *left* = **numeric-magnitude** *right*.

> Equal int magnitudes are exactly equal int payloads.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **int-type**, **value-type** *right* = **int-type** · **numeric-magnitude** *left* = **numeric-magnitude** *right* ↔ **int-payload** *left* = **int-payload** *right*.

> Chars and symbols match exactly when their scalar contents match.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **char-type**, **value-type** *right* = **char-type** · **matches?** *left* *right* ↔ **char-codepoint** *left* = **char-codepoint** *right*.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **symbol-type**, **value-type** *right* = **symbol-type** · **matches?** *left* *right* ↔ **symbol-spelling** *left* = **symbol-spelling** *right*.

> Lists match recursively and positionally.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **list-type**, **value-type** *right* = **list-type** · **matches?** *left* *right* ↔ **list-length** *left* = **list-length** *right* ∧ (∀ *index*: `Nat`, *index* ≤ **list-length** *left* · **matches?** (**list-element** *left* *index*) (**list-element** *right* *index*)).

> Whole-value matching is dictionary-key identity.

∀ *dictionary*: `Value`, *key*: `Value`, *other*: `Value`, **value-type** *dictionary* = **dict-type**, **dict-has-key?** *dictionary* *key*, **matches?** *key* *other* · **dict-has-key?** *dictionary* *other*.

∀ *dictionary*: `Value`, *key*: `Value`, *other*: `Value`, **value-type** *dictionary* = **dict-type**, **dict-has-key?** *dictionary* *key*, **matches?** *key* *other* · **dict-value-for-key** *dictionary* *key* = **dict-value-for-key** *dictionary* *other*.

> Dictionaries match exactly when they have the same keys and the values under each key match.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **dict-type**, **value-type** *right* = **dict-type** · **matches?** *left* *right* ↔ (∀ *key*: `Value` · **dict-has-key?** *left* *key* ↔ **dict-has-key?** *right* *key*) ∧ (∀ *key*: `Value`, **dict-has-key?** *left* *key*, **dict-has-key?** *right* *key* · **matches?** (**dict-value-for-key** *left* *key*) (**dict-value-for-key** *right* *key*)).

> A task value only matches itself.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **task-type**, **value-type** *right* = **task-type** · **matches?** *left* *right* ↔ *left* = *right*.

> A port value only matches itself.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **port-type**, **value-type** *right* = **port-type** · **matches?** *left* *right* ↔ *left* = *right*.

> An address names the mailbox of one task capability.

∀ *value*: `Value`, **value-type** *value* = **address-type** · **value-type** (**address-mailbox** *value*) = **task-type**.

> Address values match when they correspond to the same task.

∀ *left*: `Value`, *right*: `Value`, **value-type** *left* = **address-type**, **value-type** *right* = **address-type** · **matches?** *left* *right* ↔ **address-mailbox** *left* = **address-mailbox** *right*.

> Scalar source kinds have readable representations.

∀ *value*: `Value`, (**value-type** *value* = **int-type** ∨ **value-type** *value* = **float-type** ∨ **value-type** *value* = **char-type** ∨ **value-type** *value* = **symbol-type**) · **readable?** *value*.

> Task, port, and address values have diagnostic displays but no readable representations.

∀ *value*: `Value`, (**value-type** *value* = **task-type** ∨ **value-type** *value* = **port-type** ∨ **value-type** *value* = **address-type**) · ¬**readable?** *value*.

> A list is readable exactly when all its elements are readable.

∀ *value*: `Value`, **value-type** *value* = **list-type** · **readable?** *value* ↔ (∀ *index*: `Nat`, *index* ≤ **list-length** *value* · **readable?** (**list-element** *value* *index*)).

> A dictionary is readable exactly when all its keys and values are readable.

∀ *value*: `Value`, **value-type** *value* = **dict-type** · **readable?** *value* ↔ (∀ *key*: `Value`, **dict-has-key?** *value* *key* · **readable?** *key* ∧ **readable?** (**dict-value-for-key** *value* *key*)).

> Hashing is congruent with whole-value matching.

∀ *left*: `Value`, *right*: `Value`, **matches?** *left*
*right* · **value-hash** *left* = **value-hash** *right*.

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

Every word is resolved when it is reached, in the root that occurrence was
written in (see Bindings and scope), against the current definitions and module
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
exception: its lookup is deferred until the word is reached. The definition's own name, written in the root it is published
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
and `see` — resolve the supplied symbol in its own root against the current
definitions each time they run. 

A word written in a module image resolves in that image, so code written in an
image keeps reaching that image's definitions after its registration is
replaced, while a qualified name reaches the registration current when it runs.
Executing a word written in an image that was never published and has since
been discarded is a `` `domain `` error.

The reader links each symbol occurrence to the root the source is read into:
the session, or core for the prelude. Moving, copying, concatenating, or
splicing values preserves each occurrence's own root, so one quotation may
contain symbols from several roots, and a quotation has no single resolution
root. A module body is the one exception: `@defm` re-homes every occurrence in
its body to the new image, whatever root each carried and however the body was
built, so session code placed in a module body no longer reaches the session
(see Modules). A symbol that `qualify`, `symbol`,
`intern`, or native code builds links to the root of the activation that built
it, so a quotation assembled from strings resolves where it was assembled
rather than where it is later called. 

A reader-produced aggregate may separately retain **source spans**, which
record where the aggregate and its reader-built descendants were read. Spans
support diagnostics and reflection; they are not an AST, a captured
environment, or a quotation-wide resolution root. Runtime aggregate
reconstruction does not acquire spans. Resolution context, spans, and
provenance are semantic metadata on stored occurrences and aggregates, but
none is part of value identity.

ECL therefore has syntactic closure without value capture: reader-authored
identifiers retain their lookup scopes, while quotation values capture no
bindings or ordinary values. An unannotated runtime-created word retains the
dynamic behavior described above.

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

### Roots and names

Definitions live in *roots*. There are three kinds:

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

Every activation has a **current root**. A word belonging to a module runs with
that module's image as its current root; every other word, whether a session
definition, a core primitive, or a prelude word, runs in its caller's root.
Outside any module word the current root is the session, or the image under
construction in a module's construction body. The current root decides where
definition words write, what `*module*` reports, and the root a symbol built at
run time links to. A core word such as `*module*` written in an escaped
quotation runs in its caller's root, so it reports the caller's module, or is
`` `domain `` at the session root.

### Binding model

There is one namespace and one binding kind. A name binds an executable body
plus metadata, and reference always invokes the body. Values are bound by
capturing them in bodies. Public and private definitions differ in visibility,
not invocation semantics. Native and builtin definitions may have different
representations but expose the same binding model.

- ``(body) `name def`` binds a word: reference applies the body. The body
  must be a list (a non-list is an error directing to `set`); a list of
  plain data is legal and yields a multi-value constant word.
- ``annotation? value `name set`` binds a constant. It is sugar, defined in ecl
  as `swap wrap swap def`: the value is wrapped, so the published body is
  `(value)`, or ``(`value)`` when the value is a word.
  Reference applies that body and pushes the captured value, quotations included — the capture is
  inert, so nothing in it executes or resolves. ``v `name set`` is therefore
  observationally ``v wrap `name def``: the sugar synthesizes no
  annotation of its own, while an annotation beneath `v` is preserved for
  `def` to consume. `which` reports the resulting public `def`, while `see`
  prints its captured body, preceded by the annotation when one is
  present; an unannotated `set` has no effect or documentation, and nothing
  distinguishes it from the corresponding `wrap` plus `def` spelling. `set`
  assigns the environment and introduces no lexical binding. For ordinary local
  values, prefer stack flow or locals.
- Redefinition (`def` or `set` over an existing name) replaces the
  complete definition: omitting an effect or docstring clears the old one.
  Every later call reaches the new definition, including calls from code
  defined before it.
- `see` prints the resolved binding's combined annotation, when present,
  followed by its body through the standard source formatter. It omits the
  navigation header, name, and `def`/`defp` terminator; `which` reports binding
  and effect metadata, `doc` returns documentation, and `effect` returns the
  declared effect as an annotation list, or `()` when none was declared.
  `` `m exports `` returns module `m`'s public word names as sorted symbols
  (`` `core exports `` lists core's), `` `m module-doc `` returns its
  documentation, and `stdlib` returns the embedded standard-library module
  names.
- Names are introduced and replaced, never removed. No word removes a
  definition or a module registration during a Session: a shadowed core word
  stays reachable as `core.name`, and a new Session starts with no top-level
  definitions.
- `def`, `defp`, `set`, `setp`, `import`, and `importp` write the current
  root, which is the session for top-level code and the image for a module's
  construction body. An image accepts them only while it is under
  construction: inside a word of a sealed module, where the current root is
  that module's image, every one of these is `` `domain ``. A word that
  belongs to no module writes its caller's current root. Every quotation a unit runs, under any combinator or `@attempt`, may
  define; a definition is an environment effect, and like IO it survives the
  failure of the `@attempt` that made it. A task runs in its spawner's root
  without owning it, so inside a task every one of these is `` `domain ``.
- `defp`/`setp`/`importp` are the private forms, legal only inside a module
  body (see Modules); at top level they are errors.
- Because `set`/`setp` are sugar, their failures are raised by the words
  they call: an underflowing `set` is `` `underflow `` from `swap`, and a
  non-symbol or reserved name is raised by `def`/`defp`. The error kind is
  unchanged; the trace names `set`/`setp` as the parent.

### Definition annotations

A definition may place one annotation quotation immediately before its body:

```ecl
(body) `name def
(before -- after) (body) `name def
(: "Documentation.") (body) `name def
(before -- after : "Documentation.") (body) `name def
```

The annotation is ordinary quotation data — no special grammar — and is
recognized only when it contains a top-level word `--` or `:`. Nested
markers and the quoted symbols `` `-- ``/`` `: `` are inert. A recognized
annotation is validated as a whole before the binding publishes: at most
one marker of each kind, `--` before `:`, only slots (see
[Quotation slots](#quotation-slots)) around `--`, and one string
after `:`. A malformed recognized annotation is a
`` `domain `` error. The quotation adjacent to the name is unconditionally the
body; only the value beneath it is considered for annotation recognition.
`set`/`setp` wrap their value before `def`/`defp` sees it,
so marker words belonging to the captured value sit nested inside the body
and remain inert. A separate annotation beneath that value is still visible
to `def`/`defp`, giving constants the same optional metadata as words.

Annotations are optional everywhere. Module `def`/`defp` accept the same four
forms as top-level `def`: no annotation, effect only, documentation only, or
both. A top-level effect is reflective metadata only; a module word's declared
effect is a live contract, checked dynamically against the observed effect when
application crosses a module boundary (violation: `` `contract ``). An omitted
module effect means there is no such check, and so does a standard-library
word's: the standard library's effects are reflective metadata, and a call with
too few values fails inside the word, as the code it runs reports it. This
source-language relaxation does not weaken the native ABI, whose `Call` effect
and documentation remain mandatory; the shipped prelude keeps its stronger
repository policy requiring meaningful documentation.

Documentation has canonical form. Publication trims source-only indentation,
folds physical line breaks within prose to spaces, collapses a paragraph
boundary to one blank line, and preserves each `-`-prefixed Markdown item on
its own logical line with its continuations folded in. A paragraph without
items whose lines do not all start at one column, such as an example, is laid
out by hand: it keeps its lines and their indentation past the documentation's
margin. A first line beside the opening quote has no column of its own. `doc`
returns this canonical string, so source formatting cannot change reflective
documentation.
Strings anywhere else retain their exact decoded codepoints.

#### Variable rows

The token `...` stands for a variable row: zero or more values whose count
the effect does not fix. Each portion of an effect may hold one `...`, at any
position among its named slots, and the named slots of that portion become a
minimum:

```ecl
(result on-ok on-err -- ...) (body) `case def
(... n -- list) (body) `pack def
(x (... -- ...) -- ... x) (body) `peek def
```

A row in the before portion declares that the word consumes at least its
named before slots and an unknown number more. A row in the after portion
declares that the word leaves at least its named after slots, with an unknown
number of further values where the row sits. The effect remains a genuine
partial contract, checked as far as its named slots allow: the named before
slots are checked at entry; with a fixed before portion, the word must leave
exactly its named after slots, or at least them when the after portion holds a
row; with a row in the before portion, the depth the word leaves is not
checked, since how many values it consumed is unknown. A word that would
otherwise carry a documentation-only annotation regains input checking and
honest reflection.

A second `...` in either portion is `` `domain ``. A `...` on one side never
refers to a `...` on the other: it is a placeholder, not a row variable, so
`(... a -- ... b)` says nothing about which values survive. Named row
variables in the Factor style (..a, ..b) are deferred to the static checker.
The native ABI is deliberately excluded: a native `Call` takes exactly its
declared inputs and `complete` requires the exact output tuple, so `...`
anywhere in a `Call` effect is refused.

#### Quotation slots

A slot is a word or a nested effect. A nested effect describes the quotation
that occupies that position, and may name it with a label: a word ending in
`:` as its first element.

```ecl
(collection (a -- b) -- collection) (body) `each def
(bool (then: -- ...) (else: -- ...) -- ...) (body) `if def
```

The bare form is the default; a label names a quotation the documentation
must refer to, typically where a word takes several. Every slot is one
element of the effect, so a nested effect never changes the word's arity or
its boundary check. A nested effect follows the same slot grammar as the
effect around it, including `...` and further nesting, and carries no
documentation string. It is documentation only: names are scoped to their
own level and carry no identity across levels, and nothing checks the
quotation against it. An isolated combinator's dynamic contract is stated
here and checked by the combinator, not by the annotation. A label anywhere
but first in a nested effect is `` `domain ``, as is nesting more than eight
levels deep.

The exact names `--`, `:`, and `...` are reserved against binding: they remain
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
- Symbols are not numeric: pervading into a quotation errors at the first
  symbol leaf, except under `=` and `<>`, which are total. Two symbols are
  equal when they name the same symbol, whatever occurrence metadata either
  carries, and a symbol equals no number: `` [`a 1] [a 2] = `` is `[1 0]`.
- Chars enter every numeric word (arithmetic, comparison, the bitwise and
  wrapping words) as their codepoints and leave as ints: `char int +` and
  `char char -` are ints, `char int =` compares the codepoint with the int,
  and no numeric result is a char. `char` is the way back: over a list of
  codepoints it is the string they spell.

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
  `-1 log`, `0 0 /`, `inf -inf +`). NaN therefore never exists, and nothing
  outside the language can introduce one: a NaN float that a native extension
  returns or puts in a port message is rejected as an invalid value.
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
  `` `overflow ``, they wrap, as Zig's operators of the same spelling do. They are
  int-only like the bitwise words (a char is its codepoint, a float is
  `` `type ``), and with
  `band` they give arithmetic modulo any power of two up to 2^64.

## Randomness

Randomness is *counter-based*: a generator state is a two-element list `[key
counter]`, and every draw is a pure function of it. `rand.int`, `rand.ints`,
and `rand.float` each take a state and return the advanced state alongside the
result, so a program's draws are reproducible by construction — running it
twice from the same key produces the same values, and nothing hidden
accumulates between submissions, tasks, or module loads.

- `rand.entropy` is the only word that reads the host, and the only
  nondeterministic word in the language. A program is reproducible unless
  it explicitly seeds from `rand.entropy`; there is no ambient default seed
  drawn at startup, and no word silently reaches a CSPRNG.
- `rand.shuffle` and `rand.deal` thread the same state through a permutation
  and a draw without replacement. Code that wants an ambient generator keeps
  the state in an agent: ``[0 0] agent.start `rng set`` then
  `rng (5 rand.int) agent.call` (see The standard library).

## Chars and strings

A string is a rank-1 char vector; there is no separate string type. `len`,
`at`, `reverse`, and list applications of `each` and `for` operate on
codepoints. UTF-8 exists only at IO boundaries: source files and
`io.prin`/`io.pp` encode and decode UTF-8, and invalid UTF-8 on input is an
error. Char semantics are codepoint semantics: grapheme segmentation,
normalization, non-ASCII case mapping, and locale collation are not provided,
so composed and decomposed `"café"` have lengths 4 and 5. Symbols are interned
at parse; strings are plain uninterned vectors.

### Conversions

Conversion between kinds is explicit and names its target. `chars` yields a
value's text content as a string: a string unchanged, a symbol's
spelling, a char as a one-element string, or a byte list decoded as UTF-8. A
byte list is an integer list whose every element is 0 through 255; bytes that
are not valid UTF-8 are `` `domain `` with `` `reason `invalid-utf8 ``. `bytes` is the
inverse: it encodes a string as UTF-8 and returns a byte list unchanged. `int`
accepts an int, a string in the integer-literal grammar, or a char, whose
codepoint it returns. `float` accepts a float, an int, or a string in the
numeric-literal grammar. A float is not accepted by `int`: `floor`, `round`,
and `ceil` name the rounding. `char` accepts a char or a string, returned
unchanged, an int in the Unicode scalar range, or a list of such ints and
chars, which becomes the string they spell. A string outside the literal
grammar is `` `parse ``; an int outside the scalar range is `` `domain ``; every
other operand kind is `` `type ``. `str` remains the readable
representation and `parse` remains the reader; neither is a conversion.

Symbol conversion is split so that programs cannot grow the interned name
space by accident. `symbol` accepts a symbol unchanged and converts a
string only when that spelling is already interned, failing `` `domain ``
otherwise; every symbol a program can meaningfully compare against was
interned when its source was read, so lookup is the common case. `intern`
accepts the same operands and creates the symbol when the spelling is new.
Both reject a string that is not a valid symbol spelling as `` `domain ``. The
interned name space grows only through reading source, `parse`, `intern`, and
the module loaders; words that materialize values from external data produce
strings, never symbols. A symbol built from a string is the same value as
the symbol read from source, so `"dup" symbol wrap call` executes `dup`.

## Modules

A module is code published under a name: a *registration* assigns an immutable
module image to a public name, and a per-session registry maps symbols to
registrations; files are transport. Modules are not values. The only way to
make one is to define it under a name, and the only way to reach one is through
that name.

### Operations

- `@defm` is ``( annotation? values body `module-name -- )``. It validates the name before
  evaluating anything: a non-symbol is `` `type ``; a name that is not a valid
  module path, the reserved name `core`, or a standard-library module name is
  `` `domain ``, and in each case the body never runs. With a valid name it runs the
  body on a fresh, isolated environment, freezes the resulting image (its
  environment and its definitions), and publishes that image as the
  registration's new generation. A body that leaves one or more values on its
  stack is `` `domain `` at completion and publishes nothing: a module body
  defines words and keeps no state. Publication is an upsert: a missing name
  creates its registration, and an existing name installs the new image as the
  current generation and carries nothing else over; the latter is a reload,
  whether `@defm` or `@load` performs it. A body failure publishes
  nothing. A registry change during construction, such as an alias now
  occupying the name, can still refuse publication after the body has run;
  the body's external effects then survive under ordinary unit semantics.
- ``(body) `name @defm`` runs the body as a unit on an empty stack. It runs
  stack-isolated: it never sees or disturbs the caller's stack.
- **A module documents itself with a documentation-only annotation.** A
  module declares no stack effect, so the value beneath the operands is its
  annotation exactly when it is `(: "text")`: a colon and one string. Any
  other value there, including a list that would be a definition's annotation,
  is the caller's data and stays on its stack. The documentation belongs to
  the generation the construction publishes, so a reload states its own and a
  reload without one leaves the module undocumented. A native module states its
  documentation in its descriptor, and every embedded standard-library module
  has one. `` `m module-doc `` returns the current generation's documentation in
  canonical form, loading the module on first mention; a module without
  documentation, or `` `core ``, is `` `domain ``.
- Modules are constructible by building the body quotation programmatically
  and enumerable and diffable through their names.
- **Module names are validated paths.** A module name is one or
  more nonempty binding-name segments joined by dots: `stats`, `core.utils`,
  and `company.data.csv` are valid; leading, trailing, and doubled dots are
  not. Definition names and aliases remain one unqualified segment. Qualified
  executable names split at their final dot, so `core.utils.f` always means
  module `core.utils`, binding `f`. The exact name `core` is reserved for the
  core qualifier (see Roots and names): registering a module or an alias under it
  is `` `domain ``, while `core.utils` stays an ordinary module name. Host
  and native factories apply the reader's single scalar-level symbol-segment
  grammar; ASCII or Unicode whitespace, delimiters, malformed UTF-8, and other
  unreadable spellings do not become validated names. Reserved syntax markers
  are interned as syntax only and cannot be minted as binding names through a
  privileged validation mode.

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

- **Construction uses ordinary unit rollback.** Its scope and bindings are
  provisional. On failure they are discarded and no
  module is registered. I/O, completed registry publications, and other
  external effects performed by the body are not rolled back. A construction
  body starts no tasks: `@spawn`, `@give`, and `@each` are `` `domain `` while
  construction is in progress, at any depth, including inside a helper word the
  body calls and inside an `@attempt` nested in the body. Registration commits atomically
  only after an image exists. A failed registration leaves the previous
  directory entry and current generation as they were.
- The registry is flat. A module body may define another module with `@defm`,
  but that registration creates an independent module with its own name and
  lifetime; it does not establish lexical nesting or parent ownership.
  Registrations commit independently, so a completed inner registration
  remains published if the outer construction body later fails.
- **Privacy is set at the definition site**: inside a module body, `def` and
  `set` bind public (exported); `defp` and `setp` bind private. Module bindings
  carry the same optional annotations as top-level ones, so a module word may
  be unannotated, documentation-only, effect-only, or both; `set`/`setp`
  publish the bare literal capture. Privacy is subtractive: private definitions
  are omitted entirely from the module's public face.
- **Tests are a distinct module-owned namespace.**
  ``annotation? (body) `name test`` accepts the same optional effect and
  documentation forms as `def`, but only while the exact direct construction
  body of `@defm` is executing. A nested quotation, child unit,
  or top-level use is `` `domain ``. Test names may equal public or private word
  names because catalog entries never enter local lookup, qualified lookup,
  imports, `words`, reflection, or module invocation. Application Sessions
  still validate placement, annotations, names, and bodies, then discard the
  declaration without retaining it or checking test-name uniqueness. Test
  Sessions retain the catalog; duplicate test names in one test image are
  `` `domain ``.
- A test-built module image freezes its definitions and test catalog
  together; an application-built image has an empty catalog. Registration
  publishes that image as one generation: reload replaces code and tests
  atomically; removal removes both; and aliases never create another suite.
- **Test discovery and execution form a closed Session mode.** Ordinary
  Sessions reject `tests` and `@test` with `` `domain ``. A test Session's
  `tests` returns each current module's tests once, aliases contributing
  none, including root sources' private tests, sorted by module, test name, and
  source identifier.
  Descriptors contain symbol fields `` `module `` and `` `name `` plus any
  declared `` `effect `` and `` `doc ``. Private tests also carry an
  integer `` `source `` identifier local to the Session, distinguishing equal
  names across files. Descriptors contain no body, generation handle, state
  handle, or executable capability.
- `descriptor @test` validates and looks up the descriptor against the
  module's current generation and its source when specified. A present test
  runs as a task whose current root is that generation's image, spawned in the current
  scope and awaited, so it observes bindings and owns tasks as any task does. It
  returns `{ok (values)}` or `{err error}`; a removed or
  replaced-away test is a reified missing-test error. The test starts on an
  empty stack, registry changes persist between invocations in
  the Session, and Session teardown destroys them. External effects are
  not transactional or rolled back.
- **`ecl test` delegates framework policy to ECL.** The command requires a
  valid module map with a local scope, loads each ECL artifact of that scope
  once, including sources with no exports, then calls the public qualified
  runner selected by `--runner` (default `test.default.run`). Tokens after `--`
  are ordinary `args`. Successful completion is status 0; `exit` selects the
  requested status; project, load, resolve, or runner failures are command
  failures. The default runner is sequential and deterministic, reports every
  result, continues after ordinary failures, and exits 1 when any test failed.
- Module code always runs under the name of the image that defined it:
  dispatch through a registered name, a construction body, an escaped
  quotation, and a private call all run module-authored words under the same
  module, so those words report the same `*module*` and spell
  their trace words `name.word`. An application through escaped
  module-authored code still crosses a module boundary for effect checking. An
  exported word's body resolves against its module's internal environment and
  then core — never the caller's environment. Publics therefore reach
  privates, and callers cannot perturb a module's behavior by shadowing.
  A module word's body is not reachable as a value: no operation extracts a
  published body, so a module's code cannot be lifted out of the image it
  resolves against.
  The rule has no exceptions, and the chain is the one each binding was
  actually defined in. A primitive or an embedded prelude definition was
  published against core alone, so core alone is its chain: it never resolves
  against a session or a module environment, whichever happens to be executing.
  Every other binding resolves against the root it was defined in: the session
  for a top-level definition and the image for a module's. There is no case
  where a binding resolves against a chain it was not defined in. So a module
  exporting a word named like a core one shadows it for that module's own
  callers, never inside the prelude words the module calls: `table.where`
  will shadow bare references to `where` inside of `table`, but it will not
  be invoked by calls to `filter` (which includes `where` in its own
  spelling), even inside of the `table` module. The same holds for the
  session, which is what makes shadowing predictable:

  ```ecl
  1 wrap                                  -- [1], reaching core's `cons`
  (pop pop 42) `cons def   1 wrap          -- still [1]
  (pop pop 42) `cons def   1 [] cons       -- 42, the session's own `cons`
  (pop pop 42) `cons def   (() cons) `wrap def   1 wrap    -- 42
  ```

  A session `def` shadows a name *for session code*. Adopting new behavior
  inside a prelude word is redefining that word: the replacement is a session
  definition, so it resolves in the session and shadows the prelude one for
  session callers from then on; what is fixed is which root each word resolves
  in. A quotation literal written
  inside a body is sealed the way the body's own references are: it resolves in
  the scope its text was written in, whoever ends up applying it. `all?` is
  `(|l q| l q each 1 (and) fold)` and `uncons` is `(dup first swap rest)`, but a
  session `and` or `swap` leaves both alone:

  ```ecl
  (pop pop 42) `and def   [1 1] (1 =) all?      -- 1
  (pop pop 99) `swap def  [1 2] uncons          -- 1 [2]
  ```

  Splicing or rearranging quotations preserves the roots of their existing
  word occurrences. A word the implementation builds for itself carries no
  root and resolves in core. Re-registering a module publishes a new image
  under the module name, so a qualified word reached afterwards runs the new
  code, in code defined earlier too. Words written in the old image go on
  resolving there. Runtime-built captures retain their existing word
  scopes.
- `@defm` takes a body and a name — ``(body) `name @defm`` — and nothing
  crosses the boundary. There is no ambient environment between a module's
  own definitions and core.

- **A word resolves in the scope its text was written in.** The word itself
  carries the scope, so it
  survives every operation that moves code around: `cat` splices
  tokens from two sources into one list and each token keeps the scope it was
  written in. A module word may hand `(private-helper)` to `each` and the
  private still resolves, because the literal was written inside the module;
  a module word may accept `(bump)` from its caller and that `bump` resolves in
  the caller, because the caller wrote it; and both hold when the stdlib passes
  the caller's quotation as ordinary data. A module body is the one place a
  word changes scope: `@defm` re-homes it.
- **Every word in a module body is module text.** `@defm` copies its body
  and gives every word in it the new image's scope, including words nested in
  quotation, list, and dict values, however the body was built. A body
  produced by `cat`, `cons`, or any other list operation is re-homed
  as a literal is; a stack value such an operation stored entered as data, so
  a symbol among them is a quoted occurrence and the body pushes it (see
  Lexical structure). For example, ``7 `k set ((k) `geta) (def) cat `m @defm``
  builds the body at runtime, and `k` inside it is a module word: `m.geta`
  fails with `` `undefined-word `` because the module defines no `k`.
- **A module holds no state.** A registration publishes an image and nothing
  else: there is no per-registration operand stack, no transaction against
  one, and no operation that reads or writes a module's storage. A construction
  body must consume everything it pushed; a body that leaves values on its
  stack fails with `` `domain `` and publishes nothing. State that must outlive a
  word lives in a task and is reached through its mailbox (see
  [Mailboxes](#mailboxes)).
- **Every published generation lasts the Session.** Reload publishes a new
  generation under the name; words written in the old one keep resolving
  there. Memory therefore grows with reload history within a
  Session; how soon an unreachable generation is reclaimed is not part of the
  language.
- Failed registration changes nothing: the previous generation, if any,
  stays current.
- A registration is never removed during a Session; reload replaces it.
- Modules are process-local: there is no persistence across process restart,
  and the native ABI exposes no module capability, so an `.eclmod` word
  cannot observe a module's internals.
- **Surface**: `import` consumes a module-name symbol and a list of attribute
  symbols, then publishes those attributes under their own names in the current
  environment — which inside a module body means the image, publicly, on the
  same terms `def` binds there. It validates every symbol and resolves every
  public attribute against one module generation before publishing the
  first name. A missing or private attribute is `` `undefined-word `` and
  publishes none of the request; malformed operand and name domains are
  `` `type `` and `` `domain ``, respectively. Each imported name is an alias,
  `x` for `m.x`: every later binding or lookup of `x` follows it to the
  definition `m.x` selects then, so an import never captures the definition it
  validated, and reflection reports that definition's metadata. A public
  import in a module re-exports the alias, which chains: `a.x` names `m.x`.
  Alias cycles are `` `domain `` when reached or validated; an alias whose
  target is missing is `` `undefined-word `` then.
  Imports between modules do not depend on which file declares a module or
  where in it. When a module body imports from a module that is unregistered
  because its own load is still in progress (declared later in the same file,
  or by a file whose load led to this one), the import publishes its aliases
  without loading, and the load that registers the module validates them
  before it completes. A missing or private attribute then fails that load as
  `` `undefined-word ``, whose data names the importing module. Each deferred
  name is checked once, by that load. Construction still cannot call such a
  name, because it resolves only once its module is sealed. Top-level imports
  are never deferred.
  At top level, naming a binding that already exists replaces only that
  binding; in a module body an imported name, like a defined one, may be
  introduced once. Importing selected names never splices an entire module.
  `importp` is the private form: the importing module uses the names without
  re-exporting them.
  Dotted words split at their final dot and give qualified access with no
  import. `qualify` validates a module-name symbol, which may be `` `core ``,
  and an unqualified binding-name symbol and constructs the corresponding
  executable word; `execute` resolves that word when it runs, in the root the
  symbol carries, and invokes it as dispatch would, preserving its current
  root, private lookup, annotations, tracing, native/builtin path, and
  cancellation. `alias` registers a short registry name; aliases and module
  names may not collide in either direction. `which` shows any name's
  resolution.
- **Qualified resolution observes registrations only.** A qualified name
  splits at its final dot into a module name and a public binding name. The
  module name selects a registered module directly or through an alias,
  except that the reserved module segment `core` selects the core scope (see
  Roots and names) and never consults the registry.
  A missing registration or public binding raises `` `undefined-word ``.
  Filesystem search, embedded resources, module maps, native loading, and
  eager or on-demand acquisition are host facilities outside the language
  semantics. A host may obtain and register an image by any means, but ECL
  programs observe only the resulting registration, never whether a module is
  "loaded" or how it was transported.

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



### Task scopes and observation

Task scopes exist at two places: the session root and each spawned
task. Code runs either in a task, its *current task*, or at the session root,
and the words that park, own, or observe bindings act on that one. A spawn is
owned by the current task, or by the session root when no task is executing.
`@attempt`, `@load`, and module construction open no scope; they are units
nested inside the current task or the root. Combinator applications open
neither a scope nor a unit. A task's attached unit cannot become terminal while a task it owns is
active: its completion cancels the remaining owned tasks and waits for their
complete descendant scopes to quiesce. The session root scope closes only at
`exit` or session end. `task.pending` reports pending descendants in
deterministic spawn preorder.

`task.await-any` accepts a nonempty task list and returns the selected index and
cached task result. Among tasks terminal when the operation begins, the lowest
input index wins; otherwise the first subsequent completion wins.

The composition `(task.await) each` awaits every input,
returns cached results in input order, preserves failures as data, and does not
cancel siblings.

`@each` spawns one task per element and enforces exactly one result value
from each. It returns results in input order. After the leftmost
failure it cancels the remaining element tasks, waits for quiescence, and
re-raises that failure. Selection of the leftmost failure is independent of
schedule order. Element tasks have no simultaneous-progress guarantee; a
program that requires cross-element rendezvous to make progress is invalid.

Await order is program order. Nondeterminism enters through `task.await-any` and
through I/O interleaving among concurrent tasks. I/O remains ordered within
one task. Sequential combinators including `each`, `for`, and `fold` execute
left to right.

`exit` is available only at the root, outside `@attempt`. Elsewhere it
raises `` `domain ``. An allowed exit first cancels and quiesces the root task
scope, then terminates the process with the supplied status.

### Mailboxes

Every task owns one mailbox, open while the task is active and closed when its
attached unit becomes terminal; closing discards every queued message. An
address is an opaque value that names a mailbox and nothing else.
`task.address` derives a task's address from its handle; `task.self` yields the
executing task's own address and raises `` `domain `` at the session root, which
owns tasks but is not one and has no mailbox. Addresses match by mailbox
identity, print as an unreadable marker, and are rejected by JSON, native
views, and port messages as task handles are.

A handle reaches a task's result; an address does not. That is why a handle can
never travel through a mailbox while an address can be sent, stored, and
forwarded freely: a message holding a handle could close a reference cycle
through the result it reaches. `task.send ( address value -- )` first checks
the value for handles, raising `` `type `` if it finds one, then queues it. A
mailbox holds sixteen messages; a sender to a full mailbox parks until the
receiver takes one. Sending to a closed mailbox raises `` `io `` with
`` `reason `closed ``. Messages from one sender arrive in the order sent; order
across senders is unspecified.

`task.receive ( -- value )` takes the oldest queued message, parking until one
arrives. `task.receive-for ( ms -- result )` bounds the wait and returns
`{ok value}` or `{err {kind timeout}}`, with the same `` `overflow `` rule as
`task.await-for`. Both raise `` `domain `` at the root. Cancellation of a parked
sender or receiver is observed as for any wait.

There is no request/reply primitive. A caller that wants an answer spawns a
helper task, sends the helper's address along with the request, and awaits the
helper, whose result is the reply; `task.await-for` bounds the exchange.

### External ports and processes

An external port belongs to the scope it was created in: the current task's,
or the session root's. The
scope, not the number or location of port values, owns the live external
resource. Closing a scope stops new operations, requests cancellation, and
does not complete until each owned resource has published a terminal state and
released its scope membership. Returning or storing a port neither detaches it
nor transfers ownership; a port that outlives its owning scope remains an
opaque handle to terminal state. Ownership moves only when a unit constructor
moves it: `@give` makes the new child's scope the owner as part of
constructing that child, so the resource is never unowned and is never
reachable by the child before the child owns it. Ownership governs lifetime,
not use: any code holding a port value may operate on it, but only code whose
current scope owns a port may give it away.

Port operations may suspend the current task, or the root, on external
readiness. Such a
suspension is an ordinary scheduler park: it consumes no worker while waiting,
participates in the same cancellation and deadline arbitration as task waits,
and resumes a bounded continuation. Input and output queues are bounded, so a
producer waits under pressure rather than causing unbounded allocation.

Filesystem words select a named directory root and a canonical relative path
beneath it. The command line provides its startup working directory as `` `cwd ``.
All operations are available on named roots, subject to operating-system
permissions. Path manipulation is pure string computation and proves nothing
about containment; containment is enforced at the root's retained directory
handle. Filesystem operations are bounded drivers whose staged mutations either
publish atomically or leave the destination unchanged.

The standard streams are endpoints of this kind, named by `fd.in`, `fd.out`,
and `fd.err`. They belong to the Session rather than to a task scope: every
task and the root share the same three values, nothing closes them, and `@give` does not
move them. Input reads return what the host has and `[]` at stable EOF, on
every later read as well; one reader may be pending. Output writes from
different tasks are served in the order they began, and each call's bytes
stay contiguous. When standard input is the program source there is no input
device, and `fd.in` is `` `io ``. Text crosses these endpoints only through the
`io` words, which encode and decode UTF-8 at the boundary. A file opened with
`fs.open-reader` and a process pipe are endpoints of the same kind. A read
may leave bytes read ahead with the endpoint value, and `fd.close` closes an
endpoint that is its own resource; one borrowed from a resource closes with
it.

The shipped `proc` module provides subprocess words. A process specification
names one absolute executable path, an argument vector, an optional absolute
working directory, and the child's complete environment. A child inherits no
host environment variable that the program did not pass it. It never denotes a
shell command and never searches `PATH`. Process streams are byte lists; text
encoding, stream merging, and line framing are user policy.

A process port has stdin, stdout, stderr, and one immutable terminal result.
The output streams remain independent and return an empty byte list only after
stable EOF. Termination is tagged as exited-with-code, signaled, stopped, or an
unknown host status. A nonzero exit code is result data, not an ECL error;
spawn, pipe, timeout, cancellation, allocation, and cleanup failures
remain errors of their corresponding ordinary kinds.

The reference distribution initially provides process ports on POSIX hosts.
Each child starts in a dedicated process group; scope cancellation signals the
group and reaps the direct child before completing. Descendants that inherit
that group are covered, while a hostile child that creates a new session is
outside this portable process-group guarantee. A host without an equivalent
tree-owning backend rejects process creation rather than silently weakening
cleanup to one PID.

Inbound network listening requests one local IP literal and port, subject to
operating-system restrictions and runtime limits. Addresses are normalized
before binding and never resolved through a name service. Port zero requests
an ephemeral port.

A listener is a port. Binding and listening complete before the value is
returned, the value belongs to the scope it was created in, and accepting a
connection is the only listener operation that parks. The bound address and
port are observable data; closing a listener, explicitly or through scope
closure, is one idempotent transition after which the address is no longer
observable, every accept waiting on it fails, and the same address and
port may be bound again. A host bind failure is `` `io `` carrying the requested
address, the requested port, and one reason from a closed vocabulary.

A connection is a port too, distinct from a listener and from a process port.
It belongs to the scope that accepted it, not to the
listener's scope: closing that scope aborts the connection even while its
value is stored elsewhere, and closing the listener leaves accepted
connections open. A connection not yet accepted stays in the host's backlog;
the runtime takes one only while an accept is outstanding and a
live-connection slot is available. Reads and writes park on readiness under
the ordinary scheduler rules, are bounded by host-configured queue
capacities, and exchange exact byte lists. One read may be pending per
connection; writes are serialized in arrival order with each call's bytes
contiguous. Explicit close delivers the bytes already queued and then shuts
the socket down; scope closure discards them and shuts down at once. Both
ends' addresses are observable data while the connection is open. A peer
failure is `` `io `` carrying the peer's address, the peer's port, and one reason
from a closed vocabulary; a cancelled wait fails only the task, or the root,
that was waiting.

A serving word built over connections applies its handler in a fresh unit per
request under the checked one-result contract. A request's framing failure,
or its handler's failure or ill-formed result, is data to the serving word
and affects only that request. A serving word runs until it is cancelled or
accept fails fatally; either ending quiesces its children by the
ordinary scope rules, and the serving word never closes a listener it did not
create.

## Standard environment

[`ENVIRONMENT.md`](ENVIRONMENT.md) defines the shipped module transports,
host-backed library contracts, project and package system, command-line
interface, and source formatter.
