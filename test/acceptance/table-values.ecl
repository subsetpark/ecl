# DoD-27: a valid table stays an ordinary dict under every core interface,
# while the table words preserve the ordered equal-length-column convention.
`table
(table? from-rows from-header-rows
 from-records rows header-rows records select rename
 with-column)
import

### set sales
{"id" [1 2 3] "city" ["Oslo" "Lima" "Oslo"]} `sales set

# Core reflection is honest: a table is a dict and behaves as one.
sales type io.pp
sales table? io.pp
sales dict.keys io.pp
sales "id" at io.pp
sales {"id" [1 2 3] "city" ["Oslo" "Lima" "Oslo"]} match? io.pp
sales str io.pp
sales json.emit io.pp

# Every constructor reaches the same value.
["id" "city"] [[1 "Oslo"] [2 "Lima"]] from-rows io.pp
[["id" "city"] [1 "Oslo"] [2 "Lima"]] from-header-rows io.pp
{"id" 1 "city" "Oslo"} {"city" "Lima" "id" 2} pair from-records io.pp

# Zero-row schemas are constructible through the explicit forms.
["id" "city"] [] from-rows io.pp
[["id" "city"]] from-header-rows io.pp
["id" "city"] [] from-rows rows len io.pp

# Conversions round-trip, and header-rows carries the schema even at zero rows.
sales dup dict.keys swap rows from-rows sales match? io.pp
sales rows io.pp
sales header-rows io.pp
sales records io.pp
sales dup header-rows from-header-rows match? io.pp
sales dup records from-records match? io.pp
["id" "city"] [] from-rows dup header-rows from-header-rows match? io.pp
["id" "city"] [] from-rows records len io.pp

# Inspection and transformation preserve schema and row order.
{"n" ["1" "2"]} {"n" ((int) each)} dict.evolve io.pp
sales ["city" "id"] select io.pp
sales {"city" "town"} rename io.pp
sales "id" [9 9 9] with-column io.pp
sales "flag" [1 0 1] with-column io.pp
sales [1 0 1] table.where io.pp

# CSV emission takes text fields; parsing with a text schema preserves them.
sales {"id" ((str) each)} dict.evolve header-rows csv.emit csv.parse from-header-rows io.pp
