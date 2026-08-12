# ecl — core vocabulary

Companion to DESIGN.md and GRAMMAR.md. Every word carries its stack
effect in decision-14 notation; quotation-taking words state the
contract required of their quotation argument. Pervasive words (marked
*pervasive*) follow decision 13.

Tiers: **[P]** primitive (requires runtime support); **[E]** prelude
(defined in ecl itself, shipped as a source module — these are the
proof that the language can build itself).

**Application contexts.** Two kinds of quotation application exist:
- *Inline*: the quotation runs on the current stack (`call`, `dip`,
  `keep`, `bi`, `tri`, `if`, `when`, `while` branches).
- *Isolated*: the quotation runs on a fresh substack per application,
  seeded with declared inputs, its result count checked against the
  contract (`each`, `each2`, `for`, `fold`, `scan`, `dict-of`,
  `attempt`, `spawn`, `module`).

## Stack plumbing

| | word | effect | |
|---|---|---|---|
| [P] | `dup`  | `( x -- x x )` | |
| [P] | `swap` | `( x y -- y x )` | |
| [P] | `pop`  | `( x -- )` | Joy name; `drop` is the sequence word |
| [P] | `over` | `( x y -- x y x )` | |
| [E] | `nip`  | `( x y -- y )` | `swap pop` |
| [P] | `dip`  | `( x q -- … x )` | inline: run `q` under the top value |
| [E] | `keep` | `( x q -- … x )` | inline: run `q` on `x`, restore `x` |
| [E] | `bi`   | `( x p q -- … )` | inline: apply `p` to x, then `q` to x |
| [E] | `tri`  | `( x p q r -- … )` | three-way `bi` |

## Application & control

