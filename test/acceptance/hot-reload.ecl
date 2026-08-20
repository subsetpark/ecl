### module math
(
 ### def inc
 (1 +) (n -- n) 'inc def)
'math
@module
'math use
'm 'math alias
10 math.inc io.pp 20 inc io.pp 30 m.inc io.pp

### module math
(
 ### def inc
 (2 +) (n -- n) 'inc def)
'math
@module
10 math.inc io.pp 20 inc io.pp 30 m.inc io.pp
