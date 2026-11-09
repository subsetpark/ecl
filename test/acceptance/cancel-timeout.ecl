((1) () while) @spawn dup task.cancel task.await `err at `kind at io.pp
((1) () while) @spawn 1 task.await-for `err at `kind at io.pp
(((1) () while) @attempt drop `after io.pp) @spawn dup task.cancel task.await `err at `kind at
io.pp
