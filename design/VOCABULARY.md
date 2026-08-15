# ecl — core vocabulary

Companion to DESIGN.md and GRAMMAR.md. Every word carries its stack
effect in decision-14 notation; quotation-taking words state the
contract required of their quotation argument. Pervasive words (marked
*pervasive*) follow decision 13.

Tiers: **[P]** primitive (requires runtime support); **[E]** prelude
(defined in ecl itself, shipped as a source module — these are the
proof that the language can build itself).

**Application contexts.** Two kinds of quotation application exist:
- *Inline*: the quotation runs on the current stack — exactly the
  Control and Cleave words: `call`, `dip`, `keep`, `bi`, `tri`, `bi2`,
  `both`, `if`, `when`, `unless`, `cond`, `while`, `times`.
- *Isolated*: the quotation runs on a fresh substack per application,
  seeded with declared inputs, its result count checked against the
  contract (`each`, `each2`, `for`, `fold`, `scan`, `infra`, `attempt`,
  `spawn`, `module`).

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
| [E] | `bi2`  | `( x y p q -- … )` | inline: binary cleave — `p` and `q` each see x y (APL fork; APCL `recombine`) |
| [E] | `both` | `( x y q -- … )` | inline: apply `q` to x, then to y (Factor `bi@`; Ψ — APCL `under`) |

## Application & control

