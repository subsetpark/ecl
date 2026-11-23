### module stdlib.test.table
(
 `stdlib.test.support
 (equal raises-containing raises-word documented)
 import

 ### test constructors
 (-- : "Validate table conventions and construct populated and empty schemas.")
 ({"a" [1 2] "b" [3 4]} dup type `dict equal
  dup table.table? 1 equal
  dict.keys ["a" "b"] equal
  {"a" [1 2] "b" [3]} table.table? 0 equal
  {} table.table? 1 equal
  5 table.table? 0 equal
  {"a" 5} table.table? 0 equal
  {a [1 2] 7 [3 4]} table.table? 1 equal
  {a [1 2] b [3 4]} table.rows ([1 3] [2 4]) equal
  {"a" [1 2] "b" [3 4]}
  ["a" "b"] [[1 3] [2 4]] table.from-rows match? 1 equal
  ["a" "b"] [] table.from-rows dup table.table? 1 equal
  table.rows len 0 equal
  [["a" "b"] [1 2] [3 4]] table.from-header-rows
  {"a" [1 3] "b" [2 4]} equal
  [["a" "b"]] table.from-header-rows table.rows len 0 equal
  {"a" 1 "b" 2} {"b" 4 "a" 3} pair table.from-records
  {"a" [1 3] "b" [2 4]} equal
  {} table.rows len 0 equal
  [] table.from-records {} equal
  {"a" 1} {"a" 2 "b" 3} pair table.from-records {"a" [1 2]} equal
  (5 table.rows) `type "expected a dict" raises-containing
  ({"a" [1 2] "b" [3]} table.rows) `shape "same length" raises-containing
  (["a" "a"] [] table.from-rows) `domain "distinct" raises-containing
  (["a" "b"] [[1]] table.from-rows) `shape "equal key" raises-containing
  ({"a" 1 "b" 2} {"a" 3} pair table.from-records) `domain "could not find" raises-containing)
 `constructors test

 ### test conversions
 (-- : "Round-trip table rows, headers, records, and zero-row schemas.")
 ({"a" [1 2] "b" [3 4]} dup dup dict.keys swap table.rows
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
 `conversions test

 ### test whole-cells
 (-- : "Transpose and gather whole heterogeneous cells, including empty schemas and string rows.")
 ((["a" "long"] ["bc" "d"]) flip (["a" "bc"] ["long" "d"]) equal
  ["ab" "cd"] flip ["ac" "bd"] equal
  ["a" "b" "c"] ([1 [] {"x" 2}] ["long" [3 4] [[5] [6 7]]]) table.from-rows
  dup {"a" [1 "long"] "b" [[] [3 4]] "c" [{"x" 2} [[5] [6 7]]]} equal
  dup table.rows ([1 [] {"x" 2}] ["long" [3 4] [[5] [6 7]]]) equal
  [0 1] table.where
  {"a" ("long") "b" ([3 4]) "c" ([[5] [6 7]])} equal
  ["a" "b"] ["ab" "cd"] table.from-rows
  {"a" "ac" "b" "bd"} equal
  ["a" "b"] [] table.from-rows [] table.where
  {"a" [] "b" []} equal
  (["a"] [[]] table.from-rows) `shape "equal key" raises-containing)
 `whole-cells test

 ### test transformations
 (-- : "Transform tables while preserving schema and row order by policy.")
 ({"a" [1 2] "b" [3 4] "c" [5 6]} ["c" "a"] table.select
  {"c" [5 6] "a" [1 2]} equal
  {"a" [1 2] "b" [3 4]} {"a" "x"} table.rename
  {"x" [1 2] "b" [3 4]} equal
  {"a" [1 2]} "a" [7 8] table.with-column {"a" [7 8]} equal
  {"a" [1 2]} "c" [7 8] table.with-column
  {"a" [1 2] "c" [7 8]} equal
  {"a" [1 2 3] "b" [4 5 6]} [1 0 1] table.where
  {"a" [1 3] "b" [4 6]} equal
  {"a" [1 2 3]} [0 0 0] table.where table.rows len 0 equal
  {"a" [1 2 3]} [1 0 2] table.where {"a" [1 3 3]} equal
  {"a" [1 2]} [] table.select {} equal
  {"a" [1 2]} {"z" "x"} table.rename {"a" [1 2]} equal
  {} "a" [1 2] table.with-column {"a" [1 2]} equal)
 `transformations test

 ### test invalid-candidates
 (-- : "Report forged and malformed table candidates through the words that meet them.")
 ({"a" [1 2]} "b" [9] put dup table.table? 0 equal type `dict equal
  ({"a" [1 2]} "b" [9] put table.rows) `shape "same length" raises-containing
  ({"a" [1 2]} ["a" "a"] table.select) `domain "distinct" raises-containing
  ({"a" [1 2] "b" [3 4]} {"a" "b"} table.rename) `domain "distinct" raises-containing
  ({"a" [1 2]} "c" [7] table.with-column) `shape "row count" raises-containing
  ({"a" [1 2 3]} [1 0] table.where) `shape "row count" raises-containing)
 `invalid-candidates test

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
  (|g| {} "total" g "v" at (sum) each put "n" g "v" at (len) each put)
  table.aggregate
  {"r" ("e" "w") "total" [40 20] "n" [2 1]} equal
  {"r" ["e" "w" "e"] "v" [10 20 30]}
  []
  (|g| {} "total" g "v" at (sum) each put)
  table.aggregate
  {"total" [60]} equal
  ["r" "v"] [] table.from-rows
  ["r"]
  (|g| {} "t" g "v" at (sum) each put)
  table.aggregate
  {"r" () "t" ()} equal
  ["r" "v"] [] table.from-rows
  []
  (|g| {} "t" g "v" at (sum) each put)
  table.aggregate
  {"t" [0]} equal
  {"r" ["e" "w" "e"] "v" [1 2 3]} ["r"] (pop {}) table.aggregate
  {"r" ("e" "w")} equal
  {"a" [1]} [] (pop {}) table.aggregate {} equal
  {"r" ["e" "e"] "v" [1 3] "w" [3 1]} ["r"]
  (|g| {} "wmean" g "v" at g "w" at * (sum) each g "w" at (sum) each / put)
  table.aggregate
  {"r" ("e") "wmean" [1.5]} equal
  ({"a" [1]} ["z"] table.group-by) `domain "could not find" raises-containing
  ({"r" ["e"] "v" [1]} ["r"] (|g| {} "r" g "v" at (sum) each put) table.aggregate)
  `domain
  "distinct"
  raises-containing
  ({"r" ["e"] "v" [1]} ["r"] (|g| {} "t" g "zz" at (sum) each put) table.aggregate)
  `domain
  "could not find"
  raises-containing
  ({"r" ["e"] "v" [1]} ["r"] (dup) table.aggregate)
  `contract
  `each
  raises-word)
 `grouping-and-aggregation test

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
  table.rows len
  0 equal
  {"a" [1] "b" [2] "v" ["p"]}
  {"c" [1] "d" [2] "n" ["q"]}
  [["a" "c"] ["b" "d"]]
  table.inner-join
  {"a" [1] "b" [2] "v" ("p") "n" ("q")} equal
  {"id" [1 2] "v" ["a" "b"]}
  {"cid" [2] "name" ["y"]}
  [["id" "cid"]]
  {"name" null}
  table.left-join-with
  {"id" [1 2] "v" ("a" "b") "name" (null "y")} equal
  {"id" [1 2 3]}
  {"cid" [2 2]}
  [["id" "cid"]]
  {}
  table.left-join-with
  table.rows len
  4 equal
  {"id" [1 2]} {"cid" [2] "name" ["y"]} [["id" "cid"]] {"name" 1 "extra" 2} table.left-join-with
  {"id" [1 2] "name" [1 "y"]} equal
  {"id" [1 2]} {"n" ["x" "y"]} [] table.inner-join
  {"id" [1 1 2 2] "n" ("x" "y" "x" "y")} equal
  ({"id" [1]} {"cid" [1] "id" [7]} [["id" "cid"]] table.inner-join)
  `domain
  "distinct"
  raises-containing
  ({"id" [1 2]} {"cid" [2] "name" ["y"]} [["id" "cid"]] {} table.left-join-with)
  `domain
  "could not find"
  raises-containing
  ({"id" [1]} {"cid" [1]} [["id"]] table.inner-join) `domain "out of bounds" raises-containing
  ({"id" [1]} {"cid" [1]} [["id" "zz"]] table.inner-join)
  `domain
  "could not find"
  raises-containing)
 `joins test

 ### test array-joins-and-groups
 (-- : "Preserve whole composite keys, stable duplicate order, fills, and empty join schemas.")
 ({"k" ["long" "a" "long"] "s" [[1] [] [1]] "v" [10 20 30]}
  ["k" "s"] (|g| {} "sum" g "v" at (sum) each put) table.aggregate
  {"k" ["long" "a"] "s" [[1] []] "sum" [40 20]} equal
  {"k" ["long" "a" "missing" "long"] "s" [[1] [] [] [1]] "v" [10 20 30 40]}
  {"rk" ["a" "long" "long"] "rs" [[] [1] [1]] "label" ["A" "L1" "L2"]}
  [["k" "rk"] ["s" "rs"]] {"label" []} table.left-join-with
  {"k" ["long" "long" "a" "missing" "long" "long"]
   "s" [[1] [1] [] [] [1] [1]] "v" [10 10 20 30 40 40]
   "label" ["L1" "L2" "A" [] "L1" "L2"]} equal
  {"k" [] "v" []} {"rk" [1] "label" ["a"]} [["k" "rk"]] table.inner-join
  {"k" [] "v" [] "label" []} equal
  {"k" [1 2]} {"rk" [] "label" []} [["k" "rk"]] table.inner-join
  {"k" [] "label" []} equal
  {"k" [1 2]} {"rk" [] "label" []} [["k" "rk"]]
  {"label" {"missing" 1}} table.left-join-with
  {"k" [1 2] "label" [{"missing" 1} {"missing" 1}]} equal
  {"k" []} {"rk" [] "label" []} [["k" "rk"]] {"label" 0} table.left-join-with
  {"k" [] "label" []} equal
  {"k" [1 2 1] "v" [10 20 30]} {"rk" [1.0 1.0 2.0] "label" ["a" "b" "c"]}
  [["k" "rk"]] table.inner-join
  {"k" [1 1 2 1 1] "v" [10 10 20 30 30] "label" ["a" "b" "c" "a" "b"]} equal
  {"k" [[1] [] [1]]} {"rk" [[] [1.0]] "v" [10 20]} [["k" "rk"]] table.inner-join
  {"k" [[1] [] [1]] "v" [20 10 20]} equal)
 `array-joins-and-groups test

 ### test documentation
 (-- : "Expose documentation for every table module export.")
 ([table.table?
   table.from-rows table.from-header-rows table.from-records table.rows
   table.header-rows table.records table.select
   table.rename table.with-column table.where table.group-by
   table.aggregate table.inner-join table.left-join-with]
  documented)
 `documentation test

 ### test aggregate-quotations
 (-- : "An aggregate is one ordinary quotation over each group's sub-table.")
 ({"k" [1 2 1] "v" [10 20 30]} ["k"]
  (|g|
   {} "s" g "v" at (sum) each put "n" g "v" at (len) each put
   "lo" g "v" at ((min) fold1) each put "hi" g "v" at ((max) fold1) each put)
  table.aggregate {"k" [1 2] "s" [40 20] "n" [2 1] "lo" [10 20] "hi" [30 20]} equal
  {"v" []} [] (|g| {} "s" g "v" at (sum) each put "n" g "v" at (len) each put) table.aggregate
  {"s" [0] "n" [0]} equal)
 `aggregate-quotations test

) `stdlib.test.table @defm
