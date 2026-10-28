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

### <>

### =
`( x y -- bool )` — **Pervasive.** Equality; numbers compare numerically
across int and float. Whole-value equality is `match?`.


### >
`( x y -- bool )` — **Pervasive.** Descending comparison, producing 0/1
masks.


### >=

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


### @attempt!
`( quotation -- result )` — *Unit constructor.* `@attempt` with no values
operand: the quotation runs on an empty stack, exactly as `[] (q) @attempt`.

#### Examples

```ecl
(40 2 +) @attempt!
# => {ok [42]}
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


### @defm!
``( body `module-name -- )`` — *Unit constructor.* `@defm` with no values
operand: the body runs on an empty stack, exactly as ``[] (body) `name @defm``.
Module discovery and the formatter's `### module` header recognize this form
too.


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


### @give!
`( ports quotation -- task )` — *Unit constructor.* `@give` with no values
operand: the child stack is the given ports alone, exactly as
`ports [] (q) @give`.


### @spawn!
`( quotation -- task )` — *Unit constructor.* `@spawn` with no values operand:
the quotation runs on an empty stack, exactly as `[] (q) @spawn`.

#### Examples

```ecl
(40 2 +) @spawn! task.await
# => {ok [42]}
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

### atan2
`( y x -- z )` — **Pervasive.** Two-argument arctangent; returns float.


### band
`( x y -- z )` — **Pervasive.** Bitwise and over the two's-complement bit
patterns of ints. Non-int leaves are `` `type ``.


### bi2

### bnot
`( x -- y )` — **Pervasive.** Invert every bit. `bnot bnot` is identity;
`0 bnot` is `-1`.


### bor
`( x y -- z )` — **Pervasive.** Bitwise or. See `band`.


### both

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

### empty?

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


### importp
`( module-name q -- )` — `import`, publishing each forwarding binding as a
private module word: the importing module's words use it, but it is not part
of that module's public surface. Legal only inside a module body; elsewhere it
is `` `domain ``.


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


### min
`( x y -- z )` — **Pervasive.** The lesser of two comparable atoms.


### neg

### nip

### not
`( bool -- bool )` — **Pervasive.** Invert 0/1 values.


### pack

#### Examples

```ecl
1 2 3 3 pack
# => [1 2 3]
```

### pair

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


### reverse

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

### sin
`( x -- y )` — **Pervasive.** Sine; float transcendental.


### sort

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

### unset

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

#### Examples

```ecl
[1 2 3 4] 3 windows
# => [[1 2 3] [2 3 4]]
```

### words
`( -- )` — Print the visible dictionary in sorted order.


### wrap

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

### append

### compose

### literal

### max-of

### min-of

### rest

### zip

### dip

### fail

### from-digits

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

#### Examples

```ecl
1 3 (10 +) iterations
# => [1 11 21 31]
```

### partial

#### Examples

```ecl
4 3 (+) partial call
# => 7
```

### scan1

### set

### setp

### uncons

### while-values

#### Examples

```ecl
1 (5 <) (1 +) while-values
# => [1 2 3 4 5]
```

### and

### clamp

### find

### or

### over

### rolldown

### rollup

### unappend

### with

#### Examples

```ecl
[3] (dup) with call
# => 3 3
```

### @each

### @each!

#### Examples

```ecl
[1 2 3] (10 *) @each!
# => [10 20 30]
```

### all?

#### Examples

```ecl
[2 4 6] (2 mod 0 =) all?
# => 1
```

### any?

### converges

### filter

#### Examples

```ecl
[1 2 3 4] (2 mod 0 =) filter
# => [2 4]
```

### fold1

### keep

### lex-cmp-with

### mod

### partition

#### Examples

```ecl
[1 2 3 4] (2 mod 0 =) partition pair
# => [[2 4] [1 3]]
```

### bi

### case

#### Examples

```ecl
3 [1 ("one") 3 ("three") ("other")] case
# => "three"
```

### chunk

#### Examples

```ecl
[0 1 2 3 4 5 6] 3 chunk
# => [[0 1 2] [3 4 5] [6]]
```

### converge

### product

### sum

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

### mean
