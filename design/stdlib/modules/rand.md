## rand

Explicit-state pseudorandom draws are pure except for `entropy`; see
[Randomness](SPEC.md#randomness). The state is `[key counter]`, and every draw
returns the advanced state alongside its result. An ambient generator is an
agent holding that state: `[0 0] agent.start 'rng set` then
`(5 rand.int) rng agent.call`.

### deal
`( state count pool -- state results )` — Draw `count` distinct ints in
`[0, pool)` without replacement, advancing the state by `count`. Work and
memory follow `count`, never `pool`. A negative count or pool, or a count
above the pool, is `'domain`; a non-int count or pool is `'type`.

#### Examples

```ecl
[7 0] 3 10 rand.deal pair
# => ([7 3] [7 0 4])
```

### entropy
`( -- result )` — Read one int from the host CSPRNG. This is the language's
only nondeterministic word, requires host IO, and is `'io` without it.

### float
`( state -- state result )` — Draw one uniform float in `[0, 1)`.

### int
`( state bound -- state result )` — Draw one unbiased uniform int in
`[0, bound)`. A bound below 1 is `'domain`.

#### Examples

```ecl
[0 0] 100 rand.int pair
# => ([0 1] 35)
```

### ints
`( state count bound -- state results )` — Draw `count` uniform ints in
`[0, bound)`, advancing the state by `count`. Each element is addressed by its
own counter position, so materialization order cannot change the list.

#### Examples

```ecl
[7 0] 4 6 rand.ints pair
# => ([7 4] [3 0 0 3])
```

### shuffle
`( state values -- state values )` — Return a uniformly selected permutation
of a list, advancing the state by the list's length. Any element kind is
permuted and the list keeps its representation. A non-list is `'type`.

#### Examples

```ecl
[7 0] [10 20 30 40] rand.shuffle pair
# => ([7 4] [40 20 30 10])
```
