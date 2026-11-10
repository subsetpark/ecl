### module csv
(: "RFC 4180 comma-separated values. `parse` splits text into rows of string fields and `emit`
    renders rows back; neither converts a field. A typed column is a `table.cast` over parsed
    rows.")
(
 ### setp block
 (-- count : "Characters lexed at a time, which bounds the masks a parse holds.")
 65536 `block setp

 ### defp refuse
 (kind message -- : "Raise an error of a kind with a message.")
 (|kind message| kind error.new message error.with-message raise) `refuse defp

 ### defp refuse-unless
 (holds kind message -- : "Raise an error of a kind with a message unless a condition holds.")
 (|holds kind message| kind message holds (pop pop) (refuse) if) `refuse-unless defp

 ### defp shifted
 (mask fill -- mask : "Each position's predecessor, with a fill before the first.")
 (wrap swap cat -1 drop) `shifted defp

 ### defp followed
 (mask fill -- mask : "Each position's successor, with a fill after the last.")
 (wrap swap 1 drop swap cat) `followed defp

 ### defp located
 (splits newlines index base -- record column :
  "The one-based record and field holding a character of a block that follows `base` records.")
 (|s n i base|
  s n and i take 0 (+) fold base + 1 +
  s i take s n and i take reverse 0 (or) scan reverse not and 0 (+) fold 1 +) `located defp

 ### defp misquoted
 (record column -- : "Raise the parse error naming a record and field.")
 (|record column|
  `parse "csv: malformed quoting at record " record str cat ", column " cat column str cat refuse)
 `misquoted defp

 ### defp malformed
 (splits newlines index base -- : "Raise the parse error for the character at an index.")
 (located misquoted) `malformed defp

 ### defp verify
 (splits newlines bad base -- : "Raise for the first set position of a mask, if any.")
 (|s n bad base| s n bad first-where base bad 0 (or) fold (malformed) (pop pop pop pop) if)
 `verify defp

 ### defp rows-of
 (text drop splits newlines -- rows : "Cut validated text into fields, and the fields into rows.")
 (|x d s n|
  x d not where at d not 0 (+) scan s where at 0 shifted cut
  n s where at where 1 + 0 shifted cut) `rows-of defp

 ### defp unclosed
 (splits newlines open base inside -- : "Raise at the last opening quote when it is never closed.")
 (last 1 = (|s n open base| s n open where last base malformed) (pop pop pop pop) if)
 `unclosed defp

 ### defp checked
 (text quote inside newlines splits open base -- :
  "Reject a quote left open, a quote that opens mid-field, text after a closing quote, and a bare
   carriage return.")
 (|x q e n s open base|
  s n open base e unclosed
  s n
  open s 1 shifted not and
  q e not and q x \, = or n or x 13 char = or 1 followed not and or
  x 13 char = e not and n 1 followed not and or
  base verify) `checked defp

 ### defp fielded
 (text quote inside newlines splits kept base -- rows :
  "Validate the quoting, then cut the fields and the rows.")
 (|x q e n s kept base|
  x q e n s q e and kept not and base checked
  x s q kept not and or x 13 char = e not and or s n rows-of) `fielded defp

 ### defp separated
 (text quote inside newlines base -- rows :
  "Find the field separators and the quotes that are text.")
 (|x q e n base| x q e n x \, = n or e not and q e not and 0 shifted q and base fielded)
 `separated defp

 ### defp quoted
 (text quote base -- rows : "Find the characters inside quotes, and the newlines.")
 (|x q base| x q q 0 (<>) scan x "\n" first = base separated) `quoted defp

 ### defp lexed
 (text base -- rows : "Split whole newline-terminated records that follow `base` earlier ones.")
 (|x base| x x \" = base quoted) `lexed defp

 ### defp held
 (state block inside -- state : "Keep a block that ends no record.")
 (|state block e| state 0 at block wrap cat e last state 2 at state 3 at 4 pack) `held defp

 ### defp resumed
 (state block inside end rows -- state : "The state after a block whose records became rows.")
 (|state block e k rows|
  block k drop wrap e last state 2 at rows wrap cat state 3 at rows len + 4 pack) `resumed defp

 ### defp divided
 (state block inside end -- state : "Lex through a block's last record end and hold the rest.")
 (|state block e k| state block e k state 0 at raze block k take cat state 3 at lexed resumed)
 `divided defp

 ### defp ended
 (state block inside -- state : "Hold a block, or lex through its last record end.")
 (|state block e|
  state block e block "\n" first = e not and where dup len 0 = (pop held) (last 1 + divided) if)
 `ended defp

 ### defp step
 (state block -- state :
  "Advance the held pieces, quote parity, row chunks, and record count by one block.")
 (|state block| state block block \" = state 1 at (<>) scan ended) `step defp

 ### defp tail
 (chunks count text -- chunks : "Lex a final record that no newline ends.")
 (|chunks count text| chunks text "\n" cat count lexed wrap cat) `tail defp

 ### defp finished
 (state -- rows : "Lex what follows the last record end and join the row chunks.")
 (|state| state 2 at state 3 at state 0 at raze dup len 0 = (pop pop) (tail) if raze)
 `finished defp

 ### defp uneven
 (widths record -- : "Raise the shape error naming a record and both widths.")
 (|widths at-record|
  `shape "csv: record " at-record 1 + str cat " has " cat widths at-record at str cat
  " fields where record 1 has " cat widths first str cat refuse) `uneven defp

 ### defp ragged
 (rows widths -- : "Raise for the first record whose width differs from the first record's.")
 (|rows widths| widths widths widths first = not first-where uneven) `ragged defp

 ### defp rectangular
 (rows -- rows : "Reject a record whose width differs from the first record's.")
 (dup (len) each dup distinct len 2 < (pop) (ragged) if) `rectangular defp

 ### def parse
 (input -- rows :
  "Split RFC 4180 comma-separated content into rows of string fields. Input is a string or a list of
   UTF-8 bytes. Every record is data and every field is text: nothing is converted, so a typed
   column is a `table.cast` away. Accept CRLF or LF records, quoted commas and newlines,
   doubled-quote escapes, and a final record with no terminator. Preserve blank records and empty
   fields. Empty input is no rows.

   Records of unequal width are `` `shape ``. A quote inside an unquoted field, text after a closing
   quote, a carriage return outside quotes that no newline follows, and an unclosed quote are ``
   `parse ``, naming the record and field. Input that is neither text nor UTF-8 bytes fails as
   `chars` does.")
 (chars dup len block + 1 - block div range block * cut
  () 0 () 0 4 pack (step) fold finished rectangular) `parse def

 ### defp measured
 (lists message -- lengths : "Each element's length, or a type error when one is not a list.")
 (|lists message|
  message lists ((len) each) cons @attempt dup result.ok? (`ok at first nip) (pop `type swap refuse)
  if)
 `measured defp

 ### defp assembled
 (quoted bodies last -- text : "Join each field's opening quote, body, and closing punctuation.")
 (|quoted bodies last|
  ("" "\"") quoted at bodies ("," "\u{d}\n" "\"," "\"\u{d}\n") quoted 2 * last + at 3 pack flip raze
  raze) `assembled defp

 ### defp joined
 (widths lengths text quote special doubled ends starts -- text :
  "Decide which fields need quotes, double their quotes, and mark each record's last field.")
 (|widths lens flat quote special doubled ends starts|
  special ends at special starts at - 0 >
  flat quote 1 + where at lens doubled ends at doubled starts at - + 0 (+) scan 0 shifted cut
  widths where dup -1 followed <> assembled) `joined defp

 ### defp marked
 (widths lengths text quote -- text :
  "Count, before each character, the characters that force quoting and the quotes to double.")
 (|widths lens flat quote|
  widths lens flat quote
  flat \, = quote or flat 13 char = or flat "\n" first = or 0 (+) scan 0 swap cons
  quote 0 (+) scan 0 swap cons
  lens 0 (+) scan dup 0 shifted joined) `marked defp

 ### defp textual
 (widths lengths text -- text : "Reject fields that are not text, then render them.")
 (|widths lens flat|
  flat str.str? `type "csv.emit expects every field to be a string" refuse-unless
  widths lens flat flat \" = marked) `textual defp

 ### defp rendered
 (widths fields -- text : "Render validated fields, `widths` to a record, as canonical text.")
 (|widths fields|
  widths fields "csv.emit expects every field to be a string" measured fields raze textual)
 `rendered defp

 ### setp batch
 (-- count : "Records rendered at a time, which bounds the masks an emit holds.")
 4096 `batch setp

 ### defp batched
 (rows -- text : "Render one batch of records whose shapes are validated.")
 (dup (len) each swap raze rendered) `batched defp

 ### def emit
 (rows -- text :
  "Render rows of string fields as canonical, CRLF-terminated RFC 4180 text, quoting exactly the
   fields that hold a comma, a quote, a carriage return, or a newline, and doubling their quotes. No
   rows is the empty string. Non-list rows and non-string fields are `` `type ``; a row with no
   fields is `` `shape ``.")
 (dup type `list match? `type "csv.emit expects a list of records" refuse-unless
  dup "csv.emit expects every record to be a list" measured 0 = 0 (or) fold not
  `shape "csv.emit rejects a record with no fields" refuse-unless
  dup len batch + 1 - batch div range batch * cut (batched) each raze) `emit def
) `csv @defm
