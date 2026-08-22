### def compose
(left right -- quotation : "Concatenate two quotations in execution order.")
(cat dup len 0 = (pop ()) when)
'compose def

### def first
(list -- value : "Return the first element of a nonempty list.")
(dup len pop 0 at)
'first def

### def wrap
(value -- list : "Wrap one value in a one-element list.")
(() cons)
'wrap def

### def literal
(value -- quotation : "Return a quotation that pushes the exact value as inert data when called.")
(wrap (first) cons)
'literal def

### def dip
(: "Run a quotation beneath a protected top stack value.")
(swap literal compose call)
'dip def

### def over
(x y -- x y x : "Copy the value beneath the top of the stack onto the top.")
(swap dup (swap) dip)
'over def

### def partial
(value quotation -- quotation :
 "Return a quotation that pushes an inert captured value before running another quotation.")
(swap literal swap compose)
'partial def

### def with
(values quotation -- quotation :
 "Return a quotation that pushes every value from a list, in order and inertly, before running
  another quotation.

  This is how a unit constructor is seeded: an @ word gives its quotation a fresh stack, so values
  (q) with @attempt, values (q) with @spawn, and values (body) with 'name @defm hand that unit
  exactly the values the caller chose to pass.")
(((literal) each) dip append raze)
'with def

### def mod
(x y -- z : "Compute checked integer remainders pervasively.")
(over over div * -)
'mod def

### def neg
(x -- y : "Negate numeric values pervasively with checked integer overflow.")
(-1 *)
'neg def

### def abs
(x -- y : "Return absolute numeric values pervasively with checked integer overflow.")
(dup neg 0 + swap max)
'abs def

### def <>
(x y -- bool : "Compare conforming values for pervasive inequality, producing boolean masks.")
(= not)
'<> def

### def <=
(x y -- bool : "Compare conforming values pervasively for less-than-or-equal order.")
(> not)
'<= def

### def >=
(x y -- bool : "Compare conforming values pervasively for greater-than-or-equal order.")
(< not)
'>= def

### def and
(x y -- bool : "Compute boolean conjunction pervasively over 0 and 1 values.")
((not not) dip not not min)
'and def

### def or
(x y -- bool : "Compute boolean disjunction pervasively over 0 and 1 values.")
((not not) dip not not max)
'or def

### def nip
(x y -- y : "Discard the value immediately beneath the top of the stack.")
(swap pop)
'nip def

### def keep
(: "Apply a quotation while preserving its input beneath the quotation's results.")
(over (call) dip)
'keep def

### def bi
(: "Apply two quotations to the same input, leaving the first quotation's results before the
    second's.")
((keep) dip call)
'bi def

### def tri
(: "Apply three quotations to the same input in left-to-right order.")
(((keep) dip keep) dip call)
'tri def

### def bi2
(: "Apply each of two quotations to the same pair of input values.")
(|x y p q| x y p call x y q call)
'bi2 def

### def both
(: "Apply one quotation independently to each of two input values.")
(|x y q| x q call y q call)
'both def

### def when
(: "Call a quotation when the condition is the boolean 1; otherwise do nothing.")
(() if)
'when def

### def unless
(: "Call a quotation when the condition is the boolean 0; otherwise do nothing.")
(() swap if)
'unless def

### def case
# Validate the clause container before inspecting any clause.
(: "Select and call the first quotation whose key matches the subject.

    The clause list has the form [key action ... else]. Every action and the final else value must
    be a quotation. Keys remain inert data, and all choices are validated before any user quotation
    runs.")
(dup type 'list match?
 # A case table is [key action ... else]: nonempty and odd in length.
 (dup len dup 0 > swap 2 mod 1 = and
  ((|subject clauses|

    # Collect every action plus the mandatory else quotation. Running
    # `len pop` in isolation validates that each choice is a quotation
    # without executing user code.
    clauses dup len 2 div range 2 * 1 + at
    clauses last append
    dup (len pop) for

    # Extract the even key slots, compare the captured subject with each,
    # and let find's len-on-miss result select the final else quotation.
    clauses dup len 2 div range 2 * at
    subject (match?) partial each 1 find at call)
   call)
  (pop pop {'kind 'shape 'msg "case requires a nonempty odd clause list ending in else"} raise)
  if)
 (pop pop {'kind 'type 'msg "case expected a clause list"} raise)
 if)
'case def

### def signum
(number -- sign : "Return -1, 0, or 1 according to the sign of a number.")
(dup 0 > swap 0 < -)
'signum def

### def clamp
(value lower upper -- bounded :
 "Constrain a value to the inclusive interval between lower and upper.")
((max) dip min)
'clamp def

### def last
(sequence -- value : "Return the final element of a nonempty sequence.")
(dup len 1 - at)
'last def

### def pair
(first second -- list : "Collect two stack values into a two-element list in stack order.")
(() cons cons)
'pair def

### def pack
(: "Collect the requested number of preceding stack values into a list, preserving their order.")
(() swap (cons) times)
'pack def

### def append
(sequence value -- sequence : "Append one value to the end of a sequence.")
(wrap cat)
'append def

### def rest
(list -- list : "Return all but the first element of a nonempty list.")
(dup first pop 1 drop)
'rest def

### def reverse
(list -- list : "Return a list with its top-level element order reversed.")
(dup len dup 0 =
 (pop)
 (dup range swap 1 - swap - at)
 if)
'reverse def

### def uncons
(list -- first rest : "Split a nonempty list into its first element and remaining elements.")
(dup first swap rest)
'uncons def

### def unappend
(list -- initial last : "Split a nonempty list into its initial elements and last element.")
(reverse uncons reverse swap)
'unappend def

### def empty?
(sequence -- bool : "Return true when a sequence has no elements.")
(len 0 =)
'empty? def

### def zip
(left right -- pairs : "Pair corresponding elements from two conforming sequences.")
((pair) zip-with)
'zip def

### def lex-cmp
(left right comparator -- order :
 "Compare two sequences lexicographically. The comparator runs only through the first differing
  pair; a shared prefix is ordered by sequence length.")
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
 call)
'lex-cmp def

### def min-of
(sequence -- value : "Return the least element of a nonempty sequence.")
(dup first (min) fold)
'min-of def

### def max-of
(sequence -- value : "Return the greatest element of a nonempty sequence.")
(dup first (max) fold)
'max-of def

### def sort
(sequence -- sorted : "Return a stably ascending permutation of a sequence.")
(dup grade at)
'sort def

### def distinct
(list -- list : "Return the first occurrence of each distinct list value in input order.")
(group keys)
'distinct def

### def at-path
(ds l -- x : "Look up each key or index in a path from left to right.")
(swap (at) fold)
'at-path def

### def vals
(dict -- values : "Return a dictionary's values in insertion order.")
(dup keys swap (swap at) partial each)
'vals def

### def keys-exactly?
(candidate declared -- bool : "Test whether a dict has exactly the declared keys, in any order.")
(|candidate declared|
 candidate keys len declared len =
 declared distinct len declared len =
 and
 declared candidate (swap has?) partial all?
 and)
'keys-exactly? def

### def at-or
(collection key default -- value :
 "Look up a key or index, returning a fallback value when lookup fails.")
(|d k default| d k default d k has? (pop at) (nip nip) if)
'at-or def

### def pairs
(dict -- pairs : "Return a dictionary's entries as key/value pairs in dictionary order.")
(dup keys swap vals zip)
'pairs def

### def filter
(sequence predicate -- matches :
 "Apply a predicate to every element, retaining each element as many times as its returned
  non-negative integer count.")
(over swap each where at)
'filter def

### def partition
(sequence predicate -- matches rejects : "Split a sequence into matching and nonmatching elements.")
(|l q| l q each l over where at swap not l swap where at)
'partition def

### def any?
(sequence predicate -- bool :
 "Return 1 when a predicate returns 1 for at least one element; otherwise return 0.")
(|l q| l q each 0 (or) fold)
'any? def

### def all?
(sequence predicate -- bool :
 "Return 1 when a predicate returns 1 for every element; otherwise return 0.")
(|l q| l q each 1 (and) fold)
'all? def

### def sum
(sequence -- total : "Add every element of a numeric sequence, using zero for an empty sequence.")
(0 (+) fold)
'sum def

### def prod
(sequence -- product :
 "Multiply every element of a numeric sequence, using one for an empty sequence.")
(1 (*) fold)
'prod def

### def mean
(sequence -- mean : "Return the arithmetic mean of a nonempty numeric sequence.")
(dup sum swap len /)
'mean def

### def fail
(: "Raise a user-kind error whose message is the supplied value.")
(wrap ('kind 'user 'msg) swap compose dict-of raise)
'fail def

### def find
(sequence needle -- index :
 "Return the first matching index, or the sequence length when no element matches.")
((match?) partial each dup where swap len swap dup len 0 =
 (pop)
 (first nip)
 if)
'find def

### def await-all
(tasks -- results : "Wait for every task and return its result in input order.")
((await) each)
'await-all def

### def set
(: "Bind a value as a constant word in the current scope; an optional annotation may precede the
    value.")
(swap literal swap def)
'set def

### def setp
(: "Bind a private module value as a constant word; an optional annotation may precede the value.")
(swap literal swap defp)
'setp def

### def assert
(bool error -- :
 "Raise an error dict unless the condition is the boolean 1, discarding the dict when it holds.")
(swap (pop) (raise) if)
'assert def

### def rotate
(list count -- rotated :
 "Rotate a list left by a count, wrapping cyclically; a negative count rotates right and an empty
  list is returned unchanged.")
(|xs n| xs dup len range n + dup len mod dup len + dup len mod at)
'rotate def

### def windows
(list width -- windows : "Return every overlapping window of a positive width.")
(() stencil)
'windows def

### def each-prior
(list seed quotation -- list :
 "Apply a binary quotation to each element and its predecessor, using the explicit seed before the
  first element.")
(|xs seed quotation| xs seed xs cons -1 drop quotation zip-with)
'each-prior def

### def fold1
(list quotation -- value :
 "Reduce a nonempty list from its first element rather than from an explicit accumulator.")
(|xs quotation| xs uncons swap quotation fold)
'fold1 def

### def scan1
(list quotation -- list :
 "Return a nonempty list's first element followed by successive accumulator values from reducing its
  remaining elements.")
(|xs quotation| xs first wrap xs rest xs first quotation scan cat)
'scan1 def

### def iterations
(value count quotation -- list :
 "Return the initial value followed by a nonnegative number of successive quotation applications.")
(|value count quotation|
 value wrap count range value (pop) quotation compose scan cat)
'iterations def

### def while-values
(value predicate step -- list :
 "Return the initial value and successive states through the first state for which the predicate is
  false.")
(|value predicate step|
 value predicate step (dup) compose unfold nip value swap cons)
'while-values def

### def converges
(value quotation -- list :
 "Return successive unary quotation applications until the next value equals either the initial or
  immediately preceding value, without repeating that boundary value.")
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
 unfold nip value swap cons)
'converges def

### def converge
(value quotation -- value : "Return the last value before unary iteration converges or cycles.")
(converges last)
'converge def
