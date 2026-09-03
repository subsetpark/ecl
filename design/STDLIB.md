# ecl — core and standard library reference

Every public binding below ships in the core image or embedded standard
library, one entry per word. Prelude and core come first; standard-library
modules then appear by module name, with each section's words ordered by
codepoint — the language's own string ordering (`cmp`) — so symbol-spelled
words precede letter-spelled ones. An entry gives the word's successful stack
effect followed by its semantics. Source and native bindings carry declared
effects reflected by `which` and `see`; built-in words that hand work to a scheduler driver
state the same shape in their documentation because their result appears after
the primitive callback returns. The language rules behind those effects live in the
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
`'overflow`.

### \*file\*
`( -- string )` — Return the source name attached to the currently executing
reader-authored occurrence. A definition reports the file that authored its
body even when another file calls it. `'domain` in runtime-assembled code with
no source provenance; there is no fallback to the caller's file.

### \*module\*
`( -- 'module-name )` — Return the canonical registration name selected by
the current module activation. The same image registered under different names
reports the name through which it was called; an alias reports its target's
canonical name. `'domain` at top level, during module construction, through an
anonymous module value, or through an escaped quotation whose image has no
invoking registration.

### +
`( x y -- z )` — **Pervasive.** Add. Acts ordinally on chars:
`char int +` (either order) is a char; `char char +` is `'type`. Integer
overflow is `'overflow`.

#### Examples

```ecl
1 2 +
# => 3
```

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
`( values quotation -- result )` — *Unit constructor.* Initialize an isolated
substack from the explicit values list, then run the quotation as a new unit.
Use `[]` for no initial values. Always pushes exactly one result:
`{'ok (values)}` with the successful stack values as a list, or
`{'err <error dict>}`.

Observationally `@spawn await` — same result shape, same error protocol,
same self-contained-quotation contract — differing only in scheduling.
That identity is what makes the isolation non-arbitrary rather than an
implementation accident. The complete form is `values (q) @attempt`. See
Errors.

#### Examples

```ecl
[1 2] (3 +) @attempt
# => {'ok [1 5]}
```

### @defm
`( values body 'module-name -- )` — *Unit constructor.* Exactly `@module` followed
by `register`: run the body on a fresh environment, then validate the
canonical module path and register the resulting image under it. The body is
evaluated before the name is validated, so the two spellings agree on every
observable outcome.

The name is last, matching `def` and `set`: the bound name sits nearest
the binder. Registration is therefore `values (body) 'name @defm`. See
Modules.

### @each
`( sequence values quotation -- results )` — *Unit constructor*, one fresh unit
per element, contract `( a -- b )` enforced per element. Concurrent
`each`: ordered results, leftmost failure re-raised after cancelling and
quiescing the remainder. Each child's stack starts with its element deepest;
`list values (q) @each` adds the shared values above it. See
Concurrency.

