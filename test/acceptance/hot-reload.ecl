### module math
(
 ### def inc
 (n -- n)
 (1 +) 'inc def) 'math @defm
'math ('inc) import
'm 'math alias
10 math.inc io.pp 20 inc io.pp 30 m.inc io.pp

### module math
(
 ### def inc
 (n -- n)
 (2 +) 'inc def) 'math @defm
10 math.inc io.pp 20 inc io.pp 30 m.inc io.pp
