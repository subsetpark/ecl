<!-- Generated from design/stdlib by design/stdlib/assemble.ecl; edit the fragments. -->

# ECL standard library reference

## Prelude and core

### \*
`( x y -- z )` — Evaluate `x` * `y`

### \*%
`( x y -- z )` — Multiply integers modulo 2^64 in two's complement, wrapping where `*` raises `` `overflow ``.

#### Examples

```ecl
4294967295 4294967295 *%
# => -8589934591
1103515245 4198498305 *% 12345 +% 4294967295 band
# => 1325825702
```

### \*file\*
`( -- string )` — Return the source name attached to the currently executing reader-authored occurrence.

### \*module\*
`( -- module-name )` — Return the name of the module whose code is running.

### +
`( x y -- z )` — Evaluate `x` + `y`

#### Examples

```ecl
1 2 +
# => 3
```

### +%
`( x y -- z )` — Add integers modulo 2^64 in two's complement, wrapping where `+` raises `` `overflow ``.

#### Examples

```ecl
9223372036854775807 1 +%
# => -9223372036854775808
```

### -
`( x y -- z )` — Evaluate `x` - `y`

### -%
`( x y -- z )` — Subtract integers modulo 2^64 in two's complement, wrapping where `-` raises `` `overflow ``.

### /
`( x y -- z )` — Evaluate `x` / `y`. Any nonzero number / 0 is signed inf; 0 / 0 is `` `domain ``

### <
`( x y -- bool )` — Evaluate `x` < `y`.

### <=
`( x y -- bool )` — Evaluate `x` <= `y`.

### =
`( x y -- bool )` — Pervasively evaluate `x` = `y`.

### >
`( x y -- bool )` — Evaluate `x` > `y`.

### >=
`( x y -- bool )` — Evaluate `x` >= `y`.

### @attempt
`( quotation -- result )` — Run the quotation as a new unit on an empty, isolated stack. It will push a result object, containing either `ok <values>` with the successful stack values as a list, or `{err <error dict>}`.

#### Examples

```ecl
(1 2 3 +) @attempt
# => {ok [1 5]}
```

### @defm
`( body module-name -- )` — Construct a module image and register it under `module-name`. The body is run in a new unit.

### @give
`( ports quotation -- task )` — Create a new task and evaluate `quotation`. The tasks's stack will be seeded with the contents of `ports`. Every port in `ports` additionally has its ownership transferred to the new task; the port's lifetime is determined by the lifetime of the task that owns it.

#### Examples

```ecl
{address "127.0.0.1" port 0} net.listen
wrap (net.local-address `port at 0 >) @give task.await
# => {ok [1]}
```

### @load
`( path -- )` — Evaluate the source file at `path`. The file is run in a new unit.

### @spawn
`( quotation -- task )` — Create a new task and evaluate `quotation`.

#### Examples

```ecl
(40 2 +) @spawn task.await
# => {ok [42]}
```

### @test
`( descriptor -- result )` — When in a test session, execute the test described by `descriptor` in a new unit. Returns `{ok (values)}` or `{err error}`.

### above
`( ... (q: ... -- ...) -- ... )` — Evaluate `q`, then restore the values it consumed above its results, in their original order.

### abs
`( x -- y )` — Evaluate the absolute value of `x`.

### alias
`( name short -- )` — Bind `short` in the current scope as an alias of the module name `name`: a qualified word written in this scope whose module part is exactly `short` denotes `name` instead, resolved at each call. The alias is private to the scope and never exported. Inside a module it is legal only during construction.

### all?
`( list (p: a -- bool) -- bool )` — Return 1 when `p` returns 1 for every element of `list`; otherwise return 0.

#### Examples

```ecl
[2 4 6] (2 mod 0 =) all?
# => 1
```

### and
`( x y -- bool )` — Evaluate boolean `x` and `y`.

### any?
`( list (p: a -- bool) -- bool )` — Return 1 when `q` returns 1 for at least one element of `list`; otherwise return 0.

### apply
`( quotation -- ... )` — Run `quotation` on the current stack.

### args
`( -- arguments )` — The process arguments following the script or source, as a list of strings.

### assert
`( bool error -- )` — Raise `error` unless `bool` is 1.

### at
`( collection key -- value )` — Index a list or look up a dict key. A list pervades over the selector; a dict takes it as one whole key.

#### Examples

```ecl
[10 20 30] [2 0] at
# => [30 10]
```

### at-path
`( ds path -- x )` — Follow `path` through `ds` via `at`; an empty path returns `ds` unchanged.

### atan2
`( y x -- z )` — Two-argument arctangent.

### band
`( x y -- z )` — Bitwise and.

### below
`( ... (q: ... -- ...) -- ... )` — Evaluate `q`, then restore the values it consumed below its results, in their original order.

### bi
`( ... p q -- ... )` — Apply `p` and `q` to the same view of the stack. Push `p`'s results, followed by `q`'s results.

### bnot
`( x -- y )` — Bitwise not.

### bor
`( x y -- z )` — Bitwise or.

### both
`( x y q -- ... )` — Apply `q` to `x` and `y`.

### bracket
`( ... p q -- ... )` — Apply `q` to the inputs it takes from the top of the stack and `p` to the inputs it takes from what remains. Push `p`'s results, followed by `q`'s results, in place of everything they consumed. `q` runs first. `(p) (q) bracket` is `[(p) (q)] spread`.

### bsl
`( x count -- y )` — Shift the bit pattern left by `count` places, truncating bits shifted off the top.

### bsr
`( x count -- y )` — Shift the bit pattern right by `count` places, filling zeros from the top.

### bxor
`( x y -- z )` — Bitwise exclusive or.

### bytes
`( value -- bytes )` — Encode a UTF-8 string as a byte list: an integer list whose elements are 0 through 255.

#### Examples

```ecl
"hé" bytes
# => [104 195 169]
```

### bytes?
`( value -- bool )` — Return 1 when the value is a byte list, a list of integers in `0...255` such as `bytes` returns and `stream.write` accepts as one piece, and 0 for anything else, including a string.

### cat
`( left right -- list )` — Concatenate `left` and `right`.

### ceil
`( x -- integer )` — Round up to the nearest integer.

### char
`( value -- chars )` — Return a char unchanged, or the char with an int's codepoint. A string is returned unchanged, and a list of chars or codepoints becomes the string of those chars. An int or list element outside the Unicode scalar range is `domain`. Unlike `chars`, integers are codepoints, not UTF-8 bytes.

#### Examples

```ecl
955 char
# => \λ
```

### chars
`( value -- string )` — Return a value's text content as a string.

#### Examples

```ecl
`foo chars [104 195 169] chars
# => "foo" "hé"
```

### clamp
`( value lower upper -- bounded )` — Constrain `value` to the inclusive interval between `lower` and `upper`.

### cleave
`( ... quotations -- ... )` — Apply each quotation in `quotations` to the same view of the stack. Push each quotation's results to the stack in order.

### cmp
`( left right -- ordering )` — Return -1 if `left` < `right`, 0 if `left` = `right`, and 1 if `left` > `right`.

#### Examples

```ecl
[1 2] [1 3] cmp [["b" 1]] [["a" 2]] cmp [1] [1 0] cmp
# => -1 1 -1
```

### collect
`( quotation -- list )` — Run `quotation` on an empty stack and return the results as a list.

#### Examples

```ecl
9 (1 2 3 +) collect
# => 9 [1 5]
```

### cond
`( clauses -- ... )` — Conditionally evaluate the first action in `clauses` whose predicate is true.

`clauses` consists of an odd number of quotations; every odd quotation (except the last) is a predicate, and is directly followed by its associated action. If no predicate evaluates to true, then evaluate the last quotation (`else`). Each quotation runs against the same view of the stack.

#### Examples

```ecl
10 20 [(pop 10 =) (pop pop 111) (pop pop 222)] cond
# => 111
```

### cons
`( value list -- result )` — Prepend `value` to the left end of `list`.

#### Examples

```ecl
4 3 (+) cons apply
# => 7
```

```ecl
`w (dup) cons apply
# => w w
```

### cos
`( x -- y )` — Evaluate the cosine of `x`.

### cut
`( list indices -- pieces )` — Split `list` into sublists starting at every element of `indices`.

#### Examples

```ecl
[0 1 2 3 4 5 6] [0 2 5] cut
# => [[0 1] [2 3 4] [5 6]]
"hello world" [6] cut
# => ["world"]
```

### def
`( ... body name -- )` — Bind `name` to `body` in the current scope. Optionally, consume an annotation quotation below the body as binding metadata.

### defp
`( ... body name -- )` — Bind `name` to `body` in the current scope. This is only valid in a module body, and prevents the binding from being accessed outside of the module image. Optionally, consume an annotation quotation below the body as binding metadata.

### del
`( collection selector -- collection )` — Remove the element at `selector` inside of `collection`. When `collection` is a list, selector behaviour is pervasive; when `collection` is a dict, `selector` is treated as a whole-value key.

### dip
`( x (q: ... -- ...) -- ... x )` — Run a quotation beneath a protected top stack value: evaluate `q` with `x` removed, then push `x` on top of its results.

### dip-n
`( ... (q: ... -- ...) n -- ... )` — Run a quotation beneath the top `n` stack values: evaluate `q` with them removed, then they push them back in their original order after its results.

### dip2
`( x y (q: ... -- ...) -- ... x y )` — Run `q` beneath `x y`, then push `x y` back in their original order after its results.

### distinct
`( list -- list )` — Return a list with the first occurrence of each distinct element of `list`, in order.

### div
`( x y -- z )` — Evaluate `x` / `y`, with a floored integer result.

### doc
`( name -- string )` — Return the canonical documentation string of `name`.

### drop
`( list count -- result )` — Remove the first `count` elements of `list`, or the last `count` if `count` is negative.

### dup
`( x -- x x )` — Duplicate the top stack value.

### dup2
`( x y -- x y x y )` — Copy the top two stack values onto the top, preserving their order.

### each
`( collection (q: a -- b) -- collection )` — Evaluate `q` against every element in `collection`, collecting the results of each application in order in a collection of the same type. When `collection` is a dict, then `a` is a value in `collection`, and it's mapped back to the same key in the result.

#### Examples

```ecl
[1 2 3] (dup *) each
# => [1 4 9]

{a 1 b 2} (1 +) each
# => {a 2 b 3}
```

### each-prior
`( list seed (q: prior current -- result) -- list )` — Apply `q` to each successive pair of elements in `list`, using `seed` as the predecessor of the first element.

```
 Ex:
   [12 13 11] 10 (-) each-prior
 [-2 -1 2]
```

### effect
`( name -- annotation )` — Return the stack effect of `name`, or `()`.

#### Examples

```ecl
`+ effect
# => (x y -- z)
```

### empty?
`( list -- bool )` — Return 1 when `list` has no elements and 0 otherwise.

### execute
`( word -- ... )` — Evaluate a symbol's binding and dispatch.

### exit
`( status -- )` — Called from the root unit, cancel and quiesce all descendants, then terminate the process with the given status.

### exp
`( x -- y )` — Evaluate e ^ `x`.

### exports
`( module-name -- names )` — Return the public words of a module as a list of symbols in codepoint order.

#### Examples

```ecl
`tar exports
# => (read unpack)
```

### filter
`( list (p: a -- count) -- matches )` — Apply `p` to every element of `list`, retaining each element as many times as its returned int.

#### Examples

```ecl
[1 2 3 4] (2 mod 0 =) filter
# => [2 4]
```

### find
`( haystack needle -- index )` — Return the index of the first element of `haystack` for which `needle match?` returns 1, or the list length when no element matches.

### first
`( list -- value )` — Return the first element of `list`.

#### Examples

```ecl
(dup swap) first
# => dup
```

### first-where
`( counts -- index )` — For each element `e` at index `i` of `counts`: return the first `i` where `e 0 >`. Return the length of `counts` otherwise.

### flip
`( vec -- flipped )` — Transpose rectangular vector `vec` along the diagonal.

#### Examples

```ecl
(["a" "long"] ["bc" "d"]) flip
# => (("a" "bc") ("long" "d"))
["ab" "cd"] flip
# => ("ac" "bd")
```

### float
`( value -- float )` — Convert a value to a float, or parse a string representation of a float.

#### Examples

```ecl
"2.5e1" float 3 float
# => 25.0 3.0
```

### floor
`( x -- integer )` — Round down to the nearest integer.

### fold
`( list accumulator (acc a -- acc) -- accumulator )` — Reduce left-to-right from the supplied accumulator.

#### Examples

```ecl
[1 2 3 4] 0 (+) fold
# => 10
```

### fold1
`( list (acc a -- acc) -- value )` — Reduce a nonempty list left to right from its first element.

### for
`( collection (a --) -- )` — Evaluate `q` against every element in `collection`. `q` must leave no results.

### getenv
`( name -- value )` — Return the value of the variable `name` in the process environment.

### grade
`( list -- indices )` — Return the indices of `list` permuted such that their associated elements are sorted in ascending order.

#### Examples

```ecl
[3 1 2] grade
# => [1 2 0]
```

```ecl
[3 1 2] dup grade at
# => [1 2 3]
```

### group
`( list -- dict )` — Return a dict from each distinct element of `list` to the ascending list of indices of its occurrences.

#### Examples

```ecl
[a b a] group
# => {a [0 2] b [1]}
```

### group-columns
`( columns -- groups )` — Group rows from a nonempty list of equal-length columns. Keys are whole composite lists; row indices within each group are ascending. Zero rows produces an empty dictionary. An empty column list or ragged columns raises `` `shape ``; non-list columns raise `` `type ``.

### has?
`( haystack needle -- bool )` — `in?` with its operands reversed: return 1 if `haystack` contains `needle`. A list haystack pervades over `needle`; a dict haystack takes `needle` as one whole key.

### helper
`( quotation -- quotation )` — Mark a quotation read from source as a helper body and return it. A word defined with a helper body reports a failure inside it at the place that called the word, as an assertion does: `(body) helper `name def`. Every word still appears in `trace`.

### id
`( x -- x )` — Return the top value unchanged. Inside a measured quotation it takes the value from beneath, so `(pop id)` selects the second value.

### if
`( bool then else -- ... )` — Run `then` when the condition is 1, `else` when it is 0.

### import
`( module-name bindings -- )` — For each value in `bindings`, create a public alias in the current scope from <value> to <module-name>.<value>.

### importp
`( module-name q -- )` — For each value in `bindings`, create a private alias in the current scope from <value> to <module-name>.<value>.

### in?
`( needle haystack -- bool )` — Return 1 if `needle` is in `haystack`. A list haystack pervades over `needle`; a dict haystack takes `needle` as one whole key.

#### Examples

```ecl
[2 5] [1 2 3] in?
# => [1 0]
```

### infra
`( list (q: ... -- ...) -- list )` — Evaluate `q` with `list`'s elements as stack, and push the resulting stack as a list.

#### Examples

```ecl
[1 2 3] (dup) infra
# => [1 2 3 3]
```

### int
`( value -- int )` — Convert a value to an int, or parse a string representation of an int.

#### Examples

```ecl
"42" int "a" first int
# => 42 97
```

### intern
`( value -- symbol )` — Given a string, return the symbol with the same spelling. Returns a symbol unchanged. A new valid spelling is added to the intern table. Interned symbols live for the whole process and are never reclaimed, and the table's capacity is fixed, so interning unbounded external input can exhaust it and fail with out-of-memory.

#### Examples

```ecl
"fresh-name" intern
# => fresh-name
```

### last
`( list -- value )` — Return the final element of `list`.

### len
`( list -- count )` — Return the length of `list`.

### lex-cmp-with
`( left right (left-element right-element -- order) -- order )` — Compare two lists lexicographically with a comparator that returns −1, 0, or 1. The comparator runs only through the first differing pair; when the shared prefix is equal, the lists are ordered by length.

### linrec
`( predicate base pre post -- ... )` — Linear recursion. Evaluate `predicate` and then restore any consumed elements. If `predicate` pushes 1, consume the boolean and evaluate `base`. If `predicate` pushes 0, consume the boolean, evaluate `pre`, recurse from `pre`'s resulting stack, then evaluate `post`.

### log
`( x -- y )` — Evaluate the natural logarithm of `x`.

### match?
`( left right -- bool )` — Compare two whole values for equality.

#### Examples

```ecl
[1 2] [1 2] match?
# => 1
```

### max
`( x y -- z )` — Evaluate the numeric maximum of `x` and `y`.

### mean
`( list -- mean )` — Return the arithmetic mean of `list`.

### min
`( x y -- z )` — Evaluate the numeric minimum of `x` and `y`.

### mod
`( x y -- z )` — Compute the remainder of floored `x` / `y`, taking the sign of `y`.

### module-doc
`( module-name -- string )` — Return the docstring of `module-name`'s current image.

### neg
`( x -- y )` — Evaluate -`x`.

### nip
`( x y -- y )` — Discard the second value on the stack.

### not
`( bool -- bool )` — Invert boolean `x`.

### not=
`( x y -- bool )` — Evaluate `x` != `y`.

### of
`( key collection -- value )` — `at` with its operands reversed: index a list or look up a dict key. A list pervades over the selector; a dict takes it as one whole key.

### or
`( x y -- bool )` — Evaluate boolean `x` or `y`.

### over
`( x y -- x y x )` — Copy the value beneath the top of the stack onto the top.

### pack
`( ... n -- list )` — Collect the top `n` values into a list.

#### Examples

```ecl
1 2 3 3 pack
# => [1 2 3]
```

### pair
`( x y -- list )` — Collect `x y` into a two-element list.

### parse
`( string -- quotation )` — Parse source text into an unevaluated quotation. Reading interns every symbol and word in the string.

#### Examples

```ecl
"[1 2]" parse first
# => [1 2]
```

### partition
`( list (p: a -- bool) -- matches rejects )` — Split `list` into the elements for which `p` returned 1 and those that returned 0.

#### Examples

```ecl
[1 2 3 4] (2 mod 0 =) partition pair
# => [[2 4] [1 3]]
```

### pop
`( x -- )` — Discard the top stack value.

### pow
`( x y -- z )` — Exponentiation.

### product
`( list -- product )` — Multiply every element of a numeric list; 1 when the list is empty. A nonempty list's product starts from its first element, so a list of rows multiplies to a row.

### put
`( collection selector value -- collection )` — Set the element at `selector` to `value` inside of `collection`. When `collection` is a list, selector behaviour is pervasive; when `collection` is a dict, `selector` is treated as a whole-value key.

#### Examples

```ecl
[10 20 30] [0 2] 99 put
# => [99 20 99]
```

### qualify
`( module-name binding-name -- qualified-word )` — Create a symbol value containing the qualified name `module-name`.`binding-name`.

### raise
`( error -- )` — Raise an error from an error dict.

### range
`( bound -- list )` — Return the integer range from 0 to `bound`, exclusive.

#### Examples

```ecl
5 range
# => [0 1 2 3 4]
```

### raze
`( list -- list )` — Flatten `list` one level.

### reshape
`( list new-shape -- vec )` — Flatten `list` and reflow it such that `vec shape new-shape match?`

#### Examples

```ecl
[1 2 3 4] [2 3] reshape
# => [[1 2 3] [4 1 2]]
```

### rest
`( list -- result )` — Return all but the first element of `list`.

### reverse
`( list -- result )` — Return `list` with its elements in reverse order.

### rolldown
`( x y z -- y z x )` — Rotate the top three stack values downward.

### rollup
`( x y z -- z x y )` — Rotate the top three stack values upward.

### rotate
`( list count -- rotated )` — Shift the elements of `list` to the left by `count` places, wrapping the first `count` elements to the end.

#### Examples

```ecl
[1 2 3 4 5] 2 rotate
# => [3 4 5 1 2]
```

### round
`( x -- integer )` — Round to the nearest integer.

### scan
`( list accumulator (acc a -- acc) -- list )` — Reduce left-to-right from the supplied accumulator. Return a list of the state of the accumulator after each reduction.

#### Examples

```ecl
[1 2 3 4] 0 (+) scan
# => [1 3 6 10]
```

### see
`( name -- )` — Print `name`'s combined annotation, when present, followed by its body.

### shape
`( vec -- shape )` — Given a rectangular n-dimensional vector `vec`, return a list of `n` elements, where each element is the length of `vec` along the associated dimension.

### signum
`( number -- sign )` — Return −1, 0, or 1 according to the sign of `number`.

### sin
`( x -- y )` — Evaluate the sine of `x`.

### spread
`( ... quotations -- ... )` — Apply each quotation in `quotations` to its own inputs: the last takes what it needs from the top of the stack, the one before it from what remains, and so on. Push every quotation's results in the order of the quotations, in place of everything they consumed. The quotations run last to first.

### sqrt
`( x -- y )` — Square root.

### stack
Copy the operand stack into a bottom-to-top list while leaving every original value in place.

### stencil
`( list width (q: window -- result) -- list )` — Apply `q` to each overlapping window of a positive int width, left-to-right.

#### Examples

```ecl
[1 2 3 4] 3 (sum) stencil
# => [6 9]
```

### str
`( value -- string )` — Render `value` as a string.

#### Examples

```ecl
"abc" str
# => "\"abc\""
```

### sum
`( list -- total )` — Add every element of a numeric list; 0 when the list is empty. A nonempty list's total starts from its first element: a list of rows sums to a row, and a sum of negative zeros is `-0.0`.

#### Examples

```ecl
[1 2 3] sum
# => 6
[[1 2] [3 4]] sum
# => [4 6]
[] sum
# => 0
```

### swap
`( x y -- y x )` — Exchange the top two stack values.

### symbol
`( value -- symbol )` — Given a string, return the symbol with the same spelling. Returns a symbol unchanged.

#### Examples

```ecl
"foo" symbol `foo match?
# => 1
```

### take
`( list count -- result )` — Return a list containing the first `count` elements of `list`, or the last `count` elements if `count` is negative. If `list len 0 >`, cycle the elements of `list`.

#### Examples

```ecl
[1 2 3] 5 take
# => [1 2 3 1 2]
```

### test
`( ... body name -- )` — Create a test binding of `name` to `body` in module scope. The binding is only visible when run in a test session. A test descriptor for the program will be returned when `tests` is run inside the test session.

### tests
`( -- descriptors )` — When in a test session, return a list of test descriptors for every test defined by all currently-registered modules, sorted by (module, test name). Each dictionary contains symbol fields `` `module `` and `` `name `` plus optional declared `` `effect `` and `` `doc ``.

### times
`( n quotation -- ... )` — Evaluate `quotation` `n` times.

### tri
`( ... p q r -- ... )` — Apply `p`, `q`, `r` to the same view of the stack. Push `p`'s results, followed by `q`'s results, followed by `r`'s.

### type
`( value -- type )` — Return the value's kind as a symbol: one of `int`, `float`, `char`, `symbol`, `list`, `dict`, `task`, `port`, or `address`.

#### Examples

```ecl
"abc" type
# => list
```

### uncons
`( list -- first rest )` — Split a nonempty `list` into its first element and remaining elements.

### unfold
`( state (predicate: state -- bool) (step: state -- state item) -- state list )` — Evaluate `predicate`; when it returns 0, return the current state and all generated items. When it returns 1, evaluate `step`, pushing `item` to `list`, and continue from the returned state.

#### Examples

```ecl
0 (5 <) (dup 1 + swap) unfold pair
# => (5 [0 1 2 3 4])
```

### unless
`( bool else -- ... )` — Call `else` when the condition is 0.

### update
`( collection selector (q: value -- value) -- collection )` — Apply `q` at the selected positions. A list collection's selector pervades with the same nested shape as `at` and is processed left to right, so repeated indices observe earlier updates. A dictionary selector is one whole-value key.

#### Examples

```ecl
[1 2 3] [2 0] (10 *) update
# => [10 2 30]
```

### when
`( bool then -- ... )` — Call `then` when the condition is 1.

### where
`( counts -- indices )` — For each element `e` at index `i` of `counts`: collect `e` copies of `i` into a list.

#### Examples

```ecl
[0 2 1] where
# => [1 1 2]
```

### while
`( cond body -- ... )` — Evaluate `cond` and then restore any consumed elements. If `cond` pushes 1, consume the boolean, evaluate `body` in place and loop. If `cond` pushes 0, consume the boolean and exit.

### while-values
`( value (p: state -- bool) (step: state -- state) -- list )` — Construct a list containing `value` and successive states through the first state for which `p` is false.

#### Examples

```ecl
1 (5 <) (1 +) while-values
# => [1 2 3 4 5]
```

### windows
`( list width -- sublists )` — Generate every contiguous subsequence of `list` of width `width`.

#### Examples

```ecl
[1 2 3 4] 3 windows
# => [[1 2 3] [2 3 4]]
```

### words
`( -- )` — Print all visible words in sorted order.

### wrap
`( value -- list )` — Wrap `value` in a list.

### zip-with
`( left right (q: a b -- c) -- list )` — Conform `left` and `right`, and apply `q` to an element from each side, collecting the results in a list.

#### Examples

```ecl
[1 2 3] [10 20 30] (+) zip-with
# => [11 22 33]
```

### @each
`( list (q: a -- b) -- results )` — Concurrently apply `q` to each element of `list`, each application in a fresh unit.

#### Examples

```ecl
[1 2 3] (10 *) @each
# => [10 20 30]
```

### append
`( list value -- list )` — Push `value` to the end of `list`.

### chunk
`( list size -- pieces )` — Split `list` into consecutive `size`-width pieces, possibly including fewer than `size` elements in the last piece.

#### Examples

```ecl
[0 1 2 3 4 5 6] 3 chunk
# => [[0 1 2] [3 4 5] [6]]
```

### converges
`( value (q: a -- a) -- list )` — ```
Construct a list containing `value` and the results of successive
applications of `q`, until the result matches
 either `value` or the immediately preceding result.
```

### fail
`( msg -- )` — Raise an error with the shape `{kind user msg msg}`.

### iterations
`( value count (q: a -- a) -- list )` — Construct a list containing `value` and the results of `count` successive applications of `q`.

#### Examples

```ecl
1 3 (10 +) iterations
# => [1 11 21 31]
```

### parse-one
`( string -- x )` — Parse source text describing exactly one form.

### retain
`( ... counts -- ... )` — Keep each of the values beneath `counts` as many times as its count, in order: the first count applies to the deepest of them, and the values consumed are as many as `counts` holds. The stack form of `where at`.

### scan1
`( list (q: acc a -- acc) -- list )` — Fold `q` over `list`, using the first element of `list` as the accumulator and returning a list of each successive accumulator value.

### set
`( ... value name -- )` — Bind `name` to `value` in the current scope. Accepts an optional annotation below `value` as metadata on the binding.

### setp
`( ... value name -- )` — Inside of a module, bind `name` to `value` only within that module.

### to-digits
`( value radices -- digits )` — Split a value into one digit per radix, most significant first, by floor division, so every digit lies from zero below its radix even for negative values. A value beyond the radices' capacity keeps only its low digits. Values pervade.

#### Examples

```ecl
13 [2 2 2 2] to-digits
# => [1 1 0 1]
3723 [24 60 60] to-digits
# => [1 2 3]
-7 [10 10] to-digits
# => [9 3]
```

### unappend
`( list -- initial last )` — Split `list` into its initial elements and last element.

### zip
`( left right -- pairs )` — Pair corresponding elements of conforming `left` and `right`.

### case
`( x clauses -- ... )` — Given a flat list of `case q` clauses, apply the first `q` whose `case` matches `x`.

`clause` should be shaped:

```
   [case1 q1
    case2 q2
    ...
    else]
```

Where `caseN` is a value to be compared against `x` with `match?`, and `qN` is the quotation to apply for the first case that matches. A matching action is called with `x` consumed.

`else` is obligatory and is applied when no case matches, with `x` still on the stack.

#### Examples

```ecl
3 [1 ("one") 3 ("three") ("other")] case
# => "three"
```

The else quotation receives the unmatched subject:

```ecl
5 [1 (10) 3 (30) (100 *)] case
# => 500
```

### converge
`( x (q: a -- a) -- y )` — Return the last value before repeated application of `q` to `x` reaches a fixed point or matches `x`.

### from-digits
`( digits base -- value )` — Combine digits, most significant first, into a value. The base is one integer for every position, or a list of radices with one per digit, as in mixed-radix time; the first radix has no effect. Digits pervade: a list of equal-length digit lists, one per position, gives one value per column.

#### Examples

```ecl
[1 0 1] 2 from-digits
# => 5
[[1 0] [0 1] [1 1]] 2 from-digits
# => [5 3]
[1 2 3] [24 60 60] from-digits
# => 3723
```

### case-with
`( x clauses (key: x -- k) -- ... )` — Like `case`, but match the clause keys against the result of applying `key` to `x`, and apply the selected action with `x` itself on the stack.

## agent

An agent is a stateful task that evaluates quotations it receives and responds with the top operand on its stack.

To spawn a new agent, apply `agent.start` to some initial value. Quotations sent to the resulting address via `agent.send` will be applied to the state. Sending a quotation via `call` or `call-for` will apply the quotation, wait for a response, and then push the response onto the calling stack.

#### Examples

An ambient random generator:

```ecl
[0 0] agent.start `rng set
rng (5 rand.int) agent.call
# => 0
```

### send
`( address quotation -- )` — Apply `quotation` to the agent's stack in a unit.

### call
`( address quotation -- result )` — Apply `quotation` to the agent's stack in a unit and return the top value. Errors are re-raised.

#### Examples

```ecl
[0 0] agent.start `g set
g (100 rand.int) agent.call g (100 rand.int) agent.call pair
# => [35 0]
[7 0] agent.start `g set
(g (1 0 div) agent.call) @attempt `err at `kind at g (dup) agent.call pair
# => (domain [7 0])
```

### call-for
`( address quotation milliseconds -- result )` — Apply `quotation` to the agent's stack in a unit and wait up to `milliseconds` for the response. Errors are re-raised.

### serve
Turn the current task into an agent whose state is the current stack, then serve until cancelled: receive a message, apply its quotation to the state as a unit, and optionally reply.

### start
`( state -- address )` — Spawn a task initialized with `state` and return its address.

## clock

Scheduler-backed time. `now`, `elapsed`, and `sleep` read the one monotonic clock the Session's scheduler owns, so a program's instants, its sleeps, and every `task.await-for` deadline agree on the current time. `unix` reads the process realtime clock, which is always available to CLI programs.

Every quantity is a whole number of milliseconds. A monotonic instant is the one-key dictionary `{monotonic ms}` counting from Session construction; a wall timestamp is `{unix ms}` counting from 1970-01-01T00:00:00Z. The tag is the clock domain: an instant handed to a `time` word, or a timestamp handed to `elapsed`, is `` `type ``. Monotonic instants are not portable across Sessions and carry no date; wall time may jump and is not suitable for scheduling.

### elapsed
`( instant -- milliseconds )` — Monotonic milliseconds from an instant produced by `now` to the present. Anything but `{monotonic int}` is `` `type ``.

### now
`( -- instant )` — Read the monotonic clock as `{monotonic ms}`. Successive reads never decrease. The first read of a fresh Session is close to `{monotonic 0}`.

### sleep
`( milliseconds -- )` — Park the calling unit until the monotonic clock has advanced by a nonnegative int duration, then continue with nothing pushed. The unit holds no worker while parked; runnable work proceeds on a one-worker pool. The deadline is captured once, before any timer state is created, and a duration of `0` is already expired at that point: the unit yields to the scheduler and resumes on its next turn without starting the timer thread. Cancellation before or after registration wakes the unit with `` `cancelled `` and retires its timer entry. A negative duration is `` `domain ``, a non-int is `` `type ``, and a duration whose deadline lies beyond any instant the clock can report is `` `overflow ``; all three fail before anything is registered.

#### Examples

```ecl
clock.now `start set 250 clock.sleep start clock.elapsed 250 >=
# => 1
```

### unix
`( -- timestamp )` — Read the process realtime clock as `{unix ms}`. Convert with the `time` module. Wall time can jump and must not be used for scheduling deadlines.

## csv

RFC 4180 comma-separated values. `parse` splits text into rows of string fields and `emit` renders rows back; neither converts a field. Convert a column with `dict.evolve` over parsed rows.

### parse
`( input -- rows )` — Split RFC 4180 comma-separated content into rows of string fields. Input is a string or a list of UTF-8 bytes. Accept CRLF or LF records, quoted commas and newlines, doubled-quote escapes, and a final record with no terminator. Preserve blank records and empty fields.

#### Examples

```ecl
"1,a\n2,\"b,c\"" csv.parse
# => (("1" "a") ("2" "b,c"))

"id,name\n1,Ada\n2,Bob" csv.parse table.from-header-rows {"id" ((int) each)} dict.evolve
# => {"id" [1 2] "name" ("Ada" "Bob")}
```

### emit
`( rows -- text )` — Render rows of string fields as canonical, CRLF-terminated RFC 4180 text, quoting any fields with commas, quotes, carriage returns, or newlines.

#### Examples

```ecl
(("a,b" "c") ("say \"hi\"" "")) csv.emit
# => "\"a,b\",c\u{d}\n\"say \"\"hi\"\"\",\u{d}\n"
```

## dict

Operations on the primitive dict type.

### associate
`( key value -- dict )` — Build a one-entry dictionary associating `key` with `value`.

#### Examples

```ecl
`args ["inspect" "alpha"] dict.associate
# => {args ["inspect" "alpha"]}
```

### at
`( dict keys -- values )` — Return a list indexing into `dict` for each element of `keys`.

### at-or
`( dict keys default -- values )` — Return a list indexing into `dict` for each element of `keys`, replacing any missing keys with `default`.

### del
`( dict keys -- dict )` — Return a dictionary containing the entries in `dict`, less those corresponding to `keys`.

### from-keys
`( keys value -- dict )` — Construct a dictionary mapping each element of `keys` to `value`.

### from-kvs
`( kvs -- dict )` — Build a dictionary from a list of key-values arranged like `[k v k v ...]`.

### from-pairs
`( pairs -- dict )` — Construct a dictionary from a list of `[key value]` pairs.

### get
`( dict key default -- value )` — Return the value in `dict` at `key`, or `default` if `key` isn't present.

### has?
`( dict keys -- bools )` — Test each element of `keys` for membership in `dict`.

### keys
`( dict -- keys )` — Return a list of the keys in `dict`.

### keys-exactly?
`( candidate declared -- bool )` — Return 1 when a dictionary has exactly the declared keys in any order, 0 otherwise.

### merge
`( left right -- dict )` — Merge `left` and `right`. For any key present in both `left` and `right`, `dict` will contain the value in `right`.

#### Examples

```ecl
{a 1 b 2} {b 20 c 30} dict.merge
# => {a 1 b 20 c 30}
```

### merge-with
`( left right (q: key left-value right-value -- value) -- dict )` — Merge `left` and `right`, resolving key collisions with `q`.

### of
`( keys dict -- values )` — Return a list indexing into `dict` for each element of `keys`.

### pairs
`( dict -- pairs )` — Return the entries of `dict` as a list of `[key value]` pairs, in `dict.keys` order.

### put
`( dict key value -- dict )` — Assign `key` to `value` in `dict`.

### reject
`( dict (p: key value -- bool) -- dict )` — Apply `p` to every entry of `dict` and discard the entries for which it returns 1.

### size
`( dict -- count )` — Return the number of keys in `dict`.

### split
`( dict keys -- selected rejected )` — Partition `dict` by `keys`, returning dictionary with every selected key followed by the remainder dictionary.

#### Examples

```ecl
{a 1 b 2} [b] dict.split pair
# => ({b 2} {a 1})
```

### take
`( dict keys -- dict )` — Return a dictionary containing only the entries in `dict` corresponding to `keys`.

### update
`( dict keys (q: value -- value) -- updated )` — Return `dict` where `q` has been applied to the values corresponding to each key in `keys`.

### update-or
`( dict key default quotation -- dict )` — If `key` is in `dict`, apply `quotation` to its value. Otherwise, map `key` to `default`.

### vals
`( dict -- values )` — Return a list of the `values` in `dict`.

### zip
`( keys values -- dict )` — Build a dictionary from key and value lists of equal length.

#### Examples

```ecl
[a b] [1 2] dict.zip
# => {a 1 b 2}
```

### evolve
`( dict spec -- dict )` — Apply each `( value -- value )` quotation in `spec` to the value under the same key in `dict`. A key of `spec` missing from `dict` is `` `domain ``.

### filter
`( dict (p: key value -- bool) -- dict )` — Apply `p` to every entry of `dict` and retain the entries for which it returns 1.

### in?
`( keys dict -- bools )` — Test each element of `keys` for membership in `dict`.

### map
`( dict (q: key value -- value) -- dict )` — Construct a dict from `dict`, applying `q` to each `key value` entry and assigning the result to `key`.

#### Examples

```ecl
{a 1 b 2} (swap pop 10 *) dict.map
# => {a 10 b 20}
```

## error

Words for manipulating the conventional `error` dict.

### new
`( kind -- error )` — Build the error dictionary `{kind kind}` from a kind symbol.

### valid?
`( value -- bool )` — Return 1 when a value satisfies the error dictionary schema `raise` enforces: a required symbol `` `kind `` and well-typed optional `` `msg ``, `` `word ``, `` `trace ``, and `` `data `` fields. Extra fields are allowed.

### kind-in?
`( error kinds -- bool )` — Return 1 when `error`'s kind occurs in `kinds`.

### kind?
`( error kind -- bool )` — Return 1 when `error` has the given kind symbol.

### with-data
`( error data -- error )` — Validate both dictionaries and return the error with `` `data `` set to `data`.

### with-message
`( error message -- error )` — Set the `` ` ``message field on `error` to `message`.

#### Examples

```ecl
`io error.new "unavailable" error.with-message
# => {kind io msg "unavailable"}
```

## fs

Filesystem words accept a named `root` symbol or a directory resource and a `path` string. The command line uses `` `cwd `` for the startup working directory. Applications may explicitly open other host directories. All filesystem operations are available on each root, subject to operating-system permissions and runtime limits.

A path is a UTF-8 slash path in the canonical grammar: `.` denotes the root itself, and every other path is one or more nonempty components separated by exactly one `/`, with no `.`, `..`, or NUL component and no leading, trailing, or repeated separator. Backslash is an ordinary filename character. Paths are never normalized here; normalize with `path.normalize` and accept the result with `path.valid-relative?` first. Words that act on a child entry (`create-*`, `replace-*`, `mkdir`, `rename`, `remove-file`, `remove-dir`) reject `.`.

Resolution is descriptor-relative beneath the root's retained handle. An intermediate symlink is followed only while its target stays within the root; an absolute target, a relative target that would pop above the root, more than 40 followed links, or more than 64 KiB of expanded resolver input is refused. `child-dir`, `open-list`, `open-reader`, `read-bytes`, `read-text`, `stat`, `list`, and the source side of `copy` follow a final link under the same rule; every other word acts on the final entry itself. Containment is never a lexical prefix check.

Path-taking failures carry a data dictionary with `` `operation `` (the word's own symbol), `` `root `` and `` `path `` (or `` `source-root ``, `` `source-path ``, `` `destination-root ``, and `` `destination-path `` for `copy`), and a closed `` `reason `` symbol: `` `invalid-path ``, `` `unknown-root ``, `` `not-found ``, `` `already-exists ``, `` `not-directory ``, `` `is-directory ``, `` `not-regular ``, `` `not-empty ``, `` `symlink-loop ``, `` `symlink-escape ``, `` `invalid-utf8 ``, `` `limit ``, `` `access-denied ``, `` `read-only ``, `` `no-space ``, `` `busy ``, `` `cross-device ``, `` `unsupported ``, `` `changed ``, or `` `io ``. The kind is `` `type `` for wrong value kinds or byte-list members outside `0..255`, `` `domain `` for malformed paths and unknown roots, `` `overflow `` for a configured limit, `` `cancelled `` for cancellation, and `` `io `` for filesystem state and host failures. Host error names never appear as data.

Reads, writes, and copies are bounded by the transfer limit (1 GiB by default) and advance in 64 KiB quanta; listings are bounded by an entry count (100,000) and aggregate name bytes (64 MiB). A Session runs at most 64 path operations at once; further ones wait, cancellably, in arrival order. Operations on an open writer, cursor, or stage, and a lock's contention, hold no such slot. Mutation stages complete contents in a private sibling entry and publishes with one atomic namespace operation, so failure or cancellation before the commit leaves the destination unchanged. Staged contents are flushed to the device before publication, so a crash after the commit cannot leave an empty file under the final name; directory entry durability, ownership, timestamps, and extended attributes are not promised. Created files use the host's ordinary creation mode under the process umask, a replaced file keeps its permission bits, and a copy carries the source's permission bits under the umask.

### child-dir
`( root path -- directory )` — Acquire an independent directory resource beneath an existing root. Resolution, including final symlinks, is confined to that root. The acquired directory becomes the new containment boundary; closing its ordinary parent resource does not close it. Children of a staging resource, including further descendants, close when staging is sealed or closed even after task ownership transfer. `.` acquires the root itself.

### commit-dir
`( stage -- )` — Seal the stage, reject further operations, close its descendant resources, and wait for admitted operations before atomically publishing to the absent destination. Any existing entry causes an `` `io `` failure and is preserved; failure retains the sealed staging resource for joined cleanup with `port.close`. Success joins descriptor closure and keeps the published tree even if the task is subsequently cancelled. Namespace publication is atomic; directory-entry durability across a host crash is not promised.

### commit-file
`( writer -- )` — Stop admission, flush the completed stream, and atomically publish its previously absent destination. Publication is serialized against cancellation. Success joins writer cleanup; failure retains unpublished private state for explicit or scope cleanup. No allocation is required after the publication permit is granted.

### copy
`( source-root source-path destination-root destination-path -- )` — Copy a regular file, following a final source link within its root, into an absent destination entry; the roots may differ. The copy is staged and published atomically without replacing; an existing destination of any kind fails with `` `io `` and reason `` `already-exists ``, a non-regular source fails with `` `io `` and reason `` `not-regular `` or `` `is-directory ``, and the copy keeps the source file's permissions.

### create-bytes
`( root path bytes -- )` — Atomically create an absent regular file holding exact bytes. Members are validated before any external state exists. An existing regular file, directory, symlink (including a dangling one), or other entry fails with `` `io `` and reason `` `already-exists ``; a missing parent fails with `` `io `` and reason `` `not-found ``.

### create-text
`( root path string -- )` — Atomically create an absent regular file holding the string as UTF-8, with the same collision contract as `create-bytes`.

### exists?
`( root path -- bool )` — Return 1 when the final entry exists and 0 when it is definitely absent, without following a final link: a dangling link is 1. Malformed paths, unknown roots, denial, traversal failures such as a missing or escaping intermediate component, and host failures are errors rather than 0.

### list
`( root path -- entries )` — Follow the path to a directory and return its children as `{name string kind file}`, `{name string kind directory}`, `{name string kind symlink}`, or `{name string kind other}`, classified without following, excluding `.` and `..`, and sorted by Unicode scalar order of `` `name ``. A child name that is not valid UTF-8, an entry that vanishes or cannot be classified, or an exceeded listing limit fails the whole listing; nothing is silently omitted.

### lock
`( root path -- lock )` — Acquire an exclusive advisory lock on a regular file, creating an empty file if the path is absent. Existing contents are preserved; final symlinks and non-regular files are rejected. Contention parks the task between attempts and is cancellable. The returned port owns the lock until `port.close` or its owning scope exits. A lock is not a directory resource. The lock file remains after release. Coordinating applications must keep its directory entry in place: replacing or deleting it establishes a different lock identity. Advisory locking coordinates participating applications and does not prevent other filesystem access.

### lstat
`( root path -- metadata )` — Describe the final entry without following it: `{kind file size n}` for a regular file, `{kind directory}`, `{kind symlink}`, or `{kind other}`. An absent entry fails with `` `io `` and reason `` `not-found ``.

### mkdir
`( root path -- )` — Create exactly one absent directory beneath an existing parent. There is no recursive parent creation; an existing entry of any kind fails with `` `io `` and reason `` `already-exists ``.

### mkdirs
`( root path -- )` — Create missing intermediate and final directories. Existing directories are preserved, including contained symlink targets. `.` is a no-op. Every component uses the ordinary confined resolver. Failure or cancellation may leave directories created before that point.

### next-entry
`( cursor -- entry )` — Return the next `{name string kind symbol}` dictionary, or `{}` at stable end. Kinds are `` `file ``, `` `directory ``, `` `symlink ``, and `` `other ``; dot entries are omitted and symlinks are described without following them. Names must be UTF-8. Order and visibility of concurrent namespace changes follow the host filesystem; this is not a directory snapshot. Concurrent calls reserve distinct entries, though their results may complete out of order. Each result owns its name independently of subsequent calls or cursor closure. A closed cursor raises `` `io ``. Reading does not materialize the whole directory or apply the aggregate limits of `list`; callers can stop and close at any entry.

### open-dir
`( host-path -- directory )` — Open an absolute host directory path, subject to OS permissions, and return a scope-owned port resource. Host symlinks may be followed while opening this explicit root. Relative paths are rejected. `port.close` closes the resource and joins cleanup; scope exit does the same. A closing directory rejects new operations with `` `io ``. Closure waits for admitted operations to release their independent descriptor leases, then joins backend cleanup.

### open-list
`( root path -- cursor )` — Open a scope-owned incremental enumeration of a confined directory. The cursor is a port resource, distinct from a directory root. It owns its descriptor until `port.close` or scope exit. An enumeration opened through staging or its descendants also closes when staging seals.

### open-reader
`( root path -- stream )` — Open a regular file, following a final link within the root, as a readable byte endpoint for `stream.read`, `stream.read-line`, `stream.read-all` and the `io` readers, with no size limit: the stream is read a chunk at a time. The calling scope owns the file; `port.close` closes it earlier and joins cleanup, and a read after either is `` `io ``. A directory is `` `is-directory ``; a non-regular object is `` `not-regular ``.

### open-writer
`( root path -- writer )` — Open private storage for an absent regular file. The parent must exist and `.` is rejected. A writer is distinct from a directory. It retains root lifetime until joined cleanup. Staging dependencies survive task transfer. Closing an uncommitted writer removes its private contents and publishes no destination.

### publish-bytes
`( root path bytes -- )` — Atomically publish complete file contents, creating an absent destination or replacing one that exists. An entry observed before staging must be a regular file; a symlink, directory, or other entry is `` `not-regular ``. Use the observed file's permissions, or host defaults on first creation. Publication replaces the final directory entry without following it; concurrent publications each succeed and the last commit wins. An intervening directory causes failure. A failed operation preserves its destination, and cancellation before commit removes staging. Cancellation after commit does not roll back publication. Visibility is atomic; directory-entry durability across a crash is not promised.

### publish-text
`( root path string -- )` — Publish UTF-8 text under the `publish-bytes` contract.

### read-bytes
`( root path -- bytes )` — Read one regular file, following a final link within the root, and return its exact bytes as an integer list. The size observed at open is the size read; growth or shrink meanwhile fails with `` `io `` and reason `` `changed ``. A directory fails with `` `io `` and reason `` `is-directory ``; a non-regular object fails with `` `io `` and reason `` `not-regular ``; a file over the transfer limit is `` `overflow ``.

### read-text
`( root path -- string )` — Read one regular file as `read-bytes` does and decode it as UTF-8. Invalid UTF-8 is `` `io `` with reason `` `invalid-utf8 ``.

### remove-dir
`( root path -- )` — Remove one empty directory without following a final link. A nonempty directory fails with `` `io `` and reason `` `not-empty ``; a file or symlink fails with `` `io `` and reason `` `not-directory ``.

### remove-file
`( root path -- )` — Remove one non-directory entry, including a symlink itself, without following it. A directory fails with `` `io `` and reason `` `is-directory ``.

### remove-tree
`( root path -- )` — Recursively remove a directory and its contents. The final entry must be a directory, and `.` is rejected. Symlinks inside the tree are removed without following their targets. Work is incremental and cancellable; failure may leave partially removed contents with temporary entry names. Removal uses bounded descriptor storage and needs no new allocations once the selected directory has been opened.

### rename
`( root source-path destination-path -- )` — Rename an entry within one root without replacing. The source may be a regular file, symlink, or directory and is not followed; an existing destination fails with `` `io `` and reason `` `already-exists ``, and a destination on another device fails with `` `io `` and reason `` `cross-device `` rather than an emulated copy.

### replace-bytes
`( root path bytes -- )` — Atomically replace an existing regular file with exact bytes. The final entry must be observed as a regular file without following: absence fails with `` `io `` and reason `` `not-found ``, and a symlink, directory, or other entry fails with `` `io `` and reason `` `not-regular ``. The replacement is a new inode published by an atomic exchange; the word never becomes create-or-replace.

### replace-text
`( root path string -- )` — Replace an existing regular file with UTF-8 text under the `replace-bytes` contract.

### stage-dir
`( root destination -- stage )` — Create a private sibling of the destination and return a scope-owned directory resource. The destination parent must exist. Filesystem operations accept the stage as a root. `port.close` or scope exit joins descendant closure and recursive rollback; no destination is published. The staging directory uses mode `0700` under the process umask.

### stat
`( root path -- metadata )` — Follow the path, including a final link within the root, and describe the object reached with the same shapes as `lstat`. A dangling link fails with `` `io `` and reason `` `not-found ``.

### write-chunk
`( writer bytes -- )` — Append at most 65536 integer bytes. The streaming transfer limit (1 GiB by default) covers the complete stream, including previous chunks. A failed or cancelled append after writer admission prevents later publication of partial contents; a validation failure before admission does not.

## gzip

Hostile-input-safe gzip decompression. Binary payloads are ordinary lists of integers in `0...255`.

### decompress
`( bytes -- bytes )` — Decompress one gzip member and return its payload. The payload is limited to 1,073,741,824 bytes. Malformed gzip data, trailing input, a size or checksum that disagrees with the footer, an over-limit payload, and invalid byte items are `` `domain ``; a non-list input is `` `type ``.

#### Examples

```ecl
[31 139 8 0 0 0 0 0 0 255 75 76 74 6 0 194 65 36 53 3 0 0 0] gzip.decompress
# => [97 98 99]
```

### decompress-within
`( bytes maximum -- bytes )` — Like `decompress`, with the payload limited to `maximum` bytes (itself at most 1,073,741,824) instead. The footer's declared size is checked against `maximum` before any output is allocated, so a small archive cannot cost more than `maximum`. A negative or over-limit `maximum` is `` `domain ``; a non-int `maximum` is `` `type ``.

## hash

Exact content digests. Binary payloads are ordinary lists of integers in `0...255`.

### sha256
`( bytes -- lowercase-hex )` — Return the SHA-256 digest of an integer byte list. Every item must be an integer in `0..255`; strings are not byte vectors and are not coerced.

#### Examples

```ecl
[1 2 3 4] hash.sha256
# => "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a"
```

## host

Read-only metadata about the host process: its startup directory and the path of the running executable.

### cwd
`( -- path )` — Return the absolute startup directory captured by the Session host.

### executable
`( -- path )` — Return the absolute path to the currently executing ecl binary.

## http

Requests yield while awaiting network I/O, including under cooperative scheduling and with one worker. Each invocation has one total 30-second monotonic deadline, including preparation, redirects, transfer, and response construction. Expiry is `` `timeout ``; task cancellation remains `` `cancelled ``. Neither returns a partial response.

Internal Session configuration defaults to 16 live requests, a 16 KiB target, 16 MiB outbound body, 64 MiB encoded and 64 MiB decoded inbound bodies, and 64 KiB / 256 occurrences of supplied request headers and received response headers. Header byte counts include field-line framing; received whitespace counts before normalization and repeated fields count before deduplication. Redirect responses share cumulative inbound budgets; body limits also apply to chunked and compressed transfers. The response transport holds at most 64 KiB and backend scratch at most 16 MiB per request. Admission remains reserved until response construction and cleanup finish. Exceeding a limit is `` `overflow `` with the target URL in error data; allocation failure remains `OutOfMemory`. Configuration is internal: there are no new request fields or CLI options.

### send
`( request -- response )` — Send a complete `http.request` value: string `` `method `` and `` `target `` URL fields are required. Optional fields:

-- `` `headers `` are sent once per value in list order -- `` `body `` is sent exactly for POST, PUT, or PATCH. -- `` `follow-redirects `` (default 1), when 1, will follow the `Location` of a 3xx response up to three times; otherwise the 3xx is returned. Request `headers` are sent only to the origin the request names: a redirect to another scheme, host, or port drops them, and a redirect from HTTPS to HTTP fails.

Return `{status int, headers dict, body bytes}`

## http.request

Words over partial or complete request dictionaries. Recognized optional fields are `` `method ``, `` `target ``, `` `path ``, `` `query ``, `` `headers ``, `` `body ``, `` `peer ``, `` `params ``, and `` `follow-redirects ``. `http.server` handlers receive every field except `` `params ``, which `http.server.route` may add, and `` `follow-redirects ``, which only `http.send` reads. The words here build an outbound request, read absent headers/query/body using empty defaults, and return updated copies; the original is never changed. A word given a malformed request dictionary, or a name that is not a string, is `` `type ``.

### new
`( method target -- request )` — Return an outbound request with the method, the target URL, `{}` headers, and `[]` body, ready for `http.send`. The `` `path ``, `` `query ``, and `` `peer `` fields describe a received request, so only `http.server` sets them. A non-string method or target is `` `type ``.

### query
`( request -- params )` — Parse the request's `` `query `` string, such as `"a=1&b=%2Fx&c"`, into a dictionary from string keys to string values, such as `{"a" "1" "b" "/x" "c" ""}`: `&`-separated pairs, each split at its first `=`, a pair without `=` mapping its key to `""`, empty pieces ignored, and a later duplicate key replacing an earlier one. `%XX` escapes are decoded in keys and values and the decoded text must be valid UTF-8; `+` is left as it is. An empty query is `{}`. A `%` not followed by two hexadecimal digits, or a decoded key or value that is not valid UTF-8, is `` `domain ``; a non-request is `` `type ``.

#### Examples

```ecl
{query "a=1&b=%2Fx&c"} http.request.query
# => {"a" "1" "b" "/x" "c" ""}
```

### valid?
`( value -- bool )` — Return 1 for a partial or complete request dictionary containing only recognized fields: string `` `method ``, `` `target ``, `` `path ``, `` `query ``, and `` `peer ``; a `` `headers `` dictionary from ASCII-lowercased string names to lists of strings; a byte-list `` `body ``; a `` `params `` dictionary from string names to string values; and a 0 or 1 `` `follow-redirects ``. Every field is optional. Never raises.

### header
`( request name -- values )` — Return the list of values of a header, matching the name regardless of letter case, or `()` when it is absent. A non-request or non-string name is `` `type ``.

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

Words over the response dictionary `{status headers body}`: the value `http.send` returns and the value an `http.server` handler leaves. They build a response, read its headers by name regardless of letter case, classify its status, and return updated copies. `valid?` accepts every well-shaped value; the wire rules a server enforces (no 1xx, reserved header names, no CR or LF) belong to `http.server.render-response`. A word given a value that is not a response dictionary, a status outside `100...599`, or a name that is not a string is `` `type ``.

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
`( response name -- values )` — Return every value of a header as a list, matching the name regardless of letter case; a string value counts as one. `()` when the header is absent. A non-response or non-string name is `` `type ``.

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

HTTP/1.1 serving over `net` connections, defined in ECL. The module holds no authority of its own: `@serve` takes a listener the program already obtained through `net.listen`, so a Session that cannot bind cannot serve, and every socket operation is one of the `net` words. The parsers, the response renderer, and `route` take and return ordinary values and never touch a connection, so they can be used and tested without a socket. Requests and responses are the dictionaries `http.request` and `http.response` build and read.

A request is the dictionary `{method target path query headers body peer}`:

- `` `method `` and `` `target `` are the first two tokens of the request line, as strings;
- `` `path `` and `` `query `` are the target split at the first `?`, undecoded; `` `query `` is `""` when the target has no `?`;
- `` `headers `` is a dictionary from ASCII-lowercased header name to the list of its trimmed values in arrival order, so a repeated header keeps every value;
- `` `body `` is the exact byte list `Content-Length` specifies, `[]` when the request has none; and
- `` `peer `` is the peer's `address:port` formatted from `net.peer-address`, with an IPv6 address in brackets.

A response is the dictionary `{status headers body}` with exactly those keys: an integer status in `200...599`, since interim 1xx responses are not served, with an empty body when the status is 204, 205, or 304; a headers dictionary whose keys are strings and whose values are a string or a list of strings, written once per value in the given order and with the name as given; and a body that is a string, written as UTF-8, or a byte list. The names `content-length`, `connection`, and `transfer-encoding` are reserved in any letter case: the server writes `Content-Length` and `Connection: close` itself, and a response carrying one of them is `` `domain ``. Header names must be nonempty HTTP tokens and values may not contain CR, LF, NUL, or a control character other than tab, so a value built from request data cannot split the response.

Framing is HTTP/1.1 with `Content-Length` bodies only; an HTTP/1.0 request is answered the same way, and only HTTP/1.1 requests must carry one `Host` header. A HEAD request is answered with the handler's status and headers and no body. Any `Transfer-Encoding` header is answered 411 and a version other than `HTTP/1.1` or `HTTP/1.0` is answered 505. There is no keep-alive: every response carries `Connection: close`, and the connection is closed once the response is written. TLS, chunked bodies, pipelining, and upgrades belong to a proxy in front of the server.

The `@serve` configuration is a dictionary whose keys are all optional; `{}` is valid. Each limit is an integer greater than zero.

- `` `max-header-bytes `` (default `32768`): the most bytes accepted before the CRLFCRLF that ends the head; more is 431.
- `` `max-body-bytes `` (default `1048576`): the largest `Content-Length` accepted; a larger one is 413 before any body byte is read.
- `` `max-in-flight `` (default `128`): the number of acceptor children, each handling one connection at a time.
- `` `read-timeout-ms `` (default `10000`): the deadline for reading one whole request, head and body; expiry is 408.
- `` `on-failure `` (default `(str io.eprint)`): a quotation `( error -- )` applied to the error dictionary of every request the server answers 500; a failure of the quotation itself is discarded.

The server answers a request it cannot serve with a minimal `text/plain` response of the status below and then closes the connection:

- 400: a malformed request line; a header line without `:` or beginning with space or tab (obsolete folding); an HTTP/1.1 request without exactly one `Host` header of the form `uri-host [":" port]`; non-UTF-8 bytes in the head; a `Content-Length` that is not a digit string or whose repeated values differ; end of stream after some bytes arrived but before the head or the body is complete.
- 408: `` `read-timeout-ms `` elapses while the request is being read.
- 411: any `Transfer-Encoding` header.
- 413: `Content-Length` exceeds `` `max-body-bytes ``.
- 431: `` `max-header-bytes `` is exceeded before the head ends.
- 500: the handler fails, leaves other than exactly one value, or leaves a response `render-response` rejects.
- 505: a version other than `HTTP/1.1` or `HTTP/1.0`.

A peer that connects and closes without sending a byte, or that resets or otherwise fails during the read or the write, is closed silently: nothing is written and `` `on-failure `` is not applied.

The handler is a quotation with the contract `( request -- response )`. Each request applies it as `[request] handler @attempt` in a fresh unit, so a handler's failure is data to the server and the ambient stack never crosses the boundary. A successful handler leaves exactly one value, and that value must satisfy `render-response`. Any other outcome — a raised error, an empty or multi-valued result, a malformed response — answers 500 and applies the `` `on-failure `` quotation to the error dictionary (for a wrong result count, a `` `contract `` error reporting the observed count); the serving unit and every other in-flight request are unaffected. Every response the server writes, whether the handler's or its own, is validated in full before any byte is written.

`@serve` serves up to `` `max-in-flight `` connections at a time, each in a child unit that owns its connection, so a connection is closed on every path. Beyond that bound, and at the host's live-connection maximum, further connections wait in the kernel backlog.

`@serve` does not return. The serving unit ends only when it is cancelled, failing `` `cancelled ``, or when an acceptor's `net.accept` fails, in which case that error is raised from `@serve`. Abortive listener closure cancels an admitted accept; graceful shutdown may instead report backend closure as `` `io ``. Admission after closure raises `` `io ``. Either ending cancels and quiesces every acceptor, reader, and handler child by the ordinary scope rules and closes every connection those children own. The listener itself is untouched: `@serve` never calls `port.shutdown` on the listener it was given, which stays the caller's to close explicitly or through its own scope and may be served again.

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
`( headers -- length )` — Return the request body length specified by a headers dictionary as `parse-headers` builds it: `0` when `content-length` is absent, otherwise the integer every occurrence spells, leading zeros allowed, so `{"content-length" ("5")}` is 5. A value that is not a nonempty string of decimal digits, or repeated values that differ, is `` `domain `` with `` `data {status 400} ``; a value too large for a 64-bit integer exceeds every body limit and is `` `domain `` with `` `data {status 413} ``. A non-dictionary is `` `type ``.

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
`( request routes -- response )` — Dispatch a request over a list of `[method pattern handler]` rows. The method is a string compared exactly against the request's `` `method ``. A pattern is a slash path such as `"/users/:id"` whose segments must equal the request's `` `path `` segments one for one, except that a segment beginning with `:` binds any nonempty path segment under its name in a string dictionary. The first row whose pattern and method both match has the request, with `` `params `` set to that dictionary, passed to its handler, which is applied inline with the contract `( request -- response )`. Middleware is composition: wrap the handler quotation with `cat`.

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
`( listener config (handler: request -- response) -- )` — *Unit constructor*, the handler's effect enforced per request. Serve HTTP/1.1 requests from a `net` listener until the unit ends: accept in a loop and give each connection to a child unit that owns it. The child frames one request under the read deadline, applies the handler as `[request] handler @attempt` in a fresh unit, writes its single response with `Content-Length` and `Connection: close`, and closes the connection.

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

Text over byte streams. Every word here that touches a stream encodes or decodes UTF-8 at that boundary, through `bytes` and `chars`; the console conveniences are the same words applied to `stream.out` and `stream.err`.

### debug
`( value label -- value )` — Print `label`, `": "`, and the value's pretty-printed representation plus newline, leaving the value on the stack.

### eprint
`( string -- )` — Write a string followed by a newline to standard error.

### inspect
`( value -- value )` — Pretty-print a value while leaving it on the stack.

### pp
`( value -- )` — Print any value plus newline as a diagnostic display: strings and lists longer than 256 elements print as an elision marker with their length, and matrices print one row per line.

### prin
`( string -- )` — Write a string to standard output without adding a newline.

### print
`( string -- )` — Write a string followed by a newline to standard output.

### read
`( stream -- string )` — Read a byte endpoint to EOF and decode it as UTF-8.

### read-line
`( stream -- string )` — Read one line of UTF-8 text through its newline, newline included.

### stack
`( -- )` — Print each value in the currently visible operand window as a bottom-up indexed display block.

### write
`( stream chardata -- )` — Encode string or list of strings `chardata` as UTF-8 and write it to a byte endpoint.

### lines
`( stream -- strings )` — Read a byte endpoint to EOF and split the decoded text at every newline.

### stdin
`( -- string )` — Read all of stdin as text.

### write-line
`( stream string -- )` — Encode `string` as UTF-8 and write it followed by a newline.

## json

RFC 8259 JSON. `parse` reads JSON text into ECL values and `emit` renders a value as JSON text.

### emit
`( value -- text )` — Render an ECL value as RFC 8259 JSON. Dict keys must be strings or symbols; the only emitted symbol values are `` `null ``, `` `true ``, and `` `false ``.

### parse
`( text -- value )` — Parse RFC 8259 JSON. Objects become string-keyed dicts, arrays become lists, in-range integral numbers become ints, and other numbers become floats. JSON null and booleans become the ordinary symbols `` `null ``, `` `true ``, and `` `false ``.

#### Examples

```ecl
"{\"a\":[1,null]}" json.parse
# => {"a" (1 null)}
```

## net

TCP listeners and connections. Any local IP literal and port can be requested, subject to operating-system restrictions and runtime resource limits. Port zero requests an ephemeral bind. Names are never resolved. IPv4-mapped IPv6 literals normalize to IPv4. Binding uses address reuse, so a closed connection's `TIME_WAIT` does not prevent rebinding; two live listeners cannot hold the same address and port.

An accept occupies its FIFO lane until completion or cancellation; address queries use an independent control lane.

Listeners and connections belong to task scopes. Retaining or sending a port shares use; `@give` transfers ownership. A newly accepted connection remains provisionally owned by its exchange until `port.result` publishes it into the receiving scope. Failed publication retains that provisional ownership, and closing an unclaimed exchange closes the connection. Accepted connections are independent of their listener, including after listener closure. Scope closure aborts its resources and joins socket cleanup even while identities remain retained elsewhere.

A listener takes a connection from the kernel backlog only for an active accept with connection capacity available. At capacity, accept parks until a connection closes. A waiting accept holds no connection slot. Admission itself is bounded by the resource's operation capacity; additional callers park. Competing accepts consume distinct connections and do not broadcast. A peer that aborts before acceptance is skipped. The runtime does not retry a failed operation or reopen a failed resource.

Byte endpoints preserve exact integer bytes in `0...255`; they perform no text decoding. Reads have a single-pending-reader rule. Writes execute FIFO and each call stays contiguous under bounded pressure. `port.finish` on `net.output` rejects new writers and sends EOF after admitted writers and queued bytes drain, while the input direction remains readable. Framing, TLS, encoding, and protocol limits belong to libraries. Deadlines compose tasks with `task.await-for`, cancellation, and joining.

### accept
`( listener -- connection )` — Wait for a peer and claim the accepted connection port into the calling task scope. Accepted connections remain usable after their listener closes. At host connection capacity, wait until a slot is free; competing accepts receive distinct connections. A non-listener is `` `type ``. Abortive listener closure cancels admitted accepts; graceful shutdown may instead report backend closure as `` `io ``. A new call after closure is `` `io ``. Socket or buffer exhaustion and host failures are `` `io ``. Cancelling an accept closes any connection still provisionally owned by that exchange, so none is lost before delivery. Completed exchanges retain their own result and cleanup lifetime independently of the listener.

### input
`( connection -- stream )` — The connection's receiving direction as a readable byte stream for `stream.read`, `stream.read-line`, `stream.read-all`, and the `io` readers. Each call borrows a new endpoint value over the same socket, and a line reader's read-ahead belongs to the value, so read lines through one value. The stream closes with the connection.

### listen
`( config -- listener )` — Bind a TCP listener with a configuration of exactly these two symbol-keyed fields; neither has a default:
- `` `address ``: an IPv4 or IPv6 literal string without IPv6 brackets, such as `"127.0.0.1"`, `"::1"`, `"0.0.0.0"`, or `"::"`.
- `` `port ``: an integer in `0...65535`, such as `8080`; `0` requests an ephemeral port.

Loopback addresses accept local connections; wildcard addresses `"0.0.0.0"` and `"::"` bind available interfaces of their address family, subject to operating-system restrictions. Hostnames are not resolved: do not use a hostname such as `"localhost"`, a URL, or an address with an embedded port. Backlog and buffer capacities are runtime limits, not configuration fields. Inspect the assigned port with `net.local-address` after a port-zero bind.

The returned listener port is already listening and belongs to the calling task scope. Use `net.accept` for connections. `port.shutdown` on a listener closes its socket and stops accepting; its admitted accepts end with `` `io `` or `` `cancelled ``. On a connection it delivers accepted writes to the kernel before closing the socket, which does not establish peer receipt. `port.close` is the abortive, idempotent alternative. A non-dictionary or wrongly typed field is `` `type ``; missing or unknown fields, invalid literals or ports, or exhausted listener capacity is `` `domain ``. Common structured-value limits also apply. Host bind and listen failures are `` `io ``. Configuration failures include the requested address, port, and reason where available; controller and lifecycle failures report the common error kind and message.

This module provides listeners and accepted TCP connections, with no outbound-connect word. TCP is a byte stream: a read can return less than requested or combine data from multiple peer writes. Supply framing in the application, and assemble complete UTF-8 sequences before calling `chars`. For a write-side half-close that keeps the connection readable, use `dup net.output port.finish`.

#### Examples

Bind an ephemeral port and read back the assigned address:

```ecl
{address "127.0.0.1" port 0} net.listen
dup net.local-address
swap port.shutdown
# Leaves {address "127.0.0.1" port n}, where n is the assigned port.
```

A one-connection greeting server, which blocks until a peer connects. The
first close drains and closes the connection; the second closes the listener.

```ecl
{address "127.0.0.1" port 8080} net.listen
dup net.accept
dup "hello\n" bytes net.write
port.shutdown
port.shutdown
```

### local-address
`( resource -- address )` — Return `{address string port int}` for an open listener or connection. IPv4 uses dotted-quad text; IPv6 uses RFC 5952 text without brackets. A listener bound to port 0 reports its assigned port; a connection accepted through a wildcard listener reports its actual local endpoint. A wrong resource kind is `` `type ``; closure or backend failure is `` `io ``.

### output
`( connection -- stream )` — The connection's sending direction as a writable byte stream for `stream.write` and `port.finish`. Finishing it sends EOF after admitted writes drain while the input direction stays readable. Each call borrows a new endpoint value over the same socket; the stream closes with the connection.

### peer-address
`( connection -- address )` — Return the remote endpoint of an open connection in the same `{address string port int}` shape and canonical text as `net.local-address`; a listener has no peer. A non-connection is `` `type ``; closure or backend failure is `` `io ``.

### read
`( connection max -- bytes )` — Read at most positive integer `max` bytes, also bounded by the host receive capacity. Park when no data is ready; short reads are normal and do not mark message boundaries. Return exact integer bytes in `0...255`, or `[]` only at stable EOF; later reads also return `[]`. A wrong capability or non-integer maximum is `` `type ``; a nonpositive maximum is `` `domain ``; an overlapping read is `` `contract ``. Buffered bytes precede a transport failure, which raises `` `io ``. Abortive closure may discard buffered bytes. No text decoding is performed; use `chars` only on complete UTF-8 sequences.

### write
`( connection bytes -- )` — Accept a complete list of integer bytes in `0...255` in FIFO order, parking under bounded pressure. Each call stays contiguous, but TCP does not preserve message boundaries. Convert strings explicitly with `bytes`. A non-list or a string is `` `type ``; an element outside `0...255` is `` `domain ``; finished output, closure, peer reset, or other transport failure is `` `io ``. Acceptance is distinct from delivery, output EOF, and resource cleanup, and does not establish peer receipt. To send EOF while retaining input, use `net.output port.finish`.

## path

Lexical operations over slash-separated path strings. Every argument and result is a string of Unicode scalar values; the separator is always `/`, and no word reads the filesystem, consults the working directory, follows links, or applies drive-letter, backslash, case-folding, or Unicode-normalization rules. Normalization is lexical: it never proves that a path stays within a directory, which is why `fs` accepts only the canonical grammar and enforces containment at its directory handles.

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

Factories, operation selectors, and endpoint selectors are opaque `` `port `` values exported through ordinary library bindings. Repeated lookup preserves identity. Selectors belong to their issuing module instance and resource kind; using another kind or the wrong capability variant raises `` `type ``. These borrowed capabilities are not transferable scope owners.

Exchanges are opaque `` `port `` values with their own task-scope ownership. An exchange survives the invocation that created it. Retaining or sending its value shares use; `@give` transfers its scope ownership. Exiting the owning scope aborts outstanding work and joins cancellation cleanup.

New child resources carried by a result or message remain provisionally owned until `port.result` or `port.receive` succeeds. A claim publishes all attached children into the receiving scope together; failed publication retains the source and its owners. Discarding an unclaimed result or queued message closes its provisional children, and exchange cleanup joins their retirement. Already published capabilities share use without moving scope ownership. Children declare whether they depend on their issuing parent. Parent closure closes and joins dependent children even after `@give`; independent children remain usable in their receiving scope. Closed children remain opaque identities.

For TCP resources, `port.shutdown` closes a listener or delivers a connection's accepted writes before closing its socket. Accepted connections remain independent of their listener. `port.close` may discard queued connection bytes. Both words join socket cleanup. For a process, `port.shutdown` requests process-group termination with the host's escalation policy; `port.close` requests immediate process-group kill. Both join process cleanup, including blocked pipe transport. A completed process wait exchange remains observable after resource closure; new wait operations require an open resource.

A cancelled exchange raises `` `cancelled `` from `port.await` and `port.result`. Observation does not consume the result. Operations that produce only stream output have `[]` as their result. Input finish, output EOF, completion, and cleanup are distinct events. An active cancellation releases its controller lane only after acknowledgement and return; a controller that cannot restore reusable state closes its resource.

Endpoints may belong to a resource or to one exchange. Resource endpoints retain their direction and buffered data across exchange completion; finishing a resource endpoint or closing its resource ends that direction. A message may carry a sender through which its recipient replies to a backend request. Such a sender retains only its permitted direction; request identifiers, notifications, and response ordering follow the issuing library's protocol. Endpoint capabilities preserve the source identity and cannot be transferred independently with `@give`. A selector from another issuing kind, or a read or write through the wrong direction, raises `` `type ``; an endpoint not permitted by its source raises `` `domain ``. Buffered output remains readable before a terminal failure is raised. Once observed, EOF remains stable through later exchange failure or resource cleanup. An early input consumer exit wakes blocked writers with `` `io ``. Streaming callers must drain independent outputs concurrently when necessary for progress; waiting for completion does not drain them.

`port.call` is an ECL composition. It closes the exchange before returning its result or re-raising its terminal error. It leaves the resource with its owner.

Configuration and initial requests may contain integers, floats, characters, symbols, lists, dictionaries, and port capabilities. Executable words, tasks, and modules are rejected recursively with `` `type ``. Each value is bounded by 64 KiB of scalar/text bytes, 4,096 nodes, and 16 capability occurrences; exceeding a bound raises `` `overflow `` before initialization or admission. Retaining an existing resource in a request shares use and does not transfer its scope.

Messages and terminal results use the same structured-value bounds. Default message capacity is 16 per endpoint and a shared 1 MiB byte budget per resource. A controller-held message retains its capacity reservation until forwarded, returned as a result, or discarded. This permits forwarding when the shared budget is full. Exceeding the resource's entire byte budget raises `` `overflow ``; temporary saturation parks the producer. Receiving is competing consumption, not broadcast. Event construction failure leaves the message queued. A receiving scope that has begun closing cannot consume a message or result; the claim fails with `` `cancelled `` without consuming the source. Abortive close discards queued messages and unclaimed results; a discarded successful result raises `` `io `` if claimed later. Completion observation remains repeatable. Existing capabilities in messages share use and retain their owner.

#### Operations

| Word | Effect | Contract |
|---|---|---|
| `port.open` | `( factory config -- resource )` | Initialize a resource and publish it into the calling scope. Failure joins cleanup through that scope. |
| `port.begin` | `( resource operation request -- exchange )` | Admit a registered operation on its declared FIFO lane, parking while admission capacity is full. |
| `port.call` | `( resource operation request -- value )` | Begin, claim the result, and close the exchange. Requires no additional streaming input or output. |
| `port.endpoint` | `( source selector -- endpoint )` | Borrow a direction-specific endpoint supported by its resource or permitted by its exchange's operation. Supports registered byte and message endpoints; a byte endpoint is a stream for the `stream` words. |
| `port.send` | `( sender message -- )` | Enqueue one complete structured message atomically, parking under pressure. Empty values are valid messages. |
| `port.receive` | `( receiver -- event )` | Return `{kind message value value}` or `{kind eof}`. Overlapping receivers raise `` `contract ``. |
| `port.finish` | `( endpoint -- )` | Finish a writable byte endpoint or message sender after accepted writes or sends drain, so its reader sees EOF or `{kind eof}`. Idempotent; later writes or sends raise `` `io ``. |
| `port.await` | `( exchange -- )` | Wait for successful completion or raise the terminal error. Repeatable; does not drain output. |
| `port.result` | `( exchange -- value )` | Wait and claim the terminal result once. A later successful-result claim raises `` `contract ``. |
| `port.cancel` | `( exchange -- )` | Request cancellation idempotently. Completion remains observable and waits for controller return. |
| `port.shutdown` | `( resource -- )` | Stop new admission, perform registered graceful shutdown, and join cleanup. Unsupported resources raise `` `domain ``. Repeated calls observe the same outcome. |
| `port.close` | `( resource-or-exchange -- )` | Abort and join cleanup. Idempotent for every resource and exchange. |

### await
`( exchange -- )` — Observe completion without consuming the result or draining output.

### begin
`( resource operation request -- exchange )` — Admit an operation with bounded structured parameters.

### call
`( resource operation request -- value )` — Begin an operation, claim its result, and close the exchange. Use only when no additional streaming input or output is required. Close the exchange before returning or re-raising its error.

### cancel
`( exchange -- )` — Request cancellation. Completion remains observable.

### close
`( resource-or-exchange -- )` — Abort and join cleanup. Idempotent.

### endpoint
`( source selector -- endpoint )` — Borrow an attenuated endpoint supported by its source.

### finish
`( endpoint -- )` — Finish a writable endpoint after admitted writes or sends drain: a byte reader sees EOF, a message receiver {kind eof}. Idempotent; later writes or sends raise `io.

### open
`( factory config -- resource )` — Initialize a registered resource in the calling scope.

### receive
`( receiver -- event )` — Receive {kind message value value} or {kind eof}; one receiver may wait.

### result
`( exchange -- value )` — Wait and claim a result once; a later claim raises `contract.

### send
`( sender message -- )` — Atomically enqueue one bounded structured message, including an empty value.

### shutdown
`( resource -- )` — Perform registered graceful shutdown and join cleanup. Unsupported resources raise `domain.

## proc

Subprocess ports with bounded live counts, queues, and capture sizes. Process creation is available as an ordinary standard-library operation. Executable access is determined by the operating system.

`proc.spawn` creates a process resource subject to the common structured-value and process limits. The resource supports the process words and the common `port` lifecycle words.

`proc.wait` has its own FIFO lane; `proc.terminate` and `proc.kill` share an independent control lane and do not wait for exit. Cancelling a wait leaves the process running. Process exit leaves the resource open for further operations; closing the resource prevents new operations and joins backend cleanup.

`proc.stdin`, `proc.stdout`, and `proc.stderr` borrow the process's byte streams. Stdin grants writing and finishing, so `stream.write` and `port.finish` apply; stdout and stderr grant reading, so `stream.read`, `stream.read-line`, `stream.read-all`, and the `io` readers apply. An endpoint is borrowed, so `port.close` on it is `` `type ``; close the resource instead. Their byte, EOF, and single-reader contracts are shared with the corresponding process words. Finishing stdin delivers accepted bytes before closing that direction, is idempotent, and rejects subsequent writes, including empty writes. Endpoints share permitted use without owning the resource; they cannot be transferred with `@give`.

A spawn specification is a dictionary whose keys are symbols, with only the fields `` `executable `` (required), `` `args ``, `` `cwd ``, and `` `env ``. The nested environment dictionary uses **string** keys.

Paths, arguments, and environment strings cannot contain NUL. Environment names must be nonempty and contain no `=`. The child inherits nothing from the interpreter's environment: `` `env `` is exactly what it sees, and omitting it starts the child with an empty environment. Forward a host variable explicitly with `getenv`, for example `{} "HOME" dup getenv put`. There is no shell-command form, expansion, or `PATH` search: spaces and shell metacharacters in an argument are passed literally. Unknown fields and missing `` `executable `` are `` `domain ``; non-symbol keys and wrongly typed fields are `` `type ``; invalid field values are `` `domain ``. Validation precedes process creation.

Prefer `proc.run` when the output fits a known bound. With `proc.spawn`, feed stdin and drain **both** output pipes concurrently when they can fill. A child may wait for stdin EOF before exiting, so finish it with `proc.stdin port.finish` when feeding is complete. `proc.wait` does not drain output: waiting first can deadlock on a full pipe. Reads may split text characters or application messages across chunks. Close the resource with `port.close` when finished; waiting for exit does not close it.

Bytes are ordinary integer lists whose elements are all in `0...255`. Process streams do not decode Unicode. A port is an opaque identity capability that prints `<port:N>` and has type `` `port ``; it exposes no PID and cannot be passed through JSON. Native words can view and forward its opaque identity.

#### Spawn specification

| Field | Value | Required / default |
| --- | --- | --- |
| `` `executable `` | Absolute executable path string; no `PATH` lookup | Required |
| `` `args `` | List of argument strings, excluding the executable name | `[]` |
| `` `cwd `` | Absolute directory path string without `.` or `..` components | Startup working directory |
| `` `env `` | String-to-string dictionary, for example `{"LANG" "C"}` | `{}`; the child's complete environment |

#### Examples

On a POSIX host with `/bin/cat`, capture a byte-exact round trip:

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

These examples require the executables and directory they use to exist, and the
host to permit the requested paths and capture bounds. Use `bytes` to encode
text for stdin and `chars` to decode complete UTF-8 output. Arbitrary process
output may not be valid UTF-8.

### kill
`( resource -- )` — Request force termination of the process group and arrange direct-child reap. Idempotent and safe after natural exit while the resource remains open. This does not wait for exit; use `proc.wait` to observe termination and `port.close` to join cleanup.

### spawn
`( spec -- resource )` — Start the directly specified, authorized executable with stdin, stdout, and stderr pipes. `spec` is a symbol-keyed dictionary:
- `` `executable ``, required: an absolute path string.
- `` `args ``: a list of argument strings, default `[]`; it excludes the executable name.
- `` `cwd ``: an absolute path string without `.` or `..` components, default the host-configured starting directory.
- `` `env ``: a string-to-string dictionary that is the child's complete environment, default `{}`. Nothing is inherited; forward host variables explicitly with `getenv`.

Strings must not contain NUL, and environment names must be nonempty and contain no `=`. There is no shell expansion or `PATH` search. Unknown fields, invalid values, or denied authority are `` `domain ``; wrong field types are `` `type ``; launch failures are `` `io ``.

The child and its process group, pipe tasks, and spawning task-scope membership commit before the port becomes visible. The calling task scope owns the live child: scope closure cancels the process group and waits for reap even if a port value remains stored elsewhere. Returning or storing the port does not detach it; `@give` is the one way to change owner, and the unit it is given to kills the group when it ends. Use `proc.run` for bounded capture, or drain both output streams concurrently.

### stderr
`( resource -- stream )` — The process's stderr as a readable byte endpoint, with `stdout`'s contract.

### stdin
`( resource -- stream )` — The process's stdin as a writable byte endpoint for `stream.write` and `port.finish`. Each call borrows a new endpoint value over the same pipe; the pipe closes with the process resource, so the value is `` `type `` to `port.close`.

### stdout
`( resource -- stream )` — The process's stdout as a readable byte endpoint for `stream.read`, `stream.read-line`, `stream.read-all`, and the `io` readers. Each call borrows a new endpoint value over the same pipe, and a line reader's read-ahead belongs to the value, so read lines through one value. Drain stderr concurrently when it can fill, or use `proc.run` to capture both streams.

### terminate
`( resource -- )` — Request ordinary termination of the process group without waiting for exit, escalating to force termination during cleanup when needed. Idempotent and safe after natural exit while the resource remains open. Use `proc.wait` to observe termination and `port.close` to join cleanup.

### wait
`( resource -- termination )` — Park until direct-child termination without draining stdout or stderr, and return the immutable terminal result:
- `{kind exited code n}`;
- `{kind signaled signal n}`;
- `{kind stopped signal n}`; or
- `{kind unknown status n}`.

Any number of waiters and later calls receive the same dictionary. A nonzero exit code is ordinary termination data, not an ECL error. A pipe failure raises `` `io ``. Output pipes can fill and prevent exit, so drain both concurrently or use `proc.run`. Waiting requires an open resource; after closure, observe a previously completed exchange instead of admitting another wait. This leaves the resource open; use `port.close` to join cleanup.

### read-stderr
`( resource max -- bytes )` — Read at most positive integer `max` bytes from stderr, parking when no data is ready. Return exact integer bytes in `0...255`; `[]` means stable EOF, and later reads also return `[]`. Reads may be shorter than `max`. A non-integer maximum is `` `type ``; a nonpositive maximum is `` `domain ``; at most one stderr read may be pending, so overlap is `` `contract ``; pipe failure is `` `io ``. Drain stdout concurrently when it can fill, or use `proc.run` to capture both streams.

### read-stdout
`( resource max -- bytes )` — Read at most positive integer `max` bytes from stdout, parking when no data is ready. Return exact integer bytes in `0...255`; `[]` means stable EOF, and later reads also return `[]`. Reads may be shorter than `max`. A non-integer maximum is `` `type ``; a nonpositive maximum is `` `domain ``; at most one stdout read may be pending, so overlap is `` `contract ``; pipe failure is `` `io ``. Use `chars` to decode UTF-8. Drain stderr concurrently when it can fill, or use `proc.run` to capture both streams.

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

Explicit-state pseudorandom draws are pure except for `entropy`; see [Randomness](SPEC.md#randomness). The state is `[key counter]`, and every draw returns the advanced state alongside its result. An ambient generator is an agent holding that state: ``[0 0] agent.start `rng set`` then `rng (5 rand.int) agent.call`.

### deal
`( state count pool -- state results )` — Draw `count` distinct ints in `[0, pool)` without replacement.

#### Examples

```ecl
[7 0] 3 10 rand.deal pair
# => ([7 3] [7 0 4])
```

### entropy
`( -- key )` — Read one int from the host CSPRNG.

### float
`( state -- state result )` — Draw one uniform float in `[0, 1)`.

### int
`( state bound -- state result )` — Draw one unbiased uniform int in `[0, bound)`.

#### Examples

```ecl
[0 0] 100 rand.int pair
# => ([0 1] 35)
```

### ints
`( state count bound -- state results )` — Draw `count` uniform ints in `[0, bound)`, advancing the state by `count`.

#### Examples

```ecl
[7 0] 4 6 rand.ints pair
# => ([7 4] [3 0 0 3])
```

### shuffle
`( state values -- state values )` — Return a uniformly selected permutation of `values`.

#### Examples

```ecl
[7 0] [10 20 30 40] rand.shuffle pair
# => ([7 4] [40 20 30 10])
```

## result

Operations on the conventional `result` dict.

### err
`( error -- result )` — Wrap `error` in an unsuccessful result dict.

### ok
`( values -- result )` — Wrap `values` in a successful result dict.

### either
`( result on-ok on-err -- ... )` — If `result` is successful, apply `on-ok` to its values. Otherwise, apply `on-err` to its error.

#### Examples

```ecl
{kind io} result.err (first) (`kind at) result.either
# => io
```

### err?
`( result -- bool )` — Return 1 when a result is unsuccessful.

### map
`( result quotation -- result )` — If `result` is successful, then apply `quotation` to its values in a new unit and return a new result. Otherwise return `result` unchanged.

#### Examples

```ecl
[2 3] result.ok (+) result.map
# => {ok [5]}
```

### map-err
`( result (q: error -- error) -- result )` — If `result` is successful, return it unchanged. Otherwise apply `q` to its error and return a new unsuccessful result.

### ok?
`( result -- bool )` — Return 1 when a result is successful.

### or-default
`( result default -- value )` — If `result` is successful, extract the success values; otherwise return `default`.

### or-raise
`( result -- values )` — If `result` is successful, extract the success values; otherwise raise its error.

### recover
`( result quotation -- result )` — If `result` is successful, return it unchanged. Otherwise apply `quotation` to its error and return a new result.

### all
`( results -- result )` — Return the leftmost unsuccessful element of `results`, or a successful result containing the success values of all of `results`.

### partition
`( results -- successes errors )` — Partition results into success lists and error dicts, both in input order, without re-raising.

### recover-kinds
`( result kinds quotation -- result )` — Recover an unsuccessful result only when its kind is in `kinds`. Return every other result unchanged.

#### Examples

```ecl
{kind io} result.err [io timeout] (pop 99 wrap) result.recover-kinds
# => {ok ([99])}
```

## source

Inert inspection of ECL source: what a source declares, found by the reader's discovery rule without evaluating it.

### declarations
`( quotation -- list )` — Inspect parsed source without executing it. Return the symbols immediately preceding top-level `@defm` words, in source order. Preserve duplicate names and report literal spellings without validating namespace or export policy. Ignore computed names and declarations inside quotations, lists, dictionaries, strings, or comments.

#### Examples

```ecl
"() `example @defm" parse source.declarations
# => (example)
```

## str

Operations on strings.

### format
`( values template -- string )` — Interpolate positional `{}` placeholders. Strings are rendered verbatim; other values are rendered with `str`. User `{{` and `}}` to emit literal braces.

#### Examples

```ecl
["Ada" 2] "name={} n={}" str.format
# => "name=Ada n=2"
```

### join
`( strings separator -- string )` — Join `strings` with `separator`.

### split
`( string separator -- parts )` — Split `string` at every occurrence of `separator`. When `separator` is "", then `parts` will be a list of single-codepoint strings.

#### Examples

```ecl
"a,b,c" "," str.split
# => ("a" "b" "c")
```

### str?
`( value -- bool )` — Return 1 when `value` is a list of chars.

### lower
`( string -- string )` — Lowercase the ASCII codepoints in `string`.

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
`( string -- string )` — Uppercase the ASCII codepoints in `string`.

#### Examples

```ecl
"Hello, wörld!" str.upper
# => "HELLO, WöRLD!"
```

### contains?
`( string needle -- bool )` — Return 1 when `needle` occurs anywhere in `string`. Return 1 if `needle` is "".

#### Examples

```ecl
"hello" "ell" str.contains?
# => 1
```

### ends?
`( string suffix -- bool )` — Return 1 when `string` ends with `suffix`.

### index-of
`( string needle -- index )` — Return the index of `needle`'s first occurrence in `string`, or the length of `string` when `needle` does not occur. Return 0 when `needle` is "".

### repeat
`( string count -- string )` — Concatenate `count` copies of `string`.

### replace
`( string needle replacement -- string )` — Replace every occurrence of `needle` in `string`. An empty needle inserts the replacement between adjacent codepoints.

#### Examples

```ecl
"a-b-c" "-" "+" str.replace
# => "a+b+c"
```

### starts?
`( string prefix -- bool )` — Return 1 when `string` starts with `prefix`.

### pad-left
`( string width pad -- string )` — Add leading copies of the char `pad` until `string` reaches `width`; return a longer string unchanged.

### pad-right
`( string width pad -- string )` — Add trailing copies of the char `pad` until `string` reaches `width`; return a longer string unchanged.

## stream

Byte streams. A stream is a byte endpoint: the standard devices, a file opened with `fs.open-reader`, a process pipe from `proc.stdin`, `proc.stdout`, or `proc.stderr`, and a connection's endpoints are all one kind to the words here, which provide the operations every byte endpoint shares. Nothing in `stream` decodes or encodes text: that is `io`. A read of either kind may leave bytes read ahead with the endpoint value, so a program that reads lines keeps the value it reads them through.

### err
`( -- stream )` — Return a handle to stderr.

### in
`( -- stream )` — Return a handle to stdin.

### out
`( -- stream )` — Return a handle to stdout.

### read
`( stream max -- bytes )` — Read at most `max` bytes from `stream`, parking until data or EOF.

### read-all
`( stream -- bytes )` — Read to EOF and return every byte as one list. A later `read-all` on the same endpoint returns `[]`. Errors are `read`'s.

### read-line
`( stream -- bytes )` — Read through the next newline and return those bytes, including \n.

### write
`( stream data -- )` — Write bytes. `data` is a list of integer bytes in `0...255`, or a list of such lists, written contiguously in order, so a program assembling output from pieces need not join them first. A string is `` `type ``: encode text with `io.write`. Invalid byte elements are `` `domain ``; a finished endpoint or transport failure is `` `io ``.

## table

A table is any dict whose values are lists of equal length.

The `table.` words model such a value as a table where the column names are the keys, the values are the columns, and a row is an indexing into each column for some index.

### at
`( table indices -- table )` — Gather the rows of `table` at `indices`, as `at` gathers a list. A list of indices selects and reorders rows; a list of index lists, such as `group-by`'s values, makes each column a list of slices, one per index list.

#### Examples

```ecl
{"name" ("Ada" "Lin" "Bo") "score" [20 10 30]} dup "score" at grade table.at
# => {"name" ("Lin" "Ada" "Bo") "score" [10 20 30]}

{"name" ("Ada" "Lin") "score" [10 20]} [1 0] where table.at
# => {"name" ("Ada") "score" [10]}
```

Gathering `group-by`'s index lists makes each column a list of per-group
slices. The first cell of each key slice is that group's key, and reducing
each value slice aggregates it:

```ecl
{"region" ["east" "west" "east"] "amount" [10 20 30]} dup ["region"] table.group-by
dict.vals table.at
# => {"region" (("east" "east") ("west")) "amount" ([10 30] [20])}

dup ["region"] table.select ((first) each) each
"total" rolldown "amount" at (sum) each table.with-column
# => {"region" ("east" "west") "total" [40 20]}
```

### rename
`( table mapping -- table )` — Rename columns in `table` mapping names to their replacements in `mapping`.

### select
`( table names -- table )` — Select the columns `names`.

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} ("score") table.select
# => {"score" [10 20]}
```

### table?
`( candidate -- bool )` — Return 1 when `candidate` is a table, and 0 otherwise.

### from-rows
`( names rows -- table )` — Construct a table with columns `names` and rows `rows`.

#### Examples

```ecl
["name" "score"] [("Ada" 10) ("Lin" 20)] table.from-rows
# => {"name" ("Ada" "Lin") "score" [10 20]}
```

### with-column
`( table name column -- table )` — Update table with the column name `name` and data `column`. If `name` is already present, it will be replaced.

### from-header-rows
`( rows -- table )` — Construct a table from `rows`, where the first row contains the column names and the remaining rows are data.

### from-records
`( records -- table )` — Construct a table from a list of dicts. The keys of the first element of `records` are used as the columns.

#### Examples

```ecl
[{"name" "Ada" "score" 10} {"name" "Lin" "score" 20}] table.from-records
# => {"name" ("Ada" "Lin") "score" [10 20]}
```

### group-by
`( table names -- groups )` — Group row indices in `table` by `names`.

### header-rows
`( table -- rows )` — Return `table`'s rows in order, prepended by a row of column names.

### records
`( table -- records )` — Return one dict per row.

#### Examples

```ecl
{"name" ("Ada" "Lin") "score" [10 20]} table.records
# => ({"name" "Ada" "score" 10} {"name" "Lin" "score" 20})
```

### rows
`( table -- rows )` — Return `table`'s rows in order.

### inner-join
`( left right pairs -- table )` — Return the stable inner equijoin for `[left-name right-name]` key pairs. Duplicate keys expand to the full many-to-many product in left-row then right-row order, and no key pairs give the cross product. The result contains every left column and the right non-key columns; colliding non-key names are `` `domain ``.

