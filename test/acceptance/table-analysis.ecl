# DoD-29: CSV text is explicitly cast, derived, filtered, grouped, and
# aggregated with ordinary ECL quotations. No header or numeric inference
# happens anywhere: every coercion below is requested by name.
'table ('from-header-rows 'column 'cast 'with-column 'group-by 'aggregate) import

'cwd "test/acceptance/sales.csv" fs.read-text csv.parse from-header-rows 'raw set
raw io.pp
raw "amount" column io.pp

# Everything arrives as text; casting is the only coercion.
raw "amount" column first type io.pp
raw {"amount" (float) "quantity" (int)} cast 'sales set
sales io.pp
sales "amount" column first type io.pp

# A derived column must match the row count exactly.
sales "revenue" sales "amount" column sales "quantity" column * with-column 'derived set
derived io.pp

# Filtering takes an exact 0/1 mask, which is an ordinary pervasive comparison.
derived "revenue" column 100 > io.pp
derived dup "revenue" column 100 > table.where 'large set
large io.pp

# Grouping keys appear in first-occurrence order with stable ascending indices.
derived ["region"] group-by io.pp
derived ["region" "rep"] group-by io.pp
derived [] group-by io.pp

# Aggregation returns key columns first, then one column per specification in
# the order given, one row per group.
derived ["region"]
[["revenue" "revenue" (sum)] ["count" "revenue" (len)] ["mean" "revenue" (mean)]]
aggregate io.pp
large ["region"] [["revenue" "revenue" (sum)]] aggregate io.pp
derived [] [["total" "revenue" (sum)] ["rows" "revenue" (len)]] aggregate io.pp
