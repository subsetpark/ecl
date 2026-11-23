# DoD-29: CSV text is explicitly converted, derived, filtered, grouped, and
# aggregated with ordinary ECL quotations. No header or numeric inference
# happens anywhere: every coercion below is requested by name.
`table (from-header-rows with-column group-by aggregate) import

`cwd "test/acceptance/sales.csv" fs.read-text csv.parse
from-header-rows `raw set
raw io.pp
raw "amount" at io.pp

# Everything arrives as text; conversion is explicit.
raw "amount" at first type io.pp
raw {"amount" ((float) each) "quantity" ((int) each)} dict.evolve `sales set
sales io.pp
sales "amount" at first type io.pp

# A derived column must match the row count exactly.
sales "revenue" sales "amount" at sales "quantity" at * with-column `derived set
derived io.pp

# Filtering takes an exact 0/1 mask, which is an ordinary pervasive comparison.
derived "revenue" at 100 > io.pp
derived dup "revenue" at 100 > table.where `large set
large io.pp

# Grouping keys appear in first-occurrence order with stable ascending indices.
derived ["region"] group-by io.pp
derived ["region" "rep"] group-by io.pp
derived [] group-by io.pp

# Aggregation applies one quotation to each group's sub-table and returns key
# columns first, then the record's columns in its order, one row per group.
derived ["region"]
(|g| {} "revenue" g "revenue" at (sum) each put "count" g "revenue" at (len) each put
 "mean" g "revenue" at (mean) each put)
aggregate io.pp
large ["region"] (|g| {} "revenue" g "revenue" at (sum) each put) aggregate io.pp
derived [] (|g| {} "total" g "revenue" at (sum) each put "rows" g "revenue" at (len) each put)
aggregate io.pp
