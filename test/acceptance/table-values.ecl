# DoD-27: a valid table stays an ordinary dict under every core interface,
# while the table words preserve the ordered equal-length-column convention.
'table
('valid? 'names 'height 'from-columns 'from-rows 'from-header-rows
 'from-records 'rows 'header-rows 'records 'column 'cast 'select 'rename
 'with-column)
import

### def sales
{"id" [1 2 3] "city" ["Oslo" "Lima" "Oslo"]} 'sales set

# Core reflection is honest: a table is a dict and behaves as one.
sales type io.pp
sales valid? io.pp
sales dict.keys io.pp
sales "id" at io.pp
sales {"id" [1 2 3] "city" ["Oslo" "Lima" "Oslo"]} match? io.pp
sales str io.pp
sales json.emit io.pp

# Every constructor reaches the same value.
{"id" [1 2] "city" ["Oslo" "Lima"]} from-columns io.pp
["id" "city"] [[1 "Oslo"] [2 "Lima"]] from-rows io.pp
[["id" "city"] [1 "Oslo"] [2 "Lima"]] from-header-rows io.pp
{"id" 1 "city" "Oslo"} {"city" "Lima" "id" 2} 2 pack from-records io.pp

# Zero-row schemas are constructible through the explicit forms.
["id" "city"] [] from-rows io.pp
[["id" "city"]] from-header-rows io.pp
["id" "city"] [] from-rows height io.pp

# Conversions round-trip, and header-rows carries the schema even at zero rows.
sales dup names swap rows from-rows sales match? io.pp
sales rows io.pp
sales header-rows io.pp
sales records io.pp
sales dup header-rows from-header-rows match? io.pp
sales dup records from-records match? io.pp
["id" "city"] [] from-rows dup header-rows from-header-rows match? io.pp
["id" "city"] [] from-rows records len io.pp

# Inspection and transformation preserve schema and row order.
sales names io.pp
sales height io.pp
sales "city" column io.pp
{"n" ["1" "2"]} {"n" (int)} cast io.pp
sales ["city" "id"] select io.pp
sales {"city" "town"} rename io.pp
sales "id" [9 9 9] with-column io.pp
sales "flag" [1 0 1] with-column io.pp
sales [1 0 1] table.where io.pp

# csv is text-only, so a numeric column is cast explicitly before emission;
# the schema then survives the round trip.
sales {"id" (str)} cast header-rows csv.emit csv.parse from-header-rows io.pp
