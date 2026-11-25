### def all?
(list (p: a -- bool) -- bool :
 "Return 1 when `p` returns 1 for every element of `list`; otherwise return 0.")
(each 1 (and) fold) `all? def

### def any?
(list (p: a -- bool) -- bool :
 "Return 1 when `q` returns 1 for at least one element of `list`; otherwise return 0.")
(each 0 (or) fold) `any? def

### def assert
(bool error -- : "Raise `error` unless `bool` is 1.")
(swap (pop) (raise) if) helper `assert def

### def at-path
(ds path -- x : "Follow `path` through `ds` via `at`; an empty path returns `ds` unchanged.")
(swap (at) fold) `at-path def

### def both
(x y q -- ... : "Apply `q` to `x` and `y`.")
(|x y q| x q apply y q apply) `both def

### def clamp
(value lower upper -- bounded :
 "Constrain `value` to the inclusive interval between `lower` and `upper`.")
((max) dip min) `clamp def

### def collect
(quotation -- list : "Run `quotation` on an empty stack and return the results as a list.")
([] swap infra) `collect def

### def each-prior
(list seed (q: prior current -- result) -- list :
 "Apply `q` to each successive pair of elements in `list`, using `seed` as the predecessor of the
  first element.

   Ex:
     [12 13 11] 10 (-) each-prior
   [-2 -1 2]")
(|xs seed quotation| seed xs cons -1 drop xs quotation zip-with) `each-prior def

### def empty?
(list -- bool : "Return 1 when `list` has no elements and 0 otherwise.")
(len 0 =) `empty? def

### def filter
(list (p: a -- count) -- matches :
 "Apply `p` to every element of `list`, retaining each element as many times as its returned int.")
(over swap each where at) `filter def

### def dip2
(x y (q: ... -- ...) -- ... x y :
 "Run `q` beneath `x y`, then push `x y` back in their original order after its results.")
(2 dip-n) `dip2 def

### def last
(list -- value : "Return the final element of `list`.")
(dup len 1 - at) `last def

### def mean
(list -- mean : "Return the arithmetic mean of `list`.")
(dup sum swap len /) `mean def

### def pack
(... n -- list : "Collect the top `n` values into a list.")
(() swap (cons) times) `pack def

### def pair
(x y -- list : "Collect `x y` into a two-element list.")
(() cons cons) `pair def

### def partition
(list (p: a -- bool) -- matches rejects :
 "Split `list` into the elements for which `p` returned 1 and those that returned 0.")
(|l q| l q each l over where at swap not l swap where at) `partition def

### def signum
(number -- sign : "Return −1, 0, or 1 according to the sign of `number`.")
(dup 0 > swap 0 < -) `signum def

### def uncons
(list -- first rest : "Split a nonempty `list` into its first element and remaining elements.")
(dup first swap rest) `uncons def

### def unless
(bool else -- ... : "Call `else` when the condition is 0.")
(() swap if) `unless def

### def when
(bool then -- ... : "Call `then` when the condition is 1.")
(() if) `when def

### def wrap
(value -- list : "Wrap `value` in a list.")
(() cons) `wrap def

### def @each
(list (q: a -- b) -- results :
 "Concurrently apply `q` to each element of `list`, each application in a fresh unit.")
(|list quotation|
 quotation type `list match?
 ({kind type msg "@each expected a list for its quotation" word @each} raise) unless
 list type `list match?
 ({kind type msg "@each expected a list for its operand" word @each} raise) unless
 list quotation (|element quotation| element quotation (apply) cons cons @spawn) cons each
 # Await in program order. The first failure, or a child that leaves other
 # than one value, stops the walk; every task is then cancelled and joined
 # before that error is raised.
 (|tasks|
  tasks
  tasks
  (dup len range
   (|task index|
    index task task.await
    dup `ok has? (`err at raise) unless
    `ok at dup len 1 =
    (nip first)
    (pop
     (|index|
      {kind contract msg "@each child must leave exactly one result" word @each}
      `data {} `index index put put raise)
     apply)
    if)
   zip-with)
  cons @attempt
  dup `ok has?
  (nip `ok at first)
  (swap dup (task.cancel) for (task.await pop) for `err at raise)
  if)
 apply) `@each def

### def append
(list value -- list : "Push `value` to the end of `list`.")
(wrap cat) `append def

### def chunk
(list size -- pieces :
 "Split `list` into consecutive `size`-width pieces, possibly including fewer than `size` elements
  in the last piece.")
(|xs k|
 k 0 > {kind domain msg "chunk size must be positive"} assert
 xs xs len k div xs len k mod 0 > + range k * cut) `chunk def

### def converges
(value (q: a -- a) -- list :
 "
  Construct a list containing `value` and the results of successive
  applications of `q`, until the result matches
   either `value` or the immediately preceding result.")
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
 cons
 unfold nip value swap cons) `converges def

### def fail
(msg -- : "Raise an error with the shape `{kind user msg msg}`.")
(wrap (kind user msg) swap cat dict.core.from-kvs raise) helper `fail def

### def iterations
(value count (q: a -- a) -- list :
 "Construct a list containing `value` and the results of `count` successive applications of `q`.")
(|value count quotation|
 value wrap count range value (pop) quotation cat scan cat) `iterations def

### def parse-one
(string -- x : "Parse source text describing exactly one form.")
(parse dup len 1 = {kind shape msg "parse-one requires exactly one form"} assert first) `parse-one
def

### def scan1
(list (q: acc a -- acc) -- list :
 "Fold `q` over `list`, using the first element of `list` as the accumulator and returning a list of
  each successive accumulator value.")
(|xs quotation| xs first wrap xs rest xs first quotation scan cat) `scan1 def

### def set
(... value name -- :
 "Bind `name` to `value` in the current scope. Accepts an optional annotation below `value` as
  metadata on the binding.")
(swap wrap swap def) `set def

### def setp
(... value name -- : "Inside of a module, bind `name` to `value` only within that module.")
(swap wrap swap defp) `setp def

### def to-digits
(value radices -- digits :
 "Split a value into one digit per radix, most significant first, by floor division, so every digit
  lies from zero below its radix even for negative values. A value beyond the radices' capacity
  keeps only its low digits. Values pervade.")
(|x rs|
 rs (dup type `int match? (0 >) (pop 0) if) all?
 {kind domain msg "to-digits radices must be positive integers"} assert
 rs reverse x [] pair
 (|st r|
  st 0 at r mod 0 < st r
  (|n st r| st 0 at r div n - st 0 at r mod n r * + wrap st 1 at cat pair) apply)
 fold 1 at) `to-digits def

### def unappend
(list -- initial last : "Split `list` into its initial elements and last element.")
(reverse uncons reverse swap) `unappend def

