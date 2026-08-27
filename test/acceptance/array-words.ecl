[[1 2] [3 4]] flip io.pp
[1 2 3 4 5 6] [2 3] reshape io.pp
[1 2 1 3] group io.pp
[2 1 2 1] grade io.pp
9223372036854775807 -9223372036854775808 cmp io.pp
3.5 type io.pp
3.5 type {'float (42) 'int (0)} swap at call io.pp
[1 2 3] 1 9 put io.pp
['a 'b] [1 2] dict.from-lists io.pp
[1 2] 5 take io.pp
[2 0 3] where io.pp
