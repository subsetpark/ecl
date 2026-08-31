### module stdlib.test.table
[]
(
 'stdlib.test.support
 ('equal 'raises-containing 'raises-word 'documented)
 import

 ### test constructors
 (-- : "Validate table conventions and construct populated and empty schemas.")
 ({"a" [1 2] "b" [3 4]} dup type 'dict equal
  dup table.valid? 1 equal
  dict.keys ["a" "b"] equal
  {"a" [1 2] "b" [3]} table.valid? 0 equal
  {} table.valid? 0 equal
  5 table.valid? 0 equal
  {"a" 5} table.valid? 0 equal
  {"" [1]} table.valid? 0 equal
  {"a" [1 2] "b" [3 4]} table.from-columns
  ["a" "b"] [[1 3] [2 4]] table.from-rows match? 1 equal
  ["a" "b"] [] table.from-rows dup table.valid? 1 equal
  table.height 0 equal
  [["a" "b"] [1 2] [3 4]] table.from-header-rows
  {"a" [1 3] "b" [2 4]} equal
  [["a" "b"]] table.from-header-rows table.height 0 equal
  {"a" 1 "b" 2} {"b" 4 "a" 3} 2 pack table.from-records
  {"a" [1 3] "b" [2 4]} equal
  ({} table.from-columns) 'shape "at least one column" raises-containing
  (5 table.from-columns) 'type "must be a dict" raises-containing
  ({"a" [1 2] "b" [3]} table.from-columns)
  'shape
  "one length"
  raises-containing
  (["a" "a"] [] table.from-rows) 'domain "duplicate" raises-containing
  ([""] [] table.from-rows) 'domain "must not be empty" raises-containing
  (["a" "b"] [[1]] table.from-rows)
  'shape
  "one cell per column"
  raises-containing
  ([] table.from-records)
  'shape
  "cannot infer a schema"
  raises-containing
  ({"a" 1} {"a" 2 "b" 3} 2 pack table.from-records)
  'domain
  "exactly the first record's keys"
  raises-containing)
 'constructors test

 ### test conversions
 (-- : "Round-trip table rows, headers, records, and zero-row schemas.")
 ({"a" [1 2] "b" [3 4]} dup dup table.names swap table.rows
  table.from-rows match? 1 equal
  {"a" [1 2] "b" [3 4]} table.rows ([1 3] [2 4]) equal
  {"a" [1 2] "b" [3 4]} table.records
  ({"a" 1 "b" 3} {"a" 2 "b" 4}) equal
  ["a" "b"] [] table.from-rows table.header-rows (("a" "b")) equal
  ["a" "b"] [] table.from-rows table.rows len 0 equal
  {"a" [1 2] "b" [3 4]} dup table.header-rows
  table.from-header-rows match? 1 equal
  ["a" "b"] [] table.from-rows dup table.header-rows
  table.from-header-rows match? 1 equal
  {"a" [1 2] "b" [3 4]} dup table.records table.from-records match? 1 equal
  ["a"] [] table.from-rows table.records len 0 equal)
 'conversions test

 ### test transformations
 (-- : "Transform tables while preserving schema and row order by policy.")
 ({"a" [1 2] "b" [3 4]} table.names ("a" "b") equal
  {"a" [1 2] "b" [3 4]} "b" table.column [3 4] equal
  {"a" [1 2]} table.height 2 equal
  {"a" ["1" "2"] "b" ["5" "6"]}
  {"a" (parse-int)}
  table.cast
  {"a" [1 2] "b" ("5" "6")} equal
  {"a" [1 2] "b" [3 4] "c" [5 6]} ["c" "a"] table.select
  {"c" [5 6] "a" [1 2]} equal
  {"a" [1 2] "b" [3 4]} {"a" "x"} table.rename
  {"x" [1 2] "b" [3 4]} equal
  {"a" [1 2]} "a" [7 8] table.with-column {"a" [7 8]} equal
  {"a" [1 2]} "c" [7 8] table.with-column
  {"a" [1 2] "c" [7 8]} equal
  {"a" [1 2 3] "b" [4 5 6]} [1 0 1] table.where
  {"a" [1 3] "b" [4 6]} equal
  {"a" [1 2 3]} [0 0 0] table.where table.height 0 equal)
 'transformations test

 ### test invalid-candidates
 (-- : "Reject forged and malformed table candidates with stable error kinds.")
 ({"a" [1 2]} "b" [9] put dup table.valid? 0 equal type 'dict equal
  ({"a" [1 2]} "b" [9] put table.rows)
  'shape
  "one length"
  raises-containing
  ({"a" [1 2]} "z" table.column)
  'domain
  "existing column name"
  raises-containing
  ({"a" [1 2]} {"z" (str)} table.cast)
  'domain
  "existing column names"
  raises-containing
  ({"a" [1 2]} {"a" 5} table.cast)
  'type
  "quotation for every named column"
  raises-containing
  ({"a" [1 2]} ["a" "a"] table.select)
  'domain
  "duplicate"
  raises-containing
  ({"a" [1 2]} [] table.select)
  'shape
  "at least one column"
  raises-containing
  ({"a" [1 2] "b" [3 4]} {"a" "b"} table.rename)
  'domain
  "collide"
  raises-containing
  ({"a" [1 2]} {"z" "x"} table.rename)
  'domain
  "existing column names"
  raises-containing
  ({"a" [1 2]} "c" [7] table.with-column)
  'shape
  "row count"
  raises-containing
  ({"a" [1 2 3]} [1 0] table.where)
  'shape
  "row count"
  raises-containing
  ({"a" [1 2 3]} [1 0 2] table.where)
  'type
  "only 0 and 1"
  raises-containing)
 'invalid-candidates test

 ### test grouping-and-aggregation
 (-- : "Group stably and aggregate key and value columns by explicit policy.")
 ({"r" ["e" "w" "e" "n"] "v" [1 2 3 4]} ["r"] table.group-by
  {"e" [0 2] "w" [1] "n" [3]} equal
  {"r" ["e" "w"] "v" [1 2]} [] table.group-by {() [0 1]} equal
  {"r" ["e" "w" "e"] "s" ["a" "a" "b"] "v" [1 2 3]}
  ["r" "s"]
  table.group-by
  {("e" "a") [0] ("w" "a") [1] ("e" "b") [2]} equal
  {"r" ["e" "w" "e"] "v" [10 20 30]}
  ["r"]
  [["total" "v" (sum)] ["n" "v" (len)]]
  table.aggregate
  {"r" ("e" "w") "total" [40 20] "n" [2 1]} equal
  {"r" ["e" "w" "e"] "v" [10 20 30]}
  []
  [["total" "v" (sum)]]
  table.aggregate
  {"total" [60]} equal
  ["r" "v"] [] table.from-rows
  ["r"]
  [["t" "v" (sum)]]
  table.aggregate
  {"r" () "t" ()} equal
  ["r" "v"] [] table.from-rows
  []
  [["t" "v" (sum)]]
  table.aggregate
  {"t" [0]} equal
  {"r" ["e" "w" "e"] "v" [1 2 3]} ["r"] [] table.aggregate
  {"r" ("e" "w")} equal
  ({"a" [1]} ["z"] table.group-by)
  'domain
  "existing column names"
  raises-containing
  ({"a" [1]} [] [] table.aggregate)
  'domain
  "at least one key or aggregate output"
  raises-containing
  ({"r" ["e"] "v" [1]} ["r"] [["r" "v" (sum)]] table.aggregate)
  'domain
  "must not collide"
  raises-containing
  ({"r" ["e"] "v" [1]} ["r"] [["t" "zz" (sum)]] table.aggregate)
  'domain
  "existing input column"
  raises-containing
  ({"r" ["e"] "v" [1]} ["r"] [["t" "v"]] table.aggregate)
  'type
  "[output-name input-name quotation]"
  raises-containing
  ({"r" ["e"] "v" [1]} ["r"] [["t" "v" (dup)]] table.aggregate)
  'contract
  'each
  raises-word)
 'grouping-and-aggregation test

 ### test joins
 (-- : "Join tables stably with explicit keys and caller-provided missingness.")
 ({"id" [1 2 3] "v" ["a" "b" "c"]}
  {"cid" [2 3 4] "name" ["x" "y" "z"]}
  [["id" "cid"]]
  table.inner-join
  {"id" [2 3] "v" ("b" "c") "name" ("x" "y")} equal
  {"id" [1 1] "v" ["a" "b"]}
  {"cid" [1 1] "name" ["x" "y"]}
  [["id" "cid"]]
  table.inner-join
  {"id" [1 1 1 1] "v" ("a" "a" "b" "b")
   "name" ("x" "y" "x" "y")}
  equal
  {"id" [1 2] "v" ["a" "b"]}
  {"cid" [9] "name" ["x"]}
  [["id" "cid"]]
  table.inner-join
  table.height
  0 equal
  {"a" [1] "b" [2] "v" ["p"]}
  {"c" [1] "d" [2] "n" ["q"]}
  [["a" "c"] ["b" "d"]]
  table.inner-join
  {"a" [1] "b" [2] "v" ("p") "n" ("q")} equal
  {"id" [1 2] "v" ["a" "b"]}
  {"cid" [2] "name" ["y"]}
  [["id" "cid"]]
  {"name" 'null}
  table.left-join-with
  {"id" [1 2] "v" ("a" "b") "name" ('null "y")} equal
  {"id" [1 2 3]}
  {"cid" [2 2]}
  [["id" "cid"]]
  {}
  table.left-join-with
  table.height
  4 equal
  ({"id" [1]} {"cid" [1] "id" [7]} [["id" "cid"]] table.inner-join)
  'domain
  "collide non-key column names"
  raises-containing
  ({"id" [1 2]} {"cid" [2] "name" ["y"]} [["id" "cid"]] {}
   table.left-join-with)
  'domain
  "cover every appended right column"
  raises-containing
  ({"id" [1 2]} {"cid" [2] "name" ["y"]} [["id" "cid"]]
   {"name" 1 "extra" 2}
   table.left-join-with)
  'domain
  "exactly the appended right columns"
  raises-containing
  ({"id" [1]} {"cid" [1]} [] table.inner-join)
  'domain
  "at least one key pair"
  raises-containing
  ({"id" [1]} {"cid" [1]} [["id"]] table.inner-join)
  'type
  "[left-name right-name] pairs"
  raises-containing
  ({"id" [1]} {"cid" [1]} [["id" "zz"]] table.inner-join)
  'domain
  "existing right columns"
  raises-containing)
 'joins test

 ### test documentation
 (-- : "Expose documentation for every table module export.")
 (['table.valid? 'table.names 'table.height 'table.from-columns
   'table.from-rows 'table.from-header-rows 'table.from-records 'table.rows
   'table.header-rows 'table.records 'table.column 'table.cast 'table.select
   'table.rename 'table.with-column 'table.where 'table.group-by
   'table.aggregate 'table.inner-join 'table.left-join-with]
  documented)
 'documentation test
) 'stdlib.test.table @defm
