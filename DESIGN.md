# ecl — design ledger

Status: design phase. **Clean-slate language.** ec (`~/code-src/ec`, Janet) is
ancestry and a source of ideas — neither its implementation nor its semantics
are preserved. Nothing below is constrained by compatibility.

## Identity

- **Homoiconic concatenative array calculator.** RPN; evaluation is pushing.
  Arrays and programs are the same substance — lists — and APL's operators
  (fold, scan, each, rank) are Joy's combinators: words that take quotations.
  Code on the stack is a transparent sequence you build, inspect, `each`
  over, and name with the same vocabulary you use on data.
- **Grow, then harden.** The core is dynamic, late-bound, zero-ceremony: a
  calculator you open cold and type `2 3 +` into. A per-word `seal` boundary
  (deferred layer, decision 9) adds effect checking, early binding,
  compilation, and full parallel determinism — when a word matters, you
  harden it without rewriting it.
- **Positioning (final, decision 21):** the awk/sed/REPL slot — scripting,
  one-off CLI invocations, an interactive calculator. Words, not glyphs.
  Interpreted, permanently; K-order performance is the ceiling the
  architecture must be able to evolve to. (Uiua occupies "stack+array
  language"; ecl's differentiators are homoiconic quotations, a
  transactional stack — a failed unit never leaves a torn stack, it rolls
  back to its entry state — and word-based syntax.)

## Settled decisions

1. **Values are immutable.** No amend words; mutation exists only as env
   rebinding. Performance model (documented guarantee, not semantics):
   copy-on-write with uniqueness detection — append/amend on an unshared value
   is in-place into slack capacity, amortized O(1); on a shared value, one O(n)
   copy, then cheap. K/q, CBQN, Uiua, and Swift all ship this; persistent trees
   (Clojure-style) are rejected — wrong constants for array workloads.
   - Reserved, fully deferred: an Erlang-style per-substack process
     dictionary (`put`/`get`) may be added later. Constraints reserved
     with it: immutable values only; scoped to the substack (the unit
     boundary of decisions 7/20); follows env rules (a failed unit does
     not roll it back); stays out of the stdlib. All remaining questions
     (including child inheritance: empty vs copy-on-spawn) are decided if
     and when it's added.

