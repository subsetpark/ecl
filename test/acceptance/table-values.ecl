# DoD-27: a valid table stays an ordinary dict under every core interface,
# while the table words preserve the ordered equal-length-column convention.
'table use

{"id" [1 2 3] "city" ["Oslo" "Lima" "Oslo"]} 'sales set

# Core reflection is honest: a table is a dict and behaves as one.
sales type pp
sales valid? pp
sales keys pp
sales "id" at pp
sales {"id" [1 2 3] "city" ["Oslo" "Lima" "Oslo"]} match pp
sales str pp
sales json.emit pp

# Every constructor reaches the same value.
{"id" [1 2] "city" ["Oslo" "Lima"]} from-columns pp
["id" "city"] [[1 "Oslo"] [2 "Lima"]] from-rows pp
[["id" "city"] [1 "Oslo"] [2 "Lima"]] from-header-rows pp
{"id" 1 "city" "Oslo"} {"city" "Lima" "id" 2} 2 pack from-records pp

# Zero-row schemas are constructible through the explicit forms.
["id" "city"] [] from-rows pp
[["id" "city"]] from-header-rows pp
["id" "city"] [] from-rows height pp

# Conversions round-trip, and header-rows carries the schema even at zero rows.
sales dup names swap rows from-rows sales match pp
sales rows pp
sales header-rows pp
sales records pp
sales dup header-rows from-header-rows match pp
sales dup records from-records match pp
["id" "city"] [] from-rows dup header-rows from-header-rows match pp
["id" "city"] [] from-rows records len pp

# Inspection and transformation preserve schema and row order.
sales names pp
sales height pp
sales "city" column pp
{"n" ["1" "2"]} {"n" (parse first)} cast pp
sales ["city" "id"] select pp
sales {"city" "town"} rename pp
sales "id" [9 9 9] with-column pp
sales "flag" [1 0 1] with-column pp
sales [1 0 1] where pp

# csv is text-only, so a numeric column is cast explicitly before emission;
# the schema then survives the round trip.
sales {"id" (str)} cast header-rows csv.emit csv.parse from-header-rows pp
