### module dict
# Immutable, insertion-ordered dictionary operations. The host kernels live
# in `dict.core`; this module forwards them and composes the derived words
# from ordinary quotations.
[]
(
 ### def at-or
 (dict keys default -- values :
  "Look up each whole top-level key in order, preserving duplicates and using default for missing
   keys.")
 (dict.core.at-or) `at-or def

 ### def size
 (dict -- count : "Return a dictionary's entry count.")
 (dict.core.size) `size def

 ### def keys
 (dict -- keys : "Return a dictionary's keys in insertion order.")
 (dict.core.keys) `keys def

 ### def vals
 (dict -- values : "Return a dictionary's values in insertion order.")
 (dict.core.vals) `vals def

 ### def pairs
 (dict -- pairs : "Return key/value pairs in insertion order.")
 (dup dict.core.keys swap dict.core.vals zip) `pairs def

 ### def get
 (dict key default -- value :
  "Return the value of a whole-value key, or default when the dictionary has no such key.")
 (dict.core.get) `get def

 ### def has?
 (dict key -- bool : "Return whether a dictionary contains a whole-value key.")
 (dict.core.has?) `has? def

 ### def at
 (dict keys -- values :
  "Look up each whole top-level key in request order, failing if any key is absent.")
 (dict.core.at) `at def

 ### def merge
 (left right -- dict : "Merge two dictionaries, with right-hand values winning.")
 (dict.core.merge) `merge def

 ### def associate
 (value key -- dict : "Build a one-entry dictionary associating the key with the value.")
 (dict.core.associate) `associate def

 ### def from-flat
 (entries -- dict : "Build a dictionary from one flat adjacent key/value list.")
 (dict.core.from-flat) `from-flat def

 ### def from-lists
 (keys values -- dict : "Build a dictionary from parallel key and value lists.")
 (dict.core.from-lists) `from-lists def

 ### def from-pairs
 (pairs -- dict : "Build a dictionary from distinct two-element key/value pairs in list order.")
 (dup type `list match?
  (dup (dup type `list match? (len 2 =) (pop 0) if) all?
   (raze dict.core.from-flat)
   (pop `shape error.new "dict.from-pairs expects two-element pairs" error.with-message raise)
   if)
  (pop `type error.new "dict.from-pairs expects a list" error.with-message raise)
  if) `from-pairs def

 ### def from-keys
 (keys value -- dict : "Build a dictionary assigning one value to every distinct key.")
 (|keys value| keys keys value (nip) partial each dict.core.from-lists) `from-keys def

 ### def keys-exactly?
 (candidate declared -- bool :
  "Test whether a dictionary has exactly the distinct declared keys, in any order.")
 (|candidate declared|
  candidate dict.core.keys len declared len =
  declared distinct len declared len = and
  declared candidate (swap dict.core.has?) partial all? and) `keys-exactly? def

 ### def put
 (dict key value -- dict : "Assign one whole key and value; replace in place or append a new key.")
 (dict.core.put) `put def

 ### def update
 (dict keys quotation -- dict :
  "Update whole top-level keys in request order, validating all keys before applying the
   quotation.")
 (dict.core.update) `update def

 ### def update-or
 (dict key default quotation -- dict :
  "Update an existing value, or insert the default unchanged when absent.")
 (|d key default transform|
  d key
  d key default dict.core.get transform
  d key dict.core.has? (call) (pop) if
  core.put) `update-or def

 ### def map
 (dict quotation -- dict :
  "Map a ( key value -- value ) quotation while preserving keys and order.")
 (|d transform|
  d dict.core.keys
  d pairs transform ((dup first swap 1 wrap at-path) dip call) partial each
  dict.core.from-lists) `map def

 ### def filter
 (dict predicate -- dict : "Keep entries selected by a ( key value -- bool ) predicate.")
 (|d predicate|
  d pairs dup predicate ((dup first swap 1 wrap at-path) dip call) partial each
  where wrap at-path from-pairs) `filter def

 ### def reject
 (dict predicate -- dict : "Discard entries selected by a ( key value -- bool ) predicate.")
 (|d predicate|
  d pairs dup predicate ((dup first swap 1 wrap at-path) dip call not) partial each
  where wrap at-path from-pairs) `reject def

 ### def take
 (dict keys -- dict : "Keep named entries in dictionary order, ignoring missing keys.")
 (dict.core.take) `take def

 ### def del
 (dict keys -- dict :
  "Remove whole top-level keys, ignoring missing keys and preserving dictionary order.")
 (dict.core.del) `del def

 ### def split
 (dict keys -- selected rejected : "Partition a dictionary by a key list.")
 (|d keys| d keys dict.core.take d keys dict.core.del) `split def

 ### def merge-with
 (left right quotation -- dict :
  "Merge dictionaries and resolve collisions with ( key left right -- value ).")
 (dict.core.merge-with) `merge-with def
) `dict @defm
