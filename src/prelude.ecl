### def 2keep
(x y (... -- ...) -- ... x y :
 "Binary `keep`: apply a quotation to a pair of values, then restore both values, in order, on top
  of the quotation's results.")
(|x y q| x y q call x y) `2keep def

### def <=
(x y -- bool : "Compare conforming values for less-than-or-equal order.")
(> not) `<= def

### def <>
(x y -- bool : "Compare conforming values for inequality.")
(= not) `<> def

### def >=
(x y -- bool : "Compare conforming values for greater-than-or-equal order.")
(< not) `>= def

### def assert
(bool error -- : "Raise an error dict unless the condition is 1.")
(swap (pop) (raise) if) `assert def

### def at-path
(ds l -- x :
 "Repeatedly index nested lists and dicts by each key or index in the path, left to right; an empty
  path returns `ds` unchanged.")
(swap (at) fold) `at-path def

### def bi2
(x y p q -- ... : "Apply each of two quotations to the same pair of operands.")
(|x y p q| x y p call x y q call) `bi2 def

### def both
(x y q -- ... : "Apply one quotation to each of two operands.")
(|x y q| x q call y q call) `both def

### def collect
(quotation -- list : "Run a quotation on an empty isolated stack and return the results as a list.")
([] swap infra) `collect def

### def each-prior
(list seed (current prior -- result) -- list :
 "Apply the quotation to each element and its predecessor, left to right, using the explicit seed as
  the predecessor of the first element.

  Ex:
    [12 13 11] 10 (-) each-prior
  [2 1 -2]")
(|xs seed quotation| xs seed xs cons -1 drop quotation zip-with) `each-prior def

### def empty?
(list -- bool : "Return 1 when a list has no elements and 0 otherwise.")
(len 0 =) `empty? def

### def last
(list -- value : "Return the final element of a nonempty list.")
(dup len 1 - at) `last def

### def neg
(x -- y : "Negate a numeric value.")
(-1 *) `neg def

### def nip
(x y -- y : "Discard the second value on the stack.")
(swap pop) `nip def

### def pack
(... n -- list : "Collect the top `n` values into a list.")
(() swap (cons) times) `pack def

### def pair
(first second -- list : "Collect two stack values into a two-element list.")
(() cons cons) `pair def

### def partial
(value quotation -- quotation :
 "Add `value` to the left of `quotation`, preserving the quotedness of symbols.

  Ex:
    3 (+) partial
  (3 +)
    `w () partial
  (`w)")
(swap literal swap cons) `partial def

### def rest
(list -- list : "Return all but the first element of a nonempty list.")
(dup first pop 1 drop) `rest def

### def reverse
(list -- list : "Return a list with its top-level element order reversed.")
(dup len dup 0 =
 (pop)
 (dup range swap 1 - swap - at)
 if) `reverse def

### def signum
(number -- sign : "Return the int −1, 0, or 1 according to the sign of a number.")
(dup 0 > swap 0 < -) `signum def

### def sort
(list -- sorted : "Return a stable ascending sort of a list by `cmp`.")
(dup grade at) `sort def

### def tri2
(x y p q r -- ... :
 "Apply each of three quotations to the same pair of operands in left-to-right order.")
(|x y p q r| x y p call x y q call x y r call) `tri2 def

### def unless
(bool else -- ... : "Call `else` when the condition is 0; otherwise do nothing.")
(() swap if) `unless def

### def when
(bool then -- ... : "Call `then` when the condition is 1; otherwise do nothing.")
(() if) `when def

### def windows
(list width -- windows : "Return overlapping windows of width `width`.")
(() stencil) `windows def

### def wrap
(value -- list : "Wrap `value` in a list.")
(() cons) `wrap def

### def abs
(x -- y : "Return the absolute value of `x`.")
(dup neg 0 + swap max) `abs def

### def append
(list value -- list : "Push `value` to the end of `list`.")
(wrap cat) `append def

### def fail
(msg -- : "Raise a user-kind error whose message is `msg`: `{kind user msg msg}`.")
(wrap (kind user msg) swap cat dict.core.from-flat raise) `fail def

### def find
(list needle -- index :
 "Return the index of the first element of `list` for which `needle match?` returns 1, or the list
  length when no element matches.")
((match?) partial each first-where) `find def

### def iterations
(value count (a -- a) -- list :
 "Return `value` followed by `count` successive quotation applications. `count` must be a
  nonnegative int, and a zero count returns a singleton list.")
(|value count quotation|
 value wrap count range value (pop) quotation cat scan cat) `iterations def

### def parse-one
(string -- x :
 "Parse source text holding exactly one form and return that form unevaluated. No form or several
  forms is `` `shape ``.")
(parse dup len 1 = {kind shape msg "parse-one requires exactly one form"} assert first) `parse-one
def

### def scan1
(list (acc a -- acc) -- list :
 "Return a nonempty list's first element followed by the successive accumulator values from reducing
  its remaining elements.")
(|xs quotation| xs first wrap xs rest xs first quotation scan cat) `scan1 def

### def set
(... value name -- :
 "(annotation value name -- ) *or* (value name -- ). Bind `value` as a constant word in the current
  scope. Reference applies the constant's body and pushes the exact captured value, quotations
  included. `annotation` is published as the constant's metadata.")
(swap literal wrap swap def) `set def

### def setp
(... value name -- : "`set` as a private module name. A top-level `setp` is an error.")
(swap literal wrap swap defp) `setp def

### def uncons
(list -- first rest : "Split a nonempty list into its first element and remaining elements.")
(dup first swap rest) `uncons def

### def while-values
(value (predicate: state -- bool) (step: state -- state) -- list :
 "Return `value` and successive states through the first state for which the predicate is false.")
(|value predicate step|
 value predicate step (dup) cat unfold nip value swap cons) `while-values def

### def zip
(left right -- pairs : "Pair corresponding elements of two conforming lists.")
((pair) zip-with) `zip def

### def dip
(x (q: ... -- ...) -- ... x :
 "Run a quotation beneath a protected top stack value: `q` runs with `x` removed, then `x` is pushed
  after its results.")
(swap literal append call) `dip def

### def from-digits
(digits base -- value :
 "Combine digits, most significant first, into a value. The base is one integer for every position,
  or a list of radices with one per digit, as in mixed-radix time; the first radix has no effect.
  Digits pervade: a list of equal-length digit lists, one per position, gives one value per column.
  A radix list of the wrong length fails with `` `shape ``. Inverse of `to-digits` for values in
  range.")
(|ds base|
 ds base ds len base type `list match?
 (|b n| b len n = {kind shape msg "from-digits needs one radix per digit"} assert b)
 (|b n| b wrap n take)
 if
 zip 0 (|acc p| acc p 1 at * p 0 at +) fold) `from-digits def

### def unappend
(list -- initial last : "Split a nonempty list into its initial elements and last element.")
(reverse uncons reverse swap) `unappend def

### def and
(x y -- bool : "Compute boolean and over 0 and 1 values.")
((not not) dip not not min) `and def

### def clamp
(value lower upper -- bounded :
 "Constrain a value to the inclusive interval between `lower` and `upper`.")
((max) dip min) `clamp def

### def or
(x y -- bool : "Compute boolean or over 0 and 1 values.")
((not not) dip not not max) `or def

### def over
(x y -- x y x : "Copy the value beneath the top of the stack onto the top.")
(swap dup (swap) dip) `over def

### def rolldown
(x y z -- y z x : "Rotate the top three stack values downward.")
((swap) dip swap) `rolldown def

### def rollup
(x y z -- z x y : "Rotate the top three stack values upward.")
(swap (swap) dip) `rollup def

### def with
(values quotation -- quotation :
 "Push each of `values` to the left of `quotation`, preserving the quotedness of symbols.")
(((literal) each) dip cat) `with def

### def 2dup
(x y -- x y x y : "Copy the top two stack values onto the top, preserving their order.")
(over over) `2dup def

### def @each
(list values (quotation: a ... -- b) -- results :
 "Concurrent `each`: for each element of `list`, apply `quotation` in a fresh unit, with the element
  seeded to the unit stack. `values` is then seeded above the element.")
(|list values quotation|
 quotation type `list match? not
 ({kind type msg "@each expected a list for its quotation" word @each} raise) when
 values type `list match? not
 ({kind type msg "@each expected a list for its values seed" word @each} raise) when
 list type `list match? not
 ({kind type msg "@each expected a list for its operand" word @each} raise) when
 list values quotation pair
 (|element seeds| element seeds first cons seeds 1 at @spawn)
 partial each
 dup
 (|failure entry tasks|
  failure entry tasks failure len 0 >
  (|failure entry tasks| entry 1 at task.await pop failure)
  (|failure entry tasks|
   tasks entry first 1 +
   entry first entry 1 at task.await
   dup `ok dict.has?
   (|index outcome|
    index outcome `ok at len 1 =
    (pop [])
    (|index|
     `kind `contract `msg "@each child must leave exactly one result" `word `@each
     `data `index index pair dict.from-flat 8 pack dict.from-flat wrap)
    if)
   (|index outcome| outcome `err at wrap)
   if
   dup len 0 >
   (|tasks start failure| tasks start drop (task.cancel) for failure)
   (|tasks start failure| failure)
   if)
  if)
 partial
 over dup len range swap (pair) zip-with [] rolldown fold
 dup len 0 > (nip first raise) (pop (task.await `ok at first) each) if) `@each def

### def all?
(list (a -- bool) -- bool :
 "Return 1 when the predicate returns 1 for every element; otherwise return 0.")
(|l q| l q each 1 (and) fold) `all? def

### def any?
(list (a -- bool) -- bool :
 "Return 1 when the predicate returns 1 for at least one element; otherwise return 0.")
(|l q| l q each 0 (or) fold) `any? def

### def converges
(value (a -- a) -- list :
 "Return the initial value and successive applications until the next value is structurally equal to
  either the initial or immediately preceding value; that repeated boundary value is not appended.")
(|value quotation|
 value value value wrap quotation each first 3 pack
 (|state|
  state 2 at state 0 at match? not
  state 2 at state 1 at match? not
  and)
 quotation
 (|state quotation|
  state 0 at
  state 2 at
  state 2 at wrap quotation each first
  3 pack
  state 2 at)
 partial
 unfold nip value swap cons) `converges def

### def filter
(list (a -- count) -- matches :
 "Apply the predicate to every element, retaining each element as many times as its returned
  nonnegative int.")
(over swap each where at) `filter def

### def fold1
(list (acc a -- acc) -- value :
 "Reduce a nonempty list left to right from its first element rather than from an explicit
  accumulator; an empty list requires `fold`.")
(swap uncons swap rolldown fold) `fold1 def

### def keep
(x (... -- ...) -- ... x :
 "Apply a quotation to a value, then restore the value on top of the quotation's results.")
(over (call) dip) `keep def

### def lex-cmp-with
(left right (left-element right-element -- order) -- order :
 "Compare two lists lexicographically with an inline comparator that returns −1, 0, or 1. The
  comparator runs only through the first differing pair; when the shared prefix is equal, the lists
  are ordered by length.")
(0 0
 (|left right comparator index order|
  order 0 = index left len < and index right len < and)
 (|left right comparator index order|
  left right comparator index 1 +
  left index at right index at comparator call)
 while
 (|left right comparator index order|
  order left len right len cmp
  over 0 = (nip) (pop) if)
 call) `lex-cmp-with def

### def partition
(list (a -- bool) -- matches rejects :
 "Split a list into the elements whose predicate returned 1 and those that returned 0.")
(|l q| l q each l over where at swap not l swap where at) `partition def

### def @each!
(list (a -- b) -- results : "Call @each with an empty seed list.")
(|list quotation| list [] quotation @each) `@each! def

### def bi
(x p q -- ... :
 "Apply two quotations to the same input, first `p`, then `q`, leaving `p`'s results beneath
  `q`'s.")
((keep) dip call) `bi def

### def cleave
(x quotations -- ... :
 "Apply each quotation in `quotations` to `x`, leaving each quotation's results above the previous
  one's. An empty list consumes the input and leaves nothing.")
(|x qs|
 qs type `list match? {kind type msg "cleave expected a list of quotations"} assert
 qs (type `list match?) all? {kind type msg "cleave expected a list of quotations"} assert
 x wrap wrap qs len take [first] qs len take qs [call] qs len take 4 pack
 qs empty? (pop []) (flip raze) if call) `cleave def

### def cleave-n
(... n quotations -- ... :
 "N-ary cleave. Consume the top `n` values from the stack, and pass them to each quotation in
  `quotations` in order.")
(|n qs|
 n type `int match? {kind type msg "cleave-n expected an int arity"} assert
 n 0 >= {kind domain msg "cleave-n arity must be nonnegative"} assert
 qs type `list match? {kind type msg "cleave-n expected a list of quotations"} assert
 qs (type `list match?) all? {kind type msg "cleave-n expected a list of quotations"} assert
 n qs qs empty?
 (pop pack pop [])
 (|n qs|
  n pack (wrap) each qs
  (|i qs| i wrap qs len take [first] qs len take 2 pack) partial each raze
  qs wrap cat [call] qs len take wrap cat flip raze)
 if call) `cleave-n def

### def cleave2
(x y quotations -- ... :
 "Binary cleave. Consume `x` and `y`, and pass them to each quotation in `quotations` in order.")
(|x y qs|
 qs type `list match? {kind type msg "cleave2 expected a list of quotations"} assert
 qs (type `list match?) all? {kind type msg "cleave2 expected a list of quotations"} assert
 x wrap wrap qs len take [first] qs len take y wrap wrap qs len take [first] qs len take
 qs [call] qs len take 6 pack
 qs empty? (pop []) (flip raze) if call) `cleave2 def

### def converge
(x (a -- a) -- y :
 "Return the last value before repeated application reaches a fixed point or returns to the initial
  value.")
(converges last) `converge def

### def mod
(x y -- z : "Compute remainder of `x` / `y`.")
(2dup div * -) `mod def

### def product
# A nonempty list starts from its first element, as `(*) fold1` does, so
# no one seed multiplies a copy of a first row.
(list -- product :
 "Multiply every element of a numeric list; 1 when the list is empty. A nonempty list's product
  starts from its first element, so a list of rows multiplies to a row.")
(dup empty? (pop 1) ((*) fold1) if) `product def

### def sum
# A nonempty list starts from its first element, as `(+) fold1` does, so
# no zero seed copies a first row or turns a -0.0 total into 0.0.
(list -- total :
 "Add every element of a numeric list; 0 when the list is empty. A nonempty list's total starts from
  its first element: a list of rows sums to a row, and a sum of negative zeros is `-0.0`.")
(dup empty? (pop 0) ((+) fold1) if) `sum def

### def tri
(x p q r -- ... : "Apply three quotations to `x` in left-to-right order.")
(((keep) dip keep) dip call) `tri def

### def case
# Validate the clause container before inspecting any clause.
(x clauses -- ... :
 "Select and call the first action whose key matches the subject. The clause list should be shaped:

    [case1 q1
     case2 q2
     ...
     else]

  Where `caseN` is a value to be compared against `x` with `match?`, and `qN` is the quotation to
  apply for the first case that matches.

  `else` is obligatory and is applied when no case matches.")
(dup type `list match?
 # A case table is [key action ... else]: nonempty and odd in length.
 (dup len dup 0 > swap 2 mod 1 = and
  ((|subject clauses|

    # Collect every action plus the mandatory else quotation. Running
    # `len pop` in isolation validates that each choice is a quotation
    # without executing user code.
    clauses dup len 2 div range 2 * 1 + at
    clauses last append
    dup (len pop) for

    # Search the even key slots. Find's length-on-miss result selects the
    # final else quotation when no key matched.
    clauses dup len 2 div range 2 * at
    subject find at call)
   call)
  (pop pop {kind shape msg "case requires a nonempty odd clause list ending in else"} raise)
  if)
 (pop pop {kind type msg "case expected a clause list"} raise)
 if) `case def

### def chunk
(list size -- pieces :
 "Split a list into consecutive pieces of a positive size; the last piece is shorter when the size
  does not divide the length.")
(|xs k|
 k 0 > {kind domain msg "chunk size must be positive"} assert
 xs xs len k div xs len k mod 0 > + range k * cut) `chunk def

### def mean
(list -- mean : "Return the arithmetic mean of a nonempty numeric list.")
(dup sum swap len /) `mean def

### def to-digits
(value radices -- digits :
 "Split a value into one digit per radix, most significant first, by floor division, so every digit
  lies from zero below its radix even for negative values. A value beyond the radices' capacity
  keeps only its low digits. Values pervade: a list of values gives one digit list per radix.
  Radices must be positive integers, or the word fails with `` `domain ``; `[2] 8 take` builds eight
  binary radices.")
(|x rs|
 rs (dup type `int match? (0 >) (pop 0) if) all?
 {kind domain msg "to-digits radices must be positive integers"} assert
 rs reverse x [] pair
 (|st r|
  st 0 at r mod 0 < st r
  (|n st r| st 0 at r div n - st 0 at r mod n r * + wrap st 1 at cat pair) call)
 fold 1 at) `to-digits def
