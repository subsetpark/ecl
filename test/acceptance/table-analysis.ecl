# DoD-29: CSV text is explicitly converted, derived, filtered, grouped, and
# aggregated with ordinary ECL quotations. No header or numeric inference
# happens anywhere: every coercion below is requested by name.
`table (from-header-rows with-column group-by select) import

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

# Filtering turns an ordinary pervasive comparison into row indices with `where`.
derived "revenue" at 100 > io.pp
derived dup "revenue" at 100 > where table.at `large set
large io.pp

# Grouping keys appear in first-occurrence order with stable ascending indices.
derived ["region"] group-by io.pp
derived ["region" "rep"] group-by io.pp
derived [] group-by io.pp

# Gathering the group indices makes every column a list of per-group slices.
# The first cell of each key slice is the group's key; reducing each value
# slice gives one aggregate per group.
derived dup ["region"] group-by dict.vals table.at `by-region set
by-region ["region"] select ((first) each) each
"revenue" by-region "revenue" at (sum) each with-column
"count" by-region "revenue" at (len) each with-column
"mean" by-region "revenue" at (mean) each with-column
io.pp
large dup ["region"] group-by dict.vals table.at `large-by-region set
large-by-region ["region"] select ((first) each) each
"revenue" large-by-region "revenue" at (sum) each with-column
io.pp
derived dup [] group-by dict.vals table.at "revenue" at `overall set
{} "total" overall (sum) each with-column "rows" overall (len) each with-column io.pp
