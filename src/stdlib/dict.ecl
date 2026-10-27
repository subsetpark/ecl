### module dict
# Immutable, insertion-ordered dictionary operations. The host kernels live
# in `dict.core`; this module forwards them and composes the derived words
# from ordinary quotations.
[]
(
 ### def at-or
 (dict keys default -- values :
  "Like `dict.at`, using `default` as a whole value for each missing key.")
 (dict.core.at-or) `at-or def

 ### def size
 (dict -- count : "Return the dictionary's entry count.")
 (dict.core.size) `size def

 ### def keys
 (dict -- keys : "Return keys in insertion order.")
 (dict.core.keys) `keys def

 ### def vals
 (dict -- values : "Return values in insertion order.")
 (dict.core.vals) `vals def

 ### def pairs
 (dict -- pairs :
  "Return insertion-ordered `[key value]` pairs. This is the bridge to generic entry iteration when
   keys are needed. Value-only `each` operates on a dictionary directly; reductions and predicates
   can consume `dict.vals`, so they need no dictionary-specific duplicates.")
 (dup dict.core.keys swap dict.core.vals zip) `pairs def

 ### def get
 (dict key default -- value :
  "The value of one whole-value key, or `default` when the dictionary has no such key. A
   non-dictionary is `` `type ``.")
 (dict.core.get) `get def

 ### def has?
 (dict key -- bool :
  "Whole-value key membership. Keys are inert and only absence is false: lookup machinery failures
   are errors, never converted to 0.")
 (dict.core.has?) `has? def

 ### def at
 (dict keys -- values :
  "Look up each top-level key in request order, preserving duplicates. An absent key is `` `domain
   ``. Strings and composite keys are whole values; the result has one element per requested key.")
 (dict.core.at) `at def

 ### def merge
 (left right -- dict :
  "Merge two dictionaries; right-hand values win. Existing left keys retain their positions and
   right-only keys append in right order. Key-aligned arithmetic remains pervasive `+` on dicts.")
 (dict.core.merge) `merge def

 ### def associate
 (value key -- dict : "Build a one-entry dictionary associating `key` with `value`.")
 (dict.core.associate) `associate def

 ### def from-flat
 (entries -- dict :
  "Build a dictionary from one flat, even-length list by pairing adjacent entries without executing
   them. This is the runtime counterpart of the `{…}` literal: `` `total 3 4 + pair dict.from-flat
   `` is `{total 7}`. An odd entry count is `` `contract ``; duplicate keys are `` `domain ``.")
 (dict.core.from-flat) `from-flat def

 ### def from-lists
 (keys values -- dict :
  "Build a dictionary from parallel conforming key and value lists. Unequal lengths are `` `shape
   ``; duplicate keys are `` `domain ``.")
 (dict.core.from-lists) `from-lists def

 ### def from-pairs
 (pairs -- dict :
  "Build a dictionary from a list of exact `[key value]` pairs in list order. A malformed pair is ``
   `shape ``; duplicate keys are `` `domain ``.")
 (dup type `list match?
  (dup (dup type `list match? (len 2 =) (pop 0) if) all?
   (raze dict.core.from-flat)
   (pop `shape error.new "dict.from-pairs expects two-element pairs" error.with-message raise)
   if)
  (pop `type error.new "dict.from-pairs expects a list" error.with-message raise)
  if) `from-pairs def

 ### def from-keys
 (keys value -- dict :
  "Build a dictionary assigning one value to every distinct key. Duplicate keys are `` `domain ``.")
 (|keys value| keys keys value (nip) partial each dict.core.from-lists) `from-keys def

 ### def keys-exactly?
 (candidate declared -- bool :
  "Return 1 when a dictionary has exactly the declared keys in any order. A duplicate declaration
   returns 0.")
 (|candidate declared|
  candidate dict.core.keys len declared len =
  declared distinct len declared len = and
  declared candidate (swap dict.core.has?) partial all? and) `keys-exactly? def

 ### def put
 (dict key value -- dict :
  "Assign one whole key and value. An existing key retains its position; a new key appends at the
   end.")
 (dict.core.put) `put def

 ### def update
 (dict keys quotation -- dict :
  "Apply an isolated `( value -- value )` quotation to each whole top-level key without moving
   entries. Keys are processed in request order, so duplicates observe earlier updates. All keys are
   validated before the quotation is first applied; an absent key is `` `domain ``, and an empty key
   list returns the dictionary unchanged.")
 (dict.core.update) `update def

 ### def update-or
 (dict key default quotation -- dict :
  "Update an existing value as `update` does, or append the absent key with the default unchanged.
   The default does not pass through the quotation.")
 (|d key default transform|
  d key
  d key default dict.core.get transform
  d key dict.core.has? (call) (pop) if
  core.put) `update-or def

 ### def map
 (dict quotation -- dict :
  "Call a `( key value -- value )` quotation for every entry, replacing values while preserving keys
   and insertion order.")
 (|d transform|
  d dict.core.keys
  d pairs transform ((dup first swap 1 wrap at-path) dip call) partial each
  dict.core.from-lists) `map def

 ### def filter
 (dict predicate -- dict :
  "Call a `( key value -- bool )` predicate in insertion order and retain the entries for which it
   returns 1.")
 (|d predicate|
  d pairs dup predicate ((dup first swap 1 wrap at-path) dip call) partial each
  where wrap at-path from-pairs) `filter def

 ### def reject
 (dict predicate -- dict :
  "Call a `( key value -- bool )` predicate in insertion order and discard the entries for which it
   returns 1.")
 (|d predicate|
  d pairs dup predicate ((dup first swap 1 wrap at-path) dip call not) partial each
  where wrap at-path from-pairs) `reject def

 ### def take
 (dict keys -- dict :
  "Keep entries named by a key list, ignoring absent keys. Output follows dictionary order
   independently of the requested key-list order.")
 (dict.core.take) `take def

 ### def del
 (dict keys -- dict :
  "Remove entries named by whole top-level keys, ignoring absent and duplicate keys and preserving
   retained dictionary order.")
 (dict.core.del) `del def

 ### def split
 (dict keys -- selected rejected :
  "Partition a dictionary by a key list, returning selected then rejected entries; ignore absent
   keys and preserve dictionary order in both results.")
 (|d keys| d keys dict.core.take d keys dict.core.del) `split def

 ### def merge-with
 (left right quotation -- dict :
  "Merge two dictionaries, resolving each shared key with `( key left-value right-value -- value )`.
   Existing left keys keep their positions; right-only keys append in right order.")
 (dict.core.merge-with) `merge-with def
) `dict @defm
