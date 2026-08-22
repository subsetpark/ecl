### module math
(
 ### def inc
 (1 +) (n -- n) 'inc def)
'math
@defm
'math.inc 'inc import
'm 'math alias
10 math.inc io.pp 20 inc io.pp 30 m.inc io.pp

### module math
(
 ### def inc
 (2 +) (n -- n) 'inc def)
'math
@defm
10 math.inc io.pp 20 inc io.pp 30 m.inc io.pp
