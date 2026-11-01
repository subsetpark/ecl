### def <=
(x y -- bool :
 "**Pervasive.** Compare conforming values for less-than-or-equal order, producing boolean masks.")
(> not) `<= def

### def <>
(x y -- bool :
 "**Pervasive.** Compare conforming values for inequality, producing boolean masks. On 0/1 masks
  this is xor; there is no separate word.")
(= not) `<> def

### def >=
(x y -- bool :
 "**Pervasive.** Compare conforming values for greater-than-or-equal order, producing boolean
  masks.")
(< not) `>= def

### def assert
(bool error -- :
 "Raise an error dict unless the condition is the boolean 1, discarding the dict when it holds.
  Defined in ecl.")
(swap (pop) (raise) if) `assert def

### def at-path
(ds l -- x :
 "Repeatedly index nested lists and dicts by each key or index in the path, left to right; an empty
  path returns `ds` unchanged.")
(swap (at) fold) `at-path def

### def bi2
(x y p q -- ... :
 "*Inline.* Binary cleave: apply each of two quotations to the same pair of input values.")
(|x y p q| x y p call x y q call) `bi2 def

### def both
(x y q -- ... :
 "*Inline.* Apply one quotation independently to each of two input values, `x` first.")
(|x y q| x q call y q call) `both def

### def collect
(quotation -- list :
 "Run a quotation on an empty isolated stack and return what it leaves as a list, preserving order.
  The quotation cannot see values beneath it.")
([] swap infra) `collect def

### def each-prior
(list seed quotation -- list :
 "*Isolated*, contract `( current prior -- result )`. Apply the quotation to each element and its
  predecessor, left to right, using the explicit seed as the predecessor of the first element. Thus
  `[12 13 11] 10 (-) each-prior` is `[2 1 -2]`. Defined in ecl over `zip-with`.")
(|xs seed quotation| xs seed xs cons -1 drop quotation zip-with) `each-prior def

### def empty?
(sequence -- bool : "Return 1 when a sequence has no elements and 0 otherwise.")
(len 0 =) `empty? def

### def last
(sequence -- value : "Return the final element of a nonempty sequence.")
(dup len 1 - at) `last def

### def max-of
(sequence -- value : "Return the greatest element of a nonempty sequence.")
(dup first (max) fold) `max-of def

### def min-of
(sequence -- value : "Return the least element of a nonempty sequence.")
(dup first (min) fold) `min-of def

### def neg
(x -- y : "**Pervasive.** Negate numeric values with checked integer overflow.")
(-1 *) `neg def

### def nip
(x y -- y : "Discard the value immediately beneath the top of the stack.")
(swap pop) `nip def

### def pack
(: "Takes `x₁ … xₙ n` and leaves a list. Collect the top `n` values into a list, preserving their
    order; `n` must be a nonnegative int. Deliberately state-dependent stack surgery.")
(() swap (cons) times) `pack def

### def pair
(first second -- list : "Collect two stack values into a two-element list in stack order.")
(() cons cons) `pair def

### def partial
(value quotation -- quotation :
 "Safe partial application: return a quotation that pushes an inert captured value before running
  another quotation. Even a captured word remains data. `3 (+) partial` is `(3 +)`, and a captured
  word `w` is prefixed as `` `w ``.")
(swap literal swap cons) `partial def

### def rest
(list -- list : "Return all but the first element of a nonempty list.")
(dup first pop 1 drop) `rest def

### def reverse
(list -- list :
 "Return a list with its top-level element order reversed. Defined in ecl as an index permutation.")
(dup len dup 0 =
 (pop)
 (dup range swap 1 - swap - at)
 if) `reverse def

### def signum
(number -- sign :
 "**Pervasive** by composition. Return the int −1, 0, or 1 according to the sign of a number.")
(dup 0 > swap 0 < -) `signum def

### def sort
(sequence -- sorted : "Return a stable ascending sort of a sequence by `cmp`.")
(dup grade at) `sort def

### def tri2
(x y p q r -- ... :
 "*Inline.* Binary cleave: apply each of three quotations to the same pair of input values in
  left-to-right order.")
(|x y p q r| x y p call x y q call x y r call) `tri2 def

### def unless
(bool else -- ... :
 "*Inline.* Call the quotation when the condition is the boolean 0; otherwise do nothing.")
(() swap if) `unless def

### def when
(bool then -- ... :
 "*Inline.* Call the quotation when the condition is the boolean 1; otherwise do nothing.")
(() if) `when def

### def windows
(list width -- windows : "Return every overlapping window of a positive width.")
(() stencil) `windows def

### def wrap
(value -- list : "Wrap one value in a one-element list.")
(() cons) `wrap def

### def abs
(x -- y :
 "**Pervasive.** Return absolute numeric values with checked integer overflow. Defined in ecl; ``
  `abs see `` renders the definition.")
(dup neg 0 + swap max) `abs def

### def append
(sequence value -- sequence : "Append one value to the end of a sequence.")
(wrap cat) `append def

### def compose
(left right -- quotation : "Concatenate two quotations in execution order.")
(cat dup len 0 = (pop ()) when) `compose def

### def find
(sequence needle -- index :
 "Return the index of the first element that returns 1 from `match?` against the needle, or the
  sequence length when no element matches. Defined in ecl.")
((match?) partial each first-where) `find def

### def scan1
(list quotation -- list :
 "*Isolated*, contract `( acc a -- acc )`. Return a nonempty list's first element followed by the
  successive accumulator values from reducing its remaining elements. Defined in ecl over `scan`.")
(|xs quotation| xs first wrap xs rest xs first quotation scan cat) `scan1 def

### def set
(: "Takes an optional annotation, a value, and a name, and leaves nothing. Bind the value as a
    constant word in the current scope. Reference applies the constant's body and pushes the exact
    captured value, quotations included. Defined in ecl as `swap literal wrap swap def`, so `v `name
    set` is observationally `v literal wrap `name def`: the stored body is `(v)`, or `` (`v) `` for
    a symbol. An optional annotation beneath `v` is published as the constant's metadata; marker
    words inside `v` are nested in the body and remain captured data.")
(swap literal wrap swap def) `set def

### def setp
(: "Takes an optional annotation, a value, and a name, and leaves nothing. Bind the value as a
    private module constant word; an optional annotation may precede the value. Defined in ecl as
    `swap literal wrap swap defp`. A top-level `setp` is an error, raised by the `defp` it calls.")
(swap literal wrap swap defp) `setp def

### def uncons
(list -- first rest : "Split a nonempty list into its first element and remaining elements.")
(dup first swap rest) `uncons def

### def zip
(left right -- pairs : "Pair corresponding elements of two conforming sequences.")
((pair) zip-with) `zip def

### def dip
(x q -- ... :
 "*Inline.* Run a quotation beneath a protected top stack value: `q` runs with `x` removed, then `x`
  returns on top of its results.")
(swap literal append call) `dip def

### def fail
(msg -- :
 "Raise a user-kind error whose message is the supplied value: `{kind user msg msg}`. Defined in
  ecl.")
(wrap (kind user msg) swap compose dict.core.from-flat raise) `fail def

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

### def iterations
(value count quotation -- list :
 "*Isolated*, unary contract `( a -- a )`. Return the initial value followed by `count` successive
  quotation applications. `count` must be a nonnegative int, and a zero count returns a singleton
  list. Defined in ecl over `scan`.")
(|value count quotation|
 value wrap count range value (pop) quotation compose scan cat) `iterations def

### def unappend
(list -- initial last : "Split a nonempty list into its initial elements and last element.")
(reverse uncons reverse swap) `unappend def

### def while-values
(value predicate step -- list :
 "*Isolated*, contracts `( state -- bool )` and `( state -- state )`. Return the initial value and
  successive states through the first state for which the predicate is false. Defined in ecl over
  `unfold`.")
(|value predicate step|
 value predicate step (dup) compose unfold nip value swap cons) `while-values def

### def and
(x y -- bool :
 "**Pervasive.** Compute boolean conjunction over 0 and 1 values. Both operands are already
  evaluated; there is no short-circuiting. Defined in ecl.")
((not not) dip not not min) `and def

### def clamp
(value lower upper -- bounded :
 "**Pervasive** by composition. Constrain a value to the inclusive interval between lower and
  upper.")
((max) dip min) `clamp def

### def or
(x y -- bool :
 "**Pervasive.** Compute boolean disjunction over 0 and 1 values. Both operands are already
  evaluated; there is no short-circuiting. Defined in ecl.")
((not not) dip not not max) `or def

### def over
(x y -- x y x : "Copy the value beneath the top of the stack onto the top.")
(swap dup (swap) dip) `over def

### def rolldown
(x y z -- y z x : "Rotate the top three stack values downward, from x y z to y z x.")
((swap) dip swap) `rolldown def

### def rollup
(x y z -- z x y : "Rotate the top three stack values upward, from x y z to z x y.")
(swap (swap) dip) `rollup def

### def with
(values quotation -- quotation :
 "Return a quotation that pushes every value from a list, in order and inertly, before running
  another quotation. Calling the result starts with the list's elements as separate stack values.
  Defined in ecl as `((literal) each) dip cat`.

  This is ordinary quotation composition and constructs nothing. It is not a unit's seed operand:
  the flattened quotation it returns is a runtime-built body, so `@defm` gives it no reader
  attribution. Unit constructors instead take their initial values and body as two separate
  operands, preserving the exact body for attribution.")
(((literal) each) dip cat) `with def

### def @each
(sequence values quotation -- results :
 "*Unit constructor*, one fresh unit per element, contract `( a -- b )` enforced per element.
  Concurrent `each`: apply a quotation in one fresh unit per element and return one result per
  element in input order. Each child's stack starts with its element deepest; `list values (q)
  @each` adds the shared values above it. Results are joined in order; the leftmost failure cancels
  every later task, waits for them to quiesce, and is re-raised. Defined in ecl over `@spawn`,
  `task.await`, and `task.cancel`. Inside a module construction body, at any depth, this constructor
  is `` `domain ``: a module body defines words and starts no tasks (see Modules). See
  Concurrency.")
(|sequence values quotation|
 quotation type `list match? not
 ({kind type msg "@each expected a quotation/list" word @each} raise)
 when
 values type `list match? not ({kind type msg "@each expected a list" word @each} raise) when
 sequence type `list match? not ({kind type msg "@each expected a list" word @each} raise) when
 sequence values quotation pair
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
(sequence predicate -- bool :
 "*Isolated*, contract `( a -- bool )`. Return 1 when the predicate returns 1 for every element;
  otherwise return 0.")
(|l q| l q each 1 (and) fold) `all? def

### def any?
(sequence predicate -- bool :
 "*Isolated*, contract `( a -- bool )`. Return 1 when the predicate returns 1 for at least one
  element; otherwise return 0. The predicate runs on every element; there is no early exit.")
(|l q| l q each 0 (or) fold) `any? def

### def converges
(value quotation -- list :
 "*Isolated*, unary contract `( a -- a )`. Return the initial value and successive applications
  until the next value is structurally equal to either the initial or immediately preceding value;
  that repeated boundary value is not appended. Defined in ecl over `unfold`.")
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
(sequence predicate -- matches :
 "*Isolated*, contract `( a -- count )`. Apply the predicate to every element, retaining each
  element as many times as its returned nonnegative int. A 0/1 predicate is ordinary filtering.")
(over swap each where at) `filter def

### def fold1
(list quotation -- value :
 "*Isolated*, contract `( acc a -- acc )`. Reduce a nonempty list left to right from its first
  element rather than from an explicit accumulator; an empty list requires `fold`. Defined in ecl.")
(swap uncons swap rolldown fold) `fold1 def

### def keep
(x q -- ... :
 "*Inline.* Apply a quotation to a value, then restore the value on top of the quotation's
  results.")
(over (call) dip) `keep def

### def lex-cmp-with
(left right comparator -- order :
 "Compare two sequences lexicographically with an inline `( left-element right-element -- order )`
  comparator that returns −1, 0, or 1. The comparator runs only through the first differing pair;
  when the shared prefix is equal, the sequences are ordered by length. Defined in ecl.")
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

### def mod
(x y -- z : "**Pervasive.** Compute checked integer remainders.")
(over over div * -) `mod def

### def partition
(sequence predicate -- matches rejects :
 "*Isolated*, contract `( a -- bool )`. Split a sequence into the elements whose predicate returned
  1 and those that returned 0. Defined in ecl.")
(|l q| l q each l over where at swap not l swap where at) `partition def

### def @each!
(sequence quotation -- results :
 "*Unit constructor*, one fresh unit per element, contract `( a -- b )` enforced per element.
  `@each` with no shared values: each child's stack starts with its element alone, so `list (q)
  @each!` is `list [] (q) @each`. Defined in ecl over `@each`.")
(|sequence quotation| sequence [] quotation @each) `@each! def

### def bi
(x p q -- ... :
 "*Inline.* Apply two quotations to the same input, first `p`, then `q`, leaving `p`'s results
  beneath `q`'s.")
((keep) dip call) `bi def

### def case
# Validate the clause container before inspecting any clause.
(x clauses -- ... :
 "*Inline.* Select and call the first action whose key matches the subject. The clause list is flat,
  nonempty, and odd: `[key action … else]`. Keys are inert data: any value, never executed, with
  duplicates legal and the first `match?` result of 1 winning. Every action and the else must be a
  quotation, and all of them are validated before any comparison or user quotation runs. When no key
  matches, the else runs. Defined in ecl; `` `case see `` renders the definition.")
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

### def converge
(value quotation -- value :
 "*Isolated*, unary contract `( a -- a )`. Return the last value before repeated application reaches
  a fixed point or returns to the initial value.")
(converges last) `converge def

### def product
# A nonempty sequence starts from its first element, as `(*) fold1` does, so
# no one seed multiplies a copy of a first row.
(sequence -- product :
 "Multiply every element of a numeric sequence; 1 when the sequence is empty. A nonempty sequence's
  product starts from its first element, so a list of rows multiplies to a row.")
(dup empty? (pop 1) ((*) fold1) if) `product def

### def sum
# A nonempty sequence starts from its first element, as `(+) fold1` does, so
# no zero seed copies a first row or turns a -0.0 total into 0.0.
(sequence -- total :
 "Add every element of a numeric sequence; 0 when the sequence is empty. A nonempty sequence's total
  starts from its first element: a list of rows sums to a row, and a sum of negative zeros is
  `-0.0`.")
(dup empty? (pop 0) ((+) fold1) if) `sum def

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

### def tri
(x p q r -- ... : "*Inline.* Apply three quotations to the same input in left-to-right order.")
(((keep) dip keep) dip call) `tri def

### def mean
(sequence -- mean : "Return the arithmetic mean of a nonempty numeric sequence.")
(dup sum swap len /) `mean def
