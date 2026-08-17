[1 2 3] (dup *) each pp
[1 2 3] 10 (pair) zip-with pp
10 [1 2 3] (pair) zip-with pp
[1 2 3] (pp) for
[1 2 3] 0 (+) fold pp
[1 2 3] 0 (+) scan pp
[1 2 3] (dup) infra pp
0 3 (1 +) times pp
[(0) (111) (222)] cond pp
[(1) (111) (222)] cond pp
3 [1 ("one") 3 ("three") ("other")] case pp
"42" parse first pp