2. **Data model: atoms + lists, K-style nesting.** Atoms: int64, float64,
   char, symbol. No rank-carrying arrays — a matrix is a list of equal-length
   vectors; rank is emergent (depth), not intrinsic. Homogeneous lists
   auto-specialize to flat typed leaf buffers (representation, not semantics).
   **Vector ⊂ Quotation is literal:** a vector *is* a homogeneous list;
   `(1 2 3)` and `[1 2 3]` are the same value. Ragged data is legal (a list
   whose elements didn't specialize). Box = quote: heterogeneity lives in
   lists, no separate box or generic-list type. Strings are rank-1 char
   vectors. Dicts are first-class (`{...}` literal), the table story is
   dict-of-column-vectors. **`shape` demands rectangularity**: on ragged
   data it errors — `len` (top-level count) is the word that works on any
   list.

3. **Broadcast: leading-axis, pairwise descent** (K conformability). Atoms
   extend to lists; lists pair elementwise at each level and recurse. (ec's
   suffix-agreement fill is not carried over.)

4. **Numbers: int64 + float64 in v1.** Exactness (bignums/rationals/decimals)
   deferred, not rejected — it is a positioning decision to revisit.
   **Integer overflow is an error** — no wrapping, no silent promotion;
   scalar and array arithmetic behave identically (the divergence a
   promotion rule would create is why promotion is in Rejected).

5. **Bindings: `def`/`let` split.** Executability is a property of the
   *binding*, not the value (forced by decision 2: with one list type there is
   nothing to dispatch on). `(body) 'name def` binds a word — reference
   applies the body. `value 'name let` binds a value — reference pushes it,
   including quotations-as-data. One namespace, entries tagged word|value.
   `def` requires a list body (else error pointing at `let`); a data list as
   body is legal and yields a multi-value constant word. Everything is
   late-bound until sealed: unsealed words see re-`def`s and re-`let`s of
   their dependencies immediately. No Thunk concept.

6. **No closures, ever.** A quotation is a plain inspectable list; capture is
   `curry`/splice producing a new plain list (`3 (+) curry` → `(3 +)`).
   Locals are definition-site sugar that desugars to point-free code before
   storage; head-position only; not permitted across quotation boundaries in
   v1 (error suggests `curry`). Spelling: `(|lo hi| …)`, Rust/Ruby-style —
   see GRAMMAR.md. The locals sugar shares no vocabulary with `let` — they
   are unrelated mechanisms.

7. **Errors: crash-only, observed as data at unit boundaries.** No
   try/catch, no handler quotations. Errors propagate; the failing unit of
   work dies; the transactional stack makes death free — a failed unit
   (e.g. a REPL line) leaves nothing, rolling back to its entry state.
   The guarantee is stack-only, stated honestly: env writes and IO
   performed before the failure survive. Failure is observed from outside,
   as data, at one explicit boundary word: `(q) attempt` runs a
   self-contained quotation (effect `( -- ... )`; inputs arrive via `curry`
   or env names, never the ambient stack — the same rule as every other
   quotation boundary) on an isolated substack, and always pushes exactly
   one outcome value: `{'ok (results)}` or `{'err <error dict>}`. Uniform
   arity is what makes reified failure safe in a stack language — the
   desync argument that killed results-on-stack does not apply, because a
   failure never shares a stack with the code observing it. Handling is
   ordinary dict handling: `ok?`, `unwrap` (results, or re-raise),
   `or-else` (default on failure). The unit of failure is the unit of
   concurrency: `spawn` (decision 20) accepts exactly what `attempt`
   accepts and delivers the same outcome; `par-each` re-raises the
   leftmost `'err`, keeping parallel failure deterministic. The REPL is
   the implicit top-level boundary.

8. **No macro layer.** Runtime quotation construction (`compose`, `curry`,
   list words) plus `def` *is* the metaprogramming system; `'word body`
   fetches a word's list for surgery, `def` rebinds. With immutability,
   build-new-then-rebind is the only way code changes (this is what makes
   cache invalidation tractable). Parse-time words are capped at a handful
   (locals sugar, literal readers) and the cap is policy.

9. **`seal` is a deferred layer, by construction.** The grow-then-harden
   boundary (`'name ( effect ) seal`: declared effect checked against the
   stored body, callees early-bound, compiled form cached, parallel
   eligibility) is a *strict extension* of a completely dynamic substrate:
   a program that never calls `seal` never observes it, and adding it later
   changes no existing program's meaning. All seal design questions —
   dependency-rebinding friction, declaration grammar, checker scope
   (row polymorphism; equality-only shapes), cache policy — are deferred as
   a bundle. v1 correctness rests entirely on decision 14's dynamic
   contracts; seal buys earlier errors, speed, and `par-each`'s upgrade
   to full observational equivalence with `each` (decision 11).
   The substrate invariants that keep the layer possible (each settled
   independently, now also load-bearing for this): quotations are plain
   lists (6, 8); code changes only via `def`/`let` rebinding (1, 5);
   combinator contracts define the effect vocabulary (14); the env is
   enumerable.

10. **Evaluator: one explicit frame machine.** Guaranteed TCO through words,
    `if`, and combinator tail positions; recursion combinators
    (primrec/linrec) iterative, never on the host stack; unit rollback and
    `attempt`/`spawn` boundaries are frame operations. No bytecode VM unless profiling
    demands one — the APL performance model (fat flat primitives, thin
    dispatch) is the bet.

11. **Effects/IO: plain impure words.** Sequential combinators guarantee
    left-to-right order, so IO inside `each`/`for` is well-defined.
    `par-each` is stdlib over `spawn`/`await` (decision 20): result order
    and leftmost-error are deterministic today; the deferred seal layer's
    purity checking later *upgrades* it to full observational equivalence
    with `each` (no cross-task IO interleaving possible). Purity checking
    remains scoped to where it pays. No effect monads.

12. **Division is `/`.** Fold is the word `fold` (aliases can come later —
    words-not-glyphs is the identity). Glyph budget spent on literals:
    `( )` quotation, `[ ]` list/vector, `{ }` dict, `'name` quoted symbol,
    `" "` string.

13. **Pervasion: K semantics.** Scalar arithmetic and comparison words
    recurse through nesting to atoms, ragged lists included. Dicts: pervade
    over values (keys preserved); dict-with-dict aligns by key — matching
    keys combine, unmatched keys pass through (union, identity fill).
    Symbols error. Chars: ordinal arithmetic per decision 15 (`char int +`
    → char, `char char -` → int, else error). Note the unified-value dividend: an
    all-numeric list *is* a vector, so "pervading into code" is only
    observable for numeric lists; a quotation containing words errors at
    the first symbol leaf.

14. **Combinator contracts; `each` replaces `map`.** Every quotation-taking
    combinator states the stack effect it requires of its quotation
    argument. Unsealed quotations are checked dynamically at each
    application (violation = immediate error naming the element and the
    observed effect); sealed quotations are checked once, statically.
    - `each` (K `'`): requires `( a -- b )`; applies one level down the
      leading axis, exactly one result per element; result specializes when
      rectangular. Depth composes by nesting: `((q) each) each`.
    - `each2`: requires `( a b -- c )`; zip with broadcast conformability.
      Each-left/right are derived via `curry`, not primitives.
    - `for`: requires `( a -- )`; the ordered effect loop, collects nothing.
    - `fold`/`scan`: require `( acc a -- acc )`.
    There is no collect-all `map` (result length would be a dynamic property
    of stack behavior — a loop, not an array operation). Filter is the mask
    idiom (`dup 0 > where at`); flat-map is `each raze`. Pervasion restated
    in this frame: atomic words descend to atoms intrinsically; `each`
    lowers application by exactly one level. Derived verbs come free from
    homoiconicity: `((1 +) each) 'inc-all def`. Implied core vocabulary:
    `where`, `at`, `raze`.

15. **Chars are Unicode codepoints; UTF-8 at the boundary.** A char is a
    distinct atom (not an integer): `len`/`at`/`reverse`/`each` on strings
    operate on codepoints. Storage rides leaf specialization: a string leaf
    carries a width tag (1/2/4 bytes per char, per string — PEP 393 model),
    so ASCII costs 1 byte/char and indexing stays O(1). UTF-8 exists only
    at IO boundaries (source files, read/write/say); invalid UTF-8 on input
    errors. Bytes are not chars: binary IO yields int/byte vectors, never
    strings (deliberate departure from K). Char arithmetic is ordinal:
    `char int +` → char, `char char -` → int, `char char +` → error;
    comparison by codepoint. Symbols are interned at parse; strings are
    plain immutable vectors, uninterned. Deferred explicitly (stdlib layer,
    needs Unicode tables): grapheme segmentation, normalization, non-ASCII
    case mapping, locale collation — codepoint semantics documented
    honestly (composed vs decomposed "café" is 4 vs 5 chars). Char literal
    syntax: `\a` / `\space` / `\u{...}`, Clojure-style (see GRAMMAR.md).

16. **Printing exposes representation.** A list prints with `[...]` when
    specialized (homogeneous flat leaf, or rectangular nesting of
    specialized lists) and `(...)` when generic — same kind of value either
    way; the brackets show what the representation did. So `(1 2 3)` prints
    as `[1 2 3]`, and a ragged result like `[[1 2] [3]] 10 *` prints as
    `([10 20] [30])`. Either bracket pair is accepted on input and
    normalizes; printed output round-trips to the same value. Pairs must
    match: `[1 2 3)` is a parse error — brackets are interchangeable per
    pair, never per token. Specialization is therefore visible at the
    prompt, not mysterious.

17. **Dict literals are sugar over `dict-of`.** Brackets quote in ecl, so
    `{...}` does not get private evaluation semantics: it desugars at parse
    time to `( body ) dict-of`, where `dict-of` is an ordinary word with an
    ordinary contract — apply the quotation on a fresh substack (child
    env), require an even number of results (else error), pair them off in
    order, build the dict. Consequences: bodies see env names but never
    the outer stack (a literal denotes a self-contained value; `5 {'x 1}`
    is the same dict regardless of the 5); computed construction is free
    (`('total 3 4 +) dict-of`); nesting desugars mechanically; `see` shows
    the desugared truth; locals cannot reach into a dict literal (it is a
    quotation boundary — use `let` or point-free feeding). Duplicate keys
    error; merging is explicit (decision 13's key-aligned `+`, or a merge
    word). Any value is a legal key (immutability makes everything
    hashable); symbols are the idiom; insertion order is preserved (column
    order for tables). `{}` is the empty dict; dicts print as
    `{key value ...}` and round-trip.

18. **Modules: named registry values, definition-site privacy.** A module
    is a named, registered value — not a file. A per-session registry maps
    symbols to modules; files are transport (`load` replays a script;
    registering a module is just a side effect a script can have). The
    only file/name coupling is convention: `'stats use` on an unregistered
    name searches `ECL_PATH` for `stats.ecl`, loads it, retries. `module`
    is an ordinary word, `'name ( body ) module`: runs the body on a fresh
    env, registers the result. Modules are first-class (enumerable,
    diffable, constructible programmatically by building the body
    quotation).
    - **Privacy at the definition site:** inside a module body, `def`/`let`
      bind public (exported), `defp`/`letp` bind private (Elixir-style).
      Privacy is subtractive — privates are absent from the module's public
      face, not access-checked. At top level `defp`/`letp` are an error
      (there is no module to be private to; Elixir precedent). Visibility
      is one more property of the binding, alongside decision 5's
      word|value tag.
    - **Resolution context is a property of the binding** (decision 5
      doctrine extended): an exported word carries its home module's
      *name*; its body resolves against `registry[home]`'s chain (internal
      env → the module's own `use`s → core), never the caller's env. So
      publics reach privates, callers cannot perturb module behavior,
      quotations stay plain lists (`'stats.stdev body` is just a list;
      re-`def`ing it elsewhere honestly loses the private context), and
      re-registering a module hot-heals all callers via the registry
      indirection (Erlang-style reload).
    - **Surface:** `use` splices exports (session defs shadow uses, later
      `use` shadows earlier, core at root); dotted symbols (`stats.mean`)
      give qualified access with no import; `alias` registers a short
      name; `which` shows any name's resolution.
    - **Tension, stated:** REPL words resolve dynamically, module words
      against their home — the one place "what you see is what runs" needs
      tooling (`which`; `see` displays home) rather than raw text.

19. **Error values.** Every error is a dict: `'kind` (symbol, dispatch
    taxonomy), `'msg` (string, preformatted), `'word` (qualified symbol of
    the innermost raiser), `'trace` (list of qualified word symbols,
    innermost first — ecl-level only, never host frames), `'data`
    (kind-specific payload dict, e.g. expected/got shapes, contract's
    required-vs-observed effect and element index). Core kinds, closed
    set: `'underflow`, `'undefined-word`, `'type`, `'shape`, `'conform`,
    `'overflow`, `'domain`, `'contract`, `'parse`, `'io`, `'user`. User
    kinds are any other symbol. `raise` throws a dict; `fail` is sugar for
    raising `{'kind 'user 'msg msg}`. No host exception ever leaks.
    Errors are sendable by construction — immutable plain data, no live
    references — so the identical value crosses process boundaries when
    concurrency lands (an `'origin` field is the anticipated extension,
    not a redesign).

20. **Concurrency: tasks (structured futures), not actors.** Target scope
    is REPL / one-off CLI / scripting — the actor runtime (mailboxes,
    selective receive, named processes, supervisors) serves long-lived
    stateful servers, which ecl does not target. Four primitives;
    everything else is stdlib.
    - `spawn` `( q -- task )`: runs a self-contained quotation (`attempt`'s
      contract — inputs via `curry`/env, never ambient stack) on its own
      share-nothing substack, concurrently. Immutability makes sharing
      safe with no copying or serialization.
    - `await` `( task -- outcome )`: blocks; delivers the same
      `{'ok …}/{'err …}` outcome as `attempt`; idempotent (outcome
      cached), so handles stay observationally value-like. `await-for`
      adds a deadline → `{'err {'kind 'timeout}}`.
    - `await-any` (races); `cancel` (task dies with
      `{'err {'kind 'cancelled}}`, no-op if done). Cancellation is
      unconditional and safe *because* tasks are transactions — killing
      one discards an isolated substack and leaves nothing.
    - **`attempt` ≡ `spawn await`.** The error model is the synchronous
      degenerate case of the concurrency model.
    - **Structured lifetime:** a dying unit cancels its unawaited tasks
      ("a failed unit leaves nothing" extends to processes); dropped
      handles are cancelled at scope end — no detached daemons; the REPL
      session is the root scope; a `tasks` word lists pending work.
    - **Determinism:** await order is program order, so gathered results
      and `par-each`'s leftmost-error rule are deterministic.
      Nondeterminism enters only where chosen (`await-any`) and at IO
      interleaving across concurrent tasks (within a task IO is ordered;
      across tasks, unspecified).
    - **Refused:** promise-style combinator algebras on pending tasks —
      no `.then` chains, no auto-flattening (a task holding a task is
      just a value); await, then use ordinary words. No function
      coloring: concurrency is a property of how code is run (`i` /
      `attempt` / `spawn`), never of the code. Channels
      (producer/consumer streaming) are reserved like the pdict: if
      added, they carry immutable values only and their ends are scoped
      to units.

21. **Positioning, final: the awk/sed/REPL slot; interpreted forever;
    K-order performance as the ceiling, evolved rather than premature.**
    - Bread and butter: scripting, one-off CLI invocations, the REPL. The
      cold-start soul test stays sacred: `ecl '3 4 +'` answers instantly,
      zero ceremony.
    - Interpreted, permanently: no JIT, no machine-code compilation, ever.
      The performance model is K's — interpreter overhead amortized over
      fat, flat array primitives ("K is fast because memcpy is fast").
      K and J prove the ceiling is reachable interpreted.
    - "Evolvable to fast" is an architecture constraint on v1, not a v1
      speed requirement. Invariants the slow-but-correct implementation
      must never violate: (a) flat specialized leaves (decision 2) — the
      data representation *is* the performance plan; (b) CoW + uniqueness
      for hidden in-place mutation and slack-capacity append (decision 1);
      (c) coarse primitives — pervasion, `each`/`fold`/`scan`,
      `where`/`at`/`raze` execute as single runtime loops over leaves, so
      optimization concentrates in a few dozen kernels and per-token
      dispatch never needs to be fast; (d) the seal layer's "compiled
      form" means internal threaded/opcode arrays at most, never native
      code.
    - Exactness (decision 4) stays deferred-not-rejected; this positioning
      neither demands nor forecloses it.
    - Host/implementation language is outside this ledger; the runtime is
      specified implementation-agnostically below.

## Runtime (implementation-agnostic)

Derived from the decisions above; any implementation language that can
deliver these six components is acceptable. Host choice is an
implementation matter, not a design matter.

- **Values.** Immutable, reference-shared heap values. Atoms: int64,
  float64, char (codepoint), interned symbol. Lists are generic spines
  (sequences of value references) or specialized leaves (contiguous
  homogeneous buffers: i64, f64, chars at tagged width 1/2/4);
  specialization happens at construction and is semantically invisible
  except through printing (d.16). Every value supports structural
  equality, hashing, printing. Each heap value carries sharing metadata
  (refcount or shared bit) sufficient to answer "uniquely held?" — set at
  the enumerable sharing points (dup-family, env binding, list
  inclusion). Uniquely-held values may be mutated in place by the runtime
  (append into slack capacity; bucket-sized allocations; amortized O(1));
  shared values copy first (d.1). Dicts: insertion-ordered maps, any
  value as key. Tasks: write-once outcome cells with identity.

- **Frame machine.** One explicit evaluation loop; no evaluation
  recursion on the implementation call stack, ever (d.10). A unit =
  (frame stack, data stack, env reference). Frames hold pending
  combinator work; tail positions reuse frames (TCO); primrec/linrec are
  iterative frames. All control effects are frame operations: error =
  unwind the unit's frames wholesale; cancel = discard at a safe point;
  rollback = discard substack + frames. The machine maintains the
  ecl-level trace (qualified words + provenance) for error dicts (d.19);
  host frames never appear.

- **Environment + registry.** Chained tables symbol → binding; a binding
  carries kind (word|value), visibility (public|private), body/value,
  doc, home module, and a reserved effect-declaration slot (seal layer,
  d.9). Envs are enumerable and reifiable (d.18: module construction,
  `which`, completion). Per-session module registry name → module;
  module-word execution resolves through registry indirection (hot
  reload). Binding writes are observable events (future cache
  invalidation hook).

- **Scheduler.** Units may execute concurrently and in parallel — the
  runtime must not assume a single thread of execution (no GIL-shaped
  design). spawn creates a unit; tasks are write-once cells (await
  blocks, idempotent, cached outcome; await-any; deadline timers for
  await-for). Every unit records spawned children; death or scope-end
  cancels unawaited children (d.20). Cancellation lands at frame
  boundaries; discarding a unit is safe because units share nothing
  mutable.

- **Kernels.** Coarse primitives — pervasive arithmetic/comparison,
  `each`/`each2`/`fold`/`scan`/`for`, `where`/`at`/`raze`,
  take/drop/reverse/index, dict align/merge, string search/split —
  execute as single runtime loops over leaves, never per-element trips
  through the frame machine when data is specialized; generic spines fall
  back to recursive descent. These few dozen loops are the entire
  optimization surface (d.21): kernels over flat buffers get fast;
  per-token dispatch never needs to.

- **Boundary layers.** Reader: matched-delimiter grammar → values,
  provenance attached to every token; parse-time transforms are exactly
  the capped set (locals desugar, `{...}` → `dict-of`). Printer:
  representation-exposing, round-tripping (d.16). IO: UTF-8
  encode/decode at the edge, byte IO distinct from char IO (d.15),
  ordered within a unit (d.11); every host error converts to an error
  dict at this boundary — no host exception or host frame crosses into
  the language (d.19).

## Rejected

Closures. Result-values-on-stack (an unchecked error value desynchronizes
every later word's stack picture — corruption, not a message; `attempt`'s
uniform-arity outcome at an isolated boundary is the sound exception).
Local try/catch handlers (dynamic-extent observation imported from
applicative languages; replaced by crash-only + `attempt`). Lisp-style
condition/restart systems (require dynamically-bound handler state, and
restarts pay off in long-lived images — rollback being free removes their
payoff here). Effect monads.
A separate macro system. Persistent tree structures. Numeric tower in core
v1. Bignum promotion inside flat leaves (scalar/array semantics would
diverge). Remora-style static shape types (research program). Early bytecode
VM. Machine-code compilation and JIT, permanently (decision 21) — the
K/J interpreter-amortization model is the committed performance
architecture. APL-style rank-carrying flat arrays with strided views (right answer for
a BQN competitor; wrong one for this language).

## Reopened by the clean-slate call

- **All naming.** Word names (dup/swap/dip/primrec...) are ec inheritance,
  not commitments.
- **Grammar.** Settled — see GRAMMAR.md (companion spec: tokens, forms,
  units, round-trip).

## Open questions

None. Everything is settled above or explicitly deferred with its
constraints pre-written: the seal layer and module–seal interaction
(decision 9), pdict (decision 1), channels (decision 20), exactness
(decision 4), and the naming item under Reopened. Host choice is
deliberately absent: the Runtime section specifies what any
implementation must deliver, and nothing more.
