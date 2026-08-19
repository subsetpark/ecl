### def compose
(cat dup len 0 = (pop ()) when)
(left right -- quotation : "Concatenate two quotations in execution order.")
'compose def

### def first
(dup len pop 0 at)
(list -- value : "Return the first element of a nonempty list.")
'first def

### def wrap
(() cons)
(value -- list : "Wrap one value in a one-element list.")
'wrap def

### def literal
(wrap (first) cons)
(value -- quotation : "Return a quotation that pushes the exact value as inert data when called.")
'literal def

### def dip
(swap literal compose call)
(: "Run a quotation beneath a protected top stack value.")
'dip def

### def over
(swap dup (swap) dip)
(x y -- x y x : "Copy the value beneath the top of the stack onto the top.")
'over def

### def partial
(swap literal swap compose)
(value quotation -- quotation :
 "Return a quotation that pushes an inert captured value before running another quotation.")
'partial def

### def with
(((literal) each) dip append raze)
(values quotation -- quotation :
 "Return a quotation that pushes every value from a list, in order and inertly, before running
  another quotation.

  This is how a unit constructor is seeded: an @ word gives its quotation a fresh stack, so values
  (q) with @attempt, values (q) with @spawn, and values (body) with 'name @module hand that unit
  exactly the values the caller chose to pass.")
'with def

### def str
(wrap "{}" format)
(value -- string : "Return the canonical printed representation of a value as a string.")
'str def

### def mod
(over over div * -)
(x y -- z : "Compute checked integer remainders pervasively.")
'mod def

### def neg
(-1 *)
(x -- y : "Negate numeric values pervasively with checked integer overflow.")
'neg def

### def abs
(dup neg 0 + swap max)
(x -- y : "Return absolute numeric values pervasively with checked integer overflow.")
'abs def

### def <>
(= not)
(x y -- bool : "Compare conforming values for pervasive inequality, producing boolean masks.")
'<> def

### def <=
(> not)
(x y -- bool : "Compare conforming values pervasively for less-than-or-equal order.")
'<= def

### def >=
(< not)
(x y -- bool : "Compare conforming values pervasively for greater-than-or-equal order.")
'>= def

### def and
((not not) dip not not min)
(x y -- bool : "Compute boolean conjunction pervasively over 0 and 1 values.")
'and def

### def or
((not not) dip not not max)
(x y -- bool : "Compute boolean disjunction pervasively over 0 and 1 values.")
'or def

### def nip
(swap pop)
(x y -- y : "Discard the value immediately beneath the top of the stack.")
'nip def

### def keep
(over (call) dip)
(: "Apply a quotation while preserving its input beneath the quotation's results.")
'keep def

### def bi
((keep) dip call)
(: "Apply two quotations to the same input, leaving the first quotation's results before the
    second's.")
'bi def

### def tri
(((keep) dip keep) dip call)
(: "Apply three quotations to the same input in left-to-right order.")
'tri def

### def bi2
(|x y p q| x y p call x y q call)
(: "Apply each of two quotations to the same pair of input values.")
'bi2 def

### def both
(|x y q| x q call y q call)
(: "Apply one quotation independently to each of two input values.")
'both def

### def when
(() if)
(: "Call a quotation when the condition is the boolean 1; otherwise do nothing.")
'when def

### def unless
(() swap if)
(: "Call a quotation when the condition is the boolean 0; otherwise do nothing.")
'unless def

### def case
# Validate the clause container before inspecting any clause.
(dup type 'list match
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
    subject (match) partial each 1 find at call)
   call)
  (pop pop {'kind 'shape 'msg "case requires a nonempty odd clause list ending in else"} raise)
  if)
 (pop pop {'kind 'type 'msg "case expected a clause list"} raise)
 if)
(: "Select and call the first quotation whose key matches the subject.

    The clause list has the form [key action ... else]. Every action and the final else value must
    be a quotation. Keys remain inert data, and all choices are validated before any user quotation
    runs.")
'case def

### def signum
(dup 0 > swap 0 < -)
(number -- sign : "Return -1, 0, or 1 according to the sign of a number.")
'signum def

### def clamp
((max) dip min)
(value lower upper -- bounded :
 "Constrain a value to the inclusive interval between lower and upper.")
'clamp def

### def last
(dup len 1 - at)
(sequence -- value : "Return the final element of a nonempty sequence.")
'last def

### def pair
(() cons cons)
(first second -- list : "Collect two stack values into a two-element list in stack order.")
'pair def

### def pack
(() swap (cons) times)
(: "Collect the requested number of preceding stack values into a list, preserving their order.")
'pack def

### def append
(wrap cat)
(sequence value -- sequence : "Append one value to the end of a sequence.")
'append def

### def rest
(dup first pop 1 drop)
(list -- list : "Return all but the first element of a nonempty list.")
'rest def

### def reverse
(dup len dup 0 =
 (pop)
 (dup range swap 1 - swap - at)
 if)
(list -- list : "Return a list with its top-level element order reversed.")
'reverse def

### def uncons
(dup first swap rest)
(list -- first rest : "Split a nonempty list into its first element and remaining elements.")
'uncons def

### def unappend
(reverse uncons reverse swap)
(list -- initial last : "Split a nonempty list into its initial elements and last element.")
'unappend def

### def empty?
(len 0 =)
(sequence -- bool : "Return true when a sequence has no elements.")
'empty? def

### def zip
((pair) zip-with)
(left right -- pairs : "Pair corresponding elements from two conforming sequences.")
'zip def

### def min-of
(dup first (min) fold)
(sequence -- value : "Return the least element of a nonempty sequence.")
'min-of def

### def max-of
(dup first (max) fold)
(sequence -- value : "Return the greatest element of a nonempty sequence.")
'max-of def

### def sort
(dup grade at)
(sequence -- sorted : "Return a stably ascending permutation of a sequence.")
'sort def

### def distinct
(group keys)
(list -- list : "Return the first occurrence of each distinct list value in input order.")
'distinct def

### def at-path
(swap (at) fold)
(ds l -- x : "Look up each key or index in a path from left to right.")
'at-path def

### def vals
(dup keys swap (swap at) partial each)
(dict -- values : "Return a dictionary's values in insertion order.")
'vals def

### def at-or
(|d k default| d k default d k has? (pop at) (nip nip) if)
(collection key default -- value :
 "Look up a key or index, returning a fallback value when lookup fails.")
'at-or def

### def pairs
(dup keys swap vals zip)
(dict -- pairs : "Return a dictionary's entries as key/value pairs in dictionary order.")
'pairs def

### def filter
(over swap each where at)
(sequence predicate -- matches :
 "Apply a predicate to every element, retaining each element as many times as its returned
  non-negative integer count.")
'filter def

### def partition
(|l q| l q each l over where at swap not l swap where at)
(sequence predicate -- matches rejects : "Split a sequence into matching and nonmatching elements.")
'partition def

### def any?
(|l q| l q each 0 (or) fold)
(sequence predicate -- bool :
 "Return 1 when a predicate returns 1 for at least one element; otherwise return 0.")
'any? def

### def all?
(|l q| l q each 1 (and) fold)
(sequence predicate -- bool :
 "Return 1 when a predicate returns 1 for every element; otherwise return 0.")
'all? def

### def sum
(0 (+) fold)
(sequence -- total : "Add every element of a numeric sequence, using zero for an empty sequence.")
'sum def

### def prod
(1 (*) fold)
(sequence -- product :
 "Multiply every element of a numeric sequence, using one for an empty sequence.")
'prod def

### def mean
(dup sum swap len /)
(sequence -- mean : "Return the arithmetic mean of a nonempty numeric sequence.")
'mean def

### def print
(prin "\n" prin)
(text -- : "Print a string followed by a newline.")
'print def

### def inspect
(dup pp)
(value -- value : "Pretty-print a value while leaving the original value on the stack.")
'inspect def

### def fail
(wrap ('kind 'user 'msg) swap compose dict-of raise)
(: "Raise a user-kind error whose message is the supplied value.")
'fail def

### def find
(|sequence needle| sequence needle (match) partial each dup where swap len swap dup len 0 =
 (pop)
 (first nip)
 if)
(sequence needle -- index :
 "Return the first matching index, or the sequence length when no element matches.")
'find def

### def await-all
((await) each)
(tasks -- results : "Wait for every task and return its result in input order.")
'await-all def

### def set
(swap literal swap def)
(value name -- : "Bind a value as a constant word in the current scope.")
'set def

### def setp
(swap literal swap defp)
(value name -- : "Bind a private module value as a constant word.")
'setp def

### def assert
(swap (pop) (raise) if)
(bool error -- :
 "Raise an error dict unless the condition is the boolean 1, discarding the dict when it holds.")
'assert def

### def lines
(slurp "\n" split)
(path -- list : "Read one UTF-8 file and split it into its newline-separated lines.")
'lines def

### def rotate
(|xs n| xs dup len range n + dup len mod dup len + dup len mod at)
(list count -- rotated :
 "Rotate a list left by a count, wrapping cyclically; a negative count rotates right and an empty
  list is returned unchanged.")
'rotate def