### left-join-with
`( left right pairs fill -- table )` — Return the stable left equijoin, using fill values for unmatched rows. `fill` must hold a value for every appended right column.

## tar

Hostile-input-safe tar reading and extraction. Binary payloads are ordinary lists of integers in `0...255`; compressed archives pass through [`gzip`](#gzip) first. `unpack` validates the whole archive before touching the filesystem, then publishes through the [`fs`](#fs) staging words.

### read
`( bytes -- members )` — Validate a tar byte list with the hostile-input parser and limits that `unpack` relies on, without filesystem writes, and return its members in archive order as `{path string kind symbol bytes list}`. Kinds are `` `file `` and `` `directory ``; a directory's bytes are `[]`. Unsafe, linked, special, duplicate, malformed, or over-limit members and invalid byte items are `` `domain ``; a non-list input is `` `type ``.

### unpack
`( root destination bytes -- regular-file-paths )` — Validate and atomically unpack a tar byte list beneath a previously absent `destination`, a canonical relative path under a filesystem root or directory resource. Return normalized regular-file paths in archive order.

## task

Task handles are created by the core unit constructors `@spawn` and `@give`. A handle observes a task's lifetime and result. `task.address` derives the task's address, which reaches only its mailbox, and `task.self` is the executing task's own. Use `(task.await) each` to collect results in input order without cancelling siblings or re-raising task errors.

Request and reply is a composition over `send` and `receive`: spawn a helper task, send its address with the request, and await the helper, whose result is the reply. `task.await-for` bounds the exchange.

#### Examples

Request and reply:

```ecl
(|a v| (task.receive) @spawn dup task.address {} `value v put `from rolldown put a swap task.send task.await `ok at first) `ask def
(task.receive dup `from at swap `value at 1 + task.send) @spawn task.address 41 ask
# => 42
```

