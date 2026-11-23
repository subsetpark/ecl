### module dict
(: "Operations on the primitive dict type.")
(
 `dict.core
 [at-or size keys vals get at merge associate from-kvs zip put update take del
  merge-with] import

 ### def has?
 (dict keys -- bools : "Test each element of `keys` for membership in `dict`.")
 (|d requested|
  requested type `list match?
  (`type error.new "dict.has? expects a list of keys" error.with-message raise)
  unless
  requested d (swap dict.core.has?) cons each) `has? def

 ### def in?
 (keys dict -- bools : "Test each element of `keys` for membership in `dict`.")
 (|requested d| d requested has?) `in? def

 ### def of
 (keys dict -- values : "Return a list indexing into `dict` for each element of `keys`.")
 (|keys d| d keys dict.core.at) `of def

 ### def pairs
 (dict -- pairs :
  "Return the entries of `dict` as a list of `[key value]` pairs, in `dict.keys` order.")
 (dup dict.core.keys swap dict.core.vals core.zip) `pairs def

 ### def from-pairs
 (pairs -- dict : "Construct a dictionary from a list of `[key value]` pairs.")
 (dup type `list match?
  (dup (dup type `list match? (len 2 =) (pop 0) if) all?
   (raze dict.core.from-kvs)
   (pop `shape error.new "dict.from-pairs expects two-element pairs" error.with-message raise)
   if)
  (pop `type error.new "dict.from-pairs expects a list" error.with-message raise)
  if) `from-pairs def

 ### def from-keys
 (keys value -- dict : "Construct a dictionary mapping each element of `keys` to `value`.")
 (|keys value| keys keys value (nip) cons each dict.core.zip) `from-keys def

 ### def keys-exactly?
 (candidate declared -- bool :
  "Return 1 when a dictionary has exactly the declared keys in any order, 0 otherwise.")
 (|candidate declared|
  candidate dict.core.keys len declared len =
  declared distinct len declared len = and
  declared candidate (swap dict.core.has?) cons all? and) `keys-exactly? def

 ### def update-or
 (dict key default quotation -- dict :
  "If `key` is in `dict`, apply `quotation` to its value. Otherwise, map `key` to `default`.")
 (|d key default transform|
  d key
  d key default dict.core.get transform
  d key dict.core.has? (apply) (pop) if
  core.put) `update-or def

 ### def map
 (dict (q: key value -- value) -- dict :
  "Construct a dict from `dict`, applying `q` to each `key value` entry and assigning the result to
   `key`.")
 (|d transform|
  d dict.core.keys
  d pairs transform ((dup first swap 1 wrap at-path) dip apply) cons each
  dict.core.zip) `map def

 ### def evolve
 (dict spec -- dict :
  "Apply each `( value -- value )` quotation in `spec` to the value under the same key in `dict`. A
   key of `spec` missing from `dict` is `` `domain ``.")
 (pairs swap (|d pair| d pair first pair 1 core.at core.update) fold) `evolve def

 ### def filter
 (dict (p: key value -- bool) -- dict :
  "Apply `p` to every entry of `dict` and retain the entries for which it returns 1.")
 (|d predicate|
  d pairs dup predicate ((dup first swap 1 wrap at-path) dip apply) cons each
  where wrap at-path from-pairs) `filter def

 ### def reject
 (dict (p: key value -- bool) -- dict :
  "Apply `p` to every entry of `dict` and discard the entries for which it returns 1.")
 (|d predicate| d predicate (not) cat dict.filter) `reject def

 ### def split
 (dict keys -- selected rejected :
  "Partition `dict` by `keys`, returning dictionary with every selected key followed by the
   remainder dictionary.")
 (|d keys| d keys dict.core.take d keys dict.core.del) `split def

) `dict @defm
