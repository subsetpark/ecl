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
`( unit-input -- result )` — *Unit constructor.* Run a quotation, or a plan's
body seeded by its values (an unseeded quotation's contract is `( -- ... )`;
inputs via `seed`, `literal`, or `partial`) as a new unit on an isolated
substack. Always pushes exactly one result:
`{'ok (values)}` with the successful stack values as a list, or
`{'err <error dict>}`.

Observationally `@spawn await` — same result shape, same error protocol,
same self-contained-quotation contract — differing only in scheduling.
That identity is what makes the isolation non-arbitrary rather than an
implementation accident. Seed it with `values (q) seed @attempt`. See
Errors.

### @defm
`( unit-input 'module-name -- )` — *Unit constructor.* Exactly `@module` followed
by `register`: run the body on a fresh environment, then validate the
canonical module path and register the resulting image under it. The body is
evaluated before the name is validated, so the two spellings agree on every
observable outcome.

The name is last, matching `def` and `set`: the bound name sits nearest
the binder. Seeded registration is therefore `values (body) seed 'name
@defm`, with the name riding above the plan and no shuffle at all. See
Modules.

### @each
`( sequence unit-input -- results )` — *Unit constructor*, one fresh unit
per element, contract `( a -- b )` enforced per element. Concurrent
`each`: ordered results, leftmost failure re-raised after cancelling and
quiescing the remainder. Each child's stack is seeded with exactly its
element; `list values (q) seed @each` adds shared values above it. See
Concurrency.

### @module
`( unit-input -- module )` — *Unit constructor.* Run the body on a fresh
environment and return the resulting anonymous immutable module image. No
registry name is claimed and no name is validated. The body's final operand
stack becomes the image's initial-state template. Seed it with `values (body)
seed @module`. See [Modules](SPEC.md#modules).

### @spawn
`( unit-input -- task )` — *Unit constructor*, contract `( -- ... )`
(inputs via `seed`/`partial`, never the ambient stack). Run a
self-contained quotation concurrently in a child task. Seed it with
`values (q) seed @spawn`. See [Concurrency](SPEC.md#concurrency).

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
Defined in ecl; `'case see` renders the definition.

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

### last
`( sequence -- value )` — Final element of a nonempty sequence.
Equivalent to `dup len 1 - at`.

### len
`( list -- count )` — Top-level element count; works on any list,
including ragged data.

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
`( collection selector value -- collection )` — Functional replacement.
For a list collection, a nested list selector is pervasive and replacement
lists conform recursively to its shape; an atomic replacement extends across
every selected position. Selector leaves are integer indices. Repeated indices
are processed left to right, so the last replacement wins. For a dictionary,
the selector is always one whole-value key, including a list key.

### qualify
`( 'module-name 'binding-name -- qualified-word )` — Validate a canonical
module path and one unqualified, non-reserved binding segment, then construct
their qualified executable word directly from the interned components. It
does not parse source or grant module-state/lifecycle authority; use `execute`
to invoke the result dynamically.