| | word | effect | |
|---|---|---|---|
| [P] | `call`    | `( q -- … )` | inline application (Joy's `i`) |
| [P] | `cons`    | `( x l -- l' )` | prepend a value onto any list. On data: `1 [2 3] cons` → `[1 2 3]`. On code, this IS partial application: `3 (+) cons` → `(3 +)`. Joy's name; Factor calls the same operation `curry`, a misnomer |
| [P] | `compose` | `( q r -- qr )` | concatenate quotations |
| [P] | `if`      | `( bool then else -- … )` | inline; branches run on current stack |
| [E] | `when`    | `( bool then -- … )` | `() if` |
| [P] | `while`   | `( cond body -- … )` | inline; `cond` must leave one bool; TCO'd |

## Binding & reflection

| | word | effect | |
|---|---|---|---|
| [P] | `def`    | `( body 'name -- )`; module: `( body fx 'name -- )` | bind word (public in modules, with mandatory effect declaration) — d.5, d.9, d.18 |
| [P] | `defp`   | `( body fx 'name -- )` | bind private word with declared effect; top-level error — d.9 |
| [P] | `let`    | `( x 'name -- )` | bind value |
| [P] | `letp`   | `( x 'name -- )` | bind private value; top-level error |
| [P] | `body`   | `( 'name -- q )` | a word's stored list |
| [P] | `to-word`   | `( x -- w )` | symbol → word (executable in code); a word passes through — d.22 |
| [P] | `to-symbol` | `( x -- s )` | word → symbol; a symbol passes through |
| [P] | `see`    | `( 'name -- )` | print definition (desugared truth) |
| [P] | `which`  | `( 'name -- )` | print resolution (module home, shadowing) |
| [P] | `words`  | `( -- )` | list the visible dictionary |
| [P] | `module` | `( 'name body -- )` | isolated; register module — d.18 |
| [P] | `use`    | `( 'name -- )` | splice module exports into scope; stderr notice per shadowed export — d.18 |
| [P] | `alias`  | `( 'short 'name -- )` | short registry name |
| [P] | `load`   | `( path -- )` | replay file as one unit — d.18, grammar |
| [P] | `parse`  | `( string -- q )` | the reader, reified: source text → list |
| [P] | `str`    | `( x -- string )` | printed representation (round-trips, d.16) |

## Arithmetic — all *pervasive* (d.13)

`+` `-` `*` `/` `( x y -- z )`; `/` is float division (d.12).
`div` `mod` `( x y -- z )` integer division / modulo.
`neg` `abs` `sqrt` `( x -- y )`.
`floor` `ceil` `round` `( x -- n )` — return int64; `'overflow` outside
the range (d.22).
`pow` `min` `max` `( x y -- z )`; `pow` returns float.
All [P]. Integer overflow errors (d.4). Char arithmetic per d.15.
Floats: `inf`/`-inf` are literals and propagate through arithmetic; NaN
never exists — NaN-producing operations error `'domain`, and non-finite
results from finite inputs error `'overflow` (d.22).

## Comparison & logic — *pervasive* except `match`

`=` `<` `>` `<=` `>=` `<>` `( x y -- bool )` — 0/1 masks. [P]
`and` `or` `not` — on 0/1 ints. [P]
`match` `( x y -- bool )` — structural whole-value equality, **not**
pervasive (the K `~` distinction: `[1 2] [1 2] =` is `[1 1]`,
`[1 2] [1 2] match` is `1`). [P]

## Lists & arrays

| | word | effect | |
|---|---|---|---|
| [P] | `len`      | `( l -- n )` | top-level count; any list (d.2) |
| [P] | `shape`    | `( l -- l' )` | rectangular only, else `'shape` error (d.2) |
| [P] | `first`    | `( l -- x )` | |
| [E] | `last`     | `( l -- x )` | |
| [P] | `rest`     | `( l -- l' )` | |
| [P] | `take`     | `( l n -- l' )` | negative n: from the end |
| [P] | `drop`     | `( l n -- l' )` | sequence drop (K sense); stack word is `pop` |
| [P] | `at`       | `( l i -- x )` | index; pervasive over `i` (index vectors select) |
| [P] | `where`    | `( mask -- l )` | 0/1 mask → indices (d.14) |
| [P] | `in`       | `( x l -- bool )` | membership; pervasive over `x` |
| [E] | `find`     | `( l x -- i )` | index of first match, or len |
| [P] | `raze`     | `( l -- l' )` | flatten one level (d.14) |
| [P] | `cat`      | `( l m -- lm )` | concatenate two lists |
| [E] | `wrap`     | `( x -- l )` | one-element list (ec heritage name) |
| [E] | `pair`     | `( x y -- l )` | two-element list |
| [P] | `reverse`  | `( l -- l' )` | |
| [P] | `flip`     | `( l -- l' )` | transpose; rectangular only (K name) |
| [P] | `range`    | `( n -- l )` | `[0 1 … n-1]` |
| [P] | `reshape`  | `( l shape -- l' )` | cycle data to shape (K/APL) |
| [P] | `grade`    | `( l -- indices )` | ascending sort permutation (K) |
| [E] | `sort`     | `( l -- l' )` | `dup grade at` |
| [P] | `distinct` | `( l -- l' )` | first occurrences, order kept (K) |
| [P] | `group`    | `( l -- d )` | dict: value → indices (K) |

## Dicts

| | word | effect | |
|---|---|---|---|
| [P] | `dict-of` | `( q -- d )` | isolated; pairs off results — d.17 |
| [P] | `keys`    | `( d -- l )` | insertion order |
| [P] | `vals`    | `( d -- l )` | |
| [P] | `at`      | `( d k -- v )` | same word as list indexing; missing key errors |
| [P] | `put`     | `( d k v -- d' )` | functional update (new dict) |
| [P] | `del`     | `( d k -- d' )` | |
| [E] | `has?`    | `( d k -- bool )` | |
| [P] | `merge`   | `( d e -- d' )` | right wins; the explicit word d.17 promises |

## Iteration — all *isolated*, contracts per d.14

| | word | effect | quotation contract |
|---|---|---|---|
| [P] | `each`  | `( l q -- l' )` | `( a -- b )` |
| [P] | `each2` | `( l m q -- l' )` | `( a b -- c )`, broadcast conformability |
| [P] | `for`   | `( l q -- )` | `( a -- )`, ordered |
| [P] | `fold`  | `( l acc q -- acc' )` | `( acc a -- acc )` |
| [P] | `scan`  | `( l acc q -- l' )` | `( acc a -- acc )`, keeps intermediates |

## Strings (mostly free via array words)

| | word | effect | |
|---|---|---|---|
| [P] | `split`  | `( s sep -- l )` | list of strings |
| [P] | `join`   | `( l sep -- s )` | |
| [P] | `format` | `( l template -- s )` | interpolation: `{}` positional placeholders, each filled with the value's `str`; `{{`/`}}` for literal braces — `[3.14 2] "pi={} n={}" format` |

(`upper`/`lower`/`trim` etc.: stdlib module, ASCII in v1 per d.15.)

## Errors & outcomes (d.7, d.19)

| | word | effect | |
|---|---|---|---|
| [P] | `raise`   | `( errdict -- )` | throw |
| [E] | `fail`    | `( msg -- )` | raise `{'kind 'user 'msg msg}` |
| [P] | `attempt` | `( q -- outcome )` | isolated; `{'ok (…)}` / `{'err {…}}` |
| [E] | `ok?`     | `( outcome -- bool )` | |
| [E] | `ok!`     | `( outcome -- l )` | results list, or re-raise the error — asserts what `ok?` tests |
| [E] | `or-else` | `( outcome x -- l/x )` | results, or default on failure |

(`ok! call` unpacks results onto the stack — a data list applied
pushes its elements.)

## Concurrency (d.20)

| | word | effect | |
|---|---|---|---|
| [P] | `spawn`     | `( q -- task )` | isolated, concurrent |
| [P] | `await`     | `( task -- outcome )` | idempotent |
| [P] | `await-for` | `( task ms -- outcome )` | `'timeout` on deadline |
| [P] | `await-any` | `( l -- i outcome )` | first completion; index + outcome |
| [P] | `cancel`    | `( task -- )` | no-op if done |
| [P] | `tasks`     | `( -- l )` | pending tasks in scope |
| [E] | `par-each`  | `( l q -- l' )` | spawn per element, await in order, re-raise leftmost `'err` |

## IO

| | word | effect | |
|---|---|---|---|
| [P] | `prin`    | `( s -- )` | write a string's chars raw, no newline; non-string is a `'type` error |
| [E] | `print`   | `( s -- )` | `prin "\n" prin` — string + newline |
| [P] | `pp`      | `( x -- )` | pretty-print any value + newline — human layout, may elide huge leaves; contrast `str`, the canonical round-trip form |
| [E] | `inspect` | `( x -- x )` | `dup pp` — the pipeline probe |
| [P] | `slurp` | `( path -- s )` | whole file as string (UTF-8, d.15) |
| [P] | `spit`  | `( s path -- )` | write file |
| [E] | `lines` | `( path -- l )` | `slurp "\n" split` |
| [P] | `args`  | `( -- l )` | CLI arguments, list of strings |
| [P] | `exit`  | `( n -- )` | terminate process |

## Derived showcase (prelude, in ecl)

```
(dup grade at)                'sort    def
(swap pop)                    'nip     def
(0 (+) fold)                  'sum     def
(1 (*) fold)                  'prod    def
(dup sum swap len /)          'mean    def
```

Counts: ~70 primitives, ~15 prelude words. The kernel surface
(decision 21's optimization target) is the pervasive arithmetic plus
the [P] list/dict words plus the iteration combinators — about forty
loops.
