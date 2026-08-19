# DoD-29: CSV text is explicitly cast, derived, filtered, grouped, and
# aggregated with ordinary ECL quotations. No header or numeric inference
# happens anywhere: every coercion below is requested by name.
'table use

"test/acceptance/sales.csv" slurp csv.parse from-header-rows 'raw set
raw pp
raw "amount" column pp

# Everything arrives as text; casting is the only coercion.
raw "amount" column first type pp
raw {"amount" (parse first) "quantity" (parse first)} cast 'sales set
sales pp
sales "amount" column first type pp

# A derived column must match the row count exactly.
sales "revenue" sales "amount" column sales "quantity" column * with-column 'derived set
derived pp

# Filtering takes an exact 0/1 mask, which is an ordinary pervasive comparison.
derived "revenue" column 100 > pp
derived dup "revenue" column 100 > where 'large set
large pp

# Grouping keys appear in first-occurrence order with stable ascending indices.
derived ["region"] group-by pp
derived ["region" "rep"] group-by pp
derived [] group-by pp

# Aggregation returns key columns first, then one column per specification in
# the order given, one row per group.
derived ["region"]
[["revenue" "revenue" (sum)] ["count" "revenue" (len)] ["mean" "revenue" (mean)]]
aggregate pp
large ["region"] [["revenue" "revenue" (sum)]] aggregate pp
derived [] [["total" "revenue" (sum)] ["rows" "revenue" (len)]] aggregate pp
