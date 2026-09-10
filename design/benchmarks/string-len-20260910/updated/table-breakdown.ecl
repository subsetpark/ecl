'cwd "metal_bands.csv" fs.read-bytes [] csv.parse-header 'columns set 'names set
clock.now 'tick set names columns dict.from-lists 'bands set "dict construction" io.pp tick clock.elapsed io.pp
clock.now 'tick set bands table.from-columns pop "first table validation" io.pp tick clock.elapsed io.pp
clock.now 'tick set 100 (bands table.from-columns pop) times "100 warm validations" io.pp tick clock.elapsed io.pp
clock.now 'tick set bands ["Country"] table.group-by 'groups set "country grouping" io.pp tick clock.elapsed io.pp
clock.now 'tick set bands "Band ID" at groups dict.vals 'count reduce-groups 'counts set "count reduction" io.pp tick clock.elapsed io.pp
clock.now 'tick set bands ["Country"] [["bands" "Band ID" 'count]] table.aggregate 'aggregation set "symbol aggregate" io.pp tick clock.elapsed io.pp
clock.now 'tick set bands ["Country"] [["bands" "Band ID" (len)]] table.aggregate pop "quotation aggregate" io.pp tick clock.elapsed io.pp
clock.now 'tick set bands ["Country" "Status"] table.group-by pop "composite grouping" io.pp tick clock.elapsed io.pp
clock.now 'tick set bands table.rows pop "row materialization" io.pp tick clock.elapsed io.pp
'cwd "all_bands_discography.csv" fs.read-bytes [] csv.parse-header dict.from-lists table.from-columns 'albums set
clock.now 'tick set bands "Band ID" at wrap group-columns 'lg set "join left grouping" io.pp tick clock.elapsed io.pp
clock.now 'tick set albums "Band ID" at wrap group-columns 'rg set "join right grouping" io.pp tick clock.elapsed io.pp
clock.now 'tick set rg lg dict.keys [] dict.at-or 'distinct-matches set "join distinct lookup" io.pp tick clock.elapsed io.pp
clock.now 'tick set lg dict.vals (len) each 'group-lengths set "join group lengths" io.pp tick clock.elapsed io.pp
clock.now 'tick set distinct-matches group-lengths core.where at 'expanded set "join expand matches" io.pp tick clock.elapsed io.pp
clock.now 'tick set lg dict.vals raze 'flat-left set "join flatten left indices" io.pp tick clock.elapsed io.pp
clock.now 'tick set flat-left grade 'order set "join grade left indices" io.pp tick clock.elapsed io.pp
clock.now 'tick set expanded order at 'matches set "join reorder matches" io.pp tick clock.elapsed io.pp
clock.now 'tick set matches (len) each 'match-lengths set "join match lengths" io.pp tick clock.elapsed io.pp
clock.now 'tick set match-lengths core.where 'li set "join left selectors" io.pp tick clock.elapsed io.pp
clock.now 'tick set matches raze 'ri set "join right selectors" io.pp tick clock.elapsed io.pp
clock.now 'tick set bands dict.vals li (at) partial each 'lv set "join left gather" io.pp tick clock.elapsed io.pp
albums ["Album Name" "Type" "Year" "Number of Reviews" "Average Rating"] dict.at 'right-columns set
clock.now 'tick set right-columns ri (at) partial each 'rv set "join right gather" io.pp tick clock.elapsed io.pp
clock.now 'tick set bands dict.keys ["Album Name" "Type" "Year" "Number of Reviews" "Average Rating"] cat lv rv cat dict.from-lists 'joined set "join output dictionary" io.pp tick clock.elapsed io.pp
"join rows" io.pp joined table.height io.pp
clock.now 'tick set bands albums [["Band ID" "Band ID"]] table.inner-join pop "whole join" io.pp tick clock.elapsed io.pp
