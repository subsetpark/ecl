### All four annotation forms are legal in a module root.
'forms (
  (1 +) 'bare def
  (2 *) ( n -- n ) 'effected def
  (3 -) ( : "Subtract three." ) 'documented def
  (4 div) ( n -- n : "Divide by four." ) 'complete def
  (dup +) 'hidden defp
  (3 *) ( n -- n ) 'hidden-effect defp
  (4 +) ( : "Private and documented." ) 'hidden-doc defp
  (5 -) ( n -- n : "Private, both portions." ) 'hidden-both defp
  (hidden hidden-effect hidden-doc hidden-both) 'via-private def
) module

### Reflection reports exactly the portions that were supplied.
'forms.bare see
'forms.effected see
'forms.documented see
'forms.complete see
'forms.documented doc pp

### Unannotated module words cross the home boundary unchecked, and a
### supplied effect stays a live caller-stack contract.
10 forms.bare pp
10 forms.effected pp
10 forms.documented pp
12 forms.complete pp
10 forms.via-private pp

### `set` is exactly literal capture plus unannotated `def`.
42 'answer set
42 literal 'spelled def
'answer body 'spelled body match pp
'answer see
'spelled see

### A declared effect that the body violates is still 'contract.
'liar ((1 2) ( -- n ) 'two def) module
(liar.two) attempt 'err at 'kind at pp

### A malformed recognized annotation is still 'domain.
('broken ((3) ( : ) 'bad def) module) attempt 'err at 'kind at pp

### An undocumented word has no documentation to report.
('forms.bare doc) attempt 'err at 'kind at pp

### A list in annotation position that recognizes no marker is the body, not
### a malformed annotation: whatever the definition displaces stays on the
### construction stack and becomes durable module state.
'positional (((dup without) within) 'peek def (dup) (a b) 'f def) module
'positional.f body pp
positional.peek pp
