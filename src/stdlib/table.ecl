### module table
# Tables are column dictionaries. Column names are nonempty strings, column
# values are lists, and every column has the same length. A table has at least
# one column and may have zero rows. Column order is dictionary insertion order.
#
# Tables remain ordinary dictionaries: `type`, `keys`, `at`, and `put` keep
# their normal behavior. Exported table operations validate table arguments and
# raise an error for invalid dictionaries.
[]
(
 ### defp text?
 (value -- bool : "Return 1 when every item in a list is a character.")
 ((type 'char match?) all?) 'text? defp

 ### defp string?
 (value -- bool : "Return 1 when a value is a string and 0 for every other value.")
 (dup type 'list match? (text?) (pop 0) if) 'string? defp

 ### defp checked
 (candidate -- table : "Validate and return a table candidate.")
 (dup type 'dict match?
  'type error.new "a table must be a dict of columns" error.with-message assert
  dup dict.size 0 >
  'shape error.new "a table must have at least one column" error.with-message assert
  dup dict.keys (string?) all?
  'type error.new "table column names must be strings" error.with-message assert
  dup dict.keys (len) each 0 > 1 (and) fold
  'domain error.new "table column names must not be empty" error.with-message assert
  dup dict.vals (type 'list match?) all?
  'type error.new "table columns must be lists" error.with-message assert
  dup dict.vals (len) each distinct len 2 <
  'shape error.new "table columns must share one length" error.with-message assert) 'checked defp

 ### defp convention-miss?
 (result -- bool : "Return 0 for a table validation error and re-raise any other error.")
 (dup 'err at ['type 'shape 'domain] error.kind-in? (pop 0) ('err at raise) if) 'convention-miss?
 defp

 ### def valid?
 (candidate -- bool :
  "Return 1 when a candidate is a table and 0 when it is not.

   Cancellation, allocation failure, and other runtime errors propagate.")
 (wrap (checked pop) @attempt dup result.ok? (pop 1) (convention-miss?) if) 'valid? def

 ### def names
 (table -- names : "Return the column names in column order.")
 (checked dict.keys) 'names def

 ### def height
 (table -- count : "Return the number of rows.")
 (checked dict.vals first len) 'height def

 ### def from-columns
 (columns -- table : "Validate a column dictionary and return it as a table.")
 (checked) 'from-columns def

 ### def from-rows
 (names rows -- table :
  "Build a table from column names and rows of the same width.

   An empty row list produces a zero-row table with the given columns.")
 (|names rows|
  names type 'list match?
  'type error.new "table.from-rows expects a list of column names" error.with-message assert
  names len 0 >
  'shape error.new "a table must have at least one column" error.with-message assert
  names (string?) all?
  'type error.new "table column names must be strings" error.with-message assert
  names (len) each 0 > 1 (and) fold
  'domain error.new "table column names must not be empty" error.with-message assert
  names distinct len names len =
  'domain error.new "table.from-rows rejects duplicate column names" error.with-message assert
  rows type 'list match?
  'type error.new "table.from-rows expects a list of rows" error.with-message assert
  rows (type 'list match?) all?
  'type error.new "table.from-rows expects every row to be a list" error.with-message assert
  rows (len) each names len = 1 (and) fold
  'shape error.new "every row must have one cell per column name" error.with-message assert
  names rows names len transpose dict.from-lists) 'from-rows def

 ### def from-header-rows
 (rows -- table : "Build a table using the first row as column names and the rest as data rows.")
 (dup type 'list match?
  'type error.new "table.from-header-rows expects a list of rows" error.with-message assert
  dup len 0 >
  'shape error.new "table.from-header-rows needs a header row" error.with-message assert
  dup first swap 1 drop from-rows) 'from-header-rows def

 ### defp record-column
 (name records -- column : "Return one field from each record, preserving record order.")
 (|name records| records name (at) partial each) 'record-column defp

 ### def from-records
 (records -- table :
  "Build a table from a nonempty list of records with the same keys.

   The first record sets column order. Later records may use a different key order.")
 (|records|
  records type 'list match?
  'type error.new "table.from-records expects a list of records" error.with-message assert
  records len 0 >
  'shape error.new "table.from-records cannot infer a schema from no records" error.with-message
  assert
  records (type 'dict match?) all?
  'type error.new "table.from-records expects every record to be a dict" error.with-message assert
  records first dict.keys (string?) all?
  'type error.new "table column names must be strings" error.with-message assert
  records first dict.keys (len) each 0 > 1 (and) fold
  'domain error.new "table column names must not be empty" error.with-message assert
  records records first dict.keys (dict.keys-exactly?) partial all?
  'domain error.new "every record must carry exactly the first record's keys" error.with-message
  assert
  records first dict.keys
  records first dict.keys records (record-column) partial each
  dict.from-lists) 'from-records def

 ### def rows
 (table -- rows : "Return the data rows in row and column order.")
 (checked dict.vals column-rows) 'rows def

 ### def header-rows
 (table -- rows : "Return the column-name row followed by the data rows.")
 (checked dup dict.keys swap dict.vals column-rows cons) 'header-rows def

 ### def records
 (table -- records :
  "Return one record per row, with keys in column order. A zero-row table returns an empty list.")
 (checked dup dict.keys swap dict.vals column-rows swap (swap dict.from-lists) partial each)
 'records def

 ### def column
 (table name -- column : "Return a column by name.")
 (|table name|
  table checked pop
  table name dict.has?
  'domain error.new "table.column requires an existing column name" error.with-message assert
  table name at) 'column def

 ### def cast
 (table spec -- table :
  "Apply each specification's ( cell -- value ) quotation to its named column.

   The specification must be a dictionary from existing column names to quotations. All entries are
   validated before a quotation runs.")
 (|table spec|
  table checked pop
  spec type 'dict match?
  'type error.new "table.cast expects a dict from column name to quotation" error.with-message
  assert
  spec dict.keys table (swap dict.has?) partial all?
  'domain error.new "table.cast requires existing column names" error.with-message assert
  spec dict.vals (type 'list match?) all?
  'type error.new "table.cast expects a quotation for every named column" error.with-message assert
  spec dict.pairs table (cast-column) fold) 'cast def

 ### defp cast-column
 (table pair -- table : "Apply one [name quotation] cast specification to a table.")
 (|table pair| table pair first
  table pair first at pair 1 at each
  put) 'cast-column defp

 ### def select
 (table names -- table : "Return the named columns in the requested order.")
 (|table names|
  table checked pop
  names type 'list match?
  'type error.new "table.select expects a list of column names" error.with-message assert
  names len 0 >
  'shape error.new "a table must have at least one column" error.with-message assert
  names distinct len names len =
  'domain error.new "table.select rejects duplicate column names" error.with-message assert
  names table (swap dict.has?) partial all?
  'domain error.new "table.select requires existing column names" error.with-message assert
  names
  names table (swap at) partial each
  dict.from-lists) 'select def

 ### def rename
 (table mapping -- table : "Rename columns without changing column order.")
 (|table mapping|
  table checked pop
  mapping type 'dict match?
  'type error.new "table.rename expects a dict from old name to new name" error.with-message assert
  mapping dict.keys table (swap dict.has?) partial all?
  'domain error.new "table.rename requires existing column names" error.with-message assert
  mapping dict.vals (string?) all?
  'type error.new "table column names must be strings" error.with-message assert
  mapping dict.vals (len) each 0 > 1 (and) fold
  'domain error.new "table column names must not be empty" error.with-message assert
  table dict.keys mapping (swap dup at-or) partial each
  dup distinct len over len =
  'domain error.new "table.rename would collide two columns onto one name" error.with-message assert
  table dict.vals dict.from-lists) 'rename def

 ### def with-column
 (table name column -- table :
  "Replace a named column or append a new column. The column length must equal the row count.")
 (|table name column|
  table checked pop
  name string?
  'type error.new "table column names must be strings" error.with-message assert
  name len 0 >
  'domain error.new "table column names must not be empty" error.with-message assert
  column type 'list match?
  'type error.new "table.with-column expects a list" error.with-message assert
  column len table dict.vals first len =
  'shape error.new "a replacement column must match the table's row count" error.with-message assert
  table name column put) 'with-column def

 ### defp transpose
 (lists count -- transposed :
  "Transpose whole cells, retaining the known output width when either axis is empty.")
 (|lists count| lists len 0 = count 0 = or
  count ([] wrap swap take) partial
  lists (flip) partial
  if) 'transpose defp

 ### defp column-rows
 (columns -- rows : "Transpose validated columns into rows, including zero-row tables.")
 (dup first len transpose) 'column-rows defp

 ### defp name-set
 (names -- set : "Build a dictionary for whole-name membership tests.")
 (1 dict.from-keys) 'name-set defp

 ### defp exclude
 (names excluded -- names : "Remove excluded names while preserving the order of the input names.")
 (|names excluded|
  names excluded name-set (swap dict.has? not) partial filter) 'exclude defp

 ### def where
 (table mask -- table :
  "Return rows selected by a 0/1 mask. The mask length must equal the row count.")
 (|table mask|
  table checked pop
  mask type 'list match?
  'type error.new "table.where expects a mask list" error.with-message assert
  mask [0 1] in? 1 (and) fold
  'type error.new "a table mask holds only 0 and 1" error.with-message assert
  mask len table dict.vals first len =
  'shape error.new "a table mask must match the table's row count" error.with-message assert
  table mask core.where (at) partial each) 'where def

 # --- grouping, aggregation, and joins -------------------------------------

 ### defp composite-keys
 (table names -- keys : "Transpose the selected columns into whole composite row keys.")
 (|table names|
  names table (swap at) partial each table dict.vals first len transpose) 'composite-keys defp

 ### defp group-keys
 (table names -- keys :
  "Return grouping keys for all rows: scalar keys for one column and list keys for multiple
   columns.")
 (|table names| names len 1 =
  table names first (at) partial partial
  table names (composite-keys) partial partial if) 'group-keys defp

 ### defp global-group
 (table -- groups : "Return one group containing every row index.")
 (|table| [] wrap table height range wrap dict.from-lists) 'global-group defp

 ### def group-by
 (table names -- groups :
  "Group row indices by the named columns.

   Groups follow first occurrence order and indices within each group are ascending. An empty name
   list returns one group keyed by the empty list.")
 (|table names|
  table checked pop
  names type 'list match?
  'type error.new "table.group-by expects a list of column names" error.with-message assert
  names (string?) all?
  'type error.new "table column names must be strings" error.with-message assert
  names table (swap dict.has?) partial all?
  'domain error.new "table.group-by requires existing column names" error.with-message assert
  names distinct len names len =
  'domain error.new "table.group-by rejects duplicate column names" error.with-message assert
  names len 0 =
  table (global-group) partial
  table names (group-keys group) partial partial
  if) 'group-by def

 ### defp apply-aggregate
 (column quotation -- value :
  "Apply an isolated ( column -- value ) quotation to one column slice.

   The quotation must return exactly one value.")
 (|column quotation| column wrap quotation each first) 'apply-aggregate defp

 ### defp aggregate-column
 (spec table groups -- column : "Gather group slices and apply one aggregate to each slice.")
 (|spec table groups|
  table spec 1 at at groups dict.vals at
  spec 2 at (apply-aggregate) partial each) 'aggregate-column defp

 ### defp key-columns
 (groups names -- columns : "Return grouping-key columns in name order.")
 (|groups names| names len 1 =
  groups (dict.keys wrap) partial
  groups names (composite-key-columns) partial partial
  if) 'key-columns defp

 ### defp composite-key-columns
 (groups names -- columns : "Split composite group keys into one column per name.")
 (|groups names| groups dict.keys names len transpose) 'composite-key-columns defp

 ### defp spec-shaped?
 (spec -- bool : "Return 1 for an [output-name input-name quotation] aggregate specification.")
 (dup type 'list match?
  (dup len 3 =
   (dup first string? over 1 at string? and swap 2 at type 'list match? and)
   (pop 0)
   if)
  (pop 0)
  if) 'spec-shaped? defp

 ### defp aggregate-build
 (table names specs groups -- table : "Build a result table from grouping keys and aggregates.")
 (|table names specs groups|
  names specs (first) each cat
  groups names key-columns
  specs table groups (aggregate-column) partial partial each
  cat
  dict.from-lists) 'aggregate-build defp

 ### def aggregate
 (table names specs -- table :
  "Group rows and apply [output-name input-name quotation] aggregate specifications.

   All names and specifications are validated before a quotation runs. The result contains key
   columns first, followed by aggregate columns in specification order, with one row per group.")
 (|table names specs|
  table checked pop
  names type 'list match?
  'type error.new "table.aggregate expects a list of column names" error.with-message assert
  names (string?) all?
  'type error.new "table column names must be strings" error.with-message assert
  names table (swap dict.has?) partial all?
  'domain error.new "table.aggregate requires existing column names" error.with-message assert
  names distinct len names len =
  'domain error.new "table.aggregate rejects duplicate column names" error.with-message assert
  specs type 'list match?
  'type error.new "table.aggregate expects a list of specifications" error.with-message assert
  specs (spec-shaped?) all?
  'type error.new "each aggregate specification is [output-name input-name quotation]"
  error.with-message
  assert
  specs (1 at) each table (swap dict.has?) partial all?
  'domain error.new "table.aggregate requires existing input column names" error.with-message assert
  names specs (first) each cat dup distinct len swap len =
  'domain error.new "aggregate output names must not collide with each other or a key"
  error.with-message assert
  names len specs len + 0 >
  'domain error.new "table.aggregate needs at least one key or aggregate output" error.with-message
  assert
  table names specs table names group-by aggregate-build) 'aggregate def

 ### defp join-matches
 (left right pairs -- matches : "Look up each left key in grouped right-row indices.")
 (|left right pairs|
  left pairs (first) each composite-keys
  right pairs (1 at) each composite-keys group
  (swap [] at-or) partial each) 'join-matches defp

 ### defp fill-matches
 (indices missing -- indices : "Use the appended fill row when a left key has no matches.")
 (|indices missing| indices len 0 = missing (wrap) partial indices literal if) 'fill-matches defp

 ### defp join-columns
 (left right-columns extra matches -- table :
  "Gather all joined columns from shared row selectors.")
 (|left right-columns extra matches|
  left dict.keys extra cat
  left dict.vals matches (len) each core.where (at) partial each
  right-columns matches raze (at) partial each
  cat dict.from-lists) 'join-columns defp

 ### defp pair-shaped?
 (pair -- bool : "Return 1 for a [left-name right-name] join-key pair.")
 (dup type 'list match?
  (dup len 2 =
   (dup first string? swap 1 at string? and)
   (pop 0)
   if)
  (pop 0)
  if) 'pair-shaped? defp

 ### defp join-plan
 (left right pairs -- extra : "Validate join keys and return the right columns to append.")
 (|left right pairs|
  pairs type 'list match?
  'type error.new "join keys are a list of [left-name right-name] pairs" error.with-message assert
  pairs len 0 >
  'domain error.new "a join needs at least one key pair" error.with-message assert
  pairs (pair-shaped?) all?
  'type error.new "join keys are a list of [left-name right-name] pairs" error.with-message assert
  pairs (first) each left (swap dict.has?) partial all?
  'domain error.new "join keys must name existing left columns" error.with-message assert
  pairs (1 at) each right (swap dict.has?) partial all?
  'domain error.new "join keys must name existing right columns" error.with-message assert
  pairs (first) each dup distinct len swap len =
  'domain error.new "a join may not repeat a left column" error.with-message assert
  pairs (1 at) each dup distinct len swap len =
  'domain error.new "a join may not repeat a right column" error.with-message assert
  right dict.keys pairs (1 at) each exclude
  dup left dict.keys name-set (swap dict.has?) partial any? not
  'domain error.new "a join may not collide non-key column names; rename one first"
  error.with-message
  assert) 'join-plan defp

 ### defp inner-join-checked
 (left right pairs extra -- table : "Build a validated inner join with column gathers.")
 (|left right pairs extra|
  left
  extra right (swap at) partial each
  extra
  left right pairs join-matches
  join-columns) 'inner-join-checked defp

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
  inner-join-checked) 'inner-join def

 ### defp left-join-checked
 (left right pairs fill extra -- table : "Build a left join from validated fill values.")
 (|left right pairs fill extra|
  extra fill (swap dict.has?) partial all?
  'domain error.new "a fill must cover every appended right column" error.with-message assert
  extra len fill dict.size =
  'domain error.new "a fill must cover exactly the appended right columns" error.with-message assert
  left
  extra right (swap at) partial each
  extra fill (swap at) partial each
  (append) zip-with
  extra
  left right pairs join-matches
  right dict.vals first len (fill-matches) partial each
  join-columns) 'left-join-checked defp

 ### def left-join-with
 (left right pairs fill -- table :
  "Return a left equijoin using fill values for unmatched rows.

   The fill dictionary must contain exactly the appended right-column names.")
 (|left right pairs fill|
  left checked pop
  right checked pop
  fill type 'dict match?
  'type error.new "table.left-join-with expects a fill dict" error.with-message assert
  left right pairs fill
  left right pairs join-plan
  left-join-checked) 'left-join-with def

) 'table @defm