### raise
`( error -- )` — Raise a language error from an error dict.

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
state and lifetime. See [Modules](SPEC.md#modules).

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
`( 'name -- )` — Print the binding's combined annotation, when present,
followed by its body through the standard source formatter, with its
width-aware layout and no navigation header, name, or `def`/`defp` terminator.
What prints is what is stored: a name bound by `set` prints its annotation and
literal-capture body, not the `set` spelling that produced it.
Reader-built bodies retain a shared slice of their source unit, so head binders
print with their authored local names even though execution uses the lowered
`_ll`/`_gl`/`_dl` quotation. Runtime-constructed bodies without source
provenance fall back to their canonical value form. Native origins are
displayed in native body descriptors.

### seed
`( values quotation -- unit-plan )` — Seal a values list and a construction
body into one immutable unit plan, holding the two separately. Nothing is
executed, stamped, copied, or parsed: a plan is exactly the pair it was given.
The result is the seeded input every unit constructor accepts; `seed` itself
constructs no unit. See [Seeding a unit](SPEC.md#seeding-a-unit).

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
round-trip guarantee (see
[Printing and round-trip](SPEC.md#printing-and-round-trip)): reading it back yields the same
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

### tri
`( x p q r -- ... )` — *Inline.* Apply three quotations to the same input
in order. Equivalent to `((keep) dip keep) dip call`.

### tri2
`( x y p q r -- ... )` — *Inline.* Binary cleave: apply each of three
quotations to the same pair of inputs in left-to-right order. Equivalent to
`(|x y p q r| x y p call x y q call x y r call)`.

### type
`( value -- type )` — Return the value's kind as a symbol: one of `'int`,
`'float`, `'char`, `'symbol`, `'word`, `'list`, `'dict`, or `'task`.

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

### unseed
`( unit-plan -- values quotation )` — Return the exact values list and
construction body a unit plan holds. Whether a transformed body is still module
text is answered the same way as for any other value: by whether the reader
wrote it. `'type` for anything but a plan. See
[Seeding a unit](SPEC.md#seeding-a-unit).

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

This is ordinary quotation composition and constructs nothing. It is not how a
unit is seeded: the flattened quotation it returns is runtime-built, so a
constructor cannot tell the body from the values, and `@module` and `@defm`
therefore give it no module attribution. Use `seed`.

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
a partial destination. See the language specification's
[`archive` contract](SPEC.md#archive) for the complete
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

### from-pairs
`( pairs -- dict )` — Build a dictionary from a list of exact `[key value]`
pairs in list order. A malformed pair is `'shape`; duplicate keys are
`'domain`.

### has?
`( dict key -- bool )` — Whole-value key membership. Keys are inert and only
absence is false: lookup machinery failures are errors, never converted to 0.

### keys
`( dict -- keys )` — Return keys in insertion order.

### size
`( dict -- count )` — Return the number of entries in constant time.

### keys-exactly?
`( candidate declared -- bool )` — Return 1 when a dictionary has exactly the
declared keys in any order. A duplicate declaration returns 0.

### map
`( dict quotation -- dict )` — Call a `( key value -- value )` quotation for
every entry, replacing values while preserving keys and insertion order.

### map-values
`( dict quotation -- dict )` — Apply a `( value -- value )` quotation to every
value, preserving keys and insertion order.

### merge
`( left right -- dict )` — Merge two dictionaries; right-hand values win.
Existing left keys retain their positions and right-only keys append in right
order. Key-aligned arithmetic remains pervasive `+` on dicts.

### merge-with
`( left right quotation -- dict )` — Merge two dictionaries, resolving each
shared key with `( key left-value right-value -- value )`. Existing left keys
keep their positions; right-only keys append in right order.

### pairs
`( dict -- pairs )` — Return insertion-ordered `[key value]` pairs. This is the
bridge to generic iteration: `each`, `fold`, `all?`, and `any?` need no
dict-specific duplicates.

### reject
`( dict predicate -- dict )` — Call a `( key value -- bool )` predicate in
insertion order and discard the entries for which it returns 1.

### split
`( dict keys -- selected rejected )` — Partition a dictionary by a key list,
returning selected then rejected entries; ignore absent keys and preserve
dictionary order in both results.

### take
`( dict keys -- dict )` — Keep entries named by a key list, ignoring absent
keys. Output follows dictionary order, not the requested key-list order.

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

Host-backed package archive and publication capabilities. Every traversal,
write, rollback, and output materialization advances through bounded scheduler
work; no word exposes a host handle or generic filesystem mutation.

### inspect
`( bytes package-name -- manifest-text )` — Validate one tgz's hostile-input
and source-only archive envelope without creating a filesystem destination.
Return the sole root `ecl.pkg` as exact UTF-8 text.

### install
`( bytes package-name destination -- regular-file-paths )` — Repeat archive
validation, derive and validate the staged manifest/glob/module catalog, and
atomically publish at a previously absent destination. Return normalized
regular-file paths only after commit; failure never exposes a partial
destination.

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
See [Packages / Synchronization](SPEC.md#synchronization) for cache selection, two-pass fetch, error, and
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
stack and run the quotation through `seed @attempt`; return an existing
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

### ints
`( state count bound -- state results )` — Draw `count` uniform ints in
`[0, bound)`, advancing the state by `count`. Each element is addressed by its
own counter position, so materialization order cannot change the list.

## rng

These words transact against the module's durable `[key counter]` state. A
fresh process begins with a fixed key; use `rand.entropy rng.seed` to opt into
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

### format
`( values template -- string )` — Interpolate `{}` placeholders. Strings
contribute their contents; other values contribute canonical `str`. `{{` and
`}}` emit literal braces. `["Ada" 2] "name={} n={}" str.format` is
`"name=Ada n=2"`.

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
table. See the language specification's [table contract](SPEC.md#table) for
the table convention and frozen error
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