| | word | effect | |
|---|---|---|---|
| [P] | `call`    | `( q -- … )` | inline application (Joy's `i`) |
| [P] | `cons`    | `( x l -- l' )` | raw structural prepend. On data: `1 [2 3] cons` → `[1 2 3]`. On code it inserts a form: a prepended word executes when the result is called, so `cons` is not universally safe partial application. Factor's `curry` instead preserves a captured word as literal data |
| [P] | `compose` | `( q r -- qr )` | concatenate quotations |
| [E] | `literal` | `( x -- q )` | build the plain, inspectable quotation `((x) first)` as `wrap (first) cons`; calling it pushes the exact captured value without executing or resolving it. Use `literal` plus `compose` for safe arbitrary-value capture |
| [P] | `if`      | `( bool then else -- … )` | inline; branches run on current stack |
| [E] | `when`    | `( bool then -- … )` | `() if` |
| [E] | `unless`  | `( bool else -- … )` | `() swap if` |
| [P] | `while`   | `( cond body -- … )` | inline; `cond` must leave one bool; TCO'd |
| [P] | `times`   | `( n q -- … )` | inline; run `q` n times; TCO'd |
| [P] | `cond`    | `( clauses -- … )` | inline; flat nonempty odd list `[test action … else]` of quotations; prevalidated, first true test wins |
| [E] | `case`    | `( x clauses -- … )` | flat nonempty odd list `[key action … else]`; inert keys, prevalidated actions, first whole-value match wins |

Both forms require the rightmost else quotation. `cond` rejects non-quotation
tests, actions, and else before running its first test. `case` permits any
Value (including words and quotations) in key slots without executing it,
permits duplicate keys with the first match winning, and rejects every
non-quotation action/else before comparing a key. Empty or even clause lists
are `'shape`; a non-list or invalid member is `'type`.

**Combinator correspondence (Joy / APCL).** The zoo is captured, not
imported: in a concatenative substrate the applicative adaptors are
stack words. APCL `constant`/`apply`/`flip`/`duplicate`/`left`/`right`
are `wrap`/`call`/`swap`/`dup`/`pop`/`nip`; the fork (`recombine`,
`f(g(…), h(…))`) is `bi`/`bi2` + the combining word; Ψ (`under`,
`f(g(x), g(y))`) is `both` + the combining word. Joy's recursion
combinators (`genrec`/`linrec`/`binrec`/`primrec`) stay dropped — named
recursion with guaranteed TCO plus `times`/`while`/`fold` covers the
practical shapes, and Joy's `x` is `dup call`. Each inline combinator
is an idiom-recognition site (d.23).

## Binding & reflection

| | word | effect | |
|---|---|---|---|
| [P] | `def`    | `( body annotation? 'name -- )` | bind word; annotation may contain effect, docstring, or both; module definitions require the effect portion — d.5, d.9, d.18 |
| [P] | `defp`   | `( body annotation 'name -- )` | bind private module word with mandatory effect and optional docstring; top-level error — d.9 |
| [P] | `set`    | `( x 'name -- )` | assign value in the current environment; references resolve dynamically |
| [P] | `setp`   | `( x 'name -- )` | assign private module value; top-level error |
| [P] | `body`   | `( 'name -- q )` | a word's stored list |
| [P] | `doc`    | `( 'name -- string )` | resolve normally and return canonicalized documentation (soft source lines folded; paragraphs and `- ` items preserved); missing documentation is `'domain` |
| [P] | `to-word`   | `( x -- w )` | symbol → word (executable in code); a word passes through — d.22 |
| [P] | `to-symbol` | `( x -- s )` | word → symbol; a symbol passes through |
| [P] | `see`    | `( 'name -- )` | print a canonical re-readable definition with one combined annotation |
| [P] | `which`  | `( 'name -- )` | print resolution (module home, shadowing) |
| [P] | `words`  | `( -- )` | list the visible dictionary |
| [P] | `module` | `( 'name body -- )` | isolated; register module — d.18 |
| [P] | `use`    | `( 'name -- )` | splice module exports into scope; stderr notice per shadowed export — d.18 |
| [P] | `alias`  | `( 'short 'name -- )` | short registry name |
| [P] | `load`   | `( path -- )` | replay file as one unit — d.18, grammar |
| [P] | `parse`  | `( string -- q )` | the reader, reified: source text → list; `"42" parse first` is string→number |
| [P] | `type`   | `( x -- s )` | value kind as a symbol: `'int 'float 'char 'symbol 'word 'list 'dict 'task` — dict-dispatch with `case`; the closed d.22 atom set |
| [P] | `str`    | `( x -- string )` | printed representation (round-trips except Session-linked task capabilities, d.16/d.20) |

Definition annotations are ordinary quotations: `(a -- b)`,
`(: "Documentation.")`, or `(a -- b : "Documentation.")`. Top-level effects
are metadata only; cross-home module effects remain dynamically enforced.
`set`/`setp` do not recognize annotations. The exact namespace names `--` and
`:` are reserved for definitions, values, locals, modules, aliases, exports,
and native entries, while still remaining legal word and symbol values.

## Arithmetic — all *pervasive* (d.13)

`+` `-` `*` `/` `( x y -- z )`; `/` is float division (d.12).
`div` `mod` `( x y -- z )` integer division / modulo.
`neg` `abs` `sqrt` `( x -- y )`.
`floor` `ceil` `round` `( x -- n )` — return int64; `'overflow` outside
the range (d.22).
`pow` `min` `max` `( x y -- z )`; `pow` returns float.
`signum` `( x -- n )` [E] — −1/0/1 as ints; `(dup 0 > swap 0 < -)`,
pervasive by composition (APL `×⍵`).
`exp` `log` `sin` `cos` `( x -- y )`, `atan2` `( y x -- z )` — float
transcendentals, the awk floor for the d.21 slot (gap scan 2026-08-12).
d.22 governs the edges: `0 log` is −inf from a finite input, so
`'overflow`; `-1 log` would be NaN, so `'domain`.
`clamp` `( x lo hi -- y )` [E] — `((max) dip min)`.
All [P] except `signum`. Integer overflow errors (d.4). Char
arithmetic per d.15.
Floats: `inf`/`-inf` are literals and propagate through arithmetic; NaN
never exists — NaN-producing operations error `'domain`, and non-finite
results from finite inputs error `'overflow` (d.22).

## Comparison & logic — *pervasive* except `match`

`=` `<` `>` `<=` `>=` `<>` `( x y -- bool )` — 0/1 masks. [P]
`and` `or` `not` — on 0/1 ints. [P] (`<>` on 0/1 ints is xor —
no separate word.)
`match` `( x y -- bool )` — structural whole-value equality, **not**
pervasive (the K `~` distinction: `[1 2] [1 2] =` is `[1 1]`,
`[1 2] [1 2] match` is `1`). [P]
`cmp` `( x y -- n )` — three-way whole-value ordering: −1/0/1, **not**
pervasive — `cmp` is to `<` what `match` is to `=` (ruled 2026-08-12).
Domain: numbers (exact mixed int/float, no rounding through 2^53),
chars by codepoint, strings codepoint-lexicographic; anything else,
including cross-kind pairs, is `'type`. Exists because the subtraction
idiom is unsafe here: `-` errors on int64 overflow where an ordering
must be total. `grade` orders by exactly this ordering, so grade's
domain is lists whose elements `cmp` accepts. [P]

## Lists & arrays

Indexing is **0-based** throughout (K convention): `range` counts from
0, `at` indexes from 0, `where`/`grade` produce 0-based indices, and
`find` returns `len` on a miss.

| | word | effect | |
|---|---|---|---|
| [P] | `len`      | `( l -- n )` | top-level count; any list (d.2) |
| [P] | `shape`    | `( l -- l' )` | rectangular only, else `'shape` error (d.2) |
| [P] | `first`    | `( l -- x )` | |
| [E] | `last`     | `( l -- x )` | |
| [P] | `rest`     | `( l -- l' )` | |
| [P] | `take`     | `( l n -- l' )` | negative n: from the end; n beyond len cycles the data (K) — ruled 2026-08-12 |
| [P] | `drop`     | `( l n -- l' )` | sequence drop (K sense); stack word is `pop` |
| [P] | `at`       | `( l i -- x )` | index; pervasive over `i` (index vectors select) |
| [P] | `where`    | `( counts -- l )` | ints → each index replicated count times (K); a 0/1 mask is the common case, yielding positions — generalized 2026-08-12 |
| [P] | `in`       | `( x l -- bool )` | membership; pervasive over `x` |
| [E] | `find`     | `( l x -- i )` | index of first match, or len |
| [P] | `raze`     | `( l -- l' )` | flatten one level (d.14) |
| [P] | `cat`      | `( l m -- lm )` | concatenate two lists |
| [E] | `wrap`     | `( x -- l )` | one-element list (ec heritage name) |
| [E] | `pair`     | `( x y -- l )` | two-element list |
| [E] | `pack`     | `( x₁ … xₙ n -- l )` | collect the top nonnegative `n` values in original order; `() swap (cons) times`; literal `n` is checker-inferable, dynamic `n` is an unknown-effect escape hatch (d.9) |
| [E] | `append`   | `( l x -- l' )` | `wrap cat` (K `,`) |
| [E] | `empty?`   | `( l -- bool )` | `len 0 =` |
| [E] | `zip`      | `( l m -- l' )` | `(pair) each2` |
| [E] | `min-of`   | `( l -- x )` | `dup first (min) fold` (K `&/`) |
| [E] | `max-of`   | `( l -- x )` | `dup first (max) fold` (K `\|/`) |
| [P] | `put`      | `( l i x -- l' )` | functional element update; the same word as dict `put`, like `at`; CoW updates in place when unique (d.1) |
| [P] | `reverse`  | `( l -- l' )` | |
| [P] | `flip`     | `( l -- l' )` | transpose; rectangular, exact nested-list shape required (K name) |
| [P] | `range`    | `( n -- l )` | `[0 1 … n-1]` |
| [P] | `reshape`  | `( l shape -- l' )` | cycle data to exact nested-list shape; zero axis must be final |
| [P] | `grade`    | `( l -- indices )` | ascending sort permutation (K); orders by `cmp`, elements must be mutually comparable |
| [E] | `sort`     | `( l -- l' )` | `dup grade at` |
| [P] | `distinct` | `( l -- l' )` | first occurrences, order kept (K) |
| [P] | `group`    | `( l -- d )` | dict: value → indices (K) |

## Dicts

| | word | effect | |
|---|---|---|---|
| [P] | `dict-of` | `( entries -- d )` | flat even-length list of adjacent key/value entries; executes nothing — d.17 |
| [P] | `keys`    | `( d -- l )` | insertion order |
| [P] | `vals`    | `( d -- l )` | |
| [P] | `at`      | `( d k -- v )` | same word as list indexing; missing key errors |
| [P] | `put`     | `( d k v -- d' )` | functional update (new dict) |
| [P] | `del`     | `( d k -- d' )` | |
| [P] | `has?`    | `( d k -- bool )` | whole-value key membership; every key is inert; only absence is false (d.17) |
| [P] | `merge`   | `( d e -- d' )` | right wins; the explicit word d.17 promises |
| [P] | `to-dict` | `( keys vals -- d )` | dict from two conformable lists (K `!`); duplicate keys error per d.17 |
| [E] | `at-or`   | `( d k default -- v )` | value at k, or default when absent |
| [E] | `pairs`   | `( d -- l )` | list of `[k v]` pairs; `dup keys swap vals zip` — the dict-iteration form (`pairs (…) each`). Inverse round-trip is `dup keys swap vals to-dict` |

## Iteration — all *isolated*, contracts per d.14

| | word | effect | quotation contract |
|---|---|---|---|
| [P] | `each`  | `( l q -- l' )` | `( a -- b )` |
| [P] | `each2` | `( l m q -- l' )` | `( a b -- c )`, broadcast conformability |
| [P] | `for`   | `( l q -- )` | `( a -- )`, ordered |
| [P] | `fold`  | `( l acc q -- acc' )` | `( acc a -- acc )` |
| [P] | `scan`  | `( l acc q -- l' )` | `( acc a -- acc )`, keeps intermediates |
| [P] | `infra` | `( l q -- l' )` | unconstrained — `q` runs with `l`'s elements as the whole substack; the remainder is the result (Joy) |
| [E] | `filter` | `( l q -- l' )` | `( a -- bool )` — `over swap each where at` |
| [E] | `partition` | `( l q -- kept dropped )` | `( a -- bool )` |
| [E] | `any?`  | `( l q -- bool )` | `( a -- bool )` |
| [E] | `all?`  | `( l q -- bool )` | `( a -- bool )` |

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
| [E] | `or-raise` | `( outcome -- l )` | results list, or re-raise the error |
| [E] | `or-else` | `( outcome x -- l/x )` | results, or default on failure |

(`or-raise call` unpacks results onto the stack — a data list applied
pushes its elements.)

## Concurrency (d.20)

| | word | effect | |
|---|---|---|---|
| [P] | `spawn`     | `( q -- task )` | isolated, concurrent |
| [P] | `await`     | `( task -- outcome )` | idempotent |
| [P] | `await-for` | `( task ms -- outcome )` | nonnegative integer milliseconds; timeout does not cancel the task |
| [P] | `await-any` | `( l -- i outcome )` | nonempty all-task list; lowest already-done index, otherwise first completion |
| [P] | `cancel`    | `( task -- )` | no-op if done |
| [P] | `tasks`     | `( -- l )` | pending descendants in deterministic spawn preorder |
| [E] | `await-all` | `( tasks -- outcomes )` | await every task; ordinary outcomes in input order; never re-raise task failures |
| [E] | `par-each`  | `( l q -- l' )` | one task per element; ordered results; indexed one-result contract; re-raise leftmost `'err` after sibling quiescence |

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
| [P] | `getenv` | `( name -- s )` | environment variable; unset errors (absence is absence, d.22) — `attempt`/`or-else` for defaults |
| [P] | `exit`  | `( n -- )` | root-only outside `attempt`; quiesce descendants, then terminate process |

## Derived showcase (prelude, in ecl)

```
### def wrap
(() cons)
(value -- list : "Wrap one value in a one-element list.")
'wrap def

### def literal
(wrap (first) cons)
(value -- quotation :
 "Return a quotation that pushes the exact value as inert data when called.")
'literal def

### def pack
(() swap (cons) times)
(: "Collect the requested number of preceding stack values into a list, preserving their order.")
'pack def

### def signum
(dup 0 > swap 0 < -)
(number -- sign : "Return -1, 0, or 1 according to the sign of a number.")
'signum def
```

`case` is also entirely source-defined, but its validation and inert-key
selection pipeline is intentionally shown in readable, commented form in
`src/prelude.ecl` rather than compressed into this showcase. Every shipped
prelude definition follows the same `### def <name>` navigation convention and
exposes a meaningful nonempty string through `doc`.

Counts: roughly 80 primitives and 38 prelude words. The kernel surface
(decision 21's optimization target) is the pervasive arithmetic plus
the [P] list/dict words plus the iteration combinators — about forty
loops.