### address
`( task -- address )` — The address of `task`'s mailbox.

### await
`( task -- result )` — Park until `task` completes; return a result value containing the completed task's stack.

### await-any
`( tasks -- index result )` — Park until the first task in `tasks` completes and return its result.

### await-for
`( task milliseconds -- result )` — Await a task with a nonnegative int deadline; expiry returns `{err {kind timeout}}` without cancelling the task.

### cancel
`( task -- )` — Request cancellation of `task`; its result becomes `{err {kind cancelled …}}`.

### cancel-self
`( -- )` — Request cancellation of the current task.

### pending
`( -- tasks )` — Push all pending descendant tasks.

### receive
`( -- value )` — Pop the oldest message from the current task's mailbox, parking if the mailbox is empty.

### receive-for
`( milliseconds -- result )` — `task.receive` with a nonnegative int deadline: `{ok value}`, or `{err {kind timeout}}`.

### self
`( -- address )` — The address of the current task's mailbox.

### send
`( address value -- )` — Push a value to the mailbox at `address`. Any value may be sent except one containing a task handle, which is `` `type ``. If the mailbox is full, park until a message is received from it.

#### Examples

```ecl
(task.receive 1 +) @spawn dup task.address 41 task.send task.await
# => {ok [42]}
```

## test.default

The bundled runner is ordinary ECL policy over the closed `tests` / `@test` substrate. Projects may replace it with any public qualified runner word. The host supplies only catalog discovery, protected invocation, and root dispatch.

### run
`( -- )` — Discover every module's tests and invoke them sequentially, printing one `ok` or `FAIL` line to stderr for every result. Exit with status code 1 if any test failed.

## time

Pure UTC time over the millisecond timestamps `clock.unix` produces. Every word accepts and returns whole milliseconds; a timestamp is `{unix ms}` and nothing else — a `{monotonic ms}` instant, an untagged int, a float payload, or a dictionary with any other key is `` `type ``. Arithmetic is checked: leaving the int millisecond range is `` `overflow ``. Calendar words use the proleptic Gregorian calendar with no leap seconds, so Unix time here is the POSIX count in which every day has exactly 86,400,000 milliseconds. The representable range runs from `-292275055-05-16T16:47:04.192` through `292278994-08-17T07:12:55.807`.

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
`( milliseconds -- timestamp )` — Tag an integer Unix millisecond count as `{unix milliseconds}`. Negative counts denote instants before 1970.

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