### def while-values
(value (p: state -- bool) (step: state -- state) -- list :
 "Construct a list containing `value` and successive states through the first state for which `p` is
  false.")
(|value predicate step|
 value predicate step (dup) cat unfold nip value swap cons) `while-values def

### def zip
(left right -- pairs : "Pair corresponding elements of conforming `left` and `right`.")
((pair) zip-with) `zip def

### def case
# Validate the clause container before inspecting any clause.
(x clauses -- ... :
 "Given a flat list of `case q` clauses, apply the first `q` whose `case` matches `x`.

  `clause` should be shaped:

     [case1 q1
      case2 q2
      ...
      else]

  Where `caseN` is a value to be compared against `x` with `match?`, and `qN` is the quotation to
  apply for the first case that matches. A matching action is called with `x` consumed.

  `else` is obligatory and is applied when no case matches, with `x` still on the stack.")
(dup type `list match?
 # A case table is [key action ... else]: nonempty and odd in length.
 (dup len dup 0 > swap 2 mod 1 = and
  ((|subject clauses|

    # The subject stays below the selected action; a matched key drops it
    # and the else quotation receives it.
    subject

    # Collect every action plus the mandatory else quotation. Running
    # `len pop` in isolation validates that each choice is a quotation
    # without executing user code.
    clauses dup len 2 div range 2 * 1 + at
    clauses last append
    dup (len pop) for

    # Search the even key slots. Find's length-on-miss result selects the
    # final else quotation when no key matched.
    clauses dup len 2 div range 2 * at
    subject find
    dup clauses len 2 div =
    rollup at
    swap (nip) unless
    apply)
   apply)
  (pop pop {kind shape msg "case requires a nonempty odd clause list ending in else"} raise)
  if)
 (pop pop {kind type msg "case expected a clause list"} raise)
 if) `case def

### def case-with
(x clauses (key: x -- k) -- ... :
 "Like `case`, but match the clause keys against the result of applying `key` to `x`, and apply the
  selected action with `x` itself on the stack.")
(|x clauses key| x x key apply clauses case) `case-with def

### def converge
(x (q: a -- a) -- y :
 "Return the last value before repeated application of `q` to `x` reaches a fixed point or matches
  `x`.")
(converges last) `converge def

### def from-digits
(digits base -- value :
 "Combine digits, most significant first, into a value. The base is one integer for every position,
  or a list of radices with one per digit, as in mixed-radix time; the first radix has no effect.
  Digits pervade: a list of equal-length digit lists, one per position, gives one value per
  column.")
(|ds base|
 ds base ds len base type `list match?
 (|b n| b len n = {kind shape msg "from-digits needs one radix per digit"} assert b)
 (|b n| b wrap n take)
 if
 zip 0 (|acc p| acc p 1 at * p 0 at +) fold) `from-digits def

### def retain
(... counts -- ... :
 "Keep each of the values beneath `counts` as many times as its count, in order: the first count
  applies to the deepest of them, and the values consumed are as many as `counts` holds. The stack
  form of `where at`.")
(|counts| counts len pack counts where at apply) `retain def
