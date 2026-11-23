# DoD-28: invalid candidates are never implicitly repaired or reclassified. A
# malformed argument is reported by the word that meets it.
`table
(table? rows from-rows from-records select rename
 with-column aggregate inner-join left-join-with rows records)
import

# table? answers 0 for every convention mismatch, and only for those.
5 table? io.pp
{} table? io.pp
{"a" [1 2] "b" [3]} table? io.pp
{"a" 5} table? io.pp
{"a" [1 2]} table? io.pp

# The error kinds, one probe each.
(5 rows) @attempt `err at `kind at io.pp
({"a" [1 2] "b" [3]} rows) @attempt `err at `kind at io.pp
({"a" 5} rows) @attempt `err at `kind at io.pp
(["a" "a"] [] from-rows) @attempt `err at `kind at io.pp
(["a" "b"] [[1]] from-rows) @attempt `err at `kind at io.pp
({"a" 1 "b" 2} {"a" 3} pair from-records) @attempt `err at `kind at io.pp
({"a" [1 2]} ["a" "a"] select) @attempt `err at `kind at io.pp
({"a" [1 2] "b" [3 4]} {"a" "b"} rename) @attempt `err at `kind at io.pp
({"a" [1 2]} "c" [7] with-column) @attempt `err at `kind at io.pp
({"a" [1 2 3]} [1 0] table.where) @attempt `err at `kind at io.pp
({"r" ["e"] "v" [1]} ["r"] (|g| {} "r" g "v" at (sum) each put) aggregate) @attempt `err at `kind at
io.pp
({"r" ["e"] "v" [1]} ["r"] (|g| {} "t" g "zz" at (sum) each put) aggregate) @attempt `err at `kind
at
io.pp
({"id" [1]} {"cid" [1] "id" [7]} [["id" "cid"]] inner-join) @attempt `err at `kind at io.pp
({"id" [1 2]} {"cid" [2] "n" ["y"]} [["id" "cid"]] {} left-join-with) @attempt `err at `kind at
io.pp

# A quotation of the wrong shape is `contract, reported by the applying word.
({"r" ["e"] "v" [1]} ["r"] (dup) aggregate) @attempt `err at dup `kind at io.pp `word
at
io.pp

# Core put can forge an invalid candidate; the next boundary rejects it and
# core reflection keeps telling the truth.
{"a" [1 2]} "b" [9] put `broken set
broken type io.pp
broken table? io.pp
broken (rows) cons @attempt `err at `kind at io.pp
broken (records) cons @attempt `err at `kind at io.pp
broken "b" [9 9] put table? io.pp
