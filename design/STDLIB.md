<!-- Generated from design/stdlib by design/stdlib/assemble.ecl; edit the fragments. -->

# ecl — core and standard library reference

Every public binding below ships in the core image or embedded standard
library, one entry per word. Prelude and core come first; standard-library
modules then appear by module name. Each section is layered by dependency: a
word defined in ecl appears after every word of its section that its definition
uses, directly or through private helpers, so builtins and leaf definitions
open the section and each later layer builds only on earlier ones. Mutually
recursive definitions share a layer. Within a layer, words are ordered by
codepoint — the language's own string ordering (`cmp`) — so symbol-spelled
words precede letter-spelled ones. An entry gives the word's successful stack
effect followed by its semantics. For a word defined in ecl, the entry is the
definition's own annotation, the same effect and documentation that `which`,
`see`, and `doc` reflect; words without a declared effect state their shape in
documentation.
At module boundaries, declared output contracts are checked when the invocation
completes, including any deferred work. The language rules behind those effects live in the
[`language specification`](SPEC.md); this document owns the exhaustive list of
what ships.
Conventions:

- Words marked **pervasive** follow
  [Pervasion and conformability](SPEC.md#pervasion-and-conformability).
- "Equivalent to `…`" names a word defined in ecl itself; the definition
  is normative and `see` renders it.
- Words applying quotations are marked *inline* or *unit constructor*
  (see [Application contexts](SPEC.md#application-contexts)); a unit constructor states the contract
  required of its quotation, enforced at each application.
- An effect ending in `...` declares a fixed before row and a variable
  after row (see [Definition annotations](SPEC.md#definition-annotations)) and is the word's real declared
  effect. A typographic `…` *inside* an effect is only an informal picture.
- Indexing is 0-based throughout: `range` counts from 0, `at` indexes
  from 0, `where` and `grade` produce 0-based indices, and `find` returns
  the length on a miss.
- Booleans are the ints 0 and 1; a word requiring a boolean rejects every
  other value.
- Predicate words end in `?`. Symbolic comparisons (`=`, `<>`, `<`, `<=`,
  `>`, `>=`) and the boolean combinators `and`, `or`, and `not` keep their
  conventional spellings.
- Example blocks are complete expressions unless their surrounding text says
  otherwise. A `# =>` comment shows the value or values left for the command
  printer; it is not part of the word's behavior.

## Prelude and core

### *
`( x y -- z )` — **Pervasive.** Multiply. Integer overflow is
`` `overflow ``.

### *%
`( x y -- z )` — **Pervasive.** Multiply integers modulo 2^64 in two's
complement, wrapping where `*` raises `` `overflow ``. Int-only: a float or a char
is `` `type ``. With `band`, arithmetic modulo any power of two.

#### Examples

```ecl
4294967295 4294967295 *%
# => -8589934591
1103515245 4198498305 *% 12345 +% 4294967295 band
# => 1325825702
```

### \*file\*
`( -- string )` — Return the source name attached to the currently executing
reader-authored occurrence. A definition reports the file that authored its
body even when another file calls it. `` `domain `` in runtime-assembled code with
no source provenance; there is no fallback to the caller's file.

### \*module\*
``( -- `module-name )`` — Return the canonical registration name selected by
the current module activation. The same image registered under different names
reports the name through which it was called; an alias reports its target's
canonical name. `` `domain `` at top level, during module construction, or through
an escaped quotation whose image has no invoking registration.

### +
`( x y -- z )` — **Pervasive.** Add. Acts ordinally on chars:
`char int +` (either order) is a char; `char char +` is `` `type ``. Integer
overflow is `` `overflow ``.

#### Examples

```ecl
1 2 +
# => 3
```

### +%
`( x y -- z )` — **Pervasive.** Add integers modulo 2^64 in two's complement,
wrapping where `+` raises `` `overflow ``. Int-only: a float or a char is `` `type ``.

#### Examples

```ecl
9223372036854775807 1 +%
# => -9223372036854775808
```

### -
`( x y -- z )` — **Pervasive.** Subtract. Acts ordinally on chars:
`char char -` is an int, `char int -` is a char, `int char -` is `` `type ``.
Integer overflow is `` `overflow ``.

### -%
`( x y -- z )` — **Pervasive.** Subtract integers modulo 2^64 in two's
complement, wrapping where `-` raises `` `overflow ``. Int-only: a float or a char
is `` `type ``.

### /
`( x y -- z )` — **Pervasive.** Float division under IEEE rules: a nonzero
number over zero is an infinity signed by both operands, and `0 0 /` is
`` `domain `` (NaN).

### <
`( x y -- bool )` — **Pervasive.** Ascending comparison, producing 0/1
masks.

### <=
`( x y -- bool )` — **Pervasive.** Compare conforming values for less-than-or-equal order, producing boolean masks.

### <>
`( x y -- bool )` — **Pervasive.** Compare conforming values for inequality, producing boolean masks. On 0/1 masks this is xor; there is no separate word.

### =
`( x y -- bool )` — **Pervasive.** Equality; numbers compare numerically
across int and float. Whole-value equality is `match?`.

### >
`( x y -- bool )` — **Pervasive.** Descending comparison, producing 0/1
masks.

### >=
`( x y -- bool )` — **Pervasive.** Compare conforming values for greater-than-or-equal order, producing boolean masks.

### @attempt
`( values quotation -- result )` — *Unit constructor.* Initialize an isolated
substack from the explicit values list, then run the quotation as a new unit.
Use `[]` for no initial values. Always pushes exactly one result:
`{ok (values)}` with the successful stack values as a list, or
`{err <error dict>}`.

Observationally `@spawn task.await` — same result shape, same error protocol,
same self-contained-quotation contract — differing only in scheduling.
That identity is what makes the isolation non-arbitrary rather than an
implementation accident. The complete form is `values (q) @attempt`. See
Errors.

#### Examples

```ecl
[1 2] (3 +) @attempt
# => {ok [1 5]}
```

### @defm
``( values body `module-name -- )`` — *Unit constructor.* The one module
constructor. Validate the name first: a non-symbol is `` `type ``; an invalid
module path, the reserved name `core`, or a standard-library module name is
`` `domain ``, and the body never runs. Then run the body on a fresh environment
and publish the resulting image under the name. A body failure publishes
nothing; a registry change during construction may still refuse publication
after the body has run.

The name is last, matching `def` and `set`: the bound name sits nearest
the defining word. Registration is therefore ``values (body) `name @defm``. See
Modules.

### @give
`( ports values quotation -- task )` — *Unit constructor.* Like `@spawn`, and
additionally move every port in the ports list into the new unit, which owns
them from before it starts running: the child's end closes them and the
calling unit's end no longer does. The child stack is the given ports,
deepest, then the explicit values. Use `[]` for no ports, which is exactly
`@spawn`. Inside a module construction body, at any depth, this constructor
is `` `domain ``: a module body defines words and starts no tasks (see Modules).

Every kind of port can be given: listeners, connections, and process ports
alike. A port may only be given by the unit that owns it, so a unit holding a
port another unit owns cannot give it away; that is `` `domain ``, as is giving a
closed port or the same port twice. The move and the child's construction are
one step: the port is never unowned, and the child never runs before it owns
the port.

At most 16 ports may be given at once; more is `` `domain ``. That limit is
checked before the list's elements are examined, so an oversized list of
non-ports reports the limit rather than the element type. The ports list is
otherwise validated in order, and a list holding a non-port is `` `type ``.

Giving does not restrict use. The caller may still name a given port and read
or write it, exactly as a child may use a port its parent owns; what changed
is which unit's end closes it. See [Concurrency](SPEC.md#concurrency).

#### Examples

```ecl
{address "127.0.0.1" port 0} net.listen
wrap [] (net.local-address `port at 0 >) @give task.await
# => {ok [1]}
```

### @spawn
`( values quotation -- task )` — *Unit constructor.* Initialize a child stack
from the explicit values list and run the quotation concurrently. Use `[]` for
no initial values; the ambient stack never crosses the boundary. Inside a
module construction body, at any depth, this constructor is `` `domain ``: a module
body defines words and starts no tasks (see Modules). See
[Concurrency](SPEC.md#concurrency).

#### Examples

```ecl
[] (40 2 +) @spawn task.await
# => {ok [42]}
```

### @test
`( descriptor -- result )` — Test-Session-only protected invocation. Validate
a pure descriptor returned by `tests`, late-bind its module/name and optional
source identifier to
the current catalog, and run the body as a fresh isolated Unit under that
registration's private home and durable state. Return exactly
`{ok (values)}` or `{err error}`; a missing current test is a reified error.
Ordinary Sessions receive `` `domain ``.

### alias
``( `short `module-name -- )`` — Register an unqualified short registry name
for a canonical, possibly dotted module name.
Aliases and module names may not collide in either direction.

### args
`( -- arguments )` — The process arguments following the script or
source, as a list of strings.

### assert
`( bool error -- )` — Raise an error dict unless the condition is the boolean 1, discarding the dict when it holds. Defined in ecl.

### at
`( collection key -- value )` — Index a list or look up a dict key.
Pervades over nested list selectors, preserving their shape, so an index
vector selects: `[10 20 30] [2 0] at` is `[30 10]`. A dictionary key is
always one whole value, including when that value is a list. A missing dict
key is an error.

#### Examples

```ecl
[10 20 30] [2 0] at
# => [30 10]
```

### at-path
`( ds l -- x )` — Repeatedly index nested lists and dicts by each key or index in the path, left to right; an empty path returns `ds` unchanged.

### atan2
`( y x -- z )` — **Pervasive.** Two-argument arctangent; returns float.

### band
`( x y -- z )` — **Pervasive.** Bitwise and over the two's-complement bit
patterns of ints. Non-int leaves are `` `type ``.

### bi2
`( x y p q -- ... )` — *Inline.* Binary cleave: apply each of two quotations to the same pair of input values.

### bnot
`( x -- y )` — **Pervasive.** Invert every bit. `bnot bnot` is identity;
`0 bnot` is `-1`.

### bor
`( x y -- z )` — **Pervasive.** Bitwise or. See `band`.

### both
`( x y q -- ... )` — *Inline.* Apply one quotation independently to each of two input values, `x` first.

### bsl
`( x count -- y )` — **Pervasive.** Shift the bit pattern left by `count`
places, truncating bits shifted off the top rather than raising
`` `overflow ``: `maxint 1 bsl` is `-2`. A `count` outside `0..63` is
`` `domain ``.

### bsr
`( x count -- y )` — **Pervasive.** Shift the bit pattern right by
`count` places, filling zeros from the top. The logical shift makes `-1 1 bsr`
produce `maxint`. A `count` outside `0..63`
is `` `domain ``.

### bxor
`( x y -- z )` — **Pervasive.** Bitwise exclusive or. On 0/1 masks `<>`
does the same job on any leaf type; `bxor` is for whole patterns.

### bytes
`( value -- bytes )` — Encode a string as UTF-8 into a byte list: an integer
list whose elements are 0 through 255. A byte list is returned unchanged, so
the word is idempotent. Any other value is `` `type ``. Inverse of `chars`; see
[Conversions](SPEC.md#conversions).

#### Examples

```ecl
"hé" bytes
# => [104 195 169]
```

### call
`( q -- ... )` — *Inline.* Run a quotation on the current stack. A data
list pushes its elements.

### cat
`( left right -- list )` — Concatenate two lists.

### ceil
`( x -- integer )` — **Pervasive.** Round up; the result is int64,
`` `overflow `` outside its range.

### char
`( value -- char )` — Return a char unchanged, the char with an int's codepoint,
or the single char of a one-char string. An int outside the Unicode scalar
range or a string of any other length is `` `domain ``; any other value is `` `type ``.

#### Examples

```ecl
955 char
# => \λ
```

### chars
`( value -- string )` — Return a value's text content as a string: a string
unchanged, the spelling of a symbol, a char as a one-element string,
or a byte list decoded as UTF-8. Bytes that are not valid UTF-8 are `` `domain ``
with `` `reason `invalid-utf8 ``; a list that is neither a string nor a byte list,
or any other kind, is `` `type ``. Unlike `str`, the result is content rather than
representation: `` `foo chars `` is `"foo"`, not `"'foo"`. See
[Conversions](SPEC.md#conversions).

#### Examples

```ecl
`foo chars [104 195 169] chars
# => "foo" "hé"
```

### cmp
`( left right -- ordering )` — Three-way whole-value ordering, −1/0/1;
**not** pervasive — `cmp` is to `<` what `match?` is to `=`. Domain:
numbers (exact across int/float), chars by codepoint, and lists, which
compare lexicographically: corresponding elements by `cmp` until the first
nonzero result, then by length. Strings are char lists, so they order by
codepoint. Anything else, including cross-kind pairs, is `` `type ``; elements
after the first difference are never compared. Equivalent on two lists to
`(cmp) lex-cmp-with`. `cmp` exists because the subtraction idiom is unsafe
for ordering: `-` errors on int64 overflow where an ordering must be total.

#### Examples

```ecl
[1 2] [1 3] cmp [["b" 1]] [["a" 2]] cmp [1] [1 0] cmp
# => -1 1 -1
```

### collect
`( quotation -- list )` — Run a quotation on an empty isolated stack and return what it leaves as a list, preserving order. The quotation cannot see values beneath it.

#### Examples

```ecl
9 (1 2 3 +) collect
# => 9 [1 5]
```

### cond
`( clauses -- ... )` — *Inline.* The clause list is flat, nonempty, and
odd: `[test action … else]`, all quotations. The whole list is validated
before the first test runs (empty or even lists are `` `shape ``; a non-list
or non-quotation member is `` `type ``). Every test runs against the operand
stack checkpoint taken after the clause list is consumed. Tests may inspect
that stack destructively; only their top result is interpreted, and it must
be a 0/1 boolean. The complete test result is then discarded. The first true
test selects its action; otherwise the final else runs, in either case from
the original checkpoint. Stack rollback does not roll back environment or IO
effects performed by tests.

#### Examples

```ecl
10 20 [(pop 10 =) (pop pop 111) (pop pop 222)] cond
# => 111
```

### cons
`( value list -- list )` — Raw structural prepend. On data,
`1 [2 3] cons` is `[1 2 3]`. On code it inserts a form: a prepended word
executes when the result is called, so `cons` is not safe partial
application — that is `partial`.

### cos
`( x -- y )` — **Pervasive.** Cosine; float transcendental.

### cut
`( list starts -- pieces )` — Split a list into one piece per start index.
Each piece runs from its start up to the next start, and the last runs to
the end of the list; elements before the first start belong to no piece.
Starts must be integers from zero through the length, in nondecreasing
order, so equal starts give empty pieces. A start out of range or below its
predecessor fails with `` `domain `` at that start's position. Strings cut into
strings.

#### Examples

```ecl
[0 1 2 3 4 5 6] [0 2 5] cut
# => [[0 1] [2 3 4] [5 6]]
"hello world" [6] cut
# => ["world"]
```

### def
``( annotation? body `name -- )`` — Bind a quotation to a public word, with
optional effect and documentation metadata. See
[Definition annotations](SPEC.md#definition-annotations) for the annotation
forms and validation; see [Modules](SPEC.md#modules) for module-context
requirements.

### defp
``( annotation? body `name -- )`` — Bind a private module word, with
optional effect and documentation metadata. A top-level `defp` is an
error.

### del
`( collection selector -- collection )` — Functionally remove list positions
through a pervasive selector, or one whole-value dictionary key. List selector
leaves are nonnegative in-bounds integer positions in the original list;
duplicates remove a position once, and the relative order of retained elements
is unchanged. An empty selector returns the list unchanged. A missing
dictionary key leaves the dictionary unchanged. Use `dict.del` to remove a
list of whole dictionary keys.

### distinct
`( list -- list )` — First occurrence of each distinct value, in input
order. Equivalent to `group dict.keys`.

### div
`( x y -- z )` — **Pervasive.** Checked integer division. Division by
zero is `` `domain ``.

### doc
``( `name -- string )`` — Return the canonical documentation string of a
resolved binding. Missing documentation is `` `domain ``.

### drop
`( list count -- list )` — Remove `count` elements from the front, or
from the end when negative. (The stack word is `pop`.)

### dup
`( x -- x x )` — Duplicate the top stack value.

### each
`( collection quotation -- collection )` — *Isolated*, contract `( a -- b )`.
For a list, apply one level down the leading axis, exactly one result per
element; the result specializes when rectangular. For a dictionary, apply to
its values in insertion order while preserving its keys. Depth composes by
nesting: `((q) each) each`. There is no collect-all map whose output length
follows dynamic stack behavior: filtering is the mask idiom (or `filter`), and
flat-map is `each raze`. Derived verbs come free from homoiconicity:
``((1 +) each) `inc-all def``.

#### Examples

```ecl
[1 2 3] (dup *) each
# => [1 4 9]

{a 1 b 2} (1 +) each
# => {a 2 b 3}
```

### each-prior
`( list seed quotation -- list )` — *Isolated*, contract `( current prior -- result )`. Apply the quotation to each element and its predecessor, left to right, using the explicit seed as the predecessor of the first element. Thus `[12 13 11] 10 (-) each-prior` is `[2 1 -2]`. Defined in ecl over `zip-with`.

### empty?
`( sequence -- bool )` — Return 1 when a sequence has no elements and 0 otherwise.

### execute
`( symbol -- ... )` — Resolve and apply a symbol late through the ordinary
word-dispatch path, exactly as if that symbol appeared in executable position.
Non-symbols are `` `type ``; missing words are `` `undefined-word ``. Module homes,
private resolution, annotations, tracing, builtins, native calls, and
cancellation are preserved.

### exit
`( status -- )` — Root-only outside `@attempt` (`` `domain `` otherwise):
cancel and quiesce all descendants, then terminate the process with the
given status.

### exp
`( x -- y )` — **Pervasive.** Natural exponential; float transcendental.

### first
`( list -- value )` — Return the first element of a nonempty list; an empty
list is `` `domain ``. A kernel builtin rather than a prelude word, because the
reader's quote `` `x `` expands to `(x) core.first` and the prelude's own first
quote runs before any prelude word exists.

```ecl
(dup swap) first
# => dup
```

### flip
`( list -- list )` — Exchange the first two axes of a list of equally
wide rows. Cells are preserved whole: strings, nested lists, dictionaries,
and mixed values need not share a type or shape. Only the immediate row
lengths must agree. Strings used as rows transpose their characters.

An empty list or a list containing no list items is unchanged. Mixing list
rows with non-list items, unequal row lengths, or nonempty collections of
zero-width rows raises `` `shape ``; the last case cannot retain the other axis
after transposition. A non-list argument raises `` `type ``.

```ecl
(["a" "long"] ["bc" "d"]) flip
# => (("a" "bc") ("long" "d"))
["ab" "cd"] flip
# => ("ac" "bd")
```

### float
`( value -- float )` — Return a float unchanged, an int as a float, or the
value of a string in the numeric-literal grammar. A string outside that grammar
is `` `parse ``; any other value is `` `type ``.

#### Examples

```ecl
"2.5e1" float 3 float
# => 25.0 3.0
```

### floor
`( x -- integer )` — **Pervasive.** Round down; the result is int64,
`` `overflow `` outside its range.

### fold
`( list accumulator quotation -- accumulator )` — *Isolated*, contract
`( acc a -- acc )`. Reduce left-to-right from the supplied accumulator.

#### Examples

```ecl
[1 2 3 4] 0 (+) fold
# => 10
```

### for
`( collection quotation -- )` — *Isolated*, contract `( a -- )`. Apply to list
elements or dictionary values in insertion order, left-to-right, collecting
nothing.

### getenv
`( name -- string )` — The value of an environment variable, read from an
immutable snapshot taken once at session start. An unset variable is an
error, never a blank: absence is absence, and `@attempt`/`or-else` is the
defaulting idiom. Absent host IO is `` `io ``.

### grade
`( list -- indices )` — The stable ascending sort permutation. Orders by
`cmp`, so every element pair must be mutually comparable; the error's index
names the later element of a pair that is not.

#### Examples

```ecl
[3 1 2] grade
# => [1 2 0]
```

### group
`( list -- dict )` — Dict from each distinct value to the list of its
0-based indices, keyed in first-occurrence order.

#### Examples

```ecl
[a b a] group
# => {a [0 2] b [1]}
```

### group-columns
`( columns -- groups )` — Group rows from a nonempty list of equal-length
columns. Keys are whole composite lists, in first-occurrence order; row indices
within each group are ascending. Zero rows produces an empty dictionary.
An empty column list or ragged columns raises `` `shape ``; non-list columns raise `` `type ``.

### if
`( bool then else -- ... )` — *Inline.* Run `then` when the condition is 1,
`else` when it is 0; any other condition value is `` `type ``.

### import
`( module-name q -- )` — Import the public attributes named by the symbol list
`q` under their own unqualified names: `` `str (upper lower) import `` binds
`upper` and `lower`. Every requested name is validated against one module
generation before any binding is published; a missing or private attribute is
`` `undefined-word `` and publishes none of the request. A non-list `q` or a
non-symbol item is `` `type ``; an invalid module or attribute name is `` `domain ``.
Each imported binding dispatches through the module, preserves the original's
effect and documentation, and may replace an existing local binding. `see`
renders its one-word forwarding quotation.

### in?
`( value list -- bool )` — Membership. Pervades over the sought value —
the left operand, never the list — down to its atoms; each atom is then
tested by whole-value `match?` against the list's top-level elements, so
the result takes the sought value's shape: `[2 5] [1 2 3] in?` is
`[1 0]`. The list is only ever read one level deep, and a list operand
is decomposed before any comparison, so `in?` cannot ask whether a
sublist is an element: `[1 1] [[0 0] [1 1]] in?` is `[0 0]`, the results of
two atom searches. Use `([1 1] match?) any?` for
that.

#### Examples

```ecl
[2 5] [1 2 3] in?
# => [1 0]
```

### infra
`( list quotation -- list )` — *Isolated*, contract unconstrained. Run
the quotation with the list's elements as the entire substack; the
substack that remains is the result list.

#### Examples

```ecl
[1 2 3] (dup) infra
# => [1 2 3 3]
```

### int
`( value -- int )` — Return an int unchanged, a char's codepoint, or the value
of a string in the integer-literal grammar. A string outside that grammar is
`` `parse ``. A float is `` `type ``: choose `floor`, `round`, or `ceil` instead. Any
other value is also `` `type ``.

#### Examples

```ecl
"42" int "a" first int
# => 42 97
```

### intern
`( value -- symbol )` — Return a symbol unchanged, or create the symbol for
a string, interning the spelling when it is new. A string that is not a valid
symbol spelling is `` `domain ``; any other value is `` `type ``. Interned names
live for the whole process and are never reclaimed, so never apply this to
unbounded external input; `symbol` is the lookup-only form. The symbol links
to the root of the activation that built it. See
[Conversions](SPEC.md#conversions).

#### Examples

```ecl
"fresh-name" intern
# => fresh-name
```

### join
`( strings separator -- string )` — Join a list of strings with a
separator string.

### last
`( sequence -- value )` — Return the final element of a nonempty sequence.

### len
`( list -- count )` — Top-level list element count. Lists may be ragged.
Dictionary entry count is provided by `dict.size`.

### linrec
`( predicate base pre post -- ... )` — *Inline.* Explicit linear recursion.
At each descent, run `predicate` destructively against a retained checkpoint
of the complete visible operand stack. Its top result must be a 0/1 boolean
and its complete stack result is discarded. On 1, restore the checkpoint and
run `base`. On 0, restore it and run `pre`, recurse from `pre`'s resulting
stack, then run `post`. Environment and IO effects from the predicate survive
restoration. All four quotations run in the invoking application context and
communicate through ambient stack state. Non-tail recursion retains one
explicit continuation per descent rather than using the host stack; its live
storage is proportional to recursion depth.
An empty `post` quotation does not eliminate the retained recursion level.

### load
`( path -- )` — Read and evaluate a source file as one transactional unit
in the calling session.

### log
`( x -- y )` — **Pervasive.** Natural logarithm; float transcendental.
Edges follow the Numbers rules: `0 log` is `-inf`, `-1 log` is `` `domain ``
(NaN).

### match?
`( left right -- bool )` — Whole-value structural equality; **not**
pervasive. `[1 2] [1 2] =` is `[1 1]`; `[1 2] [1 2] match?` is `1`.

#### Examples

```ecl
[1 2] [1 2] match?
# => 1
```

### max
`( x y -- z )` — **Pervasive.** The greater of two comparable atoms.

### max-of
`( sequence -- value )` — Return the greatest element of a nonempty sequence.

### min
`( x y -- z )` — **Pervasive.** The lesser of two comparable atoms.

### min-of
`( sequence -- value )` — Return the least element of a nonempty sequence.

### neg
`( x -- y )` — **Pervasive.** Negate numeric values with checked integer overflow.

### nip
`( x y -- y )` — Discard the value immediately beneath the top of the stack.

### not
`( bool -- bool )` — **Pervasive.** Invert 0/1 values.

### pack
Takes `x₁ … xₙ n` and leaves a list. Collect the top `n` values into a list, preserving their order; `n` must be a nonnegative int. Deliberately state-dependent stack surgery.

#### Examples

```ecl
1 2 3 3 pack
# => [1 2 3]
```

### pair
`( first second -- list )` — Collect two stack values into a two-element list in stack order.

### parse
`( string -- quotation )` — The reader, reified: parse source text into
an unevaluated quotation. Reading interns every symbol and word in the text,
so this is a load-class word for trusted source, not a conversion: use `int`,
`float`, and `symbol` on data.

#### Examples

```ecl
"[1 2]" parse first
# => [1 2]
```

### pop
`( x -- )` — Discard the top stack value. (`drop` is the sequence word.)

### pow
`( x y -- z )` — **Pervasive.** Exponentiation; returns float.

### put
`( collection selector value -- collection )` — Functional replacement.
For a list collection, a nested list selector is pervasive and replacement
lists conform recursively to its shape; an atomic replacement extends across
every selected position. Selector leaves are integer indices. Repeated indices
are processed left to right, so the last replacement wins. For a dictionary,
the selector is always one whole-value key, including a list key.

#### Examples

```ecl
[10 20 30] [0 2] 99 put
# => [99 20 99]
```

### qualify
``( `module-name `binding-name -- qualified-word )`` — Validate a canonical
module path, or the reserved qualifier `` `core ``, and one unqualified,
non-reserved binding segment, then construct their qualified executable word
directly from the interned components. It does not parse source, intern
anything new, or grant lifecycle authority; use `execute` to
invoke the result dynamically. `` `core `dup qualify `` reaches the primitive even
where `dup` is shadowed.

### raise
`( error -- )` — Raise a language error from an error dict.

### range
`( bound -- list )` — The ints `[0 1 … bound-1]`; the bound must be a
nonnegative int.

#### Examples

```ecl
5 range
# => [0 1 2 3 4]
```

### raze
`( list -- list )` — Flatten one level. Flat-map is `each raze`.

### reduce-groups
`( values groups reducer -- results )` — Reduce each top-level index list,
preserving group and index order, including repeated indices. Reducer symbols
are `` `sum ``, `` `count ``, `` `min ``, and `` `max ``. Sum uses checked numeric
addition from zero, left to right; count accepts any selected value. Min/max
use whole-value comparison and preserve the first value on ties. Empty groups
yield zero for sum/count and raise `` `domain `` for min/max. Noninteger selectors
raise `` `type ``; negative or out-of-range indices and unknown symbols raise
`` `domain ``. Built-in reducer meanings do not depend on word bindings.

### reshape
`( list shape -- list )` — Cycle the data into the exact nested-list
shape; a zero axis must be final.

#### Examples

```ecl
[1 2 3 4] [2 3] reshape
# => [[1 2 3] [4 1 2]]
```

### rest
`( list -- list )` — Return all but the first element of a nonempty list.

### reverse
`( list -- list )` — Return a list with its top-level element order reversed. Defined in ecl as an index permutation.

### rotate
`( list count -- list )` — Rotate top-level element order left by a
count, wrapping cyclically; a negative count rotates right, counts
beyond the length wrap, and the empty list is returned unchanged.
Native: a cyclic copy of the whole list (APL/J's dyadic reverse; K
composes it from an index permutation). The count must be an int.

#### Examples

```ecl
[1 2 3 4 5] 2 rotate
# => [3 4 5 1 2]
```

### round
`( x -- integer )` — **Pervasive.** Round to nearest; the result is
int64, `` `overflow `` outside its range.

### scan
`( list accumulator quotation -- list )` — *Isolated*, contract
`( acc a -- acc )`. Like `fold` but returns every intermediate
accumulator; same length as the input.

#### Examples

```ecl
[1 2 3 4] 0 (+) scan
# => [1 3 6 10]
```

### see
``( `name -- )`` — Print the binding's combined annotation, when present,
followed by its body through the standard source formatter, with its
width-aware layout and no navigation header, name, or `def`/`defp` terminator.
What prints is what is stored: a name bound by `set` prints its annotation and
literal-capture body; the producing `set` spelling is discarded.
Reader-built bodies retain a shared slice of their source unit, so locals declarations
print with their authored local names even though execution uses the lowered
`_ll`/`_gl`/`_dl` quotation. Runtime-constructed bodies without source
provenance fall back to their canonical value form. Native origins are
displayed in native body descriptors.

### shape
`( list -- shape )` — The dimensions of rectangular data; `` `shape `` error
on ragged data (`len` is the word that works on anything).

### signum
`( number -- sign )` — **Pervasive** by composition. Return the int −1, 0, or 1 according to the sign of a number.

### sin
`( x -- y )` — **Pervasive.** Sine; float transcendental.

### sort
`( sequence -- sorted )` — Return a stable ascending sort of a sequence by `cmp`.

#### Examples

```ecl
[3 1 2] sort
# => [1 2 3]
```

### split
`( string separator -- parts )` — Split a string at every occurrence of a
separator string; the parts are strings. An empty separator splits the input
into one single-codepoint string per Unicode scalar, with no empty boundary
parts; splitting an empty string this way returns an empty list.

#### Examples

```ecl
"a,b,c" "," split
# => ("a" "b" "c")
```

### sqrt
`( x -- y )` — **Pervasive.** Square root. `` `domain `` on negative inputs
(the result would be NaN).

### stencil
`( list width quotation -- list )` — *Isolated*, contract
`( window -- result )`. Apply to each overlapping window of a positive int
width, left-to-right. A width larger than the input returns `()` without
applying the quotation; zero and negative widths are `` `domain ``. The result
has `max(len-width+1, 0)` elements.

#### Examples

```ecl
[1 2 3 4] 3 (sum) stencil
# => [6 9]
```

### str
`( value -- string )` — The canonical printed representation; carries the
round-trip guarantee (see
[Readable representations and display](SPEC.md#readable-representations-and-display)):
reading it back yields a structurally matching value for every recursively
readable value.

#### Examples

```ecl
"abc" str
# => "\"abc\""
```

### swap
`( x y -- y x )` — Exchange the top two stack values.

### symbol
`( value -- symbol )` — Return a symbol unchanged, or the already-interned
symbol whose spelling a string names. A spelling that is not yet interned is
`` `domain ``, as is a string that is not a valid symbol spelling; any other
value is `` `type ``. Every symbol written in loaded source is interned, so this
succeeds for any key a program compares against and never grows the interned
name space; use `intern` to create one. The symbol links to the root of the
activation that built it, so `"dup" symbol wrap` executes the same `dup` as
`(dup)` written there. See
[Conversions](SPEC.md#conversions).

#### Examples

```ecl
"foo" symbol `foo match?
# => 1
```

### take
`( list count -- list )` — The first `count` elements; a negative count
takes from the end. When the magnitude exceeds the length, the data
cycles.

#### Examples

```ecl
[1 2 3] 5 take
# => [1 2 3 1 2]
```

### test
``( annotation? body `name -- )`` — Declare a first-class test in the separate
catalog of the exact direct module construction body. Accepts the same optional
effect and documentation annotation forms as `def`. Tests may share names with
words and are absent from application lookup, exports, imports, reflection,
and module invocation. Top-level, nested-quotation, and child-Unit use is
`` `domain ``. Application Sessions validate and discard declarations without
retaining bodies or checking duplicate test names; Test Sessions retain them
and reject duplicate names.

### tests
`( -- descriptors )` — Test-Session-only discovery of current canonical
registrations, including root sources' private registrations, sorted by module
then test name and source identifier. Each dictionary contains
symbol fields `` `module `` and `` `name `` plus optional declared `` `effect `` and
`` `doc ``. File-private registrations also include an integer `` `source `` identifier
local to the test Session, distinguishing equal names in different files.
Descriptors never contain executable bodies or authority handles. Aliases do
not duplicate entries. Ordinary Sessions receive `` `domain ``.

### times
`( n q -- ... )` — *Inline.* Run the quotation `n` times; `n` must be a
nonnegative int. Tail-call optimized.

### tri2
`( x y p q r -- ... )` — *Inline.* Binary cleave: apply each of three quotations to the same pair of input values in left-to-right order.

### type
`( value -- type )` — Return the value's kind as a symbol: one of `int`,
`float`, `char`, `symbol`, `list`, `dict`, `task`, `port`, or `address`.

#### Examples

```ecl
"abc" type
# => list
```

### undef
`( name -- )` — Remove a direct binding from the current scope, or do nothing
when that scope does not bind the name. An exact alias of `unset`; removing a
local shadow may reveal a parent or core binding.

### undefm
``( `module-name -- )`` — Remove the module currently registered under a
canonical name or unqualified alias, resolved exactly as ordinary registry
lookup resolves it. An unregistered name is `` `undefined-word ``. Removal strips
every alias targeting the module in the same publish; an already-dispatched
call finishes under the generation it resolved. See
[Modules](SPEC.md#modules).

### unfold
`( state predicate step -- state list )` — *Isolated*. Before every step,
apply the predicate under contract `( state -- bool )`. When it returns 0,
return the current state and all generated items. When it returns 1, apply
the step under contract `( state -- state item )`, append the item, and
continue from the returned state. The predicate is therefore always checked
before the first step, and a false initial predicate returns the initial
state and `()`.

#### Examples

```ecl
0 (5 <) (dup 1 + swap) unfold pair
# => (5 [0 1 2 3 4])
```

### unless
`( bool else -- ... )` — *Inline.* Call the quotation when the condition is the boolean 0; otherwise do nothing.

### unset
`( name -- )` — Remove a direct binding from the current scope, or do nothing when that scope does not bind the name. An exact alias of `undef`; removing a local shadow may reveal a parent or core binding. Defined in ecl.

### update
`( collection selector quotation -- collection )` — Apply an isolated
`( value -- value )` quotation at the selected positions. A list collection's
selector pervades with the same nested shape as `at` and is processed left to
right, so repeated indices observe earlier updates. A dictionary selector is
one whole-value key. The entire selector is validated before the quotation is
first applied; an empty selector returns the list unchanged without applying
it.

#### Examples

```ecl
[1 2 3] [2 0] (10 *) update
# => [10 2 30]
```

### when
`( bool then -- ... )` — *Inline.* Call the quotation when the condition is the boolean 1; otherwise do nothing.

### where
`( counts -- indices )` — Expand a list of nonnegative ints into each
index replicated its count times. A 0/1 mask is the common case, yielding
the positions of 1s: `[0 1 1 0] where` is `[1 2]`.

#### Examples

```ecl
[0 2 1] where
# => [1 1 2]
```

### which
``( `name -- )`` — Print where a name resolves (module home, shadowing),
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

### windows
`( list width -- windows )` — Return every overlapping window of a positive width.

#### Examples

```ecl
[1 2 3 4] 3 windows
# => [[1 2 3] [2 3 4]]
```

### words
`( -- )` — Print the visible dictionary in sorted order.

### wrap
`( value -- list )` — Wrap one value in a one-element list.

### zip-with
`( left right quotation -- list )` — *Isolated*, contract `( a b -- c )`.
Zip two lists with broadcast conformability (an atom on either side
extends). Each-left/each-right are `partial` compositions.

#### Examples

```ecl
[1 2 3] [10 20 30] (+) zip-with
# => [11 22 33]
```

### abs
`( x -- y )` — **Pervasive.** Return absolute numeric values with checked integer overflow. Defined in ecl; `` `abs see `` renders the definition.

### append
`( sequence value -- sequence )` — Append one value to the end of a sequence.

### compose
`( left right -- quotation )` — Concatenate two quotations in execution order.

### literal
`( value -- quotation )` — Return a plain quotation that pushes the exact captured value as inert data when called, without executing or resolving it.

Every value but a symbol already pushes itself when run, so the result is `(x)`. A symbol would execute, so it is quoted as `((x) core.first)`, the quote's own expansion.

### scan1
`( list quotation -- list )` — *Isolated*, contract `( acc a -- acc )`. Return a nonempty list's first element followed by the successive accumulator values from reducing its remaining elements. Defined in ecl over `scan`.

### uncons
`( list -- first rest )` — Split a nonempty list into its first element and remaining elements.

### zip
`( left right -- pairs )` — Pair corresponding elements of two conforming sequences.

### dip
`( x q -- ... )` — *Inline.* Run a quotation beneath a protected top stack value: `q` runs with `x` removed, then `x` returns on top of its results.

### fail
`( msg -- )` — Raise a user-kind error whose message is the supplied value: `{kind user msg msg}`. Defined in ecl.

### from-digits
`( digits base -- value )` — Combine digits, most significant first, into a value. The base is one integer for every position, or a list of radices with one per digit, as in mixed-radix time; the first radix has no effect. Digits pervade: a list of equal-length digit lists, one per position, gives one value per column. A radix list of the wrong length fails with `` `shape ``. Inverse of `to-digits` for values in range.

#### Examples

```ecl
[1 0 1] 2 from-digits
# => 5
[[1 0] [0 1] [1 1]] 2 from-digits
# => [5 3]
[1 2 3] [24 60 60] from-digits
# => 3723
```

### iterations
`( value count quotation -- list )` — *Isolated*, unary contract `( a -- a )`. Return the initial value followed by `count` successive quotation applications. `count` must be a nonnegative int, and a zero count returns a singleton list. Defined in ecl over `scan`.

#### Examples

```ecl
1 3 (10 +) iterations
# => [1 11 21 31]
```

### partial
`( value quotation -- quotation )` — Safe partial application: return a quotation that pushes an inert captured value before running another quotation. Even a captured word remains data. `3 (+) partial` is `(3 +)`, and a captured word `w` is prefixed as `((w) first)`.

#### Examples

```ecl
4 3 (+) partial call
# => 7
```

### set
Takes an optional annotation, a value, and a name, and leaves nothing. Bind the value as a constant word in the current scope. Reference applies the constant's body and pushes the exact captured value, quotations included. Defined in ecl as `swap literal swap def`, so `v `name set` is observationally `v literal `name def`: the stored body is `((v) first)`. An optional annotation beneath `v` is published as the constant's metadata; marker words inside `v` are nested by `literal` and remain captured data.

### setp
Takes an optional annotation, a value, and a name, and leaves nothing. Bind the value as a private module constant word; an optional annotation may precede the value. Defined in ecl as `swap literal swap defp`. A top-level `setp` is an error, raised by the `defp` it calls.

### unappend
`( list -- initial last )` — Split a nonempty list into its initial elements and last element.

### while-values
`( value predicate step -- list )` — *Isolated*, contracts `( state -- bool )` and `( state -- state )`. Return the initial value and successive states through the first state for which the predicate is false. Defined in ecl over `unfold`.

#### Examples

```ecl
1 (5 <) (1 +) while-values
# => [1 2 3 4 5]
```

### and
`( x y -- bool )` — **Pervasive.** Compute boolean conjunction over 0 and 1 values. Both operands are already evaluated; there is no short-circuiting. Defined in ecl.

### clamp
`( value lower upper -- bounded )` — **Pervasive** by composition. Constrain a value to the inclusive interval between lower and upper.

### find
`( sequence needle -- index )` — Return the index of the first element that returns 1 from `match?` against the needle, or the sequence length when no element matches. Defined in ecl.

### or
`( x y -- bool )` — **Pervasive.** Compute boolean disjunction over 0 and 1 values. Both operands are already evaluated; there is no short-circuiting. Defined in ecl.

### over
`( x y -- x y x )` — Copy the value beneath the top of the stack onto the top.

### rolldown
`( x y z -- y z x )` — Rotate the top three stack values downward, from x y z to y z x.

### rollup
`( x y z -- z x y )` — Rotate the top three stack values upward, from x y z to z x y.

### with
`( values quotation -- quotation )` — Return a quotation that pushes every value from a list, in order and inertly, before running another quotation. Calling the result starts with the list's elements as separate stack values. Defined in ecl as `((literal) each) dip append raze`.

This is ordinary quotation composition and constructs nothing. It is not a unit's seed operand: the flattened quotation it returns is a runtime-built body, so `@defm` gives it no reader attribution. Unit constructors instead take their initial values and body as two separate operands, preserving the exact body for attribution.

#### Examples

```ecl
[3] (dup) with call
# => 3 3
```

### @each
`( sequence values quotation -- results )` — *Unit constructor*, one fresh unit per element, contract `( a -- b )` enforced per element. Concurrent `each`: apply a quotation in one fresh unit per element and return one result per element in input order. Each child's stack starts with its element deepest; `list values (q) @each` adds the shared values above it. Results are joined in order; the leftmost failure cancels every later task, waits for them to quiesce, and is re-raised. Defined in ecl over `@spawn`, `task.await`, and `task.cancel`. Inside a module construction body, at any depth, this constructor is `` `domain ``: a module body defines words and starts no tasks (see Modules). See Concurrency.

### all?
`( sequence predicate -- bool )` — *Isolated*, contract `( a -- bool )`. Return 1 when the predicate returns 1 for every element; otherwise return 0.

#### Examples

```ecl
[2 4 6] (2 mod 0 =) all?
# => 1
```

### any?
`( sequence predicate -- bool )` — *Isolated*, contract `( a -- bool )`. Return 1 when the predicate returns 1 for at least one element; otherwise return 0. The predicate runs on every element; there is no early exit.

### converges
`( value quotation -- list )` — *Isolated*, unary contract `( a -- a )`. Return the initial value and successive applications until the next value is structurally equal to either the initial or immediately preceding value; that repeated boundary value is not appended. Defined in ecl over `unfold`.

### filter
`( sequence predicate -- matches )` — *Isolated*, contract `( a -- count )`. Apply the predicate to every element, retaining each element as many times as its returned nonnegative int. A 0/1 predicate is ordinary filtering.

#### Examples

```ecl
[1 2 3 4] (2 mod 0 =) filter
# => [2 4]
```

### fold1
`( list quotation -- value )` — *Isolated*, contract `( acc a -- acc )`. Reduce a nonempty list left to right from its first element rather than from an explicit accumulator; an empty list requires `fold`. Defined in ecl.

### keep
`( x q -- ... )` — *Inline.* Apply a quotation to a value, then restore the value on top of the quotation's results.

### lex-cmp-with
`( left right comparator -- order )` — Compare two sequences lexicographically with an inline `( left-element right-element -- order )` comparator that returns −1, 0, or 1. The comparator runs only through the first differing pair; when the shared prefix is equal, the sequences are ordered by length. Defined in ecl.

### mod
`( x y -- z )` — **Pervasive.** Compute checked integer remainders.

### partition
`( sequence predicate -- matches rejects )` — *Isolated*, contract `( a -- bool )`. Split a sequence into the elements whose predicate returned 1 and those that returned 0. Defined in ecl.

#### Examples

```ecl
[1 2 3 4] (2 mod 0 =) partition pair
# => [[2 4] [1 3]]
```

### bi
`( x p q -- ... )` — *Inline.* Apply two quotations to the same input, first `p`, then `q`, leaving `p`'s results beneath `q`'s.

### case
`( x clauses -- ... )` — *Inline.* Select and call the first action whose key matches the subject. The clause list is flat, nonempty, and odd: `[key action … else]`. Keys are inert data: any value, never executed, with duplicates legal and the first `match?` result of 1 winning. Every action and the else must be a quotation, and all of them are validated before any comparison or user quotation runs. When no key matches, the else runs. Defined in ecl; `` `case see `` renders the definition.

#### Examples

```ecl
3 [1 ("one") 3 ("three") ("other")] case
# => "three"
```

### chunk
`( list size -- pieces )` — Split a list into consecutive pieces of a positive size; the last piece is shorter when the size does not divide the length.

#### Examples

```ecl
[0 1 2 3 4 5 6] 3 chunk
# => [[0 1 2] [3 4 5] [6]]
```

### converge
`( value quotation -- value )` — *Isolated*, unary contract `( a -- a )`. Return the last value before repeated application reaches a fixed point or returns to the initial value.

### product
`( sequence -- product )` — Multiply every element of a numeric sequence; 1 when the sequence is empty. A nonempty sequence's product starts from its first element, so a list of rows multiplies to a row.

### sum
`( sequence -- total )` — Add every element of a numeric sequence; 0 when the sequence is empty. A nonempty sequence's total starts from its first element: a list of rows sums to a row, and a sum of negative zeros is `-0.0`.

#### Examples

```ecl
[1 2 3] sum
# => 6
[[1 2] [3 4]] sum
# => [4 6]
[] sum
# => 0
```

### to-digits
`( value radices -- digits )` — Split a value into one digit per radix, most significant first, by floor division, so every digit lies from zero below its radix even for negative values. A value beyond the radices' capacity keeps only its low digits. Values pervade: a list of values gives one digit list per radix. Radices must be positive integers, or the word fails with `` `domain ``; `[2] 8 take` builds eight binary radices.

#### Examples

```ecl
13 [2 2 2 2] to-digits
# => [1 1 0 1]
3723 [24 60 60] to-digits
# => [1 2 3]
-7 [10 10] to-digits
# => [9 3]
```

### tri
`( x p q r -- ... )` — *Inline.* Apply three quotations to the same input in left-to-right order.

### mean
`( sequence -- mean )` — Return the arithmetic mean of a nonempty numeric sequence.

## agent

An agent is a task whose stack is its state. Quotations sent to it run in
arrival order, each as an isolated unit over that stack, so a failing
quotation leaves the state exactly as it was. A `call` quotation is
`( state... -- state... result )`: the top of its result stack is the reply and
the rest is the new state. A `send` quotation is `( state... -- state... )` and
keeps its whole result stack. This is how a program keeps state that outlives
a word, for example an ambient random generator:

```ecl
[0 0] agent.start `rng set
(5 rand.int) rng agent.call
# => 0
```

A call to an agent that has ended raises `` `io ``. A call whose request was
accepted waits forever if the agent ends before replying, unless it bounds the
call with `call-for`.

### send
`( quotation address -- )` — Apply a quotation to the agent's stack without waiting for a reply. The whole result stack becomes the new state; a failing quotation changes nothing and reports nothing.

### call
`( quotation address -- result )` — Apply a quotation to the agent's stack and return the top of the result stack; the agent keeps the rest. The quotation's own error is re-raised here and leaves the agent unchanged. A result stack with nothing on it is `` `domain ``. Replies travel through a helper task. A call to an agent that has ended raises `` `io ``; a call whose request was accepted never returns if the agent ends before replying.

#### Examples

```ecl
[0 0] agent.start `g set
(100 rand.int) g agent.call (100 rand.int) g agent.call pair
# => [35 0]
[7 0] agent.start `g set
[] ((1 0 div) g agent.call) @attempt `err at `kind at (dup) g agent.call pair
# => (domain [7 0])
```

### call-for
`( quotation address milliseconds -- result )` — `agent.call` with a nonnegative int deadline in milliseconds, checked before anything is sent: a negative duration is `` `domain `` and a non-int is `` `type ``. When no reply arrives in time the call raises `` `timeout ``, whether the deadline passed while waiting for room in a full mailbox or for the reply; the quotation, if it was sent, still runs on the agent when its turn comes, and its reply is discarded.

### serve
Stack-polymorphic. Turn the current task into an agent whose state is the stack it has now, then serve until cancelled: receive a message, apply its quotation to the state as a unit, and reply when the message asks. Spawn it directly to keep the handle: `[[7 0]] (agent.serve) @spawn` serves `[7 0]`, and `task.cancel` on the handle ends it with `` `cancelled ``.

### start
`( state -- address )` — Spawn a server whose stack holds the one value `state` and return its address. The server is owned by the spawning task scope, as any `@spawn` is.

## archive

### next-member
`( archive -- metadata )` — Select the next archive member and return
`{path string kind symbol size int}` in archive order. Kinds are `` `file `` and
`` `directory ``; size is the content length in bytes. `{}` denotes stable end.
Advancing skips unread contents of the previous member. Metadata owns its path
independently of later cursor operations or closure.

### open-tgz
`( bytes -- archive )` — Validate a gzip tar with the same hostile-input parser
and limits as `unpack-tgz`, then return a scope-owned archive resource without
filesystem writes. No manifest or package identity is required. The resource
retains the validated uncompressed document until `port.close` or scope exit;
cleanup is joined and advances incrementally through member storage.
The limits apply per document. Scope ownership governs lifetime and joined
cleanup; it does not impose an aggregate heap budget on retained archives.

### read-member
`( archive maximum -- bytes )` — Read up to `maximum` bytes from the selected
member, advancing its content position. The maximum must be an integer from
1 through 65,536. `[]` denotes end of that member, a directory, or no selected
member. Reads copy bounded chunks into independently owned values; concurrent
reads consume distinct chunks, with unspecified completion order. Coordinate
member advancement with reads when using the archive across tasks. Operations
on a closed archive raise `` `io ``.

### sha256
`( bytes -- lowercase-hex )` — Return the SHA-256 digest of an integer byte
list. Every item must be an integer in `0..255`; strings are not byte vectors
and are not coerced.

#### Examples

```ecl
[1 2 3 4] archive.sha256
# => "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a"
```

### unpack-tgz
`( bytes root destination -- regular-file-paths )` — Validate and atomically
unpack a gzip-compressed tar byte list beneath a previously absent
`destination`, a canonical relative path under a named Session filesystem root
or scope-owned directory resource (see [`fs`](#fs)). Extraction owns its
directory lease until publication or rollback completes. The destination must
name a child entry, not `.`. Return normalized regular-file paths in archive
order. Unsafe, linked, special, duplicate, malformed, or over-limit members
are `` `domain ``; invalid byte items are `` `domain ``; wrong container kinds are
`` `type ``; an unknown root or a non-canonical destination is `` `domain `` carrying the `fs` failure data; an
exhausted operation quota is `` `overflow ``; filesystem and destination
conflicts are `` `io ``. Failure never publishes a partial destination. See the
environment's [`archive` contract](ENVIRONMENT.md#byte-lists-and-archives)
for the complete format, limit, containment, and publication contract.

## clock

Scheduler-backed time. `now`, `elapsed`, and `sleep` read the one monotonic
clock the Session's scheduler owns, so a program's instants, its sleeps, and
every `task.await-for` deadline agree on the current time. `unix` reads the
process realtime clock, which is always available to CLI programs.

Every quantity is a whole number of milliseconds. A monotonic instant is the
one-key dictionary `{monotonic ms}` counting from Session construction; a wall
timestamp is `{unix ms}` counting from 1970-01-01T00:00:00Z. The tag is the
clock domain: an instant handed to a `time` word, or a timestamp handed to
`elapsed`, is `` `type ``. Monotonic instants are not portable across Sessions and
carry no date; wall time may jump and is not suitable for scheduling.

### elapsed
`( instant -- milliseconds )` — Monotonic milliseconds from an instant produced
by `now` to the present. Anything but `{monotonic int}` is `` `type ``.

### now
`( -- instant )` — Read the monotonic clock as `{monotonic ms}`. Successive
reads never decrease. The first read of a fresh Session is close to
`{monotonic 0}`.

### sleep
`( milliseconds -- )` — Park the calling unit until the monotonic clock has
advanced by a nonnegative int duration, then continue with nothing pushed. The
unit holds no worker while parked; runnable work proceeds on a one-worker pool.
The deadline is captured once, before any timer state is created, and a
duration of `0` is already expired at that point: the unit yields to the
scheduler and resumes on its next turn without starting the timer thread.
Cancellation before or after registration wakes the unit with `` `cancelled ``
and retires its timer entry. A negative duration is `` `domain ``, a non-int is
`` `type ``, and a duration whose deadline lies beyond any instant the clock can
report is `` `overflow ``; all three fail before anything is registered.

#### Examples

```ecl
clock.now `start set 250 clock.sleep start clock.elapsed 250 >=
# => 1
```

### unix
`( -- timestamp )` — Read the process realtime clock as `{unix ms}`.
Convert with the `time` module. Wall time can jump and must not be used for
scheduling deadlines.

## csv

### emit
`( rows -- text )` — Render rows of string fields as canonical,
CRLF-terminated RFC 4180 text, quoting exactly the fields that require it.
Non-list rows and non-string cells are `` `type ``; a zero-field row is `` `shape ``.

### parse
`( input schema -- columns )` — Parse comma-separated content into a list
of equal-length columns. Input is a string or a list of UTF-8 bytes. All records
are data. Accept CRLF or LF records, quoted commas and newlines, doubled-quote
escapes, and a final CR at EOF. Preserve blank records and empty fields.

Schema is `[]` for inference, or one symbol per column: `` `auto ``, `` `int ``,
`` `float ``, or `` `text ``. Inference considers every data field. Canonical decimal
integers become signed 64-bit integers; decimal fractions and exponent forms
become finite binary64 floats. Integer-to-float widening requires exact
representation of every integer. Empty fields, leading zeros, leading plus,
negative integer zero, whitespace, incompatible text, and numeric overflow
make an inferred column text. Quoting does not force text. Text fallback
preserves decoded source spelling, including earlier numeric-looking fields.
An inferred column with no data is text.

Explicit numeric schemas accept decimal leading zeros and signs, reject empty
or unconvertible fields, and never fall back to text. Explicit floats permit
rounding integers. Boolean, date, and null inference are not performed.

Empty input produces no columns with `[]`, or empty columns matching the
schema. Unequal record widths and schema-width mismatches are `` `shape ``.
Malformed quoting, invalid UTF-8, and failed numeric conversions are `` `parse ``;
conversion failures identify record and column. Invalid schema entries are
`` `domain ``, and invalid input kinds are `` `type ``. Parsing supports at most 1,019
columns, reserving the remaining native builder slots for materialization;
exceeding that limit is `` `shape ``.

### parse-header
`( input schema -- headers columns )` — Like `parse`, but return the first
record separately as text headers and exclude it from inference. Empty input
is `` `shape ``; a header-only input produces matching empty columns. Preserve
header names verbatim, including duplicates and empty names. Dictionary and
table constructors apply their own name restrictions.

#### Examples

```ecl
"1,a\n2,b" [] csv.parse
# => ([1 2] ("a" "b"))

"id,name\n1,Ada\n2,Bob" [] csv.parse-header
dict.from-lists table.from-columns
# => {"id" [1 2] "name" ("Ada" "Bob")}

"01,2\n03,4" [text int] csv.parse
# => (("01" "03") [2 4])
```

## dict

These operations preserve the language's immutable, insertion-ordered
dictionary semantics. The constructor family accepts one key/value association,
flat adjacent entries, parallel key/value lists, association lists, or one
shared value for a key list. All constructors reject duplicate keys instead of
silently choosing a winner. Core `at`, `put`, `update`, and `del` treat a
dictionary selector as one whole-value key. `dict.put` also assigns one whole key and value. Batch operations `dict.at`,
`dict.at-or`, `dict.update`, `dict.take`, `dict.del`, and `dict.split` consume
a list of whole keys: strings and composite keys remain atomic. The public
`dict` module is ECL over the host kernels exported by `dict.core`, so a
failure inside a kernel reports its `dict.core` name.

### associate
`( value key -- dict )` — Build a one-entry dictionary associating `key` with `value`.

#### Examples

```ecl
["inspect" "alpha"] `args dict.associate
# => {args ["inspect" "alpha"]}
```

### at
`( dict keys -- values )` — Look up each top-level key in request order, preserving duplicates. An absent key is `` `domain ``. Strings and composite keys are whole values; the result has one element per requested key.

### at-or
`( dict keys default -- values )` — Like `dict.at`, using `default` as a whole value for each missing key.

### del
`( dict keys -- dict )` — Remove entries named by whole top-level keys, ignoring absent and duplicate keys and preserving retained dictionary order.

### from-flat
`( entries -- dict )` — Build a dictionary from one flat, even-length list by pairing adjacent entries without executing them. This is the runtime counterpart of the `{…}` literal: `` `total 3 4 + pair dict.from-flat `` is `{total 7}`. An odd entry count is `` `contract ``; duplicate keys are `` `domain ``.

### from-keys
`( keys value -- dict )` — Build a dictionary assigning one value to every distinct key. Duplicate keys are `` `domain ``.

### from-lists
`( keys values -- dict )` — Build a dictionary from parallel conforming key and value lists. Unequal lengths are `` `shape ``; duplicate keys are `` `domain ``.

#### Examples

```ecl
[a b] [1 2] dict.from-lists
# => {a 1 b 2}
```

### from-pairs
`( pairs -- dict )` — Build a dictionary from a list of exact `[key value]` pairs in list order. A malformed pair is `` `shape ``; duplicate keys are `` `domain ``.

### get
`( dict key default -- value )` — The value of one whole-value key, or `default` when the dictionary has no such key. A non-dictionary is `` `type ``.

### has?
`( dict key -- bool )` — Whole-value key membership. Keys are inert and only absence is false: lookup machinery failures are errors, never converted to 0.

### keys
`( dict -- keys )` — Return keys in insertion order.

### keys-exactly?
`( candidate declared -- bool )` — Return 1 when a dictionary has exactly the declared keys in any order. A duplicate declaration returns 0.

### merge
`( left right -- dict )` — Merge two dictionaries; right-hand values win. Existing left keys retain their positions and right-only keys append in right order. Key-aligned arithmetic remains pervasive `+` on dicts.

#### Examples

```ecl
{a 1 b 2} {b 20 c 30} dict.merge
# => {a 1 b 20 c 30}
```

### merge-with
`( left right quotation -- dict )` — Merge two dictionaries, resolving each shared key with `( key left-value right-value -- value )`. Existing left keys keep their positions; right-only keys append in right order.

### pairs
`( dict -- pairs )` — Return insertion-ordered `[key value]` pairs. This is the bridge to generic entry iteration when keys are needed. Value-only `each` operates on a dictionary directly; reductions and predicates can consume `dict.vals`, so they need no dictionary-specific duplicates.

### put
`( dict key value -- dict )` — Assign one whole key and value. An existing key retains its position; a new key appends at the end.

### size
`( dict -- count )` — Return the dictionary's entry count.

### split
`( dict keys -- selected rejected )` — Partition a dictionary by a key list, returning selected then rejected entries; ignore absent keys and preserve dictionary order in both results.

#### Examples

```ecl
{a 1 b 2} [b] dict.split pair
# => ({b 2} {a 1})
```

### take
`( dict keys -- dict )` — Keep entries named by a key list, ignoring absent keys. Output follows dictionary order independently of the requested key-list order.

### update
`( dict keys quotation -- dict )` — Apply an isolated `( value -- value )` quotation to each whole top-level key without moving entries. Keys are processed in request order, so duplicates observe earlier updates. All keys are validated before the quotation is first applied; an absent key is `` `domain ``, and an empty key list returns the dictionary unchanged.

### update-or
`( dict key default quotation -- dict )` — Update an existing value as `update` does, or append the absent key with the default unchanged. The default does not pass through the quotation.

### vals
`( dict -- values )` — Return values in insertion order.

### filter
`( dict predicate -- dict )` — Call a `( key value -- bool )` predicate in insertion order and retain the entries for which it returns 1.

### map
`( dict quotation -- dict )` — Call a `( key value -- value )` quotation for every entry, replacing values while preserving keys and insertion order.

#### Examples

```ecl
{a 1 b 2} (swap pop 10 *) dict.map
# => {a 10 b 20}
```

### reject
`( dict predicate -- dict )` — Call a `( key value -- bool )` predicate in insertion order and discard the entries for which it returns 1.

## error

Errors are ordinary dictionaries. Construction and inspection do not raise
unless an operation's own input violates its contract; control effects remain
core words.

### new
`( kind -- error )` — Build the error dictionary `{kind kind}` from a kind symbol.

### valid?
`( value -- bool )` — Return 1 when a value satisfies the error dictionary schema: a required symbol `` `kind `` and well-typed optional `` `msg ``, `` `word ``, `` `trace ``, and `` `data `` fields. Extra fields are allowed.

### kind-in?
`( error kinds -- bool )` — Validate an error and a list of kind symbols, then return 1 when the error's kind occurs in the list.

### kind?
`( error kind -- bool )` — Validate both inputs and return 1 when the error has the given kind symbol.

### with-data
`( error data -- error )` — Validate both dictionaries and return the error with `` `data `` set to `data`.

### with-message
`( error message -- error )` — Validate the error and string message and return the error with `` `msg `` set to `message`.

#### Examples

```ecl
`io error.new "unavailable" error.with-message
# => {kind io msg "unavailable"}
```

## fs

Filesystem words accept a named `root` symbol or a directory resource and a `path` string.
The command line uses `` `cwd `` for the startup working directory. Applications
may explicitly open other host directories. All filesystem operations are available on each root,
subject to operating-system permissions and runtime limits.

A path is a UTF-8 slash path in the canonical grammar: `.` names the root
itself, and every other path is one or more nonempty components separated by
exactly one `/`, with no `.`, `..`, or NUL component and no leading, trailing,
or repeated separator. Backslash is an ordinary filename character. Paths are
never normalized here; normalize with `path.normalize` and accept the result
with `path.valid-relative?` first. Words that act on a child entry (`create-*`,
`replace-*`, `mkdir`, `rename`, `remove-file`, `remove-dir`) reject `.`.

Resolution is descriptor-relative beneath the root's retained handle. An
intermediate symlink is followed only while its target stays within the root;
an absolute target, a relative target that would pop above the root, more than
40 followed links, or more than 64 KiB of expanded resolver input is refused.
`child-dir`, `open-list`, `read-bytes`, `read-text`, `stat`, `list`, and the source side of `copy`
follow a final link under the same rule; every other word acts on the final
entry itself. Containment is never a lexical prefix check.

Path-taking failures carry a data dictionary with `` `operation `` (the word's own
symbol), `` `root `` and `` `path `` (or `` `source-root ``, `` `source-path ``,
`` `destination-root ``, and `` `destination-path `` for `copy`), and a closed
`` `reason `` symbol: `` `invalid-path ``, `` `unknown-root ``,
`` `not-found ``, `` `already-exists ``, `` `not-directory ``, `` `is-directory ``,
`` `not-regular ``, `` `not-empty ``, `` `symlink-loop ``, `` `symlink-escape ``,
`` `invalid-utf8 ``, `` `limit ``, `` `access-denied ``, `` `read-only ``, `` `no-space ``,
`` `busy ``, `` `cross-device ``, `` `unsupported ``, `` `changed ``, or `` `io ``. The kind is
`` `type `` for wrong value kinds or byte-list members outside `0..255`, `` `domain ``
for malformed paths and unknown roots,
`` `overflow `` for a configured limit, `` `cancelled `` for cancellation, and `` `io ``
for filesystem state and host failures. Host error names never appear as data.

Reads, writes, and copies are bounded by the transfer limit
(1 GiB by default) and advance in 64 KiB quanta; listings are bounded by an
entry count (100,000) and aggregate name bytes (64 MiB); a Session runs at most
64 filesystem operations at once. Mutation stages complete contents in a
private sibling entry and publishes with one atomic namespace operation, so
failure or cancellation before the commit leaves the destination unchanged.
Staged contents are flushed to the device before publication, so a crash
after the commit cannot leave an empty file under the final name; directory
entry durability, ownership, timestamps, and extended attributes are not
promised. Created files use the host's ordinary creation mode under the
process umask, a replaced file keeps its permission bits, and a copy carries
the source's permission bits under the umask.

### child-dir
`( root path -- directory )` — Acquire an independent directory resource beneath
an existing root. Resolution, including final symlinks, is confined to that
root. The acquired directory becomes the new containment boundary; closing
its ordinary parent resource does not close it. Children of a staging resource,
including further descendants, close when staging is sealed or closed even
after task ownership transfer. `.` acquires the root itself.

### commit-dir
`( stage -- )` — Seal the stage, reject further operations, close its descendant
resources, and wait for admitted operations before atomically publishing to the
absent destination. Any existing entry causes an `` `io `` failure and is preserved;
failure retains the sealed staging resource for joined cleanup with `port.close`.
Success joins descriptor closure and keeps the published tree even if the task
is subsequently cancelled. Namespace publication is atomic; directory-entry
durability across a host crash is not promised.

### commit-file
`( writer -- )` — Stop admission, flush the completed stream, and atomically
publish its previously absent destination. Publication is serialized against
cancellation. Success joins writer cleanup; failure retains unpublished private
state for explicit or scope cleanup. No allocation is required after the
publication permit is granted.

### copy
`( source-root source-path destination-root destination-path -- )` — Copy a
regular file, following a final source link within its root, into an absent
destination entry; the roots may differ. The copy is staged and published
atomically without replacing; an existing destination of any kind is
`` `already-exists ``, a non-regular source is `` `not-regular `` or `` `is-directory ``,
and no metadata is preserved.

### create-bytes
`( bytes root path -- )` — Atomically create an absent regular file holding
exact bytes. Members are validated before any external state exists. An
existing regular file, directory, symlink (including a dangling one), or other
entry is `` `already-exists ``; a missing parent is `` `not-found ``.

### create-text
`( string root path -- )` — Atomically create an absent regular file holding
the string as UTF-8, with the same collision contract as `create-bytes`.

### exists?
`( root path -- bool )` — Return 1 when the final entry exists and 0 when it is
definitely absent, without following a final link: a dangling link is 1.
Malformed paths, unknown roots, denial, traversal failures such as a missing or
escaping intermediate component, and host failures are errors rather than 0.

### list
`( root path -- entries )` — Follow the path to a directory and return its
children as `{name string kind file}`, `{name string kind directory}`,
`{name string kind symlink}`, or `{name string kind other}`, classified
without following, excluding `.` and `..`, and sorted by Unicode scalar order
of `` `name ``. A child name that is not valid UTF-8, an entry that vanishes or
cannot be classified, or an exceeded listing limit fails the whole listing;
nothing is silently omitted.

### lock
`( root path -- lock )` — Acquire an exclusive advisory lock on a regular file,
creating an empty file if the path is absent. Existing contents are preserved;
final symlinks and non-regular files are rejected. Contention parks the task
between attempts and is cancellable. The returned port owns the lock until
`port.close` or its owning scope exits. A lock is not a directory resource.
The lock file remains after release. Coordinating applications must keep its
directory entry in place: replacing or deleting it establishes a different
lock identity. Advisory locking coordinates participating applications and
does not prevent other filesystem access.

### lstat
`( root path -- metadata )` — Describe the final entry without following it:
`{kind file size n}` for a regular file, `{kind directory}`,
`{kind symlink}`, or `{kind other}`. An absent entry is `` `not-found ``.

### mkdir
`( root path -- )` — Create exactly one absent directory beneath an existing
parent. There is no recursive parent creation; an existing entry of any kind is
`` `already-exists ``.

### mkdirs
`( root path -- )` — Create missing intermediate and final directories. Existing
directories are preserved, including contained symlink targets. `.` is a no-op.
Every component uses the ordinary confined resolver. Failure or cancellation
may leave directories created before that point.

### next-entry
`( cursor -- entry )` — Return the next `{name string kind symbol}` dictionary,
or `{}` at stable end. Kinds are `` `file ``, `` `directory ``, `` `symlink ``, and `` `other ``;
dot entries are omitted and symlinks are described without following them.
Names must be UTF-8. Order and visibility of concurrent namespace changes follow
the host filesystem; this is not a directory snapshot. Concurrent calls reserve
distinct entries, though their results may complete out of order. Each result
owns its name independently of subsequent calls or cursor closure. A closed
cursor raises `` `io ``. Reading does not materialize the whole directory or apply
the aggregate limits of `list`; callers can stop and close at any entry.

### open-dir
`( host-path -- directory )` — Open an absolute host directory path, subject to
OS permissions, and return a scope-owned port resource. Host symlinks may be
followed while opening this explicit root. Relative paths are rejected.
`port.close` closes the resource and joins cleanup; scope exit does the same.
A closing directory rejects new operations with `` `io ``. Closure waits for
admitted operations to release their independent descriptor leases, then joins
backend cleanup.

### open-list
`( root path -- cursor )` — Open a scope-owned incremental enumeration of a
confined directory. The cursor is a port resource, distinct from a directory
root. It owns its descriptor until `port.close` or scope exit. An enumeration
opened through staging or its descendants also closes when staging seals.

### open-writer
`( root path -- writer )` — Open private storage for an absent regular file.
The parent must exist and `.` is rejected. A writer is distinct from a directory.
It retains root lifetime and operation admission until joined cleanup. Staging
dependencies survive task transfer. Closing an uncommitted writer removes its
private contents and publishes no destination.

### publish-bytes
`( bytes root path -- )` — Atomically publish complete file contents, creating
an absent destination or replacing one that exists. An entry observed before
staging must be a regular file; a symlink, directory, or other entry is
`` `not-regular ``. Use the observed file's permissions, or host defaults on first
creation. Publication replaces the final directory entry without following it;
concurrent publications each succeed and the last commit wins. An intervening
directory causes failure. A failed operation preserves its destination, and
cancellation before commit removes staging. Cancellation after commit does not
roll back publication. Visibility is atomic; directory-entry durability across
a crash is not promised.

### publish-text
`( string root path -- )` — Publish UTF-8 text under the `publish-bytes` contract.

### read-bytes
`( root path -- bytes )` — Read one regular file, following a final link within
the root, and return its exact bytes as an integer list. The size observed at
open is the size read; growth or shrink meanwhile is `` `changed ``. A directory is
`` `is-directory ``; a non-regular object is `` `not-regular ``; a file over the
transfer limit is `` `overflow ``.

### read-text
`( root path -- string )` — Read one regular file as `read-bytes` does and
decode it as UTF-8. Invalid UTF-8 is `` `io `` with reason `` `invalid-utf8 ``.

### remove-dir
`( root path -- )` — Remove one empty directory without following a final
link. A nonempty directory is `` `not-empty ``; a file or symlink is
`` `not-directory ``.

### remove-file
`( root path -- )` — Remove one non-directory entry, including a symlink
itself, without following it. A directory is `` `is-directory ``.

### remove-tree
`( root path -- )` — Recursively remove a directory and its contents. The final
entry must be a directory, and `.` is rejected. Symlinks inside the tree are
removed without following their targets. Work is incremental and cancellable;
failure may leave partially removed contents with temporary entry names.
Removal uses bounded descriptor storage and needs no new allocations once the
selected directory has been opened.

### rename
`( root source-path destination-path -- )` — Rename an entry within one root
without replacing. The source may be a regular file, symlink, or directory and
is not followed; an existing destination is `` `already-exists ``, and a
destination on another device is `` `cross-device `` rather than an emulated
copy.

### replace-bytes
`( bytes root path -- )` — Atomically replace an existing regular file with
exact bytes. The final entry must be observed as a regular file without
following: absence is `` `not-found ``, and a symlink, directory, or other entry
is `` `not-regular ``. The replacement is a new inode published by an atomic
exchange; the word never becomes create-or-replace.

### replace-text
`( string root path -- )` — Replace an existing regular file with UTF-8 text
under the `replace-bytes` contract.

### reserve
`( root -- reservation )` — Retain a selected directory root and one filesystem
operation slot until joined closure. A reservation can be passed as a root;
its derived operations share that slot and reject overlapping work with
`` `overflow `` and reason `` `limit ``. Closure waits for admitted work. This supports
compositions that must retain admission across inspection and publication.

### stage-dir
`( root destination -- stage )` — Create a private sibling of the destination
and return a scope-owned directory resource. The destination parent must exist.
Filesystem operations accept the stage as a root. `port.close` or scope exit
joins descendant closure and recursive rollback; no destination is published.
The staging directory uses mode `0700` under the process umask.

### stat
`( root path -- metadata )` — Follow the path, including a final link within
the root, and describe the object reached with the same shapes as `lstat`. A
dangling link is `` `not-found ``.

### write-chunk
`( writer bytes -- )` — Append at most 65536 integer bytes. The streaming transfer
limit (1 GiB by default) covers the complete stream, including previous chunks.
A failed or cancelled append prevents later publication of partial contents.

## host

### cwd
`( -- path )` — Return the absolute startup directory captured by the Session
host as UTF-8 text. This does not consult `PWD` or change the working directory.

### executable
`( -- path )` — Ask the operating system for the current executable's absolute
path and return UTF-8 text. This does not consult `PATH` or trust the executable
name supplied in the argument vector. Raise `` `io `` when the host cannot provide
the path or it is not UTF-8. This is an observation, not an open-file identity:
subsequent deletion or replacement can make the path unavailable or stale.
Neither metadata operation grants authority beyond the existing filesystem and
process facilities. Text construction is cancellable.

## http

Requests yield while awaiting network I/O, including under cooperative scheduling
and with one worker. Each invocation has one total 30-second monotonic deadline,
including preparation, redirects, transfer, and response construction. Expiry is
`` `timeout ``; task cancellation remains `` `cancelled ``. Neither returns a partial
response.

Internal Session configuration defaults to 16 live requests, a 16 KiB target,
16 MiB outbound body, 64 MiB encoded and 64 MiB decoded inbound bodies, and
64 KiB / 256 occurrences of supplied request headers and received response
headers. Header byte counts include field-line framing; received whitespace
counts before normalization and repeated fields count before deduplication.
Redirect responses share cumulative inbound budgets; body limits also apply to
chunked and compressed transfers. The response transport holds at most 64 KiB
and backend scratch at most 16 MiB per request. Admission remains reserved until
response construction and cleanup finish. Exceeding a limit is `` `overflow `` with
the target URL in error data; allocation failure remains `OutOfMemory`.
Configuration is internal: there are no new request fields or CLI options.

### get
`( request -- response )` — Fetch a partial or complete `http.request` value,
using GET and redirect following as defaults. The request must carry a string
`` `target `` URL. An optional `` `method `` overrides GET, optional `` `headers `` are
sent once per value in list order, and an optional byte-list `` `body `` is sent
exactly for POST, PUT, or PATCH. A nonempty body with another method is
`` `domain ``. Return `{status int, headers dict, body string}`. A transport or
protocol failure is `` `io `` carrying the URL in `` `path ``; a non-2xx status is an
ordinary response.

### get-bytes
`( request -- response )` — Perform the same request as `get`, including
redirects and content decoding, but return `` `body `` as the exact ordered octets
in an ordinary integer byte list. Status and headers retain the same types.
This is the binary ingress used for archives; no byte is decoded to or encoded
from a Unicode character before hashing.

### post
`( request -- response )` — Fetch the same request value as `get`, using POST,
an empty body, and no redirect following as defaults. An optional `` `method ``
or `` `body `` overrides those request defaults. Return the same response shape
and errors as `get`.

### send
`( request -- response )` — Send a complete `http.request` value. Unlike `get`
and `post`, this word supplies no method default: both string `` `method `` and
`` `target `` fields are required. Redirects are not followed. Return the same
response shape and errors as `get`.

## http.request

Words over partial or complete request dictionaries. Recognized optional
fields are `` `method ``, `` `target ``, `` `path ``, `` `query ``, `` `headers ``, `` `body ``,
`` `peer ``, and `` `params ``. `http.server` handlers receive every field except
`` `params ``, which `http.server.route` may add; outbound `http.get` and
`http.post` accept partial values and apply their documented defaults, while
`http.send` consumes a complete value. The words here build a complete
request, read absent headers/query/body using empty defaults, and return
updated copies; the original is never changed. A word given a malformed
request dictionary, or a name that is not a string, is `` `type ``.

### query
`( request -- params )` — Parse the request's `` `query `` string, such as `"a=1&b=%2Fx&c"`, into a dictionary from string keys to string values, such as `{"a" "1" "b" "/x" "c" ""}`: `&`-separated pairs, each split at its first `=`, a pair without `=` mapping its key to `""`, empty pieces ignored, and a later duplicate key replacing an earlier one. `%XX` escapes are decoded in keys and values and the decoded text must be valid UTF-8; `+` is left as it is. An empty query is `{}`. A `%` not followed by two hexadecimal digits, or a decoded key or value that is not valid UTF-8, is `` `domain ``; a non-request is `` `type ``.

#### Examples

```ecl
"GET" "/?a=1&b=%2Fx&c" http.request.new http.request.query
# => {"a" "1" "b" "/x" "c" ""}
```

### valid?
`( value -- bool )` — Return 1 for a partial or complete request dictionary containing only recognized fields: string `` `method ``, `` `target ``, `` `path ``, `` `query ``, and `` `peer ``; a `` `headers `` dictionary from ASCII-lowercased string names to lists of strings; a byte-list `` `body ``; and a `` `params `` dictionary from string names to string values. Every field is optional. Never raises.

### header
`( request name -- values )` — Return the list of values of a header, matching the name regardless of letter case, or `()` when it is absent. A non-request or non-string name is `` `type ``.

### new
`( method target -- request )` — Return a request with the method and target, `` `path `` and `` `query `` split from the target at its first `?` (`` `query `` `""` when absent), `{}` headers, `[]` body, and `""` peer. A non-string method or target is `` `type ``.

### param
`( request name -- value )` — Return the route parameter bound under the name by `http.server.route`. A request without that parameter is `` `domain ``; a non-request or non-string name is `` `type ``.

### text
`( request -- string )` — Return the body decoded as UTF-8 text. A body that is not valid UTF-8 is `domain, as for chars.

### with-body
`( request body -- request )` — Return the request with a new body: a byte list as given, or a string encoded as UTF-8. Another kind is `type.

### with-header
`( request name value -- request )` — Return the request with a value added under the ASCII-lowercased header name: a string or a list of strings, appended to the values already there. A non-string name or a bad value is `` `type ``.

### with-param
`( request name value -- request )` — Return the request with a route parameter bound under the name, as `http.server.route` does. A non-string name or value is `` `type ``.

### header?
`( request name -- bool )` — Return 1 when the request carries the header under any letter case.

### json
`( request -- value )` — Return the body parsed as JSON: `chars` then `json.parse`, so a body that is not UTF-8 or not JSON fails as they do.

## http.response

Words over the response dictionary `{status headers body}`: the value
`http.get`, `http.post`, and `http.send` return and the value an `http.server`
handler leaves. They build a response, read its headers by name regardless of
letter case, classify its status, and return updated copies. `valid?` accepts
every well-shaped value; the wire rules a server enforces (no 1xx, reserved
header names, no CR or LF) belong to `http.server.render-response`. A word
given a value that is not a response dictionary, a status outside `100...599`,
or a name that is not a string is `` `type ``.

### redirect
`( location -- response )` — Return a 302 response with `{"location" (location)}` as its headers and an empty body. A non-string location is `` `type ``.

### json
`( status value -- response )` — Return a response whose body is the value rendered with `json.emit` and whose headers are `{"content-type" ("application/json")}`. A bad status is `` `type ``; a value `json.emit` rejects fails as `json.emit` does.

### new
`( status -- response )` — Return `{status status headers {} body ""}`. A status outside `100...599` is `` `type ``.

### text
`( status string -- response )` — Return a response with the string as its body and `{"content-type" ("text/plain; charset=utf-8")}` as its headers. A bad status or a non-string body is `` `type ``.

### not-found
`( -- response )` — Return 404 "not found" text.

### valid?
`( value -- bool )` — Return 1 for a response dictionary: exactly `` `status ``, `` `headers ``, and `` `body ``, with an integer status in `100...599`, a headers dictionary from string names to a string or a list of strings, and a string or byte-list body. Never raises.

### class
`( response -- class )` — Return the status class: 2 for 200...299, 4 for 400...499, and so on.

### header
`( response name -- values )` — Return every value of a header as a list, matching the name regardless of letter case and in dictionary order; a string value counts as one. `()` when the header is absent. A non-response or non-string name is `` `type ``.

### with-body
`( response body -- response )` — Return the response with a new string or byte-list body; another kind is `type.

### with-header
`( response name value -- response )` — Return the response with a value added under the header name exactly as given: a string or a list of strings, appended to any values already under that name; an existing string value, even the empty string, counts as one. A non-string name or a bad value is `` `type ``.

### with-headers
`( response headers -- response )` — Return the response with a headers dictionary merged over its own; a right-hand name replaces a left-hand one exactly. A value that is not a dictionary of string names to header values is `` `type ``.

### with-status
`( response status -- response )` — Return the response with a new status. A bad status is `` `type ``.

### header?
`( response name -- bool )` — Return 1 when the response carries the header under any letter case.

### ok?
`( response -- bool )` — Return 1 for a status in 200...299.

## http.server

HTTP/1.1 serving over `net` connections, defined in ECL. The module holds no
authority of its own: `@serve` takes a listener the program already obtained
through `net.listen`, so a Session that cannot bind cannot serve, and every
socket operation is one of the `net` words. The parsers, the response
renderer, and `route` take and return ordinary values and never touch a
connection, so they can be used and tested without a socket. Requests and
responses are the dictionaries `http.request` and `http.response` build and
read.

A request is the dictionary
`{method target path query headers body peer}`:

- `` `method `` and `` `target `` are the first two tokens of the request line, as
  strings;
- `` `path `` and `` `query `` are the target split at the first `?`, undecoded;
  `` `query `` is `""` when the target has no `?`;
- `` `headers `` is a dictionary from ASCII-lowercased header name to the list of
  its trimmed values in arrival order, so a repeated header keeps every value;
- `` `body `` is the exact byte list named by `Content-Length`, `[]` when the
  request has none; and
- `` `peer `` is the peer's `address:port` formatted from `net.peer-address`,
  with an IPv6 address in brackets.

A response is the dictionary `{status headers body}` with exactly those
keys: an integer status in `200...599`, since interim 1xx responses are not
served, with an empty body when the status is 204, 205, or 304; a headers
dictionary whose keys are
strings and whose values are a string or a list of strings, written once per
value in the given order and with the name as given; and a body that is a
string, written as UTF-8, or a byte list. The names `content-length`,
`connection`, and `transfer-encoding` are reserved in any letter case: the
server writes `Content-Length` and `Connection: close` itself, and a response
naming one of them is `` `domain ``. Header names must be nonempty HTTP tokens
and values may not contain CR, LF, NUL, or a control character other than
tab, so a value built from request data cannot split the response.

Framing is HTTP/1.1 with `Content-Length` bodies only; an HTTP/1.0 request is
answered the same way, and only HTTP/1.1 requests must carry one `Host`
header. A HEAD request is answered with the handler's status and headers and
no body. Any `Transfer-Encoding` header is answered 411 and a
version other than `HTTP/1.1` or `HTTP/1.0` is answered 505. There is no
keep-alive: every response carries `Connection: close`, and the connection is
closed once the response is written. TLS, chunked bodies, pipelining, and
upgrades belong to a proxy in front of the server.

The `@serve` configuration is a dictionary whose keys are all optional; `{}`
is valid. Each limit is an integer greater than zero.

- `` `max-header-bytes `` (default `32768`): the most bytes accepted before the
  CRLFCRLF that ends the head; more is 431.
- `` `max-body-bytes `` (default `1048576`): the largest `Content-Length`
  accepted; a larger one is 413 before any body byte is read.
- `` `max-in-flight `` (default `128`): the number of acceptor children, each
  handling one connection at a time.
- `` `read-timeout-ms `` (default `10000`): the deadline for reading one whole
  request, head and body; expiry is 408.
- `` `on-failure `` (default `(str io.eprint)`): a quotation `( error -- )`
  applied to the error dictionary of every request the server answers 500; a
  failure of the quotation itself is discarded.

The server answers a request it cannot serve with a minimal `text/plain`
response of the status below and then closes the connection:

- 400: a malformed request line; a header line without `:` or beginning with
  space or tab (obsolete folding); an HTTP/1.1 request without exactly one
  `Host` header of the form `uri-host [":" port]`; non-UTF-8 bytes in the
  head; a
  `Content-Length` that is not a digit string or whose repeated values
  differ; end of stream after some bytes arrived but before the head or the
  body is complete.
- 408: `` `read-timeout-ms `` elapses while the request is being read.
- 411: any `Transfer-Encoding` header.
- 413: `Content-Length` exceeds `` `max-body-bytes ``.
- 431: `` `max-header-bytes `` is exceeded before the head ends.
- 500: the handler fails, leaves other than exactly one value, or leaves a
  response `render-response` rejects.
- 505: a version other than `HTTP/1.1` or `HTTP/1.0`.

A peer that connects and closes without sending a byte, or that resets or
otherwise fails during the read or the write, is closed silently: nothing is
written and `` `on-failure `` is not applied.

The handler is a quotation with the contract `( request -- response )`. Each
request applies it as `[request] handler @attempt` in a fresh unit, so a
handler's failure is data to the server and the ambient stack never crosses
the boundary. A successful handler leaves exactly one value, and that value
must satisfy `render-response`. Any other outcome — a raised error, an empty
or multi-valued result, a malformed response — answers 500 and applies the
`` `on-failure `` quotation to the error dictionary (for a wrong result count, a
`` `contract `` error naming the observed count); the serving unit and every other
in-flight request are unaffected. Every response the server writes, whether
the handler's or its own, is validated in full before any byte is written.

`@serve` serves up to `` `max-in-flight `` connections at a time, each in a child
unit that owns its connection, so a connection is closed on every path.
Beyond that bound, and at the host's live-connection maximum, further
connections wait in the kernel backlog.

`@serve` does not return. The serving unit ends only when it is cancelled,
failing `` `cancelled ``, or when an acceptor's `net.accept` fails, in which case
that error is raised from `@serve`. Abortive listener closure cancels an admitted
accept; graceful shutdown may instead report backend closure as `` `io ``. Admission
after closure raises `` `io ``. Either ending cancels and quiesces every acceptor,
reader, and handler child by the ordinary scope rules and closes every
connection those children own. The listener itself is untouched: `@serve`
never calls `net.close` on the listener it was given, which stays the
caller's to close explicitly or through its own scope and may be served
again.

#### Examples

```ecl
{address "127.0.0.1" port 8080} net.listen `l def

([["GET" "/health" (pop 200 "ok" http.response.text)]
  ["GET" "/users/:id" ("id" http.request.param 200 swap http.response.text)]]
 http.server.route)
`handler def

l {read-timeout-ms 5000} (handler) http.server.@serve
```

### content-length
`( headers -- length )` — Return the request body length named by a headers dictionary as `parse-headers` builds it: `0` when `content-length` is absent, otherwise the integer every occurrence spells, leading zeros allowed, so `{"content-length" ("5")}` is 5. A value that is not a nonempty string of decimal digits, or repeated values that differ, is `` `domain `` with `` `data {status 400} ``; a value too large for a 64-bit integer exceeds every body limit and is `` `domain `` with `` `data {status 413} ``. A non-dictionary is `` `type ``.

### parse-headers
`( lines -- headers )` — Fold a list of header-line strings into a dictionary from ASCII-lowercased name to the list of its values in arrival order, so `("Host: a" "host: b")` yields `{"host" ("a" "b")}`. The name is the text before the first `:`, and the value is the rest with surrounding ASCII whitespace removed. `()` is `{}`. A line that has no `:`, has an empty name or a name containing whitespace, or begins with a space or tab (obsolete line folding) is `` `domain `` with `` `data {status 400} ``. A non-list or a non-string line is `` `type ``.

### parse-request-line
`( line -- request-line )` — Parse a request line such as `"GET /users?id=42 HTTP/1.1"` into `{method target path query version}`: three space-separated tokens, with `` `path `` and `` `query `` the target split at its first `?`, undecoded, and `` `query `` `""` when there is no `?`. Any other token count is `` `domain `` with `` `data {status 400} ``; a version other than `HTTP/1.1` or `HTTP/1.0` is `` `domain `` with `` `data {status 505} ``. A non-string is `` `type ``.

#### Examples

```ecl
"GET /a?b=1 HTTP/1.1" http.server.parse-request-line
# => {method "GET" target "/a?b=1" path "/a" query "b=1" version "HTTP/1.1"}
```

### route
`( request routes -- response )` — *Inline.* Dispatch a request over a list of `[method pattern handler]` rows. The method is a string compared exactly against the request's `` `method ``. A pattern is a slash path such as `"/users/:id"` whose segments must equal the request's `` `path `` segments one for one, except that a segment beginning with `:` binds any nonempty path segment under its name in a string dictionary. The first row whose pattern and method both match has the request, with `` `params `` set to that dictionary, passed to its handler, which is applied inline with the contract `( request -- response )`. Middleware is composition: wrap the handler quotation with `compose`.

When some pattern matches but no matching row's method does, the result is `405 "method not allowed" text` with an `allow` header joining the matching rows' methods with `,`; when no pattern matches, the result is `http.response.not-found`. Every row is checked before any comparison: a non-list routes value is `` `type ``, a row that is not a list of three elements is `` `shape ``, and a non-string method, non-string pattern, or non-quotation handler is `` `type ``.

### render-response
`( response -- bytes )` — Validate a response dictionary in full and return the exact bytes the server writes for it: `HTTP/1.1 <status> <reason>` CRLF, one `name: value` line per header value in the given order with the name as given, so `{"set-cookie" ("a=1" "b=2")}` writes two lines, `Content-Length: <n>` CRLF (omitted for 204 and 304, whose length is not the empty body's), `Connection: close` CRLF, CRLF, then the body bytes, a string written as UTF-8. The reason phrase comes from a fixed table covering 200, 201, 204, 301, 302, 304, 400, 401, 403, 404, 405, 408, 411, 413, 431, 500, 503, and 505 and is empty for any other status, with the space before it always written. Every byte the server writes has passed this word.

A non-dictionary is `` `type ``. The following are `` `domain ``: keys other than exactly `` `status ``, `` `headers ``, and `` `body ``; a status that is not an integer in `200...599`, since interim 1xx responses are not served; a nonempty body with status 204, 205, or 304; a headers value that is not a dictionary; a header name that is not a nonempty string of HTTP token characters; a header value that is neither a string nor a list of strings, or that contains CR, LF, NUL, or a control character other than tab; a header whose lowercased name is `content-length`, `connection`, or `transfer-encoding`; and a body that is neither a string nor a list of integers in `0...255`.

#### Examples

```ecl
{status 200 headers {"set-cookie" ("a=1" "b=2")} body "ok"}
http.server.render-response chars
# => "HTTP/1.1 200 OK\u{D}\u{A}set-cookie: a=1\u{D}\u{A}set-cookie: b=2\u{D}\u{A}Content-Length: 2\u{D}\u{A}Connection: close\u{D}\u{A}\u{D}\u{A}ok"
```

### @serve
`( listener config handler -- )` — *Unit constructor*, contract `( request -- response )` enforced per request. Serve HTTP/1.1 requests from a `net` listener until the unit ends: accept in a loop and give each connection to a child unit that owns it. The child frames one request under the read deadline, applies the handler as `[request] handler @attempt` in a fresh unit, writes its single response with `Content-Length` and `Connection: close`, and closes the connection.

The request is the dictionary `{method target path query headers body peer}`: `` `method `` and `` `target `` are the request-line tokens; `` `path `` and `` `query `` are the target split at the first `?`, undecoded, with `` `query `` `""` when absent; `` `headers `` maps each ASCII-lowercased header name to the list of its trimmed values in arrival order; `` `body `` is the exact `Content-Length` byte list, `[]` when there is none; `` `peer `` is the peer's `address:port`, an IPv6 address in brackets. The response is the dictionary `{status headers body}` that `render-response` accepts; every byte written to a connection has passed `render-response`.

The configuration is a dictionary whose keys are all optional, so `{}` is valid. Each limit is an int greater than zero.
- `` `max-header-bytes `` (32768): most head bytes accepted before the CRLFCRLF terminator; more is 431.
- `` `max-body-bytes `` (1048576): largest `Content-Length` accepted; more is 413 before any body byte is read.
- `` `max-in-flight `` (128): most connections served at once; accepting waits for a free slot.
- `` `read-timeout-ms `` (10000): deadline for reading one whole request; expiry is 408.
- `` `on-failure `` (`(str io.eprint)`): a `( error -- )` quotation applied to the error of every request answered 500; a failure of the quotation itself is discarded.

A HEAD request is answered with the handler's status and headers and no body. Requests the server cannot serve are answered with a minimal `text/plain` response and closed: 400 for a malformed request line or header, an HTTP/1.1 request without exactly one well-formed Host header, non-UTF-8 head bytes, a bad `Content-Length`, or end of stream after some bytes; 411 for any `Transfer-Encoding`; 505 for a version other than HTTP/1.1 or HTTP/1.0; 431 and 413 for the size limits; 408 for the deadline; 500 when the handler fails, leaves other than one value, or leaves a response `render-response` rejects, in which case `` `on-failure `` receives the error. A peer that sends nothing before closing, or resets during the exchange, is closed silently.

Validation of the arguments completes before any request is accepted. A non-port listener, a non-dictionary configuration, a non-quotation handler, a non-int limit, or a non-quotation `` `on-failure `` is `` `type ``; an unknown configuration key or a limit not greater than zero is `` `domain ``. The word fails `` `cancelled `` when the serving unit is cancelled and re-raises an acceptor's `` `io `` failure of `net.accept`. Closing the listener ends an admitted accept with `` `io `` or `` `cancelled ``; admission after closure fails `` `io ``. Every child is quiesced by scope rules, and every connection a child owns is closed with it. It never closes the listener, which stays the caller's to close.

## io

### debug
`( value label -- value )` — Write the string label, `": "`, and the value's
pretty-printed representation plus newline, leaving the value on the stack.
Semantically `io.prin ": " io.prin io.inspect`; a non-string label is the
same `` `type `` failure as `io.prin`.

### eprint
`( string -- )` — Write a string followed by a newline to the Session's
diagnostics stream: standard error under the command line, the host's
diagnostics writer when embedded, and never standard output. When the host
supplies no diagnostics writer the string is dropped and the word succeeds.
Non-string is `` `type ``; a failed write is `` `io ``.

### inspect
`( value -- value )` — Pretty-print a value while leaving it on the stack;
the pipeline probe. Semantically `dup io.pp`.

### pp
`( value -- )` — Pretty-print any value plus newline in the display layout of
Printing. Best-effort: huge leaves may be elided, so there is no round-trip
guarantee. Use core `str` for canonical rendering.

### prin
`( string -- )` — Write a string's characters as UTF-8 without adding a
newline. Non-string is `` `type ``.

### print
`( string -- )` — Write a string followed by a newline. Semantically
`io.prin "\n" io.prin`.

### stack
Stack-polymorphic; leaves the operand stack unchanged. Print each value in the
currently visible operand window as a bottom-up indexed display block. `[0]`
is the bottom and the largest index is the top; continuation lines align after
the prefix. An isolated quotation sees only values above its isolation floor.
An empty visible window writes nothing. Rendering is best-effort and may use
the same multiline dictionary, array, and elision layout as `io.pp`.

### stdin
`( -- string )` — Read the whole standard input stream once. Legal where stdin
carries data (`-e` and script-file modes); `` `io `` where stdin is the program
source or when it has already been read.

## json

### emit
`( value -- text )` — Render an ECL value as RFC 8259 JSON. Dict keys must be
strings or symbols; the only emitted symbol values are `` `null ``, `` `true ``, and
`` `false ``.

### parse
`( text -- value )` — Parse RFC 8259 JSON. Objects become string-keyed dicts,
arrays become lists, in-range integral numbers become ints, and other numbers
become floats. JSON null and booleans become the ordinary symbols `` `null ``,
`` `true ``, and `` `false ``.

#### Examples

```ecl
"{\"a\":[1,null]}" json.parse
# => {"a" (1 null)}
```

## net

TCP listeners and connections. Any local IP literal and port can be requested,
subject to operating-system restrictions and runtime resource limits. Port zero
requests an ephemeral bind. Names are never resolved. IPv4-mapped IPv6 literals
normalize to IPv4. Binding uses address reuse, so a closed connection's
`TIME_WAIT` does not prevent rebinding; two live listeners cannot hold the same
address and port.

The public words are ECL compositions over `net.core.listener`, the registered
operations `net.core.accept`, `net.core.local-address`, and
`net.core.peer-address`, and the endpoint selectors `net.core.input` and
`net.core.output`. Each operation requires `[]`. Accept occupies its FIFO lane
until completion or cancellation. Address operations use an independent control
lane. Factories and selectors are opaque identities for their resource kinds.

Listeners and connections belong to task scopes. Retaining or sending a port
shares use; `@give` transfers ownership. A newly accepted connection remains
provisionally owned by its exchange until `port.result` publishes it into the
receiving scope. Failed publication retains that provisional ownership, and
closing an unclaimed exchange closes the connection. Accepted connections are
independent of their listener, including after listener closure. Scope closure
aborts its resources and joins socket cleanup even while identities remain
retained elsewhere.

A listener takes a connection from the kernel backlog only for an active
accept with connection capacity available. At capacity, accept parks until a
connection closes. A waiting accept holds no connection slot. Admission itself
is bounded by the resource's operation capacity; additional callers park.
Competing accepts consume distinct connections and do not broadcast. A peer
that aborts before acceptance is skipped. The runtime does not retry a failed
operation or reopen a failed resource.

Byte endpoints preserve exact integer bytes in `0...255`; they perform no text
decoding. Reads have a single-pending-reader rule. Writes execute FIFO and each
call stays contiguous under bounded pressure. `port.finish` on the output
endpoint rejects new writers and sends EOF after admitted writers and queued
bytes drain, while the input direction remains readable. Framing, TLS,
encoding, and protocol limits belong to libraries. Deadlines compose tasks
with `task.await-for`, cancellation, and joining.

### accept
`( listener -- connection )` — Wait for a peer and claim the accepted connection port into the calling task scope. Accepted connections remain usable after their listener closes. At host connection capacity, wait until a slot is free; competing accepts receive distinct connections. A non-listener is `` `type ``. Abortive listener closure cancels admitted accepts; graceful shutdown may instead report backend closure as `` `io ``. A new call after closure is `` `io ``. Socket or buffer exhaustion and host failures are `` `io ``. Cancelling an accept closes any connection still provisionally owned by that exchange, so none is lost before delivery. Completed exchanges retain their own result and cleanup lifetime independently of the listener.

### close
`( resource -- )` — Gracefully shut down a resource and join cleanup through `port.shutdown`. A listener closes its socket and stops accepting; its admitted accepts end with `` `io `` or `` `cancelled ``. A connection delivers accepted writes to the kernel before closing its socket; this does not establish peer receipt or an external acknowledgement. Cancelling shutdown may discard remaining queued bytes. Repeated graceful shutdown observes the same outcome; graceful shutdown after abortive closure raises `` `io ``. Use `port.close` for idempotent abortive cleanup. This composition also accepts other resources with registered graceful shutdown.

### listen
`( config -- listener )` — Bind a TCP listener by opening `net.core.listener` with a configuration of exactly these two symbol-keyed fields; neither has a default:
- `` `address ``: an IPv4 or IPv6 literal string without IPv6 brackets, such as `"127.0.0.1"`, `"::1"`, `"0.0.0.0"`, or `"::"`.
- `` `port ``: an integer in `0...65535`, such as `8080`; `0` requests an ephemeral port.

Loopback addresses accept local connections; wildcard addresses `"0.0.0.0"` and `"::"` bind available interfaces of their address family, subject to operating-system restrictions. Hostnames are not resolved: do not use a hostname such as `"localhost"`, a URL, or an address with an embedded port. Backlog and buffer capacities are runtime limits, not configuration fields. Inspect the assigned port with `net.local-address` after a port-zero bind.

The returned listener port is already listening and belongs to the calling task scope. Use `net.accept` for connections and `net.close` for graceful shutdown. CLI sessions grant listening; embeddings deny it by default. A non-dictionary or wrongly typed field is `` `type ``; missing or unknown fields, invalid literals or ports, denied host authority, or exhausted listener capacity is `` `domain ``. Common structured-value limits also apply. Host bind and listen failures are `` `io ``. Configuration failures include the requested address, port, and reason where available; controller and lifecycle failures report the common error kind and message.

This module provides listeners and accepted TCP connections, with no outbound-connect word. TCP is a byte stream: a read can return less than requested or combine data from multiple peer writes. Supply framing in the application, and assemble complete UTF-8 sequences before calling `chars`. For a write-side half-close that keeps the connection readable, use `dup net.core.output port.endpoint port.finish`.

#### Examples

Bind an ephemeral port and read back the assigned address:

```ecl
{address "127.0.0.1" port 0} net.listen
dup net.local-address
swap net.close
# Leaves {address "127.0.0.1" port n}, where n is the assigned port.
```

A one-connection greeting server, which blocks until a peer connects. The
first close drains and closes the connection; the second closes the listener.

```ecl
{address "127.0.0.1" port 8080} net.listen
dup net.accept
dup "hello\n" bytes net.write
net.close
net.close
```

### local-address
`( resource -- address )` — Return `{address string port int}` for an open listener or connection. IPv4 uses dotted-quad text; IPv6 uses RFC 5952 text without brackets. A listener bound to port 0 reports its assigned port; a connection accepted through a wildcard listener reports its actual local endpoint. A wrong resource kind is `` `type ``; closure or backend failure is `` `io ``.

### peer-address
`( connection -- address )` — Return the remote endpoint of an open connection in the same `{address string port int}` shape and canonical text as `net.local-address`; a listener has no peer. A non-connection is `` `type ``; closure or backend failure is `` `io ``.

### read
`( connection max -- bytes )` — Read at most positive integer `max` bytes, also bounded by the host receive capacity. Park when no data is ready; short reads are normal and do not mark message boundaries. Return exact integer bytes in `0...255`, or `[]` only at stable EOF; later reads also return `[]`. A wrong capability or non-integer maximum is `` `type ``; a nonpositive maximum is `` `domain ``; an overlapping read is `` `contract ``. Buffered bytes precede a transport failure, which raises `` `io ``. Abortive closure may discard buffered bytes. No text decoding is performed; use `chars` only on complete UTF-8 sequences.

### write
`( connection bytes -- )` — Accept a complete list of integer bytes in `0...255` in FIFO order, parking under bounded pressure. Each call stays contiguous, but TCP does not preserve message boundaries. Convert strings explicitly with `bytes`. A non-list is `` `type ``; an element outside `0...255` is `` `domain ``; finished output, closure, peer reset, or other transport failure is `` `io ``. Acceptance is distinct from delivery, output EOF, and resource cleanup, and does not establish peer receipt. To send EOF while retaining input, use `net.core.output port.endpoint port.finish`.

## path

Lexical operations over slash-separated path strings. Every argument and
result is a string of Unicode scalar values; the separator is always `/`, and
no word reads the filesystem, consults the working directory, follows links,
or applies drive-letter, backslash, case-folding, or Unicode-normalization
rules. Normalization is lexical: it never proves that a path stays within a
directory, which is why `fs` accepts only the canonical grammar and enforces
containment at its directory handles.

### absolute?
`( path -- bool )` — Return 1 exactly when the path begins with `/`.

### extension
`( path -- extension )` — Return the suffix beginning at the final dot of the last element, including the dot, or the empty string when that element has no dot: `.gz` for `x/y.tar.gz`, `.bashrc` for `.bashrc`, and `.` for `a.`.

### relative?
`( path -- bool )` — Return 1 when the path does not begin with `/`: the complement of `absolute?`.

### valid-relative?
`( path -- bool )` — Return 1 when the string is a canonical relative path accepted by `fs`: `.` alone, or nonempty components separated by single slashes with no `.`, `..`, or NUL component and no leading or trailing slash. This predicate never normalizes; normalize first when accepting untrusted text.

### basename
`( path -- name )` — Return the last element after trailing slashes are removed: `/` for a path of only slashes and `.` for an empty path.

### normalize
`( path -- path )` — Lexically clean a slash path: collapse repeated separators and `.` components, resolve each `..` against a preceding component, keep leading `..` components in a relative path, clamp an absolute path at `/`, and return `.` for an empty result. Absolute paths remain absolute and relative paths remain relative.

### components
`( path -- components )` — Normalize the path and return its non-separator components as a list of strings. `.` and `/` yield an empty list; retained leading `..` components remain; absoluteness is observable only through `absolute?`.

### dirname
`( path -- path )` — Return the normalized directory portion before the last slash, or `.` when the path has no slash. `dirname` of `/a` is `/`.

### join
`( segments -- path )` — Join a list of string segments with `/` and normalize the result. Empty segments are ignored; an empty or all-empty list yields `.`. A non-list or a non-string member is `` `type ``.

## port

Factories, operation selectors, and endpoint selectors are opaque `` `port ``
values exported through ordinary library bindings. Repeated lookup preserves
identity. Selectors belong to their issuing module instance and resource kind;
using another kind or the wrong capability variant raises `` `type ``. These
borrowed capabilities are not transferable scope owners.

Exchanges are opaque `` `port `` values with their own task-scope ownership.
An exchange survives the invocation that created it. Retaining or sending its
value shares use; `@give` transfers its scope ownership. Exiting
the owning scope aborts outstanding work and joins cancellation cleanup.

New child resources carried by a result or message remain provisionally
owned until `port.result` or `port.receive` succeeds. A claim publishes all
attached children into the receiving scope together; failed publication retains
the source and its owners. Discarding an unclaimed result or queued message
closes its provisional children, and exchange cleanup joins their retirement.
Already published capabilities share use without moving scope ownership.
Children declare whether they depend on their issuing parent. Parent closure
closes and joins dependent children even after `@give`; independent children
remain usable in their receiving scope. Closed children remain opaque identities.

| Word | Effect | Contract |
|---|---|---|
| `port.open` | `( factory config -- resource )` | Initialize a resource and publish it into the calling scope. Failure joins cleanup through that scope. |
| `port.begin` | `( resource operation request -- exchange )` | Admit a registered operation on its declared FIFO lane, parking while admission capacity is full. |
| `port.call` | `( resource operation request -- value )` | Begin, claim the result, and close the exchange. Requires no additional streaming input or output. |
| `port.endpoint` | `( source selector -- endpoint )` | Borrow a direction-specific endpoint supported by its resource or permitted by its exchange's operation. Supports registered byte and message endpoints. |
| `port.read` | `( readable max -- bytes )` | Read up to a positive maximum; `[]` denotes stable EOF. Overlapping readers raise `` `contract ``. |
| `port.write` | `( writable bytes -- )` | Accept a complete byte list under bounded pressure. Concurrent calls execute FIFO and remain contiguous. |
| `port.send` | `( sender message -- )` | Enqueue one complete structured message atomically, parking under pressure. Empty values are valid messages. |
| `port.receive` | `( receiver -- event )` | Return `{kind message value value}` or `{kind eof}`. Overlapping receivers raise `` `contract ``. |
| `port.finish` | `( writable-or-sender -- )` | Finish input after accepted data. Idempotent; later writes or sends raise `` `io ``. |
| `port.await` | `( exchange -- )` | Wait for successful completion or raise the terminal error. Repeatable; does not drain output. |
| `port.result` | `( exchange -- value )` | Wait and claim the terminal result once. A later successful-result claim raises `` `contract ``. |
| `port.cancel` | `( exchange -- )` | Request cancellation idempotently. Completion remains observable and waits for controller return. |
| `port.shutdown` | `( resource -- )` | Stop new admission, perform registered graceful shutdown, and join cleanup. Unsupported resources raise `` `domain ``. Repeated calls observe the same outcome. |
| `port.close` | `( resource-or-exchange -- )` | Abort and join cleanup. Idempotent for every resource and exchange. |

For TCP resources, `port.shutdown` closes a listener or delivers a connection's
accepted writes before closing its socket. Accepted connections remain independent
of their listener. `port.close` may discard queued connection bytes. Both words
join socket cleanup. For a process, `port.shutdown` requests process-group
termination with the host's escalation policy; `port.close` requests immediate
process-group kill. Both join process cleanup, including blocked pipe transport.
A completed process wait exchange remains observable after resource closure;
new wait operations require an open resource.

A cancelled exchange raises `` `cancelled `` from `port.await` and `port.result`.
Observation does not consume the result. Operations that produce only
stream output have `[]` as their result. Input finish, output EOF, completion,
and cleanup are distinct events. An active cancellation releases its controller
lane only after acknowledgement and return; a controller that cannot restore
reusable state closes its resource.

Endpoints may belong to a resource or to one exchange. Resource endpoints
retain their direction and buffered data across exchange completion; finishing
a resource endpoint or closing its resource ends that direction.
A message may carry a sender through which its recipient replies to a backend
request. Such a sender retains only its permitted direction; request identifiers,
notifications, and response ordering follow the issuing library's protocol.
Endpoint capabilities preserve the source identity and cannot be transferred
independently with `@give`. A selector from another issuing kind, or a read or
write through the wrong direction, raises `` `type ``; an endpoint not permitted
by its source raises `` `domain ``. Buffered output remains readable before a
terminal failure is raised. Once observed, EOF remains stable through later
exchange failure or resource cleanup. An early input consumer exit wakes blocked
writers with `` `io ``. Streaming callers must drain independent outputs concurrently when
necessary for progress; waiting for completion does not drain them.

`port.call` is an ECL composition. It closes the exchange before returning its
result or re-raising its terminal error. It leaves the resource with its owner.
The public `port` module composes the host operations exported by `port.core`.

Configuration and initial requests may contain integers, floats, characters,
symbols, lists, dictionaries, and port capabilities. Executable words, tasks,
and modules are rejected recursively with `` `type ``. Each value is bounded by
64 KiB of scalar/text bytes, 4,096 nodes, and 16 capability occurrences; exceeding
a bound raises `` `overflow `` before initialization or admission. Retaining an
existing resource in a request shares use and does not transfer its scope.

Messages and terminal results use the same structured-value bounds. Default
message capacity is 16 per endpoint and a shared 1 MiB byte budget per resource.
A controller-held message retains its capacity reservation until forwarded,
returned as a result, or discarded. This permits forwarding when the shared
budget is full. Exceeding the resource's entire byte budget raises `` `overflow ``;
temporary saturation parks the producer. Receiving is competing consumption,
not broadcast. Event construction failure leaves the message queued. A receiving
scope that has begun closing cannot consume a message or result; the claim
fails with `` `cancelled `` without consuming the source.
Abortive close discards queued messages and unclaimed results; a discarded
successful result raises `` `io `` if claimed later. Completion observation remains
repeatable. Existing capabilities in messages share use and retain their owner.

### await
`( exchange -- )` — Observe completion without consuming the result or draining output.

### begin
`( resource operation request -- exchange )` — Admit an operation with bounded structured parameters.

### cancel
`( exchange -- )` — Request cancellation. Completion remains observable.

### close
`( resource-or-exchange -- )` — Abort and join cleanup. Idempotent.

### endpoint
`( source selector -- endpoint )` — Borrow an attenuated endpoint supported by its source.

### finish
`( writable -- )` — Finish input after admitted writes. Idempotent.

### open
`( factory config -- resource )` — Initialize a registered resource in the calling scope.

### read
`( readable max -- bytes )` — Read a positive byte chunk, or [] at stable EOF.

### receive
`( receiver -- event )` — Receive {kind message value value} or {kind eof}; one receiver may wait.

### result
`( exchange -- value )` — Wait and claim a result once; a later claim raises `contract.

### send
`( sender message -- )` — Atomically enqueue one bounded structured message, including an empty value.

### shutdown
`( resource -- )` — Perform registered graceful shutdown and join cleanup. Unsupported resources raise `domain.

### write
`( writable bytes -- )` — Accept a complete byte list in FIFO order under bounded pressure.

### call
`( resource operation request -- value )` — Begin an operation, claim its result, and close the exchange. Use only when no additional streaming input or output is required. Close the exchange before returning or re-raising its error.

## proc

Subprocess ports with bounded live counts, queues, and capture sizes.
Process creation is available as an ordinary standard-library operation.
Executable access is determined by the operating system.

The public words are ECL compositions over registered process capabilities,
common port transport, and task primitives.

`proc.core.process` is the registered process factory. Applying `port.open`
to it and a spawn specification creates a process resource subject to the
common structured-value and process limits as `proc.spawn`.
The returned resource supports the process words and common lifecycle words;
the factory is an opaque identity for the process resource kind.

The registered operations `proc.core.wait`, `proc.core.terminate`,
`proc.core.kill`, and `proc.core.capture-limits` require an empty request list.
Wait returns the termination dictionary described below. Terminate and kill
request the corresponding process action and return `[]`; they do not wait
for process exit. Capture-limits returns a dictionary with `` `stdout `` and
`` `stderr `` capture limits. Wait has its own FIFO lane; the
other operations share an independent control lane. Cancelling a wait leaves
the process running and makes its lane reusable after cancellation settles.
Each exchange result is claimable once, while completion observation is
repeatable. Process exit leaves the resource open for further operations;
closing the resource prevents new admission and joins backend cleanup.

`proc.core.stdin`, `proc.core.stdout`, and `proc.core.stderr` are endpoint
selectors for process resources. `port.endpoint` with stdin grants writing and
finishing; stdout and stderr grant reading. Their byte, EOF, and single-reader
contracts are shared with the corresponding process words. Finishing stdin
delivers accepted bytes before closing that direction, is idempotent, and
rejects subsequent writes, including empty writes. Endpoints share permitted
use without owning the resource; they cannot be transferred with `@give`.

A spawn specification is a dictionary whose keys are symbols, with only the
following fields. The nested environment dictionary uses **string** keys.

| Field | Value | Required / default |
| --- | --- | --- |
| `` `executable `` | Absolute executable path string; no `PATH` lookup | Required |
| `` `args `` | List of argument strings, excluding the executable name | `[]` |
| `` `cwd `` | Absolute directory path string without `.` or `..` components | Startup working directory |
| `` `env `` | String-to-string dictionary, for example `{"LANG" "C"}` | `{}`; overlay on the captured process environment |

Paths, arguments, and environment strings cannot contain NUL. Environment
names must be nonempty and contain no `=`. An environment overlay replaces
matching names and preserves other base entries; `{}` does not clear the base.
There is no shell-command form, expansion, or `PATH` search: spaces and shell
metacharacters in an argument are passed literally. Unknown fields and missing
`` `executable `` are `` `domain ``; non-symbol keys and wrongly typed fields are
`` `type ``; invalid field values are `` `domain ``. Validation precedes process creation.

For example, on a POSIX host with `/bin/cat`, capture a byte-exact round trip:

```ecl
{executable "/bin/cat" stdin [104 101 108 108 111 10]} proc.run
# {term {kind exited code 0} stdout [104 101 108 108 111 10] stderr []}
```

A fuller specification adds arguments, a working directory, and environment:

```ecl
{executable "/bin/echo"
 `args ["hello world"]
 `cwd "/tmp"
 `env {"LANG" "C"}
 `stdout-limit 4096
 `stderr-limit 4096
 `timeout-ms 1000} proc.run
`stdout at chars
# "hello world\n"
```

These examples require the named executables and directory to exist, and the
host to permit the requested paths and capture bounds. Use `bytes` to encode
text for stdin and `chars` to decode complete UTF-8 output. Arbitrary process
output may not be valid UTF-8.

Prefer `proc.run` when the output fits a known bound. With `proc.spawn`, feed
stdin and drain **both** output pipes concurrently when they can fill. A child
may wait for stdin EOF before exiting, so call `proc.close-input` when feeding
is complete. `proc.wait` does not drain output: waiting first can deadlock on a
full pipe. Reads may split text characters or application messages across
chunks. Close the resource with `port.close` when finished; waiting for exit
does not close it.

Bytes are ordinary integer lists whose elements are all in `0...255`. Process
streams do not decode Unicode. A port is an opaque identity capability that
prints `<port:N>` and has type `` `port ``; it exposes no PID and cannot be passed
through JSON. Native words can view and forward its opaque identity.

### close-input
`( resource -- )` — Finish stdin after queued bytes have been written, sending EOF to the child. Idempotent. A concurrent or later write, including an empty write, is `` `io ``. Output remains readable; this does not wait for process exit or close the process resource.

### kill
`( resource -- )` — Request force termination of the process group and arrange direct-child reap. Idempotent and safe after natural exit while the resource remains open. This does not wait for exit; use `proc.wait` to observe termination and `port.close` to join cleanup.

### read-stderr
`( resource max -- bytes )` — Read at most positive integer `max` bytes from stderr, parking when no data is ready. Return exact integer bytes in `0...255`; `[]` means stable EOF, and later reads also return `[]`. Reads may be shorter than `max`. A non-integer maximum is `` `type ``; a nonpositive maximum is `` `domain ``; at most one stderr read may be pending, so overlap is `` `contract ``; pipe failure is `` `io ``. Drain stdout concurrently when it can fill, or use `proc.run` to capture both streams.

### read-stdout
`( resource max -- bytes )` — Read at most positive integer `max` bytes from stdout, parking when no data is ready. Return exact integer bytes in `0...255`; `[]` means stable EOF, and later reads also return `[]`. Reads may be shorter than `max`. A non-integer maximum is `` `type ``; a nonpositive maximum is `` `domain ``; at most one stdout read may be pending, so overlap is `` `contract ``; pipe failure is `` `io ``. Use `chars` to decode UTF-8. Drain stderr concurrently when it can fill, or use `proc.run` to capture both streams.

### spawn
`( spec -- resource )` — Start the directly named, authorized executable with stdin, stdout, and stderr pipes. `spec` is a symbol-keyed dictionary:
- `` `executable ``, required: an absolute path string.
- `` `args ``: a list of argument strings, default `[]`; it excludes the executable name.
- `` `cwd ``: an absolute path string without `.` or `..` components, default the host-configured starting directory.
- `` `env ``: a string-to-string dictionary overlaid on the host's environment base, default `{}`.

Strings must not contain NUL, and environment names must be nonempty and contain no `=`. There is no shell expansion or `PATH` search. Unknown fields, invalid values, or denied authority are `` `domain ``; wrong field types are `` `type ``; launch failures are `` `io ``.

The child and its process group, pipe tasks, and spawning task-scope membership commit before the port becomes visible. The calling task scope owns the live child: scope closure cancels the process group and waits for reap even if a port value remains stored elsewhere. Returning or storing the port does not detach it; `@give` is the one way to change owner, and the unit it is given to kills the group when it ends. Use `proc.run` for bounded capture, or drain both output streams concurrently.

### terminate
`( resource -- )` — Request ordinary termination of the process group without waiting for exit, escalating to force termination during cleanup when needed. Idempotent and safe after natural exit while the resource remains open. Use `proc.wait` to observe termination and `port.close` to join cleanup.

### wait
`( resource -- termination )` — Park until direct-child termination without draining stdout or stderr, and return the immutable terminal result:
- `{kind exited code n}`;
- `{kind signaled signal n}`;
- `{kind stopped signal n}`; or
- `{kind unknown status n}`.

Any number of waiters and later calls receive the same dictionary. A nonzero exit code is ordinary termination data, not an ECL error. A pipe failure raises `` `io ``. Output pipes can fill and prevent exit, so drain both concurrently or use `proc.run`. Waiting requires an open resource; after closure, observe a previously completed exchange instead of admitting another wait. This leaves the resource open; use `port.close` to join cleanup.

### write
`( resource bytes -- )` — Queue exact stdin bytes, a list of integers in `0...255`, parking under bounded pressure. Convert text with `bytes`. Calls are serialized in scheduler-arrival order and each call's bytes remain contiguous. A non-list is `` `type ``; invalid byte elements are `` `domain ``; finished, closed, or broken stdin is `` `io ``. Acceptance does not mean all bytes have reached the child. Drain stdout and stderr concurrently to avoid pipe deadlock.

### run
`( spec -- result )` — Spawn through the ordinary port controller, supply all stdin while draining stdout and stderr concurrently, wait for direct-child reap, join cleanup, and return `{term termination stdout stdout-bytes stderr stderr-bytes}`. `spec` takes the `proc.spawn` fields under the same path, string, and host-authority rules, plus these optional run-only fields, which `proc.spawn` rejects:
- `` `stdin ``: a list of integer bytes in `0...255`, default `[]`; strings require explicit `bytes` conversion.
- `` `stdout-limit ``: a nonnegative integer maximum of total captured stdout bytes, default the host stdout capture maximum.
- `` `stderr-limit ``: a nonnegative integer maximum of total captured stderr bytes, default the host stderr capture maximum.
- `` `timeout-ms ``: a nonnegative integer deadline in milliseconds covering spawn and execution; omitted means no process deadline, while scheduler cancellation remains effective.

Each capture limit must be no larger than its host maximum, and zero permits only empty output on that stream. Stdin is finished after feeding, including when omitted. The result always contains all three keys: `` `term `` has the `proc.wait` shape, and `` `stdout `` and `` `stderr `` are byte lists, empty when nothing was captured. Nonzero exit codes are returned as data; inspect `` `term `` to decide whether the command succeeded, and decode output explicitly with `chars`.

Capture overflow kills and cleans the process before raising `` `overflow ``. Deadline expiry does the same before raising `` `timeout ``; task cancellation raises `` `cancelled ``, also after joined cleanup. Wrong field types are `` `type ``; invalid values or denied authority are `` `domain ``; spawn, pipe, broken-input, and reap failures are `` `io ``. The deadline covers the child task that opens and runs the process. Output collectors enforce their limits independently; a failed collector cancels the remaining work and joins resource cleanup. Successful input acceptance is distinct from backend pipe completion, and a later broken pipe still fails the run.

## rand

Explicit-state pseudorandom draws are pure except for `entropy`; see
[Randomness](SPEC.md#randomness). The state is `[key counter]`, and every draw
returns the advanced state alongside its result. An ambient generator is an
agent holding that state: ``[0 0] agent.start `rng set`` then
`(5 rand.int) rng agent.call`.

### deal
`( state count pool -- state results )` — Draw `count` distinct ints in
`[0, pool)` without replacement, advancing the state by `count`. Work and
memory follow `count`, never `pool`. A negative count or pool, or a count
above the pool, is `` `domain ``; a non-int count or pool is `` `type ``.

#### Examples

```ecl
[7 0] 3 10 rand.deal pair
# => ([7 3] [7 0 4])
```

### entropy
`( -- result )` — Read one int from the host CSPRNG. This is the language's
only nondeterministic word, requires host IO, and is `` `io `` without it.

### float
`( state -- state result )` — Draw one uniform float in `[0, 1)`.

### int
`( state bound -- state result )` — Draw one unbiased uniform int in
`[0, bound)`. A bound below 1 is `` `domain ``.

#### Examples

```ecl
[0 0] 100 rand.int pair
# => ([0 1] 35)
```

### ints
`( state count bound -- state results )` — Draw `count` uniform ints in
`[0, bound)`, advancing the state by `count`. Each element is addressed by its
own counter position, so materialization order cannot change the list.

#### Examples

```ecl
[7 0] 4 6 rand.ints pair
# => ([7 4] [3 0 0 3])
```

### shuffle
`( state values -- state values )` — Return a uniformly selected permutation
of a list, advancing the state by the list's length. Any element kind is
permuted and the list keeps its representation. A non-list is `` `type ``.

#### Examples

```ecl
[7 0] [10 20 30 40] rand.shuffle pair
# => ([7 4] [40 20 30 10])
```

## result

Every entry validates its result envelope before invoking a caller quotation.
A success payload is always a list representing a stack.

### err
`( error -- result )` — Tag an error dict as a failed result.

### ok
`( values -- result )` — Build an ok result from a list of successful stack values, representing the stack a successful computation left.

### and-then
`( result quotation -- result )` — For a success, use its payload as the explicit values list for `@attempt`, running the quotation on an isolated stack seeded with the success values. Return a failure unchanged.

#### Examples

```ecl
[2 3] result.ok (+) result.and-then
# => {ok [5]}
```

### either
`( result on-ok on-err -- ... )` — Eliminate a result exhaustively: call `on-ok` with the success list or `on-err` with the error dict. Neither branch is isolated; each runs inline and may leave any number of values.

#### Examples

```ecl
{kind io} result.err (first) (`kind at) result.either
# => io
```

### err?
`( result -- bool )` — Return 1 when a well-formed result is a failure.

### map-err
`( result quotation -- result )` — Replace a failure's error dict with the one its isolated `( error -- error )` quotation returns. Return a success unchanged.

### ok?
`( result -- bool )` — Return 1 when a well-formed result is a success.

### or-else
`( result fallback -- value )` — Return a success list, or the fallback value for a failure.

### or-raise
`( result -- values )` — Return a success list, or re-raise the stored error dict unchanged.

### recover
`( result quotation -- result )` — For a failure, run the recovery quotation under `@attempt` on an isolated stack seeded with the stored error dict. Return a success unchanged.

### all
`( results -- result )` — Return the leftmost failure unchanged, or one success whose value is the list of success stacks in input order.

### partition
`( results -- successes errors )` — Split results into success lists and error dicts, both in input order, without re-raising.

### recover-kinds
`( result kinds quotation -- result )` — Recover a failure only when its kind is one of the listed symbols. Return every other result unchanged.

#### Examples

```ecl
{kind io} result.err [io timeout] (pop 99 wrap) result.recover-kinds
# => {ok ([99])}
```

## source

### declarations
`( quotation -- list )` — Inspect parsed source without executing it. Return
the symbols immediately preceding top-level `@defm` words, in source order.
Preserve duplicate names and report literal spellings without validating
namespace or export policy. Ignore computed names and declarations inside
quotations, lists, dictionaries, strings, or comments. This reports syntactic
declarations, not proof that executing the source would register a module.
Like other quotation operations, this accepts a list (`` `type `` otherwise).
Use `parse` to inspect text, with its ordinary parse failures. Inspection is
cancellable.

```ecl
"[] () `example @defm" parse source.declarations
# => (example)
```

## str

All case and whitespace operations use the ASCII character classes; every
non-ASCII scalar passes through unchanged.

### str?
`( value -- bool )` — Return 1 when a value is a string, a list whose every element is a char, and 0 for every other value. The empty string answers 1, and so does the empty list: they are one value. Never raises.

### contains?
`( string needle -- bool )` — Return 1 when a needle occurs anywhere in a string. The empty needle is present at index zero.

#### Examples

```ecl
"hello" "ell" str.contains?
# => 1
```

### ends?
`( string suffix -- bool )` — Return 1 when the string ends with the suffix.

### index-of
`( string needle -- index )` — Return the zero-based index of a needle's first occurrence. Return 0 for the empty needle and raise `` `domain `` when a nonempty needle is absent.

### lower
`( string -- string )` — Lowercase ASCII letters, leaving every other scalar unchanged.

### pad-left
`( string width -- string )` — Add leading spaces until the string reaches the requested width; return a longer string unchanged.

### pad-right
`( string width -- string )` — Add trailing spaces until the string reaches the requested width; return a longer string unchanged.

### repeat
`( string count -- string )` — Concatenate `count` copies of a string; `count` must be nonnegative.

### replace
`( string needle replacement -- string )` — Replace every occurrence of a needle. An empty needle inserts the replacement between adjacent scalars only, with no boundary insertion.

#### Examples

```ecl
"a-b-c" "-" "+" str.replace
# => "a+b+c"
```

### starts?
`( string prefix -- bool )` — Return 1 when the string starts with the prefix.

### trim
`( string -- string )` — Remove ASCII whitespace from both ends of a string.

#### Examples

```ecl
"  hello  " str.trim
# => "hello"
```

### trim-left
`( string -- string )` — Remove leading ASCII whitespace.

### trim-right
`( string -- string )` — Remove trailing ASCII whitespace.

### upper
`( string -- string )` — Uppercase ASCII letters, leaving every other scalar unchanged.

#### Examples

```ecl
"Hello, wörld!" str.upper
# => "HELLO, WöRLD!"
```

### format
`( values template -- string )` — Interpolate positional `{}` placeholders. Strings contribute their contents; other values contribute canonical `str`. `{{` and `}}` emit literal braces.

#### Examples

```ecl
["Ada" 2] "name={} n={}" str.format
# => "name=Ada n=2"
```

## table

Every operation except `valid?` first validates the ordinary column dict as a
table. See the environment's [table contract](ENVIRONMENT.md#tables) for the
table convention and frozen error kinds.

### from-records
`( records -- table )` — Build a table from a nonempty list of dicts sharing one key set. The first record fixes the schema order; later records may use a different key order.

#### Examples

```ecl
[{"name" "Ada" "score" 10} {"name" "Lin" "score" 20}] table.from-records
# => {"name" ("Ada" "Lin") "score" [10 20]}
```

### from-rows
`( names rows -- table )` — Build a table from explicit column names and rows of exactly that width. An empty row list preserves the named zero-row schema.

#### Examples

```ecl
["name" "score"] [("Ada" 10) ("Lin" 20)] table.from-rows
# => {"name" ("Ada" "Lin") "score" [10 20]}
```

### cast
`( table spec -- table )` — Coerce named columns with isolated `( cell -- value )` quotations. The specification must be a dictionary from existing column names to quotations. Validate the complete specification before running any quotation, and replace the table only after every cast succeeds.

### column
`( table name -- column )` — Return one existing column by name.

### from-columns
`( columns -- table )` — Validate a column dictionary and return it as a table, raising when it does not satisfy the convention.

### from-header-rows
`( rows -- table )` — Build a table from rows whose first row contains the column names and whose remaining rows are data.

### header-rows
`( table -- rows )` — Return the column-name row followed by the data rows, the schema-preserving row form.

### height
`( table -- count )` — Return the number of rows.

### names
`( table -- names )` — Return the column names in schema order.

### records
`( table -- records )` — Return one dict per row, with keys in schema order. A zero-row table returns an empty list, which necessarily loses its schema.

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} table.records
# => ({"name" "Ada" "score" 10} {"name" "Lin" "score" 20})
```

### rename
`( table mapping -- table )` — Rename columns through an ordered old-to-new mapping without changing column order; collisions are `` `domain ``.

### rows
`( table -- rows )` — Return the data rows in row and column order.

### select
`( table names -- table )` — Return the named columns in the order given.

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} ("score") table.select
# => {"score" [10 20]}
```

### valid?
`( candidate -- bool )` — Return 1 when a candidate satisfies the table convention and 0 for a convention mismatch. Cancellation, allocation failure, and other runtime errors still propagate.

### where
`( table mask -- table )` — Return the rows selected by a 0/1 mask whose length equals the row count.

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} [1 0] table.where
# => {"name" ("Ada") "score" [10]}
```

### with-column
`( table name column -- table )` — Replace an existing column or append a new one. The column length must equal the row count.

### inner-join
`( left right pairs -- table )` — Return the stable inner equijoin for `[left-name right-name]` key pairs. Duplicate keys expand to the full many-to-many product in left-row then right-row order. The result contains every left column followed by the right non-key columns; colliding non-key names are `` `domain ``.

### left-join-with
`( left right pairs fill -- table )` — Return the stable left equijoin, using fill values for unmatched rows. `fill` must name exactly every appended right column.

### group-by
`( table names -- groups )` — Group row indices by the named columns. Groups follow first-occurrence order and indices within each group are ascending; an empty name list yields one global group keyed by the empty list.

### aggregate
`( table names specs -- table )` — Group by `names` and aggregate each group with `[output-name input-name reducer]` specifications. A reducer is a quotation or one of `` `sum ``, `` `count ``, `` `min ``, and `` `max ``. Symbols use `reduce-groups`; quotations receive gathered slices and retain ordinary resolution and shadowing. All names and specifications are validated before a quotation runs. The result contains the key columns first, followed by the aggregate columns in specification order, with one row per group.

## task

Task handles are created by the core unit constructors `@spawn` and `@give`.
A handle observes a task's lifetime and result. `task.address` derives the
task's address, which names only its mailbox, and `task.self` is the
executing task's own. Use `(task.await) each` to collect results in input
order without cancelling siblings or re-raising task errors.

Request and reply is a composition over `send` and `receive`: spawn a helper
task, send its address with the request, and await the helper, whose result
is the reply. `task.await-for` bounds the exchange.

```ecl
(|a v| [] (task.receive) @spawn dup task.address {} `value v put `from rolldown put a task.send task.await `ok at first) `ask def
[] (task.receive dup `from at swap `value at 1 + swap task.send) @spawn task.address 41 ask
# => 42
```

### address
`( task -- address )` — The address of a task's mailbox. Two addresses of
one task match. An address outlives its task; after the task ends it names a
closed mailbox.

### await
`( task -- result )` — Park until the task completes; return its cached
`{ok …}`/`{err …}` result. Idempotent. See
[Concurrency](SPEC.md#concurrency).

### await-any
`( tasks -- index result )` — Race a nonempty all-task list; among tasks
already terminal at entry the lowest index wins, otherwise the first
completion.

### await-for
`( task milliseconds -- result )` — `task.await` with a nonnegative int
deadline; expiry returns `{err {kind timeout}}` without cancelling the
task. A terminal task beats even a zero deadline. A deadline beyond any
instant the scheduler clock can report is `` `overflow `` before the wait
registers.

### cancel
`( task -- )` — Request cancellation; the task's result becomes
`{err {kind cancelled …}}`. No-op when already terminal.

### cancel-self
`( -- )` — Request cancellation of the current task, exactly as `task.cancel`
does with its handle. It is only a request: execution continues, and the task
observes it at its next safe point. `` `domain `` outside a task. There is
deliberately no way to obtain the current task's handle, so a task's result
can never retain its own task.

### pending
`( -- tasks )` — Pending descendant tasks in deterministic spawn
preorder.

### receive
`( -- value )` — Take the oldest message from the executing task's mailbox,
parking until one arrives. `` `domain `` outside a task.

### receive-for
`( milliseconds -- result )` — `task.receive` with a nonnegative int
deadline: `{ok value}`, or `{err {kind timeout}}` when nothing arrives in
time. A deadline beyond any instant the scheduler clock can report is
`` `overflow ``. `` `domain `` outside a task.

### self
`( -- address )` — The executing task's own address. `` `domain `` outside a
task: the session root owns tasks but has no mailbox.

### send
`( value address -- )` — Queue a value in the mailbox an address names. Any
value may be sent except one containing a task handle, which is `` `type ``;
addresses and ports pass. A mailbox holds sixteen messages, and a sender to a
full one parks until the receiver takes a message. Sending to a task that has
ended is `` `io `` with `` `reason `closed ``. Messages from one sender arrive in
order; order across senders is unspecified.

#### Examples

```ecl
[] (task.receive 1 +) @spawn dup task.address 41 swap task.send task.await
# => {ok [42]}
```

## test.default

The bundled runner is ordinary ECL policy over the closed `tests` / `@test`
substrate. Projects may replace it with any public qualified runner word.

### run
`( -- )` — Discover canonical tests and invoke them sequentially in deterministic module and name order, printing one `ok` or `FAIL` line for every result. Continue after ordinary test failures and request process status 1 if any failed.

## time

Pure UTC time over the millisecond timestamps `clock.unix` produces. Every
word accepts and returns whole milliseconds; a timestamp is `{unix ms}` and
nothing else — a `{monotonic ms}` instant, an untagged int, a float payload,
or a dictionary with any other key is `` `type ``. Arithmetic is checked: leaving
the int millisecond range is `` `overflow ``. Calendar words use the proleptic
Gregorian calendar with no leap seconds, so Unix time here is the POSIX count
in which every day has exactly 86,400,000 milliseconds. The representable
range runs from `-292275055-05-16T16:47:04.192` through
`292278994-08-17T07:12:55.807`. Nothing in this module reads a clock.

### add
`( timestamp milliseconds -- timestamp )` — Shift a timestamp by a signed integer millisecond duration.

### cmp
`( left right -- ordering )` — Three-way compare two timestamps as −1, 0, or 1. Whole-value `match?` also compares timestamps; `<` and `=` do not.

### days
`( n -- milliseconds )` — Convert `n` whole days of 86,400 seconds to milliseconds.

### diff
`( later earlier -- milliseconds )` — Return `later` minus `earlier` in signed milliseconds.

### format
`( timestamp -- string )` — Render a timestamp as `YYYY-MM-DDTHH:MM:SS.mmmZ`: always UTC, always three fractional digits, so `format` then `parse` returns the same timestamp and `parse` then `format` returns the same text for every string in that shape. A year outside 0000 through 9999 cannot be written in four digits and is `` `domain ``.

#### Examples

```ecl
0 time.from-unix time.format
# => "1970-01-01T00:00:00.000Z"
```

### from-unix
`( milliseconds -- timestamp )` — Tag an integer Unix millisecond count as `{unix milliseconds}`. Negative counts name instants before 1970.

### from-utc
`( fields -- timestamp )` — Build a timestamp from a dictionary of int UTC calendar fields. `` `year ``, `` `month ``, and `` `day `` are required; `` `hour ``, `` `minute ``, `` `second ``, and `` `millisecond `` default to 0; `` `weekday `` is optional and must agree with the date. Any other key is `` `domain ``; a non-symbol key or non-int value is `` `type ``. Month is 1 through 12, day is 1 through the month's length in that year, hour 0 through 23, minute and second 0 through 59, and millisecond 0 through 999; anything else is `` `domain ``. `to-utc` output round-trips exactly.

### hours
`( n -- milliseconds )` — Convert `n` whole hours to milliseconds.

### minutes
`( n -- milliseconds )` — Convert `n` whole minutes to milliseconds.

### parse
`( text -- timestamp )` — Parse an RFC 3339 `date-time`, converting any offset to UTC: `YYYY-MM-DDTHH:MM:SS`, an optional fraction, then `Z` or a numeric `±HH:MM` offset that is subtracted to reach UTC. The whole text may be at most 35 characters, so a fraction holds one to fourteen digits before `Z` or one to nine before a numeric offset; longer text is `` `parse ``. `T` and `Z` may be lower case. The first three fractional digits are kept and the rest are discarded, so `"…:00.1239Z"` and `"…:00.123Z"` parse alike. Text outside the grammar, such as a space separator, a missing designator, trailing characters, a non-ASCII scalar, or an empty fraction, is `` `parse ``; a well-formed field outside its range, including second `60`, is `` `domain ``.

#### Examples

```ecl
"2024-02-29T12:34:56.789+05:30" time.parse time.format
# => "2024-02-29T07:04:56.789Z"
```

### seconds
`( n -- milliseconds )` — Convert `n` whole seconds to milliseconds.

### to-unix
`( timestamp -- milliseconds )` — Return the integer Unix millisecond count inside a timestamp.

### to-utc
`( timestamp -- fields )` — Decompose a timestamp into the UTC calendar fields `{year month day hour minute second millisecond weekday}`, all ints. `` `weekday `` counts from Monday as 0 through Sunday as 6. Years before 1 are negative in astronomical numbering: year 0 is 1 BC and is a leap year.

#### Examples

```ecl
951782400000 time.from-unix time.to-utc
# => {year 2000 month 2 day 29 hour 0 minute 0 second 0 millisecond 0 weekday 1}
```
