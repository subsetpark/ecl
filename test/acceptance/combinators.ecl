[1 2 3] (dup *) each io.pp
[1 2 3] 10 (pair) zip-with io.pp
10 [1 2 3] (pair) zip-with io.pp
[1 2 3] (io.pp) for
[1 2 3] 0 (+) fold io.pp
[1 2 3] 0 (+) scan io.pp
[1 2 3] (dup) infra io.pp
0 3 (1 +) times io.pp
[(0) (111) (222)] cond io.pp
[(1) (111) (222)] cond io.pp
3 [1 ("one") 3 ("three") ("other")] case io.pp
"42" parse first io.pp
