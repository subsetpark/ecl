## rand

Explicit-state pseudorandom draws are pure except for `entropy`; see
[Randomness](SPEC.md#randomness). The state is `[key counter]`, and every draw
returns the advanced state alongside its result. An ambient generator is an
agent holding that state: ``[0 0] agent.start `rng set`` then
`(5 rand.int) rng agent.call`.

### deal

#### Examples

```ecl
[7 0] 3 10 rand.deal pair
# => ([7 3] [7 0 4])
```

### int

#### Examples

```ecl
[0 0] 100 rand.int pair
# => ([0 1] 35)
```

### ints

#### Examples

```ecl
[7 0] 4 6 rand.ints pair
# => ([7 4] [3 0 0 3])
```

### shuffle

#### Examples

```ecl
[7 0] [10 20 30 40] rand.shuffle pair
# => ([7 4] [40 20 30 10])
```
