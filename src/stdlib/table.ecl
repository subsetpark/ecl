### module table
# Tables are column dictionaries. Column names are nonempty strings, column
# values are lists, and every column has the same length. A table has at least
# one column and may have zero rows. Column order is dictionary insertion order.
#
# Tables remain ordinary dictionaries: `type`, `keys`, `at`, and `put` keep
# their normal behavior. Exported table operations validate table arguments and
# raise an error for invalid dictionaries.
(
 ### defp text?
 (value -- bool : "Return 1 when every item in a list is a character.")
 ((type 'char match?) all?)
 'text? defp

 ### defp string?
 (value -- bool : "Return 1 when a value is a string and 0 for every other value.")
 (dup type 'list match? (text?) (pop 0) if)
 'string? defp

 ### defp checked
 (candidate -- table : "Validate and return a table candidate.")
 (dup type 'dict match?
  {'kind 'type 'msg "a table must be a dict of columns"} assert
  dup keys len 0 >
  {'kind 'shape 'msg "a table must have at least one column"} assert
  dup keys (string?) all?
  {'kind 'type 'msg "table column names must be strings"} assert
  dup keys (len 0 >) all?
  {'kind 'domain 'msg "table column names must not be empty"} assert
  dup vals (type 'list match?) all?
  {'kind 'type 'msg "table columns must be lists"} assert
  dup vals (len) each distinct len 2 <
  {'kind 'shape 'msg "table columns must share one length"} assert)
 'checked defp

 ### defp convention-miss?
 (result -- bool : "Return 0 for a table validation error and re-raise any other error.")
 (dup 'err at 'kind at ['type 'shape 'domain] in? (pop 0) ('err at raise) if)
 'convention-miss? defp

 ### def valid?
 (candidate -- bool :
  "Return 1 when a candidate is a table and 0 when it is not.

   Cancellation, allocation failure, and other runtime errors propagate.")
 (wrap (checked pop) with @attempt dup result.ok? (pop 1) (convention-miss?) if)
 'valid? def

 ### def names
 (table -- names : "Return the column names in column order.")
 (checked keys)
 'names def

 ### def height
 (table -- count : "Return the number of rows.")
 (checked vals first len)
 'height def

 ### def from-columns
 (columns -- table : "Validate a column dictionary and return it as a table.")
 (checked)
 'from-columns def

 ### def from-rows
 (names rows -- table :
  "Build a table from column names and rows of the same width.

   An empty row list produces a zero-row table with the given columns.")
 (|names rows|
  names type 'list match?
  {'kind 'type 'msg "table.from-rows expects a list of column names"} assert
  names len 0 >
  {'kind 'shape 'msg "a table must have at least one column"} assert
  names (string?) all?
  {'kind 'type 'msg "table column names must be strings"} assert
  names (len 0 >) all?
  {'kind 'domain 'msg "table column names must not be empty"} assert
  names distinct len names len =
  {'kind 'domain 'msg "table.from-rows rejects duplicate column names"} assert
  rows type 'list match?
  {'kind 'type 'msg "table.from-rows expects a list of rows"} assert
  rows (type 'list match?) all?
  {'kind 'type 'msg "table.from-rows expects every row to be a list"} assert
  rows names (len swap len =) partial all?
  {'kind 'shape 'msg "every row must have one cell per column name"} assert
  names rows names len transpose to-dict)
 'from-rows def

 ### def from-header-rows
 (rows -- table : "Build a table using the first row as column names and the rest as data rows.")
 (dup type 'list match?
  {'kind 'type 'msg "table.from-header-rows expects a list of rows"} assert
  dup len 0 >
  {'kind 'shape 'msg "table.from-header-rows needs a header row"} assert
  dup first swap 1 drop from-rows)
 'from-header-rows def

 ### defp record-column
 (name records -- column : "Return one field from each record, preserving record order.")
 (|name records| records name (at) partial each)
 'record-column defp

 ### def from-records
 (records -- table :
  "Build a table from a nonempty list of records with the same keys.

   The first record sets column order. Later records may use a different key order.")
 (|records|
  records type 'list match?
  {'kind 'type 'msg "table.from-records expects a list of records"} assert
  records len 0 >
  {'kind 'shape 'msg "table.from-records cannot infer a schema from no records"} assert
  records (type 'dict match?) all?
  {'kind 'type 'msg "table.from-records expects every record to be a dict"} assert
  records first keys (string?) all?
  {'kind 'type 'msg "table column names must be strings"} assert
  records first keys (len 0 >) all?
  {'kind 'domain 'msg "table column names must not be empty"} assert
  records records first keys (keys-exactly?) partial all?
  {'kind 'domain 'msg "every record must carry exactly the first record's keys"} assert
  records first keys
  records first keys records (record-column) partial each
  to-dict)
 'from-records def

 ### def rows
 (table -- rows : "Return the data rows in row and column order.")
 (checked dup vals swap height transpose)
 'rows def

 ### def header-rows
 (table -- rows : "Return the column-name row followed by the data rows.")
 (checked dup keys swap rows cons)
 'header-rows def

 ### def records
 (table -- records :
  "Return one record per row, with keys in column order. A zero-row table returns an empty list.")
 (checked dup keys swap rows swap (swap to-dict) partial each)
 'records def

 ### def column
 (table name -- column : "Return a column by name.")
 (|table name|
  table checked pop
  table name has?
  {'kind 'domain 'msg "table.column requires an existing column name"} assert
  table name at)
 'column def

 ### def cast
 (table spec -- table :
  "Apply each specification's ( cell -- value ) quotation to its named column.

   The specification must be a dictionary from existing column names to quotations. All entries are
   validated before a quotation runs.")
 (|table spec|
  table checked pop
  spec type 'dict match?
  {'kind 'type 'msg "table.cast expects a dict from column name to quotation"} assert
  spec keys table (swap has?) partial all?
  {'kind 'domain 'msg "table.cast requires existing column names"} assert
  spec vals (type 'list match?) all?
  {'kind 'type 'msg "table.cast expects a quotation for every named column"} assert
  spec pairs table (cast-column) fold)
 'cast def

 ### defp cast-column
 (table pair -- table : "Apply one [name quotation] cast specification to a table.")
 (|table pair| table pair first
  table pair first at pair 1 at each
  put)
 'cast-column defp

 ### def select
 (table names -- table : "Return the named columns in the requested order.")
 (|table names|
  table checked pop
  names type 'list match?
  {'kind 'type 'msg "table.select expects a list of column names"} assert
  names len 0 >
  {'kind 'shape 'msg "a table must have at least one column"} assert
  names distinct len names len =
  {'kind 'domain 'msg "table.select rejects duplicate column names"} assert
  names table (swap has?) partial all?
  {'kind 'domain 'msg "table.select requires existing column names"} assert
  names
  names table (swap at) partial each
  to-dict)
 'select def

 ### def rename
 (table mapping -- table : "Rename columns without changing column order.")
 (|table mapping|
  table checked pop
  mapping type 'dict match?
  {'kind 'type 'msg "table.rename expects a dict from old name to new name"} assert
  mapping keys table (swap has?) partial all?
  {'kind 'domain 'msg "table.rename requires existing column names"} assert
  mapping vals (string?) all?
  {'kind 'type 'msg "table column names must be strings"} assert
  mapping vals (len 0 >) all?
  {'kind 'domain 'msg "table column names must not be empty"} assert
  table keys mapping (swap dup at-or) partial each
  dup distinct len over len =
  {'kind 'domain 'msg "table.rename would collide two columns onto one name"} assert
  table vals to-dict)
 'rename def

 ### def with-column
 (table name column -- table :
  "Replace a named column or append a new column. The column length must equal the row count.")
 (|table name column|
  table checked pop
  name string?
  {'kind 'type 'msg "table column names must be strings"} assert
  name len 0 >
  {'kind 'domain 'msg "table column names must not be empty"} assert
  column type 'list match?
  {'kind 'type 'msg "table.with-column expects a list"} assert
  column len table height =
  {'kind 'shape 'msg "a replacement column must match the table's row count"} assert
  table name column put)
 'with-column def

 ### defp selected
 (mask -- indices : "Return the indices selected by a 0/1 mask.")
 (|mask| mask len range mask (swap at) partial filter)
 'selected defp

 ### defp slice-at
 (position lists -- slice : "Return the item at one position from each list.")
 (|position lists| lists position (at) partial each)
 'slice-at defp

 ### defp transpose
 (lists count -- transposed :
  "Transpose a rectangular list of lists with the given output length.

   Cells are not traversed. This supports heterogeneous rows, including strings, and zero rows.")
 (|lists count| count range lists (slice-at) partial each)
 'transpose defp

 ### defp name-set
 (names -- set : "Build a dictionary for whole-name membership tests.")
 (|names| names names (pop 1) each to-dict)
 'name-set defp

 ### defp exclude
 (names excluded -- names : "Remove excluded names while preserving the order of the input names.")
 (|names excluded|
  names excluded name-set (swap has? not) partial filter)
 'exclude defp

 ### def where
 (table mask -- table :
  "Return rows selected by a 0/1 mask. The mask length must equal the row count.")
 (|table mask|
  table checked pop
  mask type 'list match?
  {'kind 'type 'msg "table.where expects a mask list"} assert
  mask ([0 1] in?) all?
  {'kind 'type 'msg "a table mask holds only 0 and 1"} assert
  mask len table height =
  {'kind 'shape 'msg "a table mask must match the table's row count"} assert
  table keys
  table vals mask selected (at) partial each
  to-dict)
 'where def

 # --- grouping, aggregation, and joins -------------------------------------

 ### defp cell
 (name table index -- cell : "Return a cell by column name and row index.")
 (|name table index| table name at index at)
 'cell defp

 ### defp row-key
 (index table names -- key : "Return the named cells of one row as a composite key.")
 (|index table names| names table index (cell) partial partial each)
 'row-key defp

 ### defp composite-keys
 (table names -- keys : "Return one composite key per row.")
 (|table names| table height range table names (row-key) partial partial each)
 'composite-keys defp

 ### defp group-keys
 (table names -- keys :
  "Return grouping keys for all rows: scalar keys for one column and list keys for multiple
   columns.")
 (|table names| names len 1 =
  table names first (at) partial partial
  table names (composite-keys) partial partial if)
 'group-keys defp

 ### defp global-group
 (table -- groups : "Return one group containing every row index.")
 (|table| [] wrap table height range wrap to-dict)
 'global-group defp

 ### def group-by
 (table names -- groups :
  "Group row indices by the named columns.

   Groups follow first occurrence order and indices within each group are ascending. An empty name
   list returns one group keyed by the empty list.")
 (|table names|
  table checked pop
  names type 'list match?
  {'kind 'type 'msg "table.group-by expects a list of column names"} assert
  names (string?) all?
  {'kind 'type 'msg "table column names must be strings"} assert
  names table (swap has?) partial all?
  {'kind 'domain 'msg "table.group-by requires existing column names"} assert
  names distinct len names len =
  {'kind 'domain 'msg "table.group-by rejects duplicate column names"} assert
  names len 0 =
  table (global-group) partial
  table names (group-keys group) partial partial
  if)
 'group-by def

 ### defp apply-aggregate
 (column quotation -- value :
  "Apply an isolated ( column -- value ) quotation to one column slice.

   The quotation must return exactly one value.")
 (|column quotation| column wrap quotation each first)
 'apply-aggregate defp

 ### defp group-value
 (indices table spec -- value : "Apply one aggregate specification to one group.")
 (|indices table spec| table spec 1 at at indices at spec 2 at apply-aggregate)
 'group-value defp

 ### defp aggregate-column
 (spec table groups -- column : "Return one aggregate value per group.")
 (|spec table groups| groups vals table spec (group-value) partial partial each)
 'aggregate-column defp

 ### defp key-component
 (position groups -- column : "Return one component from every composite group key.")
 (|position groups| groups keys position (at) partial each)
 'key-component defp

 ### defp key-columns
 (groups names -- columns : "Return grouping-key columns in name order.")
 (|groups names| names len 1 =
  groups (keys wrap) partial
  groups names (composite-key-columns) partial partial
  if)
 'key-columns defp

 ### defp composite-key-columns
 (groups names -- columns : "Split composite group keys into one column per name.")
 (|groups names| names len range groups (key-component) partial each)
 'composite-key-columns defp

 ### defp spec-shaped?
 (spec -- bool : "Return 1 for an [output-name input-name quotation] aggregate specification.")
 (dup type 'list match?
  (dup len 3 =
   (dup first string? over 1 at string? and swap 2 at type 'list match? and)
   (pop 0)
   if)
  (pop 0)
  if)
 'spec-shaped? defp

 ### defp aggregate-build
 (table names specs groups -- table : "Build a result table from grouping keys and aggregates.")
 (|table names specs groups|
  names specs (first) each cat
  groups names key-columns
  specs table groups (aggregate-column) partial partial each
  cat
  to-dict)
 'aggregate-build defp

 ### def aggregate
 (table names specs -- table :
  "Group rows and apply [output-name input-name quotation] aggregate specifications.

   All names and specifications are validated before a quotation runs. The result contains key
   columns first, followed by aggregate columns in specification order, with one row per group.")
 (|table names specs|
  table checked pop
  names type 'list match?
  {'kind 'type 'msg "table.aggregate expects a list of column names"} assert
  names (string?) all?
  {'kind 'type 'msg "table column names must be strings"} assert
  names table (swap has?) partial all?
  {'kind 'domain 'msg "table.aggregate requires existing column names"} assert
  names distinct len names len =
  {'kind 'domain 'msg "table.aggregate rejects duplicate column names"} assert
  specs type 'list match?
  {'kind 'type 'msg "table.aggregate expects a list of specifications"} assert
  specs (spec-shaped?) all?
  {'kind 'type
   'msg "each aggregate specification is [output-name input-name quotation]"}
  assert
  specs (1 at) each table (swap has?) partial all?
  {'kind 'domain 'msg "table.aggregate requires existing input column names"} assert
  names specs (first) each cat dup distinct len swap len =
  {'kind 'domain 'msg "aggregate output names must not collide with each other or a key"} assert
  names len specs len + 0 >
  {'kind 'domain 'msg "table.aggregate needs at least one key or aggregate output"} assert
  table names specs table names group-by aggregate-build)
 'aggregate def

 ### defp key-matches
 (index left-keys right-keys -- indices : "Return matching right-row indices in ascending order.")
 (|index left-keys right-keys|
  right-keys left-keys index at (match?) partial each selected)
 'key-matches defp

 ### defp table-row
 (index table -- row : "Return one row in column order.")
 (|index table| table vals index (at) partial each)
 'table-row defp

 ### defp named-row
 (index table names -- row : "Return selected cells from one row in name order.")
 (|index table names| names table index (cell) partial partial each)
 'named-row defp

 ### defp emit-pair
 (rows right-index context left-index -- rows : "Append one matched left/right row pair.")
 (|rows right-index context left-index|
  rows
  left-index context first table-row
  right-index context 1 at context 2 at named-row
  cat
  append)
 'emit-pair defp

 ### defp emit-matches
 (matches rows index context -- rows : "Append all right matches for one left row.")
 (|matches rows index context|
  matches rows context index (emit-pair) partial partial fold)
 'emit-matches defp

 ### defp emit-filled
 (matches rows index context -- rows : "Append a fill row for an unmatched left row.")
 (|matches rows index context|
  rows
  index context first table-row
  context 5 at
  cat
  append)
 'emit-filled defp

 ### defp inner-step
 (rows index context -- rows : "Append inner-join results for one left row.")
 (|rows index context|
  index context 3 at context 4 at key-matches
  rows index context emit-matches)
 'inner-step defp

 ### defp left-step
 (rows index context -- rows : "Append left-join results for one left row.")
 (|rows index context|
  index context 3 at context 4 at key-matches
  dup len 0 =
  rows index context (emit-filled) partial partial partial
  rows index context (emit-matches) partial partial partial
  if)
 'left-step defp

 ### defp pair-shaped?
 (pair -- bool : "Return 1 for a [left-name right-name] join-key pair.")
 (dup type 'list match?
  (dup len 2 =
   (dup first string? swap 1 at string? and)
   (pop 0)
   if)
  (pop 0)
  if)
 'pair-shaped? defp

 ### defp join-plan
 (left right pairs -- extra : "Validate join keys and return the right columns to append.")
 (|left right pairs|
  pairs type 'list match?
  {'kind 'type 'msg "join keys are a list of [left-name right-name] pairs"} assert
  pairs len 0 >
  {'kind 'domain 'msg "a join needs at least one key pair"} assert
  pairs (pair-shaped?) all?
  {'kind 'type 'msg "join keys are a list of [left-name right-name] pairs"} assert
  pairs (first) each left (swap has?) partial all?
  {'kind 'domain 'msg "join keys must name existing left columns"} assert
  pairs (1 at) each right (swap has?) partial all?
  {'kind 'domain 'msg "join keys must name existing right columns"} assert
  pairs (first) each dup distinct len swap len =
  {'kind 'domain 'msg "a join may not repeat a left column"} assert
  pairs (1 at) each dup distinct len swap len =
  {'kind 'domain 'msg "a join may not repeat a right column"} assert
  right keys pairs (1 at) each exclude
  dup left keys name-set (swap has?) partial any? not
  {'kind 'domain
   'msg "a join may not collide non-key column names; rename one first"}
  assert)
 'join-plan defp

 ### defp join-context
 (left right pairs extra fill -- context :
  "Build a join context containing both tables, output names, row keys, and fill values.")
 (|left right pairs extra fill|
  left right extra
  left height range left pairs (first) each (row-key) partial partial each
  right height range right pairs (1 at) each (row-key) partial partial each
  fill
  6 pack)
 'join-context defp

 ### defp join-rows
 (left right pairs extra fill step -- table :
  "Build a join result by applying a step to each left row.")
 (|left right pairs extra fill step|
  left keys extra cat
  left height range
  []
  left right pairs extra fill join-context step partial
  fold
  from-rows)
 'join-rows defp

 ### def inner-join
 (left right pairs -- table :
  "Return the inner equijoin for [left-name right-name] key pairs.

   Duplicate keys produce every matching pair in left-row then right-row order. The result contains
   all left columns followed by right non-key columns. Colliding non-key names raise 'domain.")
 (|left right pairs|
  left checked pop
  right checked pop
  left right pairs
  left right pairs join-plan
  []
  (inner-step)
  join-rows)
 'inner-join def

 ### defp left-join-checked
 (left right pairs fill extra -- table : "Build a left join from validated fill values.")
 (|left right pairs fill extra|
  extra fill (swap has?) partial all?
  {'kind 'domain 'msg "a fill must cover every appended right column"} assert
  extra len fill keys len =
  {'kind 'domain 'msg "a fill must cover exactly the appended right columns"} assert
  left right pairs extra
  extra fill (swap at) partial each
  (left-step)
  join-rows)
 'left-join-checked defp

 ### def left-join-with
 (left right pairs fill -- table :
  "Return a left equijoin using fill values for unmatched rows.

   The fill dictionary must contain exactly the appended right-column names.")
 (|left right pairs fill|
  left checked pop
  right checked pop
  fill type 'dict match?
  {'kind 'type 'msg "table.left-join-with expects a fill dict"} assert
  left right pairs fill
  left right pairs join-plan
  left-join-checked)
 'left-join-with def

 )
'table
@defm
