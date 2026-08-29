### All four annotation forms are legal in a module root.

### module forms
(
 ### def bare
 (1 +) 'bare def

 ### def effected
 (n -- n)
 (2 *) 'effected def

 ### def documented
 (: "Subtract three.")
 (3 -) 'documented def

 ### def complete
 (n -- n : "Divide by four.")
 (4 div) 'complete def

 ### defp hidden
 (dup +) 'hidden defp

 ### defp hidden-effect
 (n -- n)
 (3 *) 'hidden-effect defp

 ### defp hidden-doc
 (: "Private and documented.")
 (4 +) 'hidden-doc defp

 ### defp hidden-both
 (n -- n : "Private, both portions.")
 (5 -) 'hidden-both defp

 ### def via-private
 (hidden hidden-effect hidden-doc hidden-both) 'via-private def
) 'forms @defm

### `see` prints each supplied annotation and body; `doc` reports documentation separately.
'forms.bare see
'forms.effected see
'forms.documented see
'forms.complete see
'forms.documented doc io.pp

### Unannotated module words cross the home boundary unchecked, and a
### supplied effect stays a live caller-stack contract.
10 forms.bare io.pp
10 forms.effected io.pp
10 forms.documented io.pp
12 forms.complete io.pp
10 forms.via-private io.pp

### `set` is exactly literal capture plus `def`, including optional metadata.

### def answer
(: "The answer.")
42 'answer set
42 literal 'spelled def
answer spelled match? io.pp
'answer see
'spelled see

### A declared effect that the body violates is still 'contract.

### module liar
(
 ### def two
 (-- n)
 (1 2) 'two def) 'liar @defm
(liar.two) @attempt 'err at 'kind at io.pp

### A malformed recognized annotation is still 'domain.
((
  ### def bad
  (:)
  (3) 'bad def)
 'broken
 @defm)
@attempt
'err
at
'kind
at
io.pp

### An undocumented word has no documentation to report.
('forms.bare doc) @attempt 'err at 'kind at io.pp

### A list beneath the body that recognizes no marker is not consumed as an
### annotation and remains durable module state.

### module positional
(
 ### def peek
 ((dup without) within) 'peek def (dup)

 ### def f
 (a b)

 ### def f
 (dup) 'f def) 'positional @defm
'positional.f see
positional.peek io.pp
