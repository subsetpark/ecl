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
(: "Call a quotation when the condition is truthy; otherwise do nothing.")
'when def

### def unless
(() swap if)
(: "Call a quotation when the condition is falsey; otherwise do nothing.")
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
    subject literal (match) compose each 1 find at call)
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

### def wrap
(() cons)
(value -- list : "Wrap one value in a one-element list.")
'wrap def

### def literal
(wrap (first) cons)
(value -- quotation : "Return a quotation that pushes the exact value as inert data when called.")
'literal def

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

### def empty?
(len 0 =)
(sequence -- bool : "Return true when a sequence has no elements.")
'empty? def

### def zip
((pair) each2)
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
 "Keep the elements for which a predicate quotation returns truthy.")
'filter def

### def partition
(|l q| l q each l over where at swap not l swap where at)
(sequence predicate -- matches rejects : "Split a sequence into matching and nonmatching elements.")
'partition def

### def any?
(|l q| l q each 0 (or) fold)
(sequence predicate -- bool : "Return true when a predicate is truthy for at least one element.")
'any? def

### def all?
(|l q| l q each 1 (and) fold)
(sequence predicate -- bool : "Return true when a predicate is truthy for every element.")
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

### def ok?
('ok has?)
(outcome -- bool : "Return true when an attempt outcome represents success.")
'ok? def

### def or-raise
(dup 'ok has? ('ok at) ('err at raise) if)
(outcome -- results : "Return an attempt's result list, or re-raise its captured error unchanged.")
'or-raise def

### def or-else
(over 'ok has? (pop 'ok at) (nip) if)
(outcome fallback -- value :
 "Return an attempt's result list on success, or the fallback value on failure.")
'or-else def

### def find
(|sequence needle| sequence needle literal (match) compose each dup where swap len swap dup len 0 =
 (pop)
 (first nip)
 if)
(sequence needle -- index :
 "Return the first matching index, or the sequence length when no element matches.")
'find def

### def par-each
(|l q|
 l type 'list match ({'kind 'type 'msg "par-each expected a list"} raise) unless
 q type 'list match ({'kind 'type 'msg "par-each expected a quotation"} raise) unless
 l (literal) q literal compose (compose spawn) compose each
 task-join)
(sequence quotation -- results :
 "Apply a quotation concurrently to every element and return one result per element in input order.")
'par-each def
