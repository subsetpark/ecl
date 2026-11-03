## agent

#### Examples

An ambient random generator:

```ecl
[0 0] agent.start `rng set
rng (5 rand.int) agent.call
# => 0
```

### call

#### Examples

```ecl
[0 0] agent.start `g set
g (100 rand.int) agent.call g (100 rand.int) agent.call pair
# => [35 0]
[7 0] agent.start `g set
[] (g (1 0 div) agent.call) @attempt `err at `kind at g (dup) agent.call pair
# => (domain [7 0])
```
