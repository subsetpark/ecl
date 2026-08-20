### module table
# The table module: a table is a validated ordinary column dictionary, never a
# new runtime kind.
#
# The convention is a nonempty insertion-ordered dict whose keys are unique
# nonempty strings and whose values are lists sharing one top-level length. A
# table may have zero rows but never zero columns. Core reflection stays
# honest — `type` still reports 'dict, and `keys`/`at`/`put` behave as they do
# for any dict — which means a core operation can produce an invalid candidate.
# Every exported word here therefore validates its table arguments before doing
# any work, rather than repairing or reclassifying what it is handed.
(
 ### def text?
 ((type 'char match?) all?)
 (value -- bool : "Return 1 when a value is a list of characters, which is what a string is.")
 'text? defp

 ### def string?
 (dup type 'list match? (text?) (pop 0) if)
 (value -- bool : "Return 1 when a value is a string, without raising for other kinds.")
 'string? defp

 ### def checked
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
 (candidate -- table :
  "Return a table unchanged, raising the convention's error kind when the candidate is invalid.")
 'checked defp

 ### def convention-miss?
 (dup 'err at 'kind at ['type 'shape 'domain] in? (pop 0) ('err at raise) if)
 (result -- bool :
  "Report a convention mismatch as 0, re-raising anything else so cancellation still propagates.")
 'convention-miss? defp

 ### def valid?
 (wrap (checked pop) with @attempt dup result.ok? (pop 1) (convention-miss?) if)
 (candidate -- bool :
  "Return 1 when a candidate satisfies the table convention and 0 when it does not.

   Only a convention mismatch answers 0; cancellation and allocation failure still propagate.")
 'valid? def

 ### def names
 (checked keys)
 (table -- names : "Return a table's column names in schema order.")
 'names def

 ### def height
 (checked vals first len)
 (table -- count : "Return a table's row count.")
 'height def

 ### def from-columns
 (checked)
 (columns -- table :
  "Return a column dict as a table, raising when it does not satisfy the convention.")
 'from-columns def

 ### def from-rows
 ((|names rows|
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
   names
   rows names len transpose
   to-dict)
  call)
 (names rows -- table :
  "Build a table from explicit column names and exact-width rows.

   An empty row list is legal and yields the named zero-row schema.")
 'from-rows def

 ### def from-header-rows
 (dup type 'list match?
  {'kind 'type 'msg "table.from-header-rows expects a list of rows"} assert
  dup len 0 >
  {'kind 'shape 'msg "table.from-header-rows needs a header row"} assert
  dup first swap 1 drop from-rows)
 (rows -- table : "Build a table from rows whose first row holds the column names.")
 'from-header-rows def

 ### def record-fits?
 ((|record names| record keys len names len =
   names record (swap has?) partial all?
   and)
  call)
 (record names -- bool : "Return 1 when a record's key set is exactly the given names.")
 'record-fits? defp

 ### def record-column
 ((|name records| records name (at) partial each) call)
 (name records -- column : "Collect one named field from every record, in record order.")
 'record-column defp

 ### def from-records
 ((|records|
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
   records records first keys (record-fits?) partial all?
   {'kind 'domain 'msg "every record must carry exactly the first record's keys"} assert
   records first keys
   records first keys records (record-column) partial each
   to-dict)
  call)
 (records -- table :
  "Build a table from a nonempty list of dicts sharing one key set.

   The first record fixes the schema order; later records may list their keys in any order but may
   not add or omit one.")
 'from-records def

 ### def rows
 (checked dup vals swap height transpose)
 (table -- rows : "Return a table's data rows in order.")
 'rows def

 ### def header-rows
 (checked dup keys swap rows cons)
 (table -- rows :
  "Return a table's rows with its column names prefixed, the schema-preserving row form.")
 'header-rows def

 ### def records
 (checked dup keys swap rows swap (swap to-dict) partial each)
 (table -- records :
  "Return a table's rows as dicts in schema order; an empty result necessarily loses the schema.")
 'records def

 ### def column
 ((|table name|
   table checked pop
   table name has?
   {'kind 'domain 'msg "table.column requires an existing column name"} assert
   table name at)
  call)
 (table name -- column : "Return one named column.")
 'column def

 ### def cast
 ((|table spec|
   table checked pop
   spec type 'dict match?
   {'kind 'type 'msg "table.cast expects a dict from column name to quotation"} assert
   spec keys table (swap has?) partial all?
   {'kind 'domain 'msg "table.cast requires existing column names"} assert
   spec vals (type 'list match?) all?
   {'kind 'type 'msg "table.cast expects a quotation for every named column"} assert
   spec pairs table (cast-column) fold)
  call)
 (table spec -- table :
  "Coerce named columns with isolated ( cell -- value ) quotations.

   The complete specification is validated before any quotation runs, and the result replaces the
   table only once every cast succeeded.")
 'cast def

 ### def cast-column
 ((|table pair| table pair first
   table pair first at pair 1 at each
   put)
  call)
 (table pair -- table :
  "Replace one column with the result of applying a cast quotation to each of its cells.")
 'cast-column defp

 ### def select
 ((|table names|
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
  call)
 (table names -- table : "Keep the named columns, in the order given.")
 'select def

 ### def rename
 ((|table mapping|
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
  call)
 (table mapping -- table :
  "Rename columns through an ordered old-to-new mapping, preserving column order.")
 'rename def

 ### def with-column
 ((|table name column|
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
  call)
 (table name column -- table :
  "Replace an existing column in place, or append a new one, keeping the row count exact.")
 'with-column def

 ### def keep-index
 ((|accumulated index mask| mask index at 1 =
   accumulated index pair (append) with
   accumulated literal
   if)
  call)
 (indices index mask -- indices :
  "Append an index to the accumulated selection when its mask entry is 1.")
 'keep-index defp

 ### def selected
 ((|mask| mask len range [] mask (keep-index) partial fold) call)
 (mask -- indices :
  "Expand a 0/1 mask into the indices it selects.

   Written with fold rather than `filter`, `partition`, or `find`, all three of which call the core
   `where` kernel. This module exports a word named `where`, and `'table use` splices that export
   into the session scope where prelude bodies resolve their dependencies — the documented way to
   patch a binding. So those three would reach `table.where` for any program that imported this
   module, including this module's own `where`.")
 'selected defp

 ### def slice-at
 ((|position lists| lists position (at) partial each) call)
 (position lists -- slice : "Take one positional element from every list.")
 'slice-at defp

 ### def transpose
 ((|lists count| count range lists (slice-at) partial each) call)
 (lists count -- transposed :
  "Transpose a rectangular list of lists, treating every cell as an opaque value.

   The core `flip` kernel cannot serve here. A string is itself a list, so a row holding both a
   number and a string is not a rectangular nested array and `flip` rejects it as 'shape — which is
   the ordinary case for a table with one numeric and one text column. Counting the output length
   explicitly also makes the zero-row case fall out rather than needing its own branch.")
 'transpose defp

 ### def name-set
 ((|names| names names (pop 1) each to-dict) call)
 (names -- set :
  "Build a dict whose keys are the given names, for membership tests.

   `in?` pervades into a sought string rather than comparing it whole, and `find` reaches the core
   `where` this module shadows, so name membership goes through `has?` on a dict instead.")
 'name-set defp

 ### def exclude
 ((|names excluded|
   names names excluded name-set (swap has?) partial each not selected at)
  call)
 (names excluded -- names :
  "Keep the names that are not in the excluded set, in their original order.")
 'exclude defp

 ### def where
 ((|table mask|
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
  call)
 (table mask -- table : "Keep the rows selected by an exact-length 0/1 mask.")
 'where def

 # --- analysis -------------------------------------------------------------

 ### def cell
 ((|name table index| table name at index at) call)
 (name table index -- cell : "Read one cell by column name and row index.")
 'cell defp

 ### def row-key
 ((|index table names| names table index (cell) partial partial each) call)
 (index table names -- key : "Collect the named cells of one row as a composite structural key.")
 'row-key defp

 ### def composite-keys
 ((|table names| table height range table names (row-key) partial partial each) call)
 (table names -- keys : "Composite keys for every row, in row order.")
 'composite-keys defp

 ### def group-keys
 ((|table names| names len 1 =
   table names first (at) partial partial
   table names (composite-keys) partial partial
   if)
  call)
 (table names -- keys :
  "Grouping keys for every row: the column itself for one name, a composite key for more.")
 'group-keys defp

 ### def global-group
 ((|table| [] wrap table height range wrap to-dict) call)
 (table -- groups : "The single global group covering every row index.")
 'global-group defp

 ### def group-by
 ((|table names|
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
  call)
 (table names -- groups :
  "Group row indices by the named columns.

   Keys appear in first-occurrence order and each group's indices stay ascending. Zero names means
   one global group, whose key is the empty list.")
 'group-by def

 ### def apply-aggregate
 ((|column quotation| column wrap quotation each first) call)
 (column quotation -- value :
  "Apply an isolated ( column -- value ) quotation once.

   Routing through `each` is what makes a quotation that leaves the wrong number of values a
   'contract failure rather than a silent stack corruption.")
 'apply-aggregate defp

 ### def group-value
 ((|indices table spec| table spec 1 at at indices at spec 2 at apply-aggregate) call)
 (indices table spec -- value :
  "Apply one aggregate specification to one group's slice of its input column.")
 'group-value defp

 ### def aggregate-column
 ((|spec table groups| groups vals table spec (group-value) partial partial each) call)
 (spec table groups -- column : "Build one aggregate column, one value per group in group order.")
 'aggregate-column defp

 ### def key-component
 ((|position groups| groups keys position (at) partial each) call)
 (position groups -- column : "Extract one component of every composite group key.")
 'key-component defp

 ### def key-columns
 ((|groups names| names len 1 =
   groups (keys wrap) partial
   groups names (composite-key-columns) partial partial
   if)
  call)
 (groups names -- columns : "The key columns implied by a grouping, in name order.")
 'key-columns defp

 ### def composite-key-columns
 ((|groups names| names len range groups (key-component) partial each) call)
 (groups names -- columns : "One column per name from composite group keys.")
 'composite-key-columns defp

 ### def spec-shaped?
 (dup type 'list match?
  (dup len 3 =
   (dup first string? over 1 at string? and swap 2 at type 'list match? and)
   (pop 0)
   if)
  (pop 0)
  if)
 (spec -- bool : "Return 1 when a value is an [output-name input-name quotation] triple.")
 'spec-shaped? defp

 ### def aggregate-build
 ((|table names specs groups|
   names specs (first) each cat
   groups names key-columns
   specs table groups (aggregate-column) partial partial each
   cat
   to-dict)
  call)
 (table names specs groups -- table :
  "Assemble key columns followed by aggregate columns in group-then-spec order.")
 'aggregate-build defp

 ### def aggregate
 ((|table names specs|
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
  call)
 (table names specs -- table :
  "Group by the named columns and aggregate each group with [output input quotation] triples.

   The whole specification is validated before any quotation runs. Key columns come first, then one
   column per specification in the order given, with one row per group.")
 'aggregate def

 ### def key-matches
 ((|index left-keys right-keys|
   right-keys left-keys index at (match?) partial each selected)
  call)
 (index left-keys right-keys -- indices :
  "Right-row indices whose key equals the left row's key, in ascending order.")
 'key-matches defp

 ### def table-row
 ((|index table| table vals index (at) partial each) call)
 (index table -- row : "One whole row of a table, in schema order.")
 'table-row defp

 ### def named-row
 ((|index table names| names table index (cell) partial partial each) call)
 (index table names -- row : "The named cells of one row, in name order.")
 'named-row defp

 ### def emit-pair
 ((|rows right-index context left-index|
   rows
   left-index context first table-row
   right-index context 1 at context 2 at named-row
   cat
   append)
  call)
 (rows right-index context left-index -- rows :
  "Append the combination of one left row with one matching right row.")
 'emit-pair defp

 ### def emit-matches
 ((|matches rows index context|
   matches rows context index (emit-pair) partial partial fold)
  call)
 (matches rows index context -- rows :
  "Append one row per match, in right-row order within this left row.")
 'emit-matches defp

 ### def emit-filled
 ((|matches rows index context|
   rows
   index context first table-row
   context 5 at
   cat
   append)
  call)
 (matches rows index context -- rows : "Append one filled row for a left row that matched nothing.")
 'emit-filled defp

 ### def inner-step
 ((|rows index context|
   index context 3 at context 4 at key-matches
   rows index context emit-matches)
  call)
 (rows index context -- rows : "Inner-join step for one left row.")
 'inner-step defp

 ### def left-step
 ((|rows index context|
   index context 3 at context 4 at key-matches
   dup len 0 =
   rows index context (emit-filled) partial partial partial
   rows index context (emit-matches) partial partial partial
   if)
  call)
 (rows index context -- rows : "Left-join step for one left row, filling when nothing matched.")
 'left-step defp

 ### def pair-shaped?
 (dup type 'list match?
  (dup len 2 =
   (dup first string? swap 1 at string? and)
   (pop 0)
   if)
  (pop 0)
  if)
 (pair -- bool : "Return 1 when a value is a [left-name right-name] string pair.")
 'pair-shaped? defp

 ### def join-plan
 ((|left right pairs|
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
  call)
 (left right pairs -- extra : "Validate a join and return the right columns the result appends.")
 'join-plan defp

 ### def join-context
 ((|left right pairs extra fill|
   left right extra
   left height range left pairs (first) each (row-key) partial partial each
   right height range right pairs (1 at) each (row-key) partial partial each
   fill
   6 pack)
  call)
 (left right pairs extra fill -- context :
  "Bundle the tables, appended names, precomputed row keys, and fill row one join needs.")
 'join-context defp

 ### def join-rows
 ((|left right pairs extra fill step|
   left keys extra cat
   left height range
   []
   left right pairs extra fill join-context step partial
   fold
   from-rows)
  call)
 (left right pairs extra fill step -- table :
  "Fold one join step over every left row and rebuild a table from the emitted rows.")
 'join-rows defp

 ### def inner-join
 ((|left right pairs|
   left checked pop
   right checked pop
   left right pairs
   left right pairs join-plan
   []
   (inner-step)
   join-rows)
  call)
 (left right pairs -- table :
  "Stable inner equijoin on [left-name right-name] key pairs.

   Duplicate keys expand to the full many-to-many product in left-row order and, within one left
   row, right-row order. The result carries every left column in its original order followed by the
   right non-key columns in right order. A non-key name collision is 'domain; resolve it with
   table.rename first.")
 'inner-join def

 ### def left-join-checked
 ((|left right pairs fill extra|
   extra fill (swap has?) partial all?
   {'kind 'domain 'msg "a fill must cover every appended right column"} assert
   extra len fill keys len =
   {'kind 'domain 'msg "a fill must cover exactly the appended right columns"} assert
   left right pairs extra
   extra fill (swap at) partial each
   (left-step)
   join-rows)
  call)
 (left right pairs fill extra -- table :
  "Left-join once the fill has been checked against the appended columns.")
 'left-join-checked defp

 ### def left-join-with
 ((|left right pairs fill|
   left checked pop
   right checked pop
   fill type 'dict match?
   {'kind 'type 'msg "table.left-join-with expects a fill dict"} assert
   left right pairs fill
   left right pairs join-plan
   left-join-checked)
  call)
 (left right pairs fill -- table :
  "Stable left equijoin that fills unmatched left rows from an exact fill dict.

   The fill must name exactly the appended right columns — no more and no fewer — so an unmatched
   row is completed only with values the caller supplied. Nothing is invented.")
 'left-join-with def

 )
'table
@defm