### @module
`( values body -- module )` — *Unit constructor.* Run the body on a fresh
environment and return the resulting anonymous immutable module image. No
registry name is claimed and no name is validated. The body's final operand
stack becomes the image's initial-state template. Use `values (body) @module`.
See [Modules](SPEC.md#modules).

### @spawn
`( values quotation -- task )` — *Unit constructor.* Initialize a child stack
from the explicit values list and run the quotation concurrently. Use `[]` for
no initial values; the ambient stack never crosses the boundary. See
[Concurrency](SPEC.md#concurrency).

#### Examples

```ecl
[] (40 2 +) @spawn await
# => {'ok [42]}
```

### @test
`( descriptor -- result )` — Test-Session-only protected invocation. Validate
a pure descriptor returned by `tests`, late-bind its canonical module/name to
the current catalog, and run the body as a fresh isolated Unit under that
registration's private home and durable state. Return exactly
`{'ok (values)}` or `{'err error}`; a missing current test is a reified error.
Ordinary Sessions receive `'domain`.

### abs
`( x -- y )` — **Pervasive.** Absolute value. Defined in ecl; `'abs see`
renders the definition.

### alias
`( 'short 'module-name -- )` — Register an unqualified short registry name
for a canonical, possibly dotted module name.
Aliases and module names may not collide in either direction.

### all?
`( sequence predicate -- bool )` — *Isolated*, contract `( a -- bool )`.
1 when the predicate returns 1 for every element. Equivalent to
`(|l q| l q each 1 (and) fold)`.

#### Examples

```ecl
[2 4 6] (2 mod 0 =) all?
# => 1
```

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
Pervades over nested list selectors, preserving their shape, so an index
vector selects: `[10 20 30] [2 0] at` is `[30 10]`. A dictionary key is
always one whole value, including when that value is a list. A missing dict
key is an error.

#### Examples

```ecl
[10 20 30] [2 0] at
# => [30 10]
```

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
`{'ok …}`/`{'err …}` result. Idempotent. See
[Concurrency](SPEC.md#concurrency).

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
task. A terminal task beats even a zero deadline. A deadline beyond any
instant the scheduler clock can report is `'overflow` before the wait
registers.

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
`count` places, filling zeros from the top. The logical shift makes `-1 1 bsr`
produce `maxint`. A `count` outside `0..63`
is `'domain`.

### bxor
`( x y -- z )` — **Pervasive.** Bitwise exclusive or. On 0/1 masks `<>`
does the same job on any leaf type; `bxor` is for whole patterns.

### bytes
`( value -- bytes )` — Encode a string as UTF-8 into a byte list: an integer
list whose elements are 0 through 255. A byte list is returned unchanged, so
the word is idempotent. Any other value is `'type`. Inverse of `chars`; see
[Conversions](SPEC.md#conversions).

#### Examples

```ecl
"hé" bytes
# => [104 195 169]
```

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
Defined in ecl; `'case see` renders the definition.

#### Examples

```ecl
3 [1 ("one") 3 ("three") ("other")] case
# => "three"
```

### cat
`( left right -- list )` — Concatenate two lists.

### ceil
`( x -- integer )` — **Pervasive.** Round up; the result is int64,
`'overflow` outside its range.

### char
`( value -- char )` — Return a char unchanged, the char with an int's codepoint,
or the single char of a one-char string. An int outside the Unicode scalar
range or a string of any other length is `'domain`; any other value is `'type`.

#### Examples

```ecl
955 char
# => \λ
```

### chars
`( value -- string )` — Return a value's text content as a string: a string
unchanged, the spelling of a symbol or word, a char as a one-element string,
or a byte list decoded as UTF-8. Bytes that are not valid UTF-8 are `'domain`
with `'reason 'invalid-utf8`; a list that is neither a string nor a byte list,
or any other kind, is `'type`. Unlike `str`, the result is content rather than
representation: `'foo chars` is `"foo"`, not `"'foo"`. See
[Conversions](SPEC.md#conversions).

#### Examples

```ecl
'foo chars [104 195 169] chars
# => "foo" "hé"
```

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
optional effect and documentation metadata. See
[Definition annotations](SPEC.md#definition-annotations) for the annotation
forms and validation; see [Modules](SPEC.md#modules) for module-context
requirements.

### defp
`( annotation? body 'name -- )` — Bind a private module word, with
optional effect and documentation metadata. A top-level `defp` is an
error.

### del
`( collection key -- collection )` — Functionally remove an in-bounds list
index or a dictionary key. List indices must be nonnegative integers within
the list; an invalid index is `'domain`. A missing dictionary key leaves the
dictionary unchanged.

### dip
`( x q -- … x )` — *Inline.* Run a quotation beneath a protected top
value: `q` runs with `x` removed, then `x` returns. Equivalent to
`swap literal compose call`.

### distinct
`( list -- list )` — First occurrence of each distinct value, in input
order. Equivalent to `group dict.keys`.

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
`( collection quotation -- collection )` — *Isolated*, contract `( a -- b )`.
For a list, apply one level down the leading axis, exactly one result per
element; the result specializes when rectangular. For a dictionary, apply to
its values in insertion order while preserving its keys. Depth composes by
nesting: `((q) each) each`. There is no collect-all map whose output length
follows dynamic stack behavior: filtering is the mask idiom (or `filter`), and
flat-map is `each raze`. Derived verbs come free from homoiconicity:
`((1 +) each) 'inc-all def`.

#### Examples

```ecl
[1 2 3] (dup *) each
# => [1 4 9]

{'a 1 'b 2} (1 +) each
# => {'a 2 'b 3}
```

### each-prior
`( list seed quotation -- list )` — *Isolated*, contract
`( current prior -- result )`. Apply left-to-right, using the explicit seed
as the predecessor of the first element. Thus
`[12 13 11] 10 (-) each-prior` is `[2 1 -2]`. Defined in ecl over
`zip-with`.

### empty?
`( sequence -- bool )` — 1 when the sequence has no elements. Equivalent
to `len 0 =`.

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

#### Examples

```ecl
[1 2 3 4] (2 mod 0 =) filter
# => [2 4]
```

### find
`( sequence needle -- index )` — Index of the first element that
returns 1 from `match?` against the needle, or the sequence length on a
miss. Defined in ecl.

### first
`( list -- value )` — First element of a nonempty list.

### flip
`( list -- list )` — Transpose; requires an exact rectangular
list-of-lists.

### float
`( value -- float )` — Return a float unchanged, an int as a float, or the
value of a string in the numeric-literal grammar. A string outside that grammar
is `'parse`; any other value is `'type`.

#### Examples

```ecl
"2.5e1" float 3 float
# => 25.0 3.0
```

### floor
`( x -- integer )` — **Pervasive.** Round down; the result is int64,
`'overflow` outside its range.

### fold
`( list accumulator quotation -- accumulator )` — *Isolated*, contract
`( acc a -- acc )`. Reduce left-to-right from the supplied accumulator.

#### Examples

```ecl
[1 2 3 4] 0 (+) fold
# => 10
```

### fold1
`( list quotation -- value )` — *Isolated*, contract `( acc a -- acc )`.
Reduce a nonempty list left-to-right from its first element. The explicit
accumulator form `fold` is required for an empty list. Defined in ecl.

### for
`( collection quotation -- )` — *Isolated*, contract `( a -- )`. Apply to list
elements or dictionary values in insertion order, left-to-right, collecting
nothing.

### getenv
`( name -- string )` — The value of an environment variable, read from an
immutable snapshot taken once at session start. An unset variable is an
error, never a blank: absence is absence, and `@attempt`/`or-else` is the
defaulting idiom. Absent host IO is `'io`.

### grade
`( list -- indices )` — The stable ascending sort permutation. Orders by
`cmp`, so every element pair must be mutually comparable.

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
['a 'b 'a] group
# => {'a [0 2] 'b [1]}
```

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
sublist is an element: `[1 1] [[0 0] [1 1]] in?` is `[0 0]`, the results of
two atom searches. Use `([1 1] match?) any?` for
that.

#### Examples

```ecl
[2 5] [1 2 3] in?
# => [1 0]
```

### import
`( module-name q -- )` — Import the public attributes named by the symbol list
`q` under their own unqualified names: `'str ('upper 'lower) import` binds
`upper` and `lower`. Every requested name is validated against one module
generation before any binding is published; a missing or private attribute is
`'undefined-word` and publishes none of the request. A non-list `q` or a
non-symbol item is `'type`; an invalid module or attribute name is `'domain`.
Each imported binding dispatches through the module, preserves the original's
effect and documentation, and may replace an existing local binding. `see`
renders its one-word forwarding quotation.

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
`'parse`. A float is `'type`: choose `floor`, `round`, or `ceil` instead. Any
other value is also `'type`.

#### Examples

```ecl
"42" int "a" first int
# => 42 97
```

### intern
`( value -- symbol )` — Return a symbol or word as a symbol, or create the
symbol for a string, interning the spelling when it is new. A string that is
not a valid symbol spelling is `'domain`; any other value is `'type`. Interned
names live for the whole process and are never reclaimed, so never apply this
to unbounded external input; `symbol` is the lookup-only form. See
[Conversions](SPEC.md#conversions).

#### Examples

```ecl
"fresh-name" intern
# => 'fresh-name
```

### iterations
`( value count quotation -- list )` — *Isolated*, unary contract
`( a -- a )`. Return the initial value followed by `count` successive
applications. `count` must be a nonnegative int, and a zero count returns a
singleton list. Defined in ecl over `scan`.

#### Examples

```ecl
1 3 (10 +) iterations
# => [1 11 21 31]
```

### join
`( strings separator -- string )` — Join a list of strings with a
separator string.

### keep
`( x q -- … x )` — *Inline.* Apply a quotation to a value, then restore
the value on top of the quotation's results. Equivalent to
`over (call) dip`.

### last
`( sequence -- value )` — Final element of a nonempty sequence.
Equivalent to `dup len 1 - at`.

### len
`( list -- count )` — Top-level list element count. Lists may be ragged.
Dictionary entry count is provided by `dict.size`.

### lex-cmp
`( left right -- order )` — Lexicographically compare two sequences using
`cmp` on corresponding elements. Stop at the first nonzero result; when the
shared prefix is equal, compare sequence lengths. Defined in ecl.

### lex-cmp-with
`( left right comparator -- order )` — Lexicographically compare two
sequences with an inline `( left-element right-element -- order )` comparator
that returns −1, 0, or 1. Stop at the first nonzero result; when the shared
prefix is equal, compare sequence lengths. Defined in ecl.

### literal
`( value -- quotation )` — Return the plain quotation `((x) first)`:
calling it pushes the exact captured value as inert data, without
executing or resolving it. Equivalent to `wrap (first) cons`.

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
Edges follow the Numbers rules: `0 log` is `'overflow` (non-finite from
finite), `-1 log` is `'domain` (NaN).

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
`( sequence -- value )` — Greatest element of a nonempty sequence.
Equivalent to `dup first (max) fold`.

### mean
`( sequence -- mean )` — Arithmetic mean of a nonempty numeric sequence.
Equivalent to `dup sum swap len /`.

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

#### Examples

```ecl
1 2 3 3 pack
# => [1 2 3]
```

### pair
`( first second -- list )` — Two-element list in stack order. Equivalent
to `() cons cons`.

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

### partial
`( value quotation -- quotation )` — Safe partial application: the result
pushes the captured value inertly, then runs the quotation. Even a
captured word remains data. Equivalent to `swap literal swap compose`;
`3 (+) partial` is `((3) first +)`.

#### Examples

```ecl
4 3 (+) partial call
# => 7
```

### partition
`( sequence predicate -- matches rejects )` — *Isolated*, contract
`( a -- bool )`. Split into elements whose predicate returned 1 and those
returning 0. Defined in ecl.

#### Examples

```ecl
[1 2 3 4] (2 mod 0 =) partition pair
# => [[2 4] [1 3]]
```

### pop
`( x -- )` — Discard the top stack value. (`drop` is the sequence word.)

### pow
`( x y -- z )` — **Pervasive.** Exponentiation; returns float.

### prod
`( sequence -- product )` — Product of a numeric sequence; 1 when empty.
Equivalent to `1 (*) fold`.

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
`( 'module-name 'binding-name -- qualified-word )` — Validate a canonical
module path, or the reserved qualifier `'core`, and one unqualified,
non-reserved binding segment, then construct their qualified executable word
directly from the interned components. It does not parse source, intern
anything new, or grant module-state/lifecycle authority; use `execute` to
invoke the result dynamically. `'core 'dup qualify` reaches the primitive even
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

### register
`( module 'module-name -- )` — Validate a canonical module path and publish a
module value under it. A missing name creates its registration and copies the
image's initial-state template into the new durable stack; an existing name
installs the new image and retains that registration's durable stack. One
image may be registered under any number of names, each with independent
state and lifetime. See [Modules](SPEC.md#modules).

### reshape
`( list shape -- list )` — Cycle the data into the exact nested-list
shape; a zero axis must be final.

#### Examples

```ecl
[1 2 3 4] [2 3] reshape
# => [[1 2 3] [4 1 2]]
```

### rest
`( list -- list )` — All but the first element of a nonempty list.

### reverse
`( list -- list )` — Reverse top-level element order. Defined in ecl as
an index permutation.

### rolldown
`( x y z -- y z x )` — Rotate the top three stack values downward.
Equivalent to `(swap) dip swap`.

### rollup
`( x y z -- z x y )` — Rotate the top three stack values upward.
Equivalent to `swap (swap) dip`.

### rotate
`( list count -- list )` — Rotate top-level element order left by a
count, wrapping cyclically; a negative count rotates right, counts
beyond the length wrap, and the empty list is returned unchanged.
Defined in ecl as a modular index permutation (the K lineage's
composed form; APL/J make dyadic reverse a primitive).

#### Examples

```ecl
[1 2 3 4 5] 2 rotate
# => [3 4 5 1 2]
```

### round
`( x -- integer )` — **Pervasive.** Round to nearest; the result is
int64, `'overflow` outside its range.

### scan
`( list accumulator quotation -- list )` — *Isolated*, contract
`( acc a -- acc )`. Like `fold` but returns every intermediate
accumulator; same length as the input.

#### Examples

```ecl
[1 2 3 4] 0 (+) scan
# => [1 3 6 10]
```

### scan1
`( list quotation -- list )` — *Isolated*, contract `( acc a -- acc )`.
Return a nonempty list's first element followed by the intermediate
accumulators from reducing its remainder. Defined in ecl over `scan`.

### see
`( 'name -- )` — Print the binding's combined annotation, when present,
followed by its body through the standard source formatter, with its
width-aware layout and no navigation header, name, or `def`/`defp` terminator.
What prints is what is stored: a name bound by `set` prints its annotation and
literal-capture body; the producing `set` spelling is discarded.
Reader-built bodies retain a shared slice of their source unit, so head binders
print with their authored local names even though execution uses the lowered
`_ll`/`_gl`/`_dl` quotation. Runtime-constructed bodies without source
provenance fall back to their canonical value form. Native origins are
displayed in native body descriptors.

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

### test
`( annotation? body 'name -- )` — Declare a first-class test in the separate
catalog of the exact direct module construction body. Accepts the same optional
effect and documentation annotation forms as `def`. Tests may share names with
words and are absent from application lookup, exports, imports, reflection,
and module invocation. Top-level, nested-quotation, and child-Unit use is
`'domain`. Application Sessions validate and discard declarations without
retaining bodies or checking duplicate test names; Test Sessions retain them
and reject duplicate names.

### tests
`( -- descriptors )` — Test-Session-only discovery of current canonical
registrations, sorted by module then test name. Each dictionary contains
symbol fields `'module` and `'name` plus optional declared `'effect` and
`'doc`; it never contains an executable body or authority handle. Aliases do
not duplicate entries. Ordinary Sessions receive `'domain`.

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
`( x -- y )` — **Pervasive.** Square root. `'domain` on negative inputs
(the result would be NaN).

### stencil
`( list width quotation -- list )` — *Isolated*, contract
`( window -- result )`. Apply to each overlapping window of a positive int
width, left-to-right. A width larger than the input returns `()` without
applying the quotation; zero and negative widths are `'domain`. The result
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

### sum
`( sequence -- total )` — Sum of a numeric sequence; 0 when empty.
Equivalent to `0 (+) fold`.

### symbol
`( value -- symbol )` — Return a symbol unchanged, a word as a symbol, or the
already-interned symbol whose spelling a string names. A spelling that is not
yet interned is `'domain`, as is a string that is not a valid symbol spelling;
any other value is `'type`. Every symbol written in loaded source is interned,
so this succeeds for any key a program compares against and never grows the
interned name space; use `intern` to create one. See
[Conversions](SPEC.md#conversions).

#### Examples

```ecl
"foo" symbol 'foo match?
# => 1
```

### swap
`( x y -- y x )` — Exchange the top two stack values.

### take
`( list count -- list )` — The first `count` elements; a negative count
takes from the end. When the magnitude exceeds the length, the data
cycles.

#### Examples

```ecl
[1 2 3] 5 take
# => [1 2 3 1 2]
```

### tasks
`( -- tasks )` — Pending descendant tasks in deterministic spawn
preorder.

### times
`( n q -- ... )` — *Inline.* Run the quotation `n` times; `n` must be a
nonnegative int. Tail-call optimized.

### tri
`( x p q r -- ... )` — *Inline.* Apply three quotations to the same input
in order. Equivalent to `((keep) dip keep) dip call`.

### tri2
`( x y p q r -- ... )` — *Inline.* Binary cleave: apply each of three
quotations to the same pair of inputs in left-to-right order. Equivalent to
`(|x y p q r| x y p call x y q call x y r call)`.

### type
`( value -- type )` — Return the value's kind as a symbol: one of `'int`,
`'float`, `'char`, `'symbol`, `'word`, `'list`, `'dict`, `'module`, or `'task`.

#### Examples

```ecl
"abc" type
# => 'list
```

### undef
`( name -- )` — Remove a direct binding from the current scope, or do nothing
when that scope does not bind the name. An exact alias of `unset`; removing a
local shadow may reveal a parent or core binding.

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

#### Examples

```ecl
0 (5 <) (dup 1 + swap) unfold pair
# => (5 [0 1 2 3 4])
```

### unless
`( bool else -- ... )` — *Inline.* Run the quotation when the condition
is 0. Equivalent to `() swap if`.

### unmodule
`( 'module-name -- )` — Close, quiesce, and retire the module currently
registered under a canonical name or unqualified alias, resolved exactly as
ordinary registry lookup resolves it. An unregistered name is `'undefined-word`. Removal strips
every alias targeting the slot in the same publish and is `'domain` when
initiated from inside any state application, since a unit holds at most one
slot's turn. See [Modules](SPEC.md#modules).

### unset
`( name -- )` — Remove a direct binding from the current scope, or do nothing
when that scope does not bind the name. An exact alias of `undef`; removing a
local shadow may reveal a parent or core binding.

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
`( bool then -- ... )` — *Inline.* Run the quotation when the condition
is 1. Equivalent to `() if`.

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

#### Examples

```ecl
1 (5 <) (1 +) while-values
# => [1 2 3 4 5]
```

### windows
`( list width -- windows )` — Return every overlapping window of a positive
width. Equivalent to `() stencil`.

#### Examples

```ecl
[1 2 3 4] 3 windows
# => [[1 2 3] [2 3 4]]
```

### with
`( values quotation -- quotation )` — Capture every element of a list as
an inert input to a quotation, preserving order. Calling the result starts
with the list's elements as separate stack values. Defined in ecl as
`((literal) each) dip append raze`.

This is ordinary quotation composition and constructs nothing. It is not a
unit's seed operand: the flattened quotation it returns is a runtime-built
body, so `@module` and `@defm` give it no reader attribution. Pass initial
values as the constructor's separate list operand.

#### Examples

```ecl
[3] (dup) with call
# => 3 3
```

### within
`( quotation -- ... )` — Run the quotation against a
private draft of the home module's durable stack, then publish the
remaining draft as that stack and deliver whatever `without` moved
outward, in invocation order. Legal only in a published word whose
definition-site home is a live, current module generation; everywhere else
it is `'domain`. Parking, nesting, and a second module's slot are
`'domain`. Any failure publishes nothing. See [Modules](SPEC.md#modules).

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
extends). Each-left/each-right are `partial` compositions.

#### Examples

```ecl
[1 2 3] [10 20 30] (+) zip-with
# => [11 22 33]
```

## archive

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
`destination`, a canonical relative path under the named Session filesystem
`root` (see [`fs`](#fs)). The root must grant `create`; the destination must
name a child entry, not `.`. Return normalized regular-file paths in archive
order. Unsafe, linked, special, duplicate, malformed, or over-limit members
are `'domain`; invalid byte items are `'domain`; wrong container kinds are
`'type`; a missing filesystem policy, unknown root, denied grant, or
non-canonical destination is `'domain` carrying the `fs` failure data; an
exhausted operation quota is `'overflow`; filesystem and destination
conflicts are `'io`. Failure never publishes a partial destination. See the
environment's [`archive` contract](ENVIRONMENT.md#byte-lists-and-archives)
for the complete format, limit, containment, and publication contract.

## clock

Scheduler-backed time. `now`, `elapsed`, and `sleep` read the one monotonic
clock the Session's scheduler owns, so a program's instants, its sleeps, and
every `await-for` deadline agree on the current time. `unix` is a separate
wall-clock grant: the Session host may withhold it, fix it, anchor it to the
monotonic clock, or pass the process clock through. The command line grants
the process clock; embedded Sessions grant none by default. Possession of host
I/O, filesystem or process authority, or a TLS verification timestamp never
implies a wall clock.

Every quantity is a whole number of milliseconds. A monotonic instant is the
one-key dictionary `{'monotonic ms}` counting from Session construction; a wall
timestamp is `{'unix ms}` counting from 1970-01-01T00:00:00Z. The tag is the
clock domain: an instant handed to a `time` word, or a timestamp handed to
`elapsed`, is `'type`. Monotonic instants are not portable across Sessions and
carry no date; wall time may jump and is not suitable for scheduling.

A Session may run under a manual monotonic clock that starts at zero and moves
only when the host advances it. Under that clock `now` is exact, `sleep` and
`await-for` complete on the advance that reaches their deadline, and no word
waits on host time. `ENVIRONMENT.md` describes the host policy.

### elapsed
`( instant -- milliseconds )` — Monotonic milliseconds from an instant produced
by `now` to the present. Anything but `{'monotonic int}` is `'type`.

### now
`( -- instant )` — Read the monotonic clock as `{'monotonic ms}`. Successive
reads never decrease. The first read of a fresh Session is close to
`{'monotonic 0}`, and exactly that under a manual clock.

### sleep
`( milliseconds -- )` — Park the calling unit until the monotonic clock has
advanced by a nonnegative int duration, then continue with nothing pushed. The
unit holds no worker while parked; runnable work proceeds on a one-worker pool.
The deadline is captured once, before any timer state is created, and a
duration of `0` is already expired at that point: the unit yields to the
scheduler and resumes on its next turn without starting the timer thread.
Cancellation before or after registration wakes the unit with `'cancelled`
and retires its timer entry. A negative duration is `'domain`, a non-int is
`'type`, and a duration whose deadline lies beyond any instant the clock can
report is `'overflow`; all three fail before anything is registered. Sleeping
inside a `within` application is `'domain`.

#### Examples

```ecl
clock.now 'start set 250 clock.sleep start clock.elapsed 250 >=
# => 1
```

### unix
`( -- timestamp )` — Read the wall clock as `{'unix ms}`. Without a wall-clock
grant this is `'domain` with `'reason 'unavailable`. Under a fixed grant every
read returns the configured value; under an anchored grant it returns the
configured base plus the monotonic milliseconds since Session construction.
Convert with the `time` module.

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

#### Examples

```ecl
"a,b\nc,d" csv.parse
# => (("a" "b") ("c" "d"))
```

## dict

These operations preserve the language's immutable, insertion-ordered
dictionary semantics. The constructor family accepts flat adjacent entries,
parallel key/value lists, association lists, or one shared value for a key
list. All constructors reject duplicate keys instead of silently choosing a
winner.

### at
`( dict keys -- values )` — Look up every whole-value key in the requested
key list and return the corresponding values in request order. Duplicate keys
produce duplicate values. An absent key is `'domain`; the operation never
silently drops a request. A structural list in `keys` is one dictionary key,
while core `at` remains the scalar operation for looking up a structural list
key directly.

### drop
`( dict keys -- dict )` — Remove entries named by a key list, ignoring absent
keys and preserving the relative order of every retained entry.

### filter
`( dict predicate -- dict )` — Call a `( key value -- bool )` predicate in
insertion order and retain the entries for which it returns 1.

### from-flat
`( entries -- dict )` — Build a dictionary from one flat, even-length list by
pairing adjacent entries without executing them. This is the runtime
counterpart of the `{…}` literal: `'total 3 4 + pair dict.from-flat` is
`{'total 7}`. An odd entry count is `'contract`; duplicate keys are `'domain`.

### from-keys
`( keys value -- dict )` — Build a dictionary assigning one value to every
distinct key. Duplicate keys are `'domain`.

### from-lists
`( keys values -- dict )` — Build a dictionary from parallel conforming key
and value lists. Unequal lengths are `'shape`; duplicate keys are `'domain`.

#### Examples

```ecl
['a 'b] [1 2] dict.from-lists
# => {'a 1 'b 2}
```

### from-pairs
`( pairs -- dict )` — Build a dictionary from a list of exact `[key value]`
pairs in list order. A malformed pair is `'shape`; duplicate keys are
`'domain`.

### has?
`( dict key -- bool )` — Whole-value key membership. Keys are inert and only
absence is false: lookup machinery failures are errors, never converted to 0.

### keys
`( dict -- keys )` — Return keys in insertion order.

### keys-exactly?
`( candidate declared -- bool )` — Return 1 when a dictionary has exactly the
declared keys in any order. A duplicate declaration returns 0.

### map
`( dict quotation -- dict )` — Call a `( key value -- value )` quotation for
every entry, replacing values while preserving keys and insertion order.

#### Examples

```ecl
{'a 1 'b 2} (swap pop 10 *) dict.map
# => {'a 10 'b 20}
```

### size
`( dict -- count )` — Return the dictionary's entry count.

### merge
`( left right -- dict )` — Merge two dictionaries; right-hand values win.
Existing left keys retain their positions and right-only keys append in right
order. Key-aligned arithmetic remains pervasive `+` on dicts.

#### Examples

```ecl
{'a 1 'b 2} {'b 20 'c 30} dict.merge
# => {'a 1 'b 20 'c 30}
```

### merge-with
`( left right quotation -- dict )` — Merge two dictionaries, resolving each
shared key with `( key left-value right-value -- value )`. Existing left keys
keep their positions; right-only keys append in right order.

### pairs
`( dict -- pairs )` — Return insertion-ordered `[key value]` pairs. This is the
bridge to generic entry iteration when keys are needed. Value-only `each`
operates on a dictionary directly; reductions and predicates can consume
`dict.vals`, so they need no dictionary-specific duplicates.

### reject
`( dict predicate -- dict )` — Call a `( key value -- bool )` predicate in
insertion order and discard the entries for which it returns 1.

### split
`( dict keys -- selected rejected )` — Partition a dictionary by a key list,
returning selected then rejected entries; ignore absent keys and preserve
dictionary order in both results.

#### Examples

```ecl
{'a 1 'b 2} ['b] dict.split pair
# => ({'b 2} {'a 1})
```

### take
`( dict keys -- dict )` — Keep entries named by a key list, ignoring absent
keys. Output follows dictionary order independently of the requested key-list
order.

### update
`( dict keys quotation -- dict )` — Apply an isolated `( value -- value )`
quotation to every requested whole-value key without moving entries. Keys are
processed in request order, so duplicates observe earlier updates. A structural
list in `keys` is one dictionary key. All keys are validated before the
quotation is first applied; an absent key is `'domain`, and an empty request
returns the dictionary unchanged.

### update-or
`( dict key default quotation -- dict )` — Update an existing value as
`update` does, or append the absent key with the default unchanged. The default
does not pass through the quotation.

### vals
`( dict -- values )` — Return values in insertion order.

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

#### Examples

```ecl
'io error.new "unavailable" error.with-message
# => {'kind 'io 'msg "unavailable"}
```

## fs

Capability-gated filesystem words. Every word names a `root` by symbol and a
`path` string. A root is a directory the Session host configured by name with
an explicit permission set; a Session constructed without a filesystem policy
denies every word with `'domain` and reason `'unavailable`. The command line
grants exactly one root, `'cwd`, for the startup working directory with every
permission. Possession of a path string, console output, or any other host
service never widens this authority.

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
`read-bytes`, `read-text`, `stat`, `list`, and the source side of `copy`
follow a final link under the same rule; every other word acts on the final
entry itself. Containment is never a lexical prefix check.

Permissions are semantic: `'read-data` authorizes `read-bytes`, `read-text`,
and the source of `copy`; `'inspect` authorizes `stat`, `lstat`, and
`exists?`; `'list` authorizes `list`; `'create` authorizes `create-*`,
`mkdir`, the destination of `copy`, and `archive.unpack-tgz`; `'replace`
authorizes `replace-*`; `'rename` authorizes `rename`; `'remove` authorizes
`remove-file` and `remove-dir`. Internal staging never needs a public grant.

Every failure carries a data dictionary with `'operation` (the word's own
symbol), `'root` and `'path` (or `'source-root`, `'source-path`,
`'destination-root`, and `'destination-path` for `copy`), and a closed
`'reason` symbol: `'invalid-path`, `'unknown-root`, `'denied`, `'unavailable`,
`'not-found`, `'already-exists`, `'not-directory`, `'is-directory`,
`'not-regular`, `'not-empty`, `'symlink-loop`, `'symlink-escape`,
`'invalid-utf8`, `'limit`, `'access-denied`, `'read-only`, `'no-space`,
`'busy`, `'cross-device`, `'unsupported`, `'changed`, or `'io`. The kind is
`'type` for wrong value kinds or byte-list members outside `0..255`, `'domain`
for malformed paths, unknown roots, denied grants, and an absent policy,
`'overflow` for a configured limit, `'cancelled` for cancellation, and `'io`
for filesystem state and host failures. Host error names never appear as data.

Reads, writes, and copies are bounded by the policy's transfer limit
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

### copy
`( source-root source-path destination-root destination-path -- )` — Copy a
regular file, following a final source link within its root, into an absent
destination entry. Requires `'read-data` on the source root and `'create` on
the destination root; the roots may differ. The copy is staged and published
atomically without replacing; an existing destination of any kind is
`'already-exists`, a non-regular source is `'not-regular` or `'is-directory`,
and no metadata is preserved.

### create-bytes
`( bytes root path -- )` — Atomically create an absent regular file holding
exact bytes. Members are validated before any external state exists. An
existing regular file, directory, symlink (including a dangling one), or other
entry is `'already-exists`; a missing parent is `'not-found`.

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
children as `{'name string 'kind 'file}`, `{'name string 'kind 'directory}`,
`{'name string 'kind 'symlink}`, or `{'name string 'kind 'other}`, classified
without following, excluding `.` and `..`, and sorted by Unicode scalar order
of `'name`. A child name that is not valid UTF-8, an entry that vanishes or
cannot be classified, or an exceeded listing limit fails the whole listing;
nothing is silently omitted.

### lstat
`( root path -- metadata )` — Describe the final entry without following it:
`{'kind 'file 'size n}` for a regular file, `{'kind 'directory}`,
`{'kind 'symlink}`, or `{'kind 'other}`. An absent entry is `'not-found`.

### mkdir
`( root path -- )` — Create exactly one absent directory beneath an existing
parent. There is no recursive parent creation; an existing entry of any kind is
`'already-exists`.

### read-bytes
`( root path -- bytes )` — Read one regular file, following a final link within
the root, and return its exact bytes as an integer list. The size observed at
open is the size read; growth or shrink meanwhile is `'changed`. A directory is
`'is-directory`; a non-regular object is `'not-regular`; a file over the
transfer limit is `'overflow`.

### read-text
`( root path -- string )` — Read one regular file as `read-bytes` does and
decode it as UTF-8. Invalid UTF-8 is `'io` with reason `'invalid-utf8`.

### remove-dir
`( root path -- )` — Remove one empty directory without following a final
link. A nonempty directory is `'not-empty`; a file or symlink is
`'not-directory`.

### remove-file
`( root path -- )` — Remove one non-directory entry, including a symlink
itself, without following it. A directory is `'is-directory`.

### rename
`( root source-path destination-path -- )` — Rename an entry within one root
without replacing. The source may be a regular file, symlink, or directory and
is not followed; an existing destination is `'already-exists`, and a
destination on another device is `'cross-device` rather than an emulated
copy.

### replace-bytes
`( bytes root path -- )` — Atomically replace an existing regular file with
exact bytes. The final entry must be observed as a regular file without
following: absence is `'not-found`, and a symlink, directory, or other entry
is `'not-regular`. The replacement is a new inode published by an atomic
exchange; the word never becomes create-or-replace.

### replace-text
`( string root path -- )` — Replace an existing regular file with UTF-8 text
under the `replace-bytes` contract.

### stat
`( root path -- metadata )` — Follow the path, including a final link within
the root, and describe the object reached with the same shapes as `lstat`. A
dangling link is `'not-found`.

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

## http.server

HTTP/1.1 serving over `net` connections, defined in ECL. The module holds no
authority of its own: `@serve` takes a listener the program already obtained
through `net.listen`, so a Session that cannot bind cannot serve, and every
socket operation is one of the `net` words. The parsers, the response
renderer, the response constructors, `route`, and `query` take and return
ordinary values and never touch a connection, so they can be used and tested
without a socket.

A request is the dictionary
`{'method 'target 'path 'query 'headers 'body 'peer}`:

- `'method` and `'target` are the first two tokens of the request line, as
  strings;
- `'path` and `'query` are the target split at the first `?`, undecoded;
  `'query` is `""` when the target has no `?`;
- `'headers` is a dictionary from ASCII-lowercased header name to the list of
  its trimmed values in arrival order, so a repeated header keeps every value;
- `'body` is the exact byte list named by `Content-Length`, `[]` when the
  request has none; and
- `'peer` is the peer's `address:port` formatted from `net.peer-address`,
  with an IPv6 address in brackets.

A response is the dictionary `{'status 'headers 'body}` with exactly those
keys: an integer status in `100...599`; a headers dictionary whose keys are
strings and whose values are a string or a list of strings, written once per
value in the given order and with the name as given; and a body that is a
string, written as UTF-8, or a byte list. The names `content-length`,
`connection`, and `transfer-encoding` are reserved in any letter case: the
server writes `Content-Length` and `Connection: close` itself, and a response
naming one of them is `'domain`. Header names must be nonempty HTTP tokens
and values may not contain CR, LF, NUL, or a control character other than
tab, so a value built from request data cannot split the response; every byte
the server writes has passed `render-response` in its single write word.

Framing is HTTP/1.1 with `Content-Length` bodies only; an HTTP/1.0 request is
answered the same way. Any `Transfer-Encoding` header is answered 411 and a
version other than `HTTP/1.1` or `HTTP/1.0` is answered 505. There is no
keep-alive: every response carries `Connection: close`, and the connection is
closed once the response is written. The head is located by its CRLFCRLF
terminator on the raw bytes before any decoding, so a binary body that
arrives with the head is never decoded as text. TLS, chunked bodies,
pipelining, and upgrades belong to a proxy in front of the server.

The `@serve` configuration is a dictionary whose keys are all optional; `{}`
is valid. Each limit is an integer greater than zero.

- `'max-header-bytes` (default `32768`): the most bytes accepted before the
  CRLFCRLF that ends the head; more is 431.
- `'max-body-bytes` (default `1048576`): the largest `Content-Length`
  accepted; a larger one is 413 before any body byte is read.
- `'max-in-flight` (default `128`): the number of acceptor children, each
  handling one connection at a time.
- `'read-timeout-ms` (default `10000`): the deadline for reading one whole
  request, head and body; expiry is 408.
- `'on-failure` (default `(str io.eprint)`): a quotation `( error -- )`
  applied to the error dictionary of every request the server answers 500.

The server answers a request it cannot serve with a minimal `text/plain`
response of the status below and then closes the connection:

- 400: a malformed request line; a header line without `:` or beginning with
  space or tab (obsolete folding); non-UTF-8 bytes in the head; a
  `Content-Length` that is not a digit string or whose repeated values
  differ; end of stream after some bytes arrived but before the head or the
  body is complete.
- 408: `'read-timeout-ms` elapses while the request is being read.
- 411: any `Transfer-Encoding` header.
- 413: `Content-Length` exceeds `'max-body-bytes`.
- 431: `'max-header-bytes` is exceeded before the head ends.
- 500: the handler fails, leaves other than exactly one value, or leaves a
  response `render-response` rejects.
- 505: a version other than `HTTP/1.1` or `HTTP/1.0`.

A peer that connects and closes without sending a byte, or that resets or
otherwise fails during the read or the write, is closed silently: nothing is
written and `'on-failure` is not applied.

The handler is a quotation with the contract `( request -- response )`. Each
request applies it as `[request] handler @attempt` in a fresh unit, so a
handler's failure is data to the server and the ambient stack never crosses
the boundary. A successful handler leaves exactly one value, and that value
must satisfy `render-response`. Any other outcome — a raised error, an empty
or multi-valued result, a malformed response — answers 500 and applies the
`'on-failure` quotation to the error dictionary (for a wrong result count, a
`'contract` error naming the observed count); the serving unit and every other
in-flight request are unaffected. Every response the server writes, whether
the handler's or its own, is validated in full before any byte is written.

`@serve` spawns `'max-in-flight` acceptor children. Each loops: `net.accept`,
read and frame the request, apply the handler, write the response, `net.close`
the connection, so every connection belongs to the scope of the child that
accepted it and is closed on every path. While every acceptor is busy no
`net.accept` is outstanding and further connections wait in the kernel
backlog; the host's live-connection maximum is a second, waiting bound at
which `net.accept` itself parks. The read deadline is a reader child under
`await-for`, cancelled on expiry.

`@serve` does not return. The serving unit ends only when it is cancelled,
failing `'cancelled`, or when an acceptor's `net.accept` fails `'io` (a
listener closed elsewhere is `'io` `'closed`), in which case that error is
raised from `@serve`. Either ending cancels and quiesces every acceptor,
reader, and handler child by the ordinary scope rules and closes every
connection those children own. The listener itself is untouched: `@serve`
never calls `net.close` on the listener it was given, which stays the
caller's to close explicitly or through its own scope and may be served
again.

#### Examples

```ecl
{'address "127.0.0.1" 'port 8080} net.listen 'l def

([["GET" "/health" (pop 200 "ok" http.server.text)]
  ["GET" "/users/:id" ('params at "id" at 200 swap http.server.text)]]
 http.server.route)
'handler def

l {'read-timeout-ms 5000} (handler) http.server.@serve
```

### @serve
`( listener config handler -- )` — *Unit constructor*, contract
`( request -- response )` enforced per request. Validate the arguments,
fill the configuration defaults, spawn `'max-in-flight` acceptor children
over the listener, and park. A non-port listener, a non-dictionary
configuration, or a non-quotation handler is `'type`; an unknown
configuration key or a limit that is not greater than zero is `'domain`; a
limit that is not an integer or an `'on-failure` that is not a quotation is
`'type`. Validation completes before any child is spawned. The word fails
`'cancelled` when the serving unit is cancelled and re-raises an acceptor's
`'io` failure of `net.accept`; it never closes the listener.

### content-length
`( headers -- int )` — Return the request body length named by a parsed
headers dictionary: `0` when `content-length` is absent, otherwise the
integer every occurrence spells, leading zeros allowed. A value that is not a
nonempty digit string, or repeated values that differ, is `'domain` with
`'data {'status 400}`; a value too large for a 64-bit integer exceeds every
body limit and is `'domain` with `'data {'status 413}`. A non-dictionary is
`'type`.

### empty
`( status -- response )` — Return `{'status status 'headers {} 'body ""}`. A
non-integer status is `'type`.

### json
`( status value -- response )` — Return a response whose body is the value
rendered with `json.emit` and whose headers are
`{"content-type" ("application/json")}`. A non-integer status is `'type`; a
value `json.emit` rejects fails as `json.emit` does.

### not-found
`( -- response )` — Return `404 "not found" text`.

### parse-headers
`( lines -- dict )` — Parse a list of header-line strings into a dictionary
from ASCII-lowercased name to the list of trimmed values in arrival order,
so `("Host: a" "host: b")` yields `{"host" ("a" "b")}`. The name is the text
before the first `:`, the value the rest with surrounding whitespace removed.
A line without `:`, or one beginning with space or tab, is `'domain` with
`'data {'status 400}`. A non-list or a non-string line is `'type`.

### parse-request-line
`( line -- dict )` — Parse a request line into
`{'method 'target 'path 'query 'version}`: three space-separated tokens,
`'path` and `'query` the target split at the first `?` undecoded, `'query`
`""` when there is no `?`. Any other token count is `'domain` with
`'data {'status 400}`; a version other than `HTTP/1.1` or `HTTP/1.0` is
`'domain` with `'data {'status 505}`. A non-string is `'type`.

#### Examples

```ecl
"GET /a?b=1 HTTP/1.1" http.server.parse-request-line
# => {'method "GET" 'target "/a?b=1" 'path "/a" 'query "b=1" 'version "HTTP/1.1"}
```

### query
`( request -- dict )` — Return the request's `'query` string as a dictionary
from string keys to string values: `&`-separated pairs, each split at its
first `=`, a pair without `=` mapping its key to `""`, empty pieces ignored,
and a later duplicate key replacing an earlier one. `%XX` escapes are decoded
in keys and values and the decoded text must be valid UTF-8; `+` is left as
it is. An empty query is `{}`. A `%` not followed by two hexadecimal digits,
or a decoded key or value that is not valid UTF-8, is `'domain`. A request
whose `'query` is not a string is `'type`.

#### Examples

```ecl
{'query "a=1&b=%2Fx&c"} http.server.query
# => {"a" "1" "b" "/x" "c" ""}
```

### redirect
`( location -- response )` — Return a 302 response with
`{"location" (location)}` as its headers and an empty body. A non-string
location is `'type`.

### render-response
`( response -- bytes )` — Validate a response dictionary and return the exact
bytes the server writes for it: `HTTP/1.1 <status> <reason>` CRLF, one
`name: value` line per header value in the given order with the name as
given, `Content-Length: <n>` CRLF, `Connection: close` CRLF, CRLF, then the
body bytes. The reason phrase comes from a fixed table covering 200, 201,
204, 301, 302, 304, 400, 401, 403, 404, 405, 408, 411, 413, 431, 500, 503,
and 505 and is empty for any other status, with the space before it always
written. A non-dictionary is `'type`. Keys other than exactly `'status`,
`'headers`, and `'body`; a status that is not an integer in `100...599`; a
headers value that is not a dictionary, a header name that is not a nonempty
string of HTTP token characters, a header value that is neither a string nor
a list of strings or that contains CR, LF, NUL, or a control character other
than tab, a header whose lowercased name is `content-length`, `connection`,
or `transfer-encoding`;
or a body that is neither a string nor a list of integers in `0...255` is
`'domain`.

#### Examples

```ecl
{'status 200 'headers {"set-cookie" ("a=1" "b=2")} 'body "ok"}
http.server.render-response chars
# => "HTTP/1.1 200 OK\u{D}\u{A}set-cookie: a=1\u{D}\u{A}set-cookie: b=2\u{D}\u{A}Content-Length: 2\u{D}\u{A}Connection: close\u{D}\u{A}\u{D}\u{A}ok"
```

### route
`( request routes -- response )` — *Inline.* Dispatch a request over a list
of `[method pattern handler]` rows. A pattern is a slash path whose segments
must equal the request's `'path` segments one for one, except that a segment
beginning with `:` binds any nonempty path segment under its name in a
string dictionary. The first row whose pattern and method both match has the
request, with `'params` set to that dictionary, passed to its handler, which
is applied inline with the contract `( request -- response )`; middleware is
`compose`. When some pattern matches but no matching row's method does, the
result is `405 "method not allowed" text` with an `allow` header joining the
matching rows' methods with `,`; when no pattern matches, the result is
`not-found`. Every row is checked before any comparison: a row that is not a
list of three elements is `'shape`, and a non-string method, non-string
pattern, or non-quotation handler is `'type`.

### text
`( status string -- response )` — Return a response with the string as its
body and `{"content-type" ("text/plain; charset=utf-8")}` as its headers. A
non-integer status or a non-string body is `'type`.

## io

### debug
`( value label -- value )` — Write the string label, `": "`, and the value's
pretty-printed representation plus newline, leaving the value on the stack.
Semantically `io.prin ": " io.prin io.inspect`; a non-string label is the
same `'type` failure as `io.prin`.

### eprint
`( string -- )` — Write a string followed by a newline to the Session's
diagnostics stream: standard error under the command line, the host's
diagnostics writer when embedded, and never standard output. When the host
supplies no diagnostics writer the string is dropped and the word succeeds.
Non-string is `'type`; a failed write is `'io`.

### inspect
`( value -- value )` — Pretty-print a value while leaving it on the stack;
the pipeline probe. Semantically `dup io.pp`.

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

#### Examples

```ecl
"{\"a\":[1,null]}" json.parse
# => {"a" (1 'null)}
```

## net

Host-backed TCP listeners and connections. The module is present in every
standard image, but binding a socket is `'domain` unless the Session host
supplied listen authority, and a program can reach a connection only through a
listener it was allowed to bind. The CLI supplies an explicit unrestricted
grant; embedding hosts default to none and may instead name an exact allowlist
of address and port pairs, a maximum number of live listeners, the kernel
accept backlog, a maximum number of live connections (default 64), and the
receive and send capacities of each connection (default 64 KiB each).

A listen configuration is a dictionary with exactly these fields:

- required `'address`: a string holding an IPv4 or IPv6 literal; and
- required `'port`: an integer in `0...65535`, where `0` requests an ephemeral
  port.

Addresses are literals only: no name resolution and no interface scope id. A
non-dictionary configuration is `'type`; a missing, unknown, or repeated field
is `'domain`; a non-string address or non-integer port is `'type`; a port
outside the range or a literal that does not parse is `'domain` with `'reason`
`'invalid` and the offending `'address` and `'port` attached. The
configuration is validated before authority is consulted, and authority is
checked before the operating system is reached.

Grants are exact. A request matches a grant entry when the two addresses are
equal after normalization (an IPv4-mapped IPv6 literal such as
`::ffff:127.0.0.1` equals `127.0.0.1`) and the ports are equal; a grant entry
whose port is `0` admits only a request whose port is `0`. Every refusal is
`'domain` with a `'reason` symbol and the requested `'address` and `'port`
attached: `'unavailable` when the Session has no listen authority, `'denied`
when no entry admits the request, and `'limit` when the number of live
listeners already equals the host maximum. A host failure to bind or listen is
`'io` with the same `'address` and `'port` and one of the closed reasons
`'in-use`, `'unavailable` (the address is not local), `'resources`,
`'unsupported`, or `'io`.

A listener is an opaque identity capability that prints `<port:N>` and has
type `'port`; it exposes no descriptor and cannot be passed through JSON or the
native value ABI. `proc` words reject a listener with `'type`, and `net` words
reject a process port with `'type`. The socket is bound and listening before
the value is returned, so a returned listener is ready, and `local-address`,
which returns the bound endpoint without parking, is the whole readiness
protocol. `accept` is the only listener word that parks.
The listener belongs to the creating unit's task scope: scope closure closes
the socket and releases the live-listener slot even if a listener value is
stored elsewhere, and `close` performs the same idempotent transition early.
There is no detach or ownership transfer. Address reuse is not requested, so
two listeners can never hold one address and port at once.

A connection is likewise an opaque `'port` value, disjoint from listeners and
process ports: a listener word applied to a connection, a connection word
applied to a listener, and either applied to a process port or a non-port are
`'type`. A connection belongs to the task scope of the unit that called
`accept`, not to the listener's scope: closing that scope aborts the
connection even while its value is retained elsewhere, and closing the
listener leaves accepted connections open. A connection that is not accepted
stays in the kernel backlog; the runtime takes a connection from the backlog
only while an `accept` is outstanding and the number of live connections is
below the host maximum, so an idle program applies no backpressure of its own
beyond the backlog. At the maximum every `accept` keeps waiting, its peer
stays in the backlog, and it proceeds once a connection closes and releases
its slot. A waiting `accept` holds no slot: the maximum bounds live
connections only, and any number of units may accept concurrently under any
maximum. `accept` fails only `'io` (`'closed`, `'resources`, or `'io`) or
`'cancelled`; the `'limit` refusal belongs to `listen` alone.

Bytes are ordinary integer lists whose elements are all in `0...255`, exactly
as for process streams; the module decodes no text. Each connection has a
bounded receive queue and a bounded send queue of the host capacities. At most
one `read` may be pending on a connection; overlap is `'contract`. Writes are
serialized in scheduler-arrival order and each call's bytes remain
contiguous. Parking on a connection holds no worker. Failures on a connection
are `'io` carrying the peer's `'address` and `'port` and one closed reason:
`'closed` after the connection was closed locally, `'reset` when the peer has
gone (a reset, or a write to a peer that has already closed), and `'io` for
every other host failure, including a transmission timeout. Cancelling a unit
parked in `accept`, `read`, or `write` fails only that unit with `'cancelled`;
bytes the peer had already sent remain available to the next `read`, and a
connection accepted for a cancelled `accept` is closed. There is no deadline
on any connection word; a deadline is `@spawn` with `await-for` and `cancel`.
TLS, framing, and every protocol limit belong to the modules built over a
connection, not to this module.

### accept
`( listener -- connection )` — Park until a peer connects, then return the
connection as a port owned by the calling unit's task scope. Any number of
units may park in `accept` on one listener; each connection wakes exactly one
of them. A closed listener, whether closed before the call or while parked, is
`'io` with `'reason` `'closed` and the listener's address and port attached.
While live connections equal the host maximum the word keeps waiting, its
peer stays in the kernel backlog, and it proceeds when any connection in the
Session closes; it never fails `'domain` `'limit`. A connection the peer aborted
before it was accepted is skipped silently. Exhaustion of descriptors or
socket buffers is `'io` `'resources`; any other host failure is `'io` `'io`.
A non-listener is `'type`.

### close
`( port -- )` — Close a listener or a connection. On a listener: close the
socket now, release its live-listener slot, and detach it from its task
scope; every unit parked in `accept` on it fails `'io` `'closed`, and the same
address and port may be bound again once `close` returns. On a connection:
refuse further writes, deliver the bytes already queued for the peer, then
shut the socket down so the peer observes end of stream; later `read`,
`write`, `peer-address`, and `local-address` calls are `'io` `'closed`.
Idempotent in both cases: closing a port that is already closed, whether by
an earlier `close` or by scope closure, does nothing and does not fail. A
non-port, or a process port, is `'type`.

### listen
`( config -- listener )` — Bind and listen on the configured address and port
and return the listener once the socket is accepting connections at the
kernel. Configuration, authority, and host failures are described above.

### local-address
`( port -- address )` — Return `{'address string 'port int}` for the local end
of a bound listener or an open connection. The address is the canonical text
of the IP literal (dotted quad for IPv4; RFC 5952 form without brackets for
IPv6) and the port is the bound port, which for an ephemeral listener is the
kernel-assigned port. A closed listener or connection is `'io` with `'reason`
`'closed` and the address and port it held attached. A non-port, or a process
port, is `'type`.

### peer-address
`( connection -- address )` — Return `{'address string 'port int}` for the
peer end of an open connection, in the same canonical text as
`local-address`. A closed connection is `'io` with `'reason` `'closed` and the
recorded peer address and port attached. A non-connection is `'type`.

### read
`( connection max -- bytes )` — Read at most `max` exact bytes, and at most
the host receive capacity, parking when nothing is queued. Return `[]` only at
stable end of stream; later reads also return `[]`. A non-connection is
`'type`; a non-integer `max` is `'type`; a `max` that is not positive is
`'domain`. A second read while one is pending is `'contract`. After a local
`close` the read is `'io` `'closed`; a peer reset is `'io` `'reset`; any other
host failure is `'io` `'io`, each with the peer's address and port attached.

### write
`( connection bytes -- )` — Queue exact bytes for the peer, parking under
bounded send pressure. Calls are serialized in scheduler-arrival order and
each call's bytes remain contiguous. A non-list is `'type` and an element
outside `0...255` is `'domain`; a string must be converted with `bytes` first.
After a local `close` the write is `'io` `'closed`; a peer that has reset or
already closed is `'io` `'reset`; any other host failure is `'io` `'io`, each
with the peer's address and port attached.

## proc

Host-backed subprocess ports. The module is present in every standard image,
but process creation is `'domain` unless the Session host supplied process
authority. The CLI supplies an explicit unrestricted policy; embedding hosts
default to none and may restrict exact executable paths, working directories,
environment inheritance, live ports, queue sizes, and run-capture sizes.

A spawn specification is a dictionary with exactly these fields:

- required `'executable`: an absolute string path;
- optional `'args`: a list of strings, default `[]`;
- optional `'cwd`: an absolute string path, defaulting to the Session's
  captured starting directory; and
- optional `'env`: a string-to-string dictionary overlaid on the policy's
  captured or empty environment base.

There is no shell-command form and no `PATH` search. Unknown fields are
`'domain`; malformed field values are `'type` or `'domain`. The host policy is
checked before the operating system is reached.

Bytes are ordinary integer lists whose elements are all in `0...255`. Process
streams do not decode Unicode. A port is an opaque identity capability that
prints `<port:N>` and has type `'port`; it exposes no PID and cannot be passed
through JSON or the native value ABI.

### close-input
`( port -- )` — Close the process's stdin after queued bytes have been written.
Idempotent. A concurrent or later `write` is `'io`.

### kill
`( port -- )` — Force termination of the port's process group and arrange for
direct-child reap. Idempotent and safe after natural exit.

### read-stderr
`( port max -- bytes )` — Read at most positive `max` exact bytes from stderr,
parking when no data is ready. Return `[]` only at stable EOF; later reads also
return `[]`. At most one stderr read may be pending; overlap is `'contract`.

### read-stdout
`( port max -- bytes )` — Read at most positive `max` exact bytes from stdout
with the same readiness, EOF, and single-reader contract as `read-stderr`.

### run
`( spec -- result )` — Spawn through the ordinary port controller, supply all
stdin while draining stdout and stderr concurrently, wait for direct-child
reap, and return
`{'term termination 'stdout stdout-bytes 'stderr stderr-bytes}`. In addition to
the spawn fields, `spec` accepts:

- optional `'stdin`: a byte list, default `[]`;
- optional `'stdout-limit` and `'stderr-limit`: nonnegative integer capture
  limits no larger than the Host policy; and
- optional `'timeout-ms`: a nonnegative integer deadline. Absence means no
  process deadline; scheduler cancellation remains effective.

Capture overflow kills and cleans the process before raising `'overflow`.
Deadline expiry does the same before raising `'timeout`; task cancellation is
`'cancelled`. Spawn, pipe, broken-input, and reap failures are `'io`. These
run-only fields are rejected by `spawn`.

### spawn
`( spec -- port )` — Start the directly named executable with stdin, stdout,
and stderr pipes. The child and its process group, pipe tasks, and spawning
task-scope membership commit before the port becomes visible. The scope owns
the live child: scope closure cancels the process group and waits for reap even
if a port value remains stored elsewhere. There is no detach or ownership
transfer.

### terminate
`( port -- )` — Request ordinary termination of the process group, escalating
to force termination during cleanup when needed. Idempotent and safe after
natural exit.

### wait
`( port -- termination )` — Park until the immutable terminal result is
available. Any number of waiters and later calls receive the same dictionary:

- `{'kind 'exited 'code n}`;
- `{'kind 'signaled 'signal n}`;
- `{'kind 'stopped 'signal n}`; or
- `{'kind 'unknown 'status n}`.

A nonzero exit code is ordinary termination data, not an ECL error.

### write
`( port bytes -- )` — Queue exact stdin bytes, parking under bounded pressure.
Calls are serialized in scheduler-arrival order and each call's bytes remain
contiguous. A closed or broken stdin is `'io`.

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

### basename
`( path -- name )` — Return the last element after trailing slashes are
removed: `/` for a path of only slashes and `.` for an empty path.

### components
`( path -- components )` — Normalize the path and return its non-separator
components as a list of strings. `.` and `/` yield an empty list; retained
leading `..` components remain; absoluteness is observable only through
`absolute?`.

### dirname
`( path -- path )` — Return the normalized portion before the last slash, or
`.` when the path has no slash. `dirname` of `/a` is `/`.

### extension
`( path -- extension )` — Return the suffix from the final dot of the last
element, including the dot (`.gz` for `x/y.tar.gz`, `.bashrc` for `.bashrc`,
`.` for `a.`), or the empty string when that element has no dot.

### join
`( segments -- path )` — Join a list of strings with `/` and normalize the
result. Empty segments are ignored; an empty or all-empty list yields `.`. A
non-list or a non-string member is `'type`.

### normalize
`( path -- path )` — Lexically clean a path: collapse repeated separators and
`.` components, resolve each `..` against a preceding component, keep leading
`..` components in a relative path, clamp an absolute path at `/`, and return
`.` for an empty result. Absolute paths remain absolute and relative paths
remain relative.

### relative?
`( path -- bool )` — The complement of `absolute?`.

### valid-relative?
`( path -- bool )` — Return 1 when the string is a canonical relative path in
the `fs` grammar: `.` alone, or nonempty components separated by single
slashes with no `.`, `..`, or NUL component and no leading or trailing slash.
This predicate never normalizes; normalize first when accepting untrusted
text.

## pkg.data

Pure structural helpers shared by the package-format modules.

### assert-inert-entry
`( pair -- )` — Discard an inert dict entry, or raise `'domain` with its key
when its value recursively contains an executable word.

### read-one
`( text -- form )` — Parse exactly one form without evaluating it. Unreadable
text is `'parse`; zero or multiple forms are `'shape`.

#### Examples

```ecl
"[1 2]" pkg.data.read-one
# => [1 2]
```

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

#### Examples

```ecl
"foo" "foo.bar" pkg.name.owns?
# => 1
```

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

#### Examples

```ecl
"1.2.0" "1.10.0" pkg.version.less?
# => 1
```

### max
`( versions -- version )` — Return the greatest member of a nonempty list of
version strings. The empty list is `'shape`; a non-list or non-string member is
`'type`; every member is validated before comparison.

## pkg.manifest

### validate-requirement
`( requirement -- requirement )` — Validate and return one exact target
package, minimum version, URL, and hash declaration.

### validate
`( candidate -- manifest )` — Return a manifest unchanged, or raise. A non-dict
is `'type`; an undeclared key, unsupported format, malformed name, version,
hash, or URL, self-requirement, ownership collision, or executable word value
is `'domain`. Export namespaces are package-owned canonical names whose values
are nonempty distinct lists of safe portable globs. Requirement keys are local
aliases and do not rewrite module names.

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
root provenance, selected packages, alias-to-package minimum edges, and
satisfaction.

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

Package archive and publication capabilities over the Session's package
authority. A package-command Session (the `ecl pkg` subcommands) retains
handles for the shared cache store and the project vendor store; words name
one with the symbol `'cache` or `'vendor` and address an entry by its
canonical `<name>-<version>-<hex>` key. No absolute path, host handle, generic
rename, or recursive deletion reaches ECL. An ordinary or embedded Session has
no package authority and every store word is `'domain`; a package Session
whose host selected no cache reports `'io` naming `ECL_CACHE`,
`XDG_CACHE_HOME`, and `HOME`; a non-canonical key or unknown store symbol is
`'domain`. Every traversal, write, rollback, and output materialization
advances through bounded scheduler work.

### gc
`( retained-store-keys -- removed-count )` — Preserve the supplied canonical
keys and every unknown cache node, and remove other canonical real-directory
entries of the shared cache through bounded detach/walk/delete phases. An
absent cache removes nothing. A non-list, non-string key, or malformed store
key is `'type` or `'domain`; filesystem failures are `'io`.

### inspect
`( bytes package-name -- manifest-text )` — Validate one tgz's hostile-input
and source-only archive envelope without creating a filesystem destination.
Return the sole root `ecl.pkg` as exact UTF-8 text. This word needs no
package authority.

### install
`( bytes package-name store key -- regular-file-paths )` — Repeat archive
validation, derive and validate the staged manifest/glob/module catalog, and
atomically publish the entry `key` in the named store, which must be absent.
Return normalized regular-file paths only after commit; failure never exposes
a partial destination.

### manifest
`( store key -- manifest-text )` — Read the installed entry's root `ecl.pkg`
as exact UTF-8 text without following a link at the entry or file level.

### present?
`( store key -- bool )` — Return 0 for an absent entry and 1 for a real
directory. A symlink, non-directory, or inaccessible entry is `'io`.

### read-seal
`( store key package-name hash -- bytes )` — Perform the same streamed seal
verification as `verify`, then return its exact octets as an ordinary integer
byte list. It never reads a caller-selected child filename.

### verify
`( store key package-name hash -- )` — Stream the installed entry's reserved
archive seal and require its SHA-256 to equal `hash`. Failures name the
package and carry the key for host-I/O errors.

## pkg.sync

Synchronization runs inside a package-command Session: stores are the
`'cache` and `'vendor` symbols of `pkg.store`, and the project's `ecl.pkg` and
`ecl.lock` are reached through the `'project` filesystem root. Cache selection
is host policy and never an evaluated word.

### install-immutable
`( bytes package store key -- )` — Install one immutable package with
`pkg.store.install`, accepting a concurrently published real directory as
success and re-raising every other failure.

### store-key
`( package requirement -- key )` — Derive the canonical
`<name>-<version>-<hex>` key from a validated selection.

### store-keys
`( lock -- keys )` — Validate a lock and return its selected canonical keys in
package-name order.

### store-root
`( lock -- store )` — Return `'vendor` for a vendored lock and `'cache`
otherwise.

### write-project-file
`( text path -- )` — Publish one project data file beneath `'project`:
`fs.create-text` when the path is absent, otherwise the strict
`fs.replace-text`. A concurrent collision surfaces as the `fs` failure rather
than becoming an upsert.

### requirement
`( package version url -- requirement )` — Fetch and inspect one exact HTTPS
package archive and return its validated version, URL, and computed hash
declaration.

### verify
`( lock -- count )` — Verify every selected seal in the lock's store and
return the selection count.

### run
`( root-manifest -- lock )` — Discover and hash-check the complete exact
transitive manifest graph, resolve it with `pkg.mvs.resolve`, fetch and
atomically install only selected missing store entries, then publish the
canonical `ecl.lock` with `write-project-file`. Return the validated lock. See
[Synchronization](ENVIRONMENT.md#synchronization) for the two-pass fetch,
error, and partial-success contracts.

### run-offline
`( root-manifest -- lock )` — Perform the same discovery, resolution,
installation check, and lock publication using only present store entries. An
absent exact entry is `'io` naming its package, store, and key; no request is
opened.

## pkg.cli

The CLI module is an ordinary line-oriented adapter. `src/main.zig` validates
argv shapes, discovers the project as trusted host startup work, and grants it
to the Session as the `'project` filesystem root together with the package
store authority; no absolute path enters evaluated code. These words return no
stack output and print one stable line on success.

- `init ( arguments -- )` creates `ecl.pkg` in the `'cwd` root and prints
  `initialized ecl.pkg for <name>`.
- `add ( arguments -- )` records one exact fetched requirement and prints
  `added <name> <version>`.
- `sync` and `sync-offline` `( arguments -- )` print `synced <count> packages`.
- `tree` and `why` `( arguments -- )` print `pkg.lock.tree` and
  `pkg.lock.why` output unchanged.
- `verify ( arguments -- )` prints `verified <count> packages`.
- `vendor ( arguments -- )` populates the fixed vendor store, atomically marks
  the lock vendored, and prints `vendored <count> packages`.
- `gc ( lock-paths -- )` unions at least one named lock, each a canonical
  relative path beneath `'cwd` (an absolute or escaping path is `'domain`),
  and prints `removed <count> packages`.

## result

Every entry validates its result envelope before invoking a caller quotation.
A success payload is always a list representing a stack.

### all
`( results -- result )` — Return the leftmost failure unchanged, or one
success whose value is the list of success stacks in input order.

### and-then
`( result quotation -- result )` — Use a success payload as the explicit values
list for `@attempt`; return an existing
failure unchanged.

#### Examples

```ecl
[2 3] result.ok (+) result.and-then
# => {'ok [5]}
```

### either
`( result on-ok on-err -- ... )` — Eliminate a result exhaustively: call the
first quotation with the success list or the second with the error dict.
Neither branch is isolated.

#### Examples

```ecl
{'kind 'io} result.err (first) ('kind at) result.either
# => 'io
```

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

#### Examples

```ecl
{'kind 'io} result.err ['io 'timeout] (pop 99 wrap) result.recover-kinds
# => {'ok ([99])}
```

## rand

Explicit-state pseudorandom draws are pure except for `entropy`; see
[Randomness](SPEC.md#randomness). The state is `[key counter]`, and every draw
returns the advanced state alongside its result.

### entropy
`( -- result )` — Read one int from the host CSPRNG. This is the language's
only nondeterministic word, requires host IO, and is `'io` without it.

### float
`( state -- state result )` — Draw one uniform float in `[0, 1)`.

### int
`( state bound -- state result )` — Draw one unbiased uniform int in
`[0, bound)`. A bound below 1 is `'domain`.

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

## rng

These words transact against the module's durable `[key counter]` state. A
fresh process begins with a fixed key; use `rand.entropy rng.seed` to opt into
nondeterminism.

### deal
`( count pool -- results )` — Draw distinct values below `pool` without
replacement. The sample is unbiased; `count > pool` is `'domain`.

#### Examples

```ecl
42 rng.seed 4 8 rng.deal
# => [5 7 0 4]
```

### float
`( -- result )` — Draw one uniform float in `[0, 1)`.

### int
`( bound -- result )` — Draw one uniform integer below a positive bound.

### ints
`( count bound -- results )` — Draw a vector of uniform integers below a
positive bound.

#### Examples

```ecl
42 rng.seed 5 10 rng.ints
# => [3 1 8 4 0]
```

### seed
`( key -- )` — Rekey the generator and reset its counter.

### shuffle
`( values -- values )` — Return a uniformly random permutation of a list.

#### Examples

```ecl
42 rng.seed [10 20 30 40] rng.shuffle
# => [20 40 10 30]
```

## str

All case and whitespace operations use the ASCII character classes; every
non-ASCII scalar passes through unchanged.

### contains?
`( string needle -- bool )` — Return 1 when a needle occurs anywhere in a
string. The empty needle is present at index zero.

#### Examples

```ecl
"hello" "ell" str.contains?
# => 1
```

### ends?
`( string suffix -- bool )` — Return 1 when a string ends with a suffix.

### format
`( values template -- string )` — Interpolate `{}` placeholders. Strings
contribute their contents; other values contribute canonical `str`. `{{` and
`}}` emit literal braces.

#### Examples

```ecl
["Ada" 2] "name={} n={}" str.format
# => "name=Ada n=2"
```

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

#### Examples

```ecl
"a-b-c" "-" "+" str.replace
# => "a+b+c"
```

### starts?
`( string prefix -- bool )` — Return 1 when a string begins with a prefix.

### str?
`( value -- bool )` — Return 1 when a value is a string: a list whose every
element is a char. The empty string answers 1, and so does the empty list —
they are one value. Never raises.

### trim
`( string -- string )` — Remove ASCII whitespace from both ends.

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
`( string -- string )` — Uppercase ASCII letters, leaving every other scalar
unchanged.

#### Examples

```ecl
"Hello, wörld!" str.upper
# => "HELLO, WöRLD!"
```

## table

Every operation except `valid?` first validates the ordinary column dict as a
table. See the environment's [table contract](ENVIRONMENT.md#tables) for the
table convention and frozen error kinds.

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

#### Examples

```ecl
[{"name" "Ada" "score" 10} {"name" "Lin" "score" 20}] table.from-records
# => {"name" ("Ada" "Lin") "score" [10 20]}
```

### from-rows
`( names rows -- table )` — Build a table from explicit names and exact-width
rows. An empty row list preserves the named zero-row schema.

#### Examples

```ecl
["name" "score"] [("Ada" 10) ("Lin" 20)] table.from-rows
# => {"name" ("Ada" "Lin") "score" [10 20]}
```

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

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} table.records
# => ({"name" "Ada" "score" 10} {"name" "Lin" "score" 20})
```

### rename
`( table mapping -- table )` — Rename columns through an ordered old-to-new
mapping while preserving column order; collisions are `'domain`.

### rows
`( table -- rows )` — Return data rows in order.

### select
`( table names -- table )` — Keep named columns in the order given.

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} ("score") table.select
# => {"score" [10 20]}
```

### valid?
`( candidate -- bool )` — Return 1 when a candidate satisfies the convention
and 0 for a convention mismatch. Cancellation and allocation failure still
propagate.

### where
`( table mask -- table )` — Keep rows selected by an exact-length 0/1 mask.

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} [1 0] table.where
# => {"name" ("Ada") "score" [10]}
```

### with-column
`( table name column -- table )` — Replace an existing column or append a new
one, keeping the row count exact.

## test.default

The bundled runner is ordinary ECL policy over the closed `tests` / `@test`
substrate. Projects may replace it with any public qualified runner word.

### run
`( -- )` — Discover canonical tests, invoke them sequentially in deterministic
module/name order, print one `ok` or `FAIL` line for every result, continue
after ordinary test failures, and request process status 1 if any failed.

## time

Pure UTC time over the millisecond timestamps `clock.unix` produces. Every
word accepts and returns whole milliseconds; a timestamp is `{'unix ms}` and
nothing else — a `{'monotonic ms}` instant, an untagged int, a float payload,
or a dictionary with any other key is `'type`. Arithmetic is checked: leaving
the int millisecond range is `'overflow`. Calendar words use the proleptic
Gregorian calendar with no leap seconds, so Unix time here is the POSIX count
in which every day has exactly 86,400,000 milliseconds. The representable
range runs from `-292275055-05-16T16:47:04.192` through
`292278994-08-17T07:12:55.807`. Nothing in this module reads a clock.

### add
`( timestamp milliseconds -- timestamp )` — Shift a timestamp by a signed int
duration.

### cmp
`( left right -- ordering )` — Three-way order two timestamps as −1, 0, or 1.
Whole-value `match?` also compares timestamps; `<` and `=` do not.

### days
`( n -- milliseconds )` — `n` days of 86,400 seconds as milliseconds.

### diff
`( later earlier -- milliseconds )` — `later` minus `earlier`, signed.

### format
`( timestamp -- string )` — Render as `YYYY-MM-DDTHH:MM:SS.mmmZ`: always UTC,
always three fractional digits, so `format` then `parse` returns the same
timestamp and `parse` then `format` returns the same text for every string in
that shape. A year outside 0000 through 9999 cannot be written in four digits
and is `'domain`.

#### Examples

```ecl
0 time.from-unix time.format
# => "1970-01-01T00:00:00.000Z"
```

### from-unix
`( milliseconds -- timestamp )` — Tag an int as `{'unix ms}`. Negative counts
name instants before 1970.

### from-utc
`( fields -- timestamp )` — Build a timestamp from a dictionary of int fields.
`'year`, `'month`, and `'day` are required; `'hour`, `'minute`, `'second`, and
`'millisecond` default to 0; `'weekday` is optional and must agree with the
date. Any other key is `'domain`; a non-symbol key or non-int value is `'type`.
Month is 1 through 12, day is 1 through the month's length in that year, hour
0 through 23, minute and second 0 through 59, millisecond 0 through 999;
anything else is `'domain`. `to-utc` output round-trips exactly.

### hours
`( n -- milliseconds )` — `n` hours as milliseconds.

### minutes
`( n -- milliseconds )` — `n` minutes as milliseconds.

### parse
`( string -- timestamp )` — Parse an RFC 3339 `date-time`:
`YYYY-MM-DDTHH:MM:SS`, an optional fraction of one or more digits, then `Z` or
a numeric `±HH:MM` offset that is subtracted to reach UTC. `T` and `Z` may be
lower case. The first three fractional digits are kept and the rest are
discarded, so `"…​:00.1239Z"` and `"…​:00.123Z"` parse alike. Text outside the
grammar — a space separator, a missing designator, trailing characters, a
non-ASCII scalar, an empty fraction — is `'parse`; a well-formed field outside
its range, including second `60`, is `'domain`.

#### Examples

```ecl
"2024-02-29T12:34:56.789+05:30" time.parse time.format
# => "2024-02-29T07:04:56.789Z"
```

### seconds
`( n -- milliseconds )` — `n` seconds as milliseconds.

### to-unix
`( timestamp -- milliseconds )` — The int inside a timestamp.

### to-utc
`( timestamp -- fields )` — Decompose into
`{'year 'month 'day 'hour 'minute 'second 'millisecond 'weekday}`, all ints.
`'weekday` counts from Monday as 0 through Sunday as 6. Years before 1 are
negative in astronomical numbering (year 0 is 1 BC and is a leap year).

#### Examples

```ecl
951782400000 time.from-unix time.to-utc
# => {'year 2000 'month 2 'day 29 'hour 0 'minute 0 'second 0 'millisecond 0 'weekday 1}
```
