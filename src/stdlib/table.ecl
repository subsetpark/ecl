### module table
(: "A table is any dict whose values are lists of equal length.

    The `table.` words model such a value as a table where the column names are the keys, the values
    are the columns, and a row is an indexing into each column for some index.")
(
 ### def table?
 (candidate -- bool : "Return 1 when `candidate` is a table, and 0 otherwise.")
 (dup type `dict match?
  (dict.vals dup (type `list match?) all? ((len) each distinct len 2 <) (pop 0) if)
  (pop 0)
  if) `table? def

 ### def from-rows
 (names rows -- table : "Construct a table with columns `names` and rows `rows`.")
 (|names rows| names rows names len transpose dict.zip) `from-rows def

 ### def from-header-rows
 (rows -- table :
  "Construct a table from `rows`, where the first row contains the column names and the remaining
   rows are data.")
 (dup first swap 1 drop from-rows) `from-header-rows def

 ### defp record-column
 (name records -- column : "Return one field from each record, preserving record order.")
 (|name records| records name (at) cons each) `record-column defp

 ### defp records-table
 (names records -- table : "Gather the `names` fields of every record into columns.")
 (|names records| names names records (record-column) cons each dict.zip) `records-table defp

 ### def from-records
 (records -- table :
  "Construct a table from a list of dicts. The keys of the first element of `records` are used as
   the columns.")
 (dup len 0 = (pop {}) (dup first dict.keys swap records-table) if) `from-records def

 ### def rows
 (table -- rows : "Return `table`'s rows in order.")
 (dict.vals column-rows) `rows def

 ### def header-rows
 (table -- rows : "Return `table`'s rows in order, prepended by a row of column names.")
 (dup dict.keys swap dict.vals column-rows cons) `header-rows def

 ### def records
 (table -- records : "Return one dict per row.")
 (dup dict.keys swap dict.vals column-rows swap (swap dict.zip) cons each) `records def

 ### def select
 (table names -- table : "Select the columns `names`.")
 (|table names| names names table (swap at) cons each dict.zip) `select def

 ### def rename
 (table mapping -- table :
  "Rename columns in `table` mapping names to their replacements in `mapping`.")
 (|table mapping| table dict.keys mapping (swap dup dict.get) cons each table dict.vals dict.zip)
 `rename def

 ### defp fits?
 (table list -- bool : "Return 1 when `list` is as long as every column of `table`.")
 (len (=) cons swap dict.vals (len) each swap all?) `fits? defp

 ### def with-column
 (table name column -- table :
  "Update table with the column name `name` and data `column`. If `name` is already present, it will
   be replaced.")
 (|table name column|
  table column fits?
  `shape error.new "a column must match the table's row count" error.with-message assert
  table name column put) `with-column def

 ### defp transpose
 (lists count -- transposed :
  "Transpose whole cells. With no lists, whose width `flip` cannot know, return `count` empty
   lists.")
 (over len 0 = (nip [] wrap swap take) (pop flip) if) `transpose defp

 ### defp column-rows
 (columns -- rows : "Transpose columns into rows; no columns have no rows.")
 (dup len 0 = () (dup first len transpose) if) `column-rows defp

 ### defp row-count
 (table -- count : "Return the number of rows; a table without columns has none.")
 (dict.vals dup len 0 = (pop 0) (first len) if) `row-count defp

 ### defp name-set
 (names -- set : "Build a dictionary for whole-name membership tests.")
 (1 dict.from-keys) `name-set defp

 ### defp exclude
 (names excluded -- names : "Remove excluded names while preserving the order of the input names.")
 (|names excluded|
  names excluded name-set (swap has? not) cons filter) `exclude defp

 ### def where
 (table mask -- table :
  "Given `mask` over the rows of `table`, take each row as many times as is reflected by its index
   in the mask.")
 (|table mask|
  table mask fits?
  `shape error.new "a table mask must match the table's row count" error.with-message assert
  table mask core.where (at) cons each) `where def

 # --- grouping, aggregation, and joins -------------------------------------

 ### defp selected-groups
 (table names -- groups : "Group selected columns using whole composite row keys.")
 (|table names| names table (swap at) cons each group-columns) `selected-groups defp

 ### defp keyed-groups
 (table names -- groups :
  "Group rows with scalar keys for one column and composite keys for multiple columns.")
 (|table names| names len 1 =
  table names first (at group) cons cons
  table names (selected-groups) cons cons if) `keyed-groups defp

 ### defp global-group
 (table -- groups : "Return one group containing every row index.")
 ([] wrap swap row-count range wrap dict.zip) `global-group defp

 ### def group-by
 (table names -- groups : "Group row indices in `table` by `names`.")
 (|table names|
  names len 0 =
  table (global-group) cons
  table names (keyed-groups) cons cons
  if) `group-by def

 ### defp key-columns
 (groups names -- columns : "Return grouping-key columns in name order.")
 (|groups names| names len 1 =
  groups (dict.keys wrap) cons
  groups names (composite-key-columns) cons cons
  if) `key-columns defp

 ### defp composite-key-columns
 (groups names -- columns : "Split composite group keys into one column per name.")
 (|groups names| groups dict.keys names len transpose) `composite-key-columns defp

 ### defp beside
 (left right -- table :
  "Place the columns of `right` after those of `left`; shared names are `` `domain ``.")
 (|left right| left dict.keys right dict.keys cat left dict.vals right dict.vals cat dict.zip)
 `beside defp

 ### def aggregate
 (table names (q: grouped -- columns) -- table :
  "Group `table` by `names` and apply `q` once to the grouped table, in which each non-key column
   holds one slice per group. `q` returns a dict of output columns with one value per group,
   typically by reducing each slice, as in `g \"v\" at (sum) each`. The result holds the key
   columns, then the output columns, with one row per group.")
 (|table names q|
  table names group-by
  dup names key-columns names swap dict.zip
  swap dict.vals (at) cons table names dict.del swap each
  wrap q each first
  beside) `aggregate def

 ### defp ordered-matches
 (left-groups right-groups -- matches : "Expand distinct-key matches into original left-row order.")
 (|left-groups right-groups|
  right-groups left-groups dict.keys [] dict.at-or
  left-groups dict.vals (len) each core.where at
  left-groups dict.vals raze grade at) `ordered-matches defp

 ### defp join-matches
 (left right pairs -- matches :
  "Look up grouped composite keys and restore left-row order. With no key pairs every left row
   matches every right row.")
 (|left right pairs|
  left pairs (first) each group-by
  right pairs (1 at) each group-by
  ordered-matches) `join-matches defp

 ### defp fill-matches
 (indices missing -- indices : "Use the appended fill row when a left key has no matches.")
 (|indices missing| indices len 0 = missing (wrap) cons indices wrap if) `fill-matches defp

 ### defp join-columns
 (left right-columns extra matches -- table :
  "Gather all joined columns from shared row selectors.")
 (|left right-columns extra matches|
  left dict.keys extra cat
  left dict.vals matches (len) each core.where (at) cons each
  right-columns matches raze (at) cons each
  cat dict.zip) `join-columns defp

 ### defp join-extra
 (right pairs -- extra : "Return the right non-key column names to append.")
 (|right pairs| right dict.keys pairs (1 at) each exclude) `join-extra defp

 ### def inner-join
 (left right pairs -- table :
  "Return the stable inner equijoin for `[left-name right-name]` key pairs. Duplicate keys expand to
   the full many-to-many product in left-row then right-row order, and no key pairs give the cross
   product. The result contains every left column and the right non-key columns; colliding non-key
   names are `` `domain ``.")
 (|left right pairs|
  left
  right pairs join-extra dup right (swap at) cons each swap
  left right pairs join-matches
  join-columns) `inner-join def

 ### def left-join-with
 (left right pairs fill -- table :
  "Return the stable left equijoin, using fill values for unmatched rows. `fill` must hold a value
   for every appended right column.")
 (|left right pairs fill|
  left
  right pairs join-extra
  dup right (swap at) cons each
  over fill (swap at) cons each
  (append) zip-with
  swap
  left right pairs join-matches
  right row-count (fill-matches) cons each
  join-columns) `left-join-with def

) `table @defm
