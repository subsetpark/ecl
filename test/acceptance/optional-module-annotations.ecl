### All four annotation forms are legal in a module root.

### module forms
(
 ### def bare
 (1 +) 'bare def

 ### def effected
 (2 *) (n -- n) 'effected def

 ### def documented
 (3 -) (: "Subtract three.") 'documented def

 ### def complete
 (4 div) (n -- n : "Divide by four.") 'complete def

 ### def hidden
 (dup +) 'hidden defp

 ### def hidden-effect
 (3 *) (n -- n) 'hidden-effect defp

 ### def hidden-doc
 (4 +) (: "Private and documented.") 'hidden-doc defp

 ### def hidden-both
 (5 -) (n -- n : "Private, both portions.") 'hidden-both defp

 ### def via-private
 (hidden hidden-effect hidden-doc hidden-both) 'via-private def
 )
'forms
@defm

### Reflection reports exactly the portions that were supplied.
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

### `set` is exactly literal capture plus unannotated `def`.
42 'answer set
42 literal 'spelled def
'answer body 'spelled body match? io.pp
'answer see
'spelled see

### A declared effect that the body violates is still 'contract.

### module liar
(
 ### def two
 (1 2) (-- n) 'two def)
'liar
@defm
(liar.two) @attempt 'err at 'kind at io.pp

### A malformed recognized annotation is still 'domain.
((
  ### def bad
  (3) (:) 'bad def)
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

### A list in annotation position that recognizes no marker is the body, not
### a malformed annotation: whatever the definition displaces stays on the
### construction stack and becomes durable module state.

### module positional
(
 ### def peek
 ((dup without) within) 'peek def (dup)

 ### def f
 (a b) 'f def)
'positional
@defm
'positional.f body io.pp
positional.peek io.pp
