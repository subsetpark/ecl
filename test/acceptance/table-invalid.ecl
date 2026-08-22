# DoD-28: invalid candidates are never implicitly repaired or reclassified, and
# every exported word validates before running a user quotation.
'table.valid? 'valid? import
'table.from-columns 'from-columns import
'table.from-rows 'from-rows import
'table.from-records 'from-records import
'table.column 'column import
'table.cast 'cast import
'table.select 'select import
'table.rename 'rename import
'table.with-column 'with-column import
'table.where 'where import
'table.aggregate 'aggregate import
'table.inner-join 'inner-join import
'table.left-join-with 'left-join-with import
'table.rows 'rows import
'table.records 'records import

# valid? answers 0 for every convention mismatch, and only for those.
5 valid? io.pp
{} valid? io.pp
{"a" [1 2] "b" [3]} valid? io.pp
{"a" 5} valid? io.pp
{"" [1]} valid? io.pp
{"a" [1 2]} valid? io.pp

# The frozen error kinds, one probe each.
(5 from-columns) @attempt 'err at 'kind at io.pp
({} from-columns) @attempt 'err at 'kind at io.pp
({"a" [1 2] "b" [3]} from-columns) @attempt 'err at 'kind at io.pp
({"a" 5} from-columns) @attempt 'err at 'kind at io.pp
({5 [1]} from-columns) @attempt 'err at 'kind at io.pp
({"" [1]} from-columns) @attempt 'err at 'kind at io.pp
(["a" "a"] [] from-rows) @attempt 'err at 'kind at io.pp
(["a" "b"] [[1]] from-rows) @attempt 'err at 'kind at io.pp
([] from-records) @attempt 'err at 'kind at io.pp
({"a" 1} {"a" 2 "b" 3} 2 pack from-records) @attempt 'err at 'kind at io.pp
({"a" [1 2]} "z" column) @attempt 'err at 'kind at io.pp
({"a" [1 2]} ["a" "a"] select) @attempt 'err at 'kind at io.pp
({"a" [1 2]} [] select) @attempt 'err at 'kind at io.pp
({"a" [1 2] "b" [3 4]} {"a" "b"} rename) @attempt 'err at 'kind at io.pp
({"a" [1 2]} {"z" "x"} rename) @attempt 'err at 'kind at io.pp
({"a" [1 2]} "c" [7] with-column) @attempt 'err at 'kind at io.pp
({"a" [1 2 3]} [1 0] where) @attempt 'err at 'kind at io.pp
({"a" [1 2 3]} [1 0 2] where) @attempt 'err at 'kind at io.pp
({"a" [1 2]} {"z" (str)} cast) @attempt 'err at 'kind at io.pp
({"a" [1 2]} {"a" 5} cast) @attempt 'err at 'kind at io.pp
({"a" [1]} [] [] aggregate) @attempt 'err at 'kind at io.pp
({"r" ["e"] "v" [1]} ["r"] [["r" "v" (sum)]] aggregate) @attempt 'err at 'kind at io.pp
({"r" ["e"] "v" [1]} ["r"] [["t" "zz" (sum)]] aggregate) @attempt 'err at 'kind at io.pp
({"r" ["e"] "v" [1]} ["r"] [["t" "v"]] aggregate) @attempt 'err at 'kind at io.pp
({"id" [1]} {"cid" [1] "id" [7]} [["id" "cid"]] inner-join) @attempt 'err at 'kind at io.pp
({"id" [1]} {"cid" [1]} [] inner-join) @attempt 'err at 'kind at io.pp
({"id" [1 2]} {"cid" [2] "n" ["y"]} [["id" "cid"]] {} left-join-with) @attempt 'err at 'kind at
io.pp

# A cast or aggregate quotation never runs before prevalidation completes: each
# probe below would raise 'user if it were reached.
({"a" [1 2]} {"z" ("reached" fail)} cast) @attempt 'err at 'kind at io.pp
({"r" ["e"] "v" [1]} ["r"] [["t" "zz" ("reached" fail)]] aggregate) @attempt 'err at 'kind at io.pp

# A quotation of the wrong shape is 'contract, reported by the applying word.
({"r" ["e"] "v" [1]} ["r"] [["t" "v" (dup)]] aggregate) @attempt 'err at dup 'kind at io.pp 'word at
io.pp

# Core put can forge an invalid candidate; the next boundary rejects it and
# core reflection keeps telling the truth.
{"a" [1 2]} "b" [9] put 'broken set
broken type io.pp
broken valid? io.pp
broken wrap (rows) with @attempt 'err at 'kind at io.pp
broken wrap (records) with @attempt 'err at 'kind at io.pp
broken "b" [9 9] put valid? io.pp
