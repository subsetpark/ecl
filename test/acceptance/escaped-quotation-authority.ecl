### A module hands out a quotation over its own private words. That quotation
### carries the image its words were written in, not a registration a call was
### resolved through, so `within` reached through it owns no slot -- and in
### particular never the caller's. Before this rule the caller's stack was the
### one that got written.

### module counter
[10]
(
 ### defp helper
 (99) 'helper defp

 ### defp bump
 (--)
 ((1 +) within) 'bump defp

 ### def leak
 (-- q)
 ((bump)) 'leak def

 ### def reach
 (-- q)
 ((helper)) 'reach def

 ### def peek
 (-- n)
 ((dup without) within) 'peek def
 ) seed 'counter @defm

### module other
[999]
(
 ### def run
 (q -- x)
 (call) 'run def

 ### def peek
 (-- n)
 ((dup without) within) 'peek def
 ) seed 'other @defm

### Resolution is unaffected: a foreign private is still reached, because lookup
### rides the word's own scope rather than the running activation's chain.
counter.reach other.run io.pp

### `within` through the escaped quotation is 'domain, and the word is spelled by
### its unqualified local name -- no registration was invoked to qualify it with.
(counter.leak other.run) @attempt 'err at dup 'kind at io.pp 'word at io.pp

### And neither durable stack moved.
counter.peek io.pp
other.peek io.pp
