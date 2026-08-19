[1 2 3] (dup *) @each pp
([1 0 0] (1 swap /) @each) @attempt 'err at 'kind at pp
([0 1] (dup 0 = (pop left-missing) (pop right-missing) if) @each) @attempt 'err at 'word at pp
