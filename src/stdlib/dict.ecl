### module dict
(: "These operations preserve the language's immutable, insertion-ordered dictionary semantics. The
    constructor family accepts one key/value association, flat adjacent entries, parallel key/value
    lists, association lists, or one shared value for a key list. All constructors reject duplicate
    keys instead of silently choosing a winner. Core `at`, `put`, `update`, and `del` treat a
    dictionary selector as one whole-value key. `dict.put` also assigns one whole key and value.
    Batch operations `dict.at`, `dict.at-or`, `dict.update`, `dict.take`, `dict.del`, and
    `dict.split` consume a list of whole keys: strings and composite keys remain atomic. The public
    `dict` module is ECL over the host kernels exported by `dict.core`, so a failure inside a kernel
    reports its `dict.core` name.")
(
 `dict.core
 [at-or size keys vals get has? at merge associate from-flat from-lists put update take del
  merge-with] import

 ### def pairs
 (dict -- pairs :
  "Return insertion-ordered `[key value]` pairs. This is the bridge to generic entry iteration when
   keys are needed. Value-only `each` operates on a dictionary directly; reductions and predicates
   can consume `dict.vals`, so they need no dictionary-specific duplicates.")
 (dup dict.core.keys swap dict.core.vals zip) `pairs def

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
 (|keys value| keys keys value (nip) cons each dict.core.from-lists) `from-keys def

 ### def keys-exactly?
 (candidate declared -- bool :
  "Return 1 when a dictionary has exactly the declared keys in any order. A duplicate declaration
   returns 0.")
 (|candidate declared|
  candidate dict.core.keys len declared len =
  declared distinct len declared len = and
  declared candidate (swap dict.core.has?) cons all? and) `keys-exactly? def

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
 (dict (key value -- value) -- dict :
  "Call the quotation for every entry, replacing values while preserving keys and insertion order.")
 (|d transform|
  d dict.core.keys
  d pairs transform ((dup first swap 1 wrap at-path) dip call) cons each
  dict.core.from-lists) `map def

 ### def filter
 (dict (key value -- bool) -- dict :
  "Call the predicate in insertion order and retain the entries for which it returns 1.")
 (|d predicate|
  d pairs dup predicate ((dup first swap 1 wrap at-path) dip call) cons each
  where wrap at-path from-pairs) `filter def

 ### def reject
 (dict (key value -- bool) -- dict :
  "Call the predicate in insertion order and discard the entries for which it returns 1.")
 (|d predicate|
  d pairs dup predicate ((dup first swap 1 wrap at-path) dip call not) cons each
  where wrap at-path from-pairs) `reject def

 ### def split
 (dict keys -- selected rejected :
  "Partition a dictionary by a key list, returning selected then rejected entries; ignore absent
   keys and preserve dictionary order in both results.")
 (|d keys| d keys dict.core.take d keys dict.core.del) `split def

) `dict @defm
