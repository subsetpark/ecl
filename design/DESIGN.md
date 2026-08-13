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
  calculator you open cold and type `2 3 +` into. The module boundary is
  the hardening boundary (decision 9): module words carry mandatory effect
  declarations — enforced dynamically in v1, statically post-v1 — plus
  early binding and compiled forms. When code matters, you harden it by
  moving it into a module.
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

5. **Bindings: `def`/`set` split.** Executability is a property of the
   *binding*, not the value (forced by decision 2: with one list type there is
   nothing to dispatch on). `(body) 'name def` binds a word — reference
   applies the body. `value 'name set` associates a value with a name in the
   current environment — reference pushes it, including quotations-as-data.
   `set` is environment assignment, not a lexical binding form: unqualified
   references resolve when executed. Prefer stack flow or binder locals for
   ordinary local values. One namespace, entries tagged word|value.
   `def` requires a list body (else error pointing at `set`); a data list as
   body is legal and yields a multi-value constant word. Everything is
   late-bound: words see re-`def`s and re-`set`s of their dependencies
   immediately — module words via registry indirection (18); decision 9's
   intra-module early-binding license is observably equivalent, never
   semantic. No Thunk concept.

6. **No closures, ever.** A quotation is a plain inspectable list; capture is
   `cons`/splice producing a new plain list (`3 (+) cons` → `(3 +)`).
   Locals are definition-site sugar that desugars to point-free code before
   storage; head-position only; not permitted across quotation boundaries in
   v1 (error suggests `cons`). Spelling: `(|lo hi| …)`, Rust/Ruby-style —
   see GRAMMAR.md. The locals sugar does not invoke `set`; they are unrelated
   mechanisms.

7. **Errors: crash-only, observed as data at unit boundaries.** No
   try/catch, no handler quotations. Errors propagate; the failing unit of
   work dies; the transactional stack makes death free — a failed unit
   (e.g. a REPL line) leaves nothing, rolling back to its entry state.
   The guarantee is stack-only, stated honestly: env writes and IO
   performed before the failure survive. Failure is observed from outside,
   as data, at one explicit boundary word: `(q) attempt` runs a
   self-contained quotation (effect `( -- ... )`; inputs arrive via `cons`
   or env names, never the ambient stack — the same rule as every other
   quotation boundary) on an isolated substack, and always pushes exactly
   one outcome value: `{'ok (results)}` or `{'err <error dict>}`. Uniform
   arity is what makes reified failure safe in a stack language — the
   desync argument that killed results-on-stack does not apply, because a
   failure never shares a stack with the code observing it. Handling is
   ordinary dict handling: `ok?`, `or-raise` (results, or re-raise),
   `or-else` (default on failure). The unit of failure is the unit of
   concurrency: `spawn` (decision 20) accepts exactly what `attempt`
   accepts and delivers the same outcome; `par-each` re-raises the
   leftmost `'err`, keeping parallel failure deterministic. The REPL is
   the implicit top-level boundary.

8. **No macro layer.** Runtime quotation construction (`compose`, `cons`,
   list words) plus `def` *is* the metaprogramming system; `'word body`
   fetches a word's list for surgery, `def` rebinds. With immutability,
   build-new-then-rebind is the only way code changes (this is what makes
   cache invalidation tractable). Parse-time words are capped at a handful
   (locals sugar, literal readers) and the cap is policy.

9. **Hardening is structural: the module boundary, not a per-word act.**
   (Re-ruled 2026-08-12; supersedes the deferred per-word `seal` — no
   `seal` word exists or ever will.) Module `def`/`defp` take a
   **mandatory effect declaration**: a plain quotation of words with one
   `--` separator, `( a b -- c )`, shape-validated at registration. Zero
   grammar change — the declaration is ordinary quotation data,
   homoiconic and inspectable. Spelling: `( body ) ( a b -- c ) 'name
   def` — module `def`/`defp` are 3-ary; top-level `def` stays 2-ary
   (context-dependent arity, precedented by `defp`'s top-level error).
   Declarations live in the binding cell's effect slot and are shown by
   `see`/`which`. The architecture is gradual checking: dynamic top
   level, declared modules, contract-guarded boundaries.
   - **v1 enforcement is dynamic:** decision 14's machinery checks the
     observed effect against the declaration at application. Declarations
     are live contracts from day one, not comments awaiting a checker.
   - **The deferred layer is now the static checker** (post-v1): verify
     bodies against declarations at registration — Factor-style; inline
     quotation literals inferred; dynamic `call` inside checked code
     requires a declared-effect variant. Checker scope (row polymorphism,
     purity marks) stays deferred as a bundle. Its arrival is a
     *principled break*, accepted on the record: a module whose
     declaration is wrong-but-unexecuted starts failing at registration.
     The old strict-extension promise is amended to: the checker rejects
     only code already violating its own stated contract (success-typing
     discipline; the Dialyzer model).
   - **Literal-count packing is inferable; dynamic packing is an escape
     hatch.** `pack` consumes the top `n` values, where `n` is itself the
     top input. A nonnegative integer literal gives the checker an ordinary
     fixed effect; a nonliteral count has unknown effect and is therefore
     unavailable inside a statically verified body. It remains legal on the
     dynamic top level, where deliberately state-dependent stack surgery
     belongs.
   - **Binding license:** only occurrences resolving to the module's own
     internal env may be early-bound, at commit time — sound because
     module envs are write-once, registration commits after success, and
     generations are pinned (18), so it is observably equivalent to late
     resolution. References through `use`s and to core stay late through
     the pinned generation: a re-registered use may newly export a name
     that shadows core, so early-binding past the internal env would
     break d.18 hot-heal. Stored bodies and escaping quotations remain
     plain unresolved lists everywhere (6, 8, 18); compiled forms live
     only in the cell.
   - **What module residence does NOT confer:** `par-each` observational
     equivalence — purity is per-word and stays deferred (11) — and
     static coverage of metaprogramming: cons/compose-built quotations
     applied mid-body resolve dynamically forever (8); every module
     keeps a dynamic path.
   - **Top-level words permanently forgo hardening.** Anything
     long-lived belongs in a module (Erlang positioning, ruled
     deliberately; hardening-by-relocation preferred over
     hardening-by-keyword).
   - Prior art: Typed Racket's boundary discipline (checked modules,
     dynamic contracts at untyped boundaries), Factor's mandatory stack
     effects, Dialyzer success typing, Erlang's local/external call
     split. The substrate invariants that keep the checker layer
     possible: quotations are plain lists (6, 8); code changes only via
     `def`/`set` rebinding (1, 5); combinator contracts define the
     effect vocabulary (14); the env is enumerable.

10. **Evaluator: one explicit frame machine.** Guaranteed TCO through words,
    `if`, and combinator tail positions; recursion combinators
    (primrec/linrec) iterative, never on the host stack; unit rollback and
    `attempt`/`spawn` boundaries are frame operations. No bytecode VM unless profiling
    demands one — the APL performance model (fat flat primitives, thin
    dispatch) is the bet.

11. **Effects/IO: plain impure words.** Sequential combinators guarantee
    left-to-right order, so IO inside `each`/`for` is well-defined.
    `par-each` is stdlib over `spawn`/`await` (decision 20): result order
    and leftmost-error are deterministic today; the deferred static
    checker's purity checking (decision 9) later *upgrades* it to full
    observational equivalence
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
    argument. Quotations are checked dynamically at each application
    (violation = immediate error naming the element and the observed
    effect); module words are additionally checked against their declared
    effects (decision 9). Under the post-v1 static checker, statically
    *verified* applications may skip the dynamic check — verification
    licenses the skip, never module residence alone.
    - `each` (K `'`): requires `( a -- b )`; applies one level down the
      leading axis, exactly one result per element; result specializes when
      rectangular. Depth composes by nesting: `((q) each) each`.
    - `each2`: requires `( a b -- c )`; zip with broadcast conformability.
      Each-left/right are derived via `cons`, not primitives.
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
    at IO boundaries (source files, read/write/print); invalid UTF-8 on input
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

17. **Dict literals are inert key/value syntax.** `{k v ...}` constructs one
    dict value directly: its top-level forms are paired adjacently without
    evaluation. The form count must be even, so `{foo bar baz}` is a parse
    error; `{foo bar}` stores the word value `bar` under the word key `foo`
    rather than resolving either name. Duplicate keys are also parse
    errors. `dict-of` is the corresponding runtime conversion
    `( entries -- d )`: it accepts one flat, even-length list, pairs adjacent
    values, and executes nothing. Computed construction therefore builds
    the entry list explicitly, for example
    `'total 3 4 + pair dict-of` produces `{'total 7}`. `to-dict`
    remains the two-column constructor. Merging is explicit (decision 13's
    key-aligned `+`, or `merge`). Any value is a legal key (immutability
    makes everything hashable); symbols are the idiom. Key identity is
    whole-value `match` identity. `has?` asks only whether such a key is
    present: keys are inert, absence is false, and
    lookup/cancellation/allocation failures are not converted to false.
    Insertion order is preserved (column order for tables). `{}` is the
    empty dict; dicts print as `{key value ...}` and round-trip.

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
    - **Privacy at the definition site:** inside a module body, `def`/`set`
      bind public (exported), `defp`/`setp` bind private (Elixir-style).
      Privacy is subtractive — privates are absent from the module's public
      face, not access-checked. At top level `defp`/`setp` are an error
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
    - **Shadow notice (ruled 2026-08-12):** `use` reports on stderr each
      session binding that shadows an incoming export ("session `mean`
      shadows `stats.mean`"). Informational only — `use` succeeds, and
      session-level shadowing stays legal (it is the documented way to
      locally patch a module word). This guards the d.9 grow→harden
      path: moving a word into a module inside a live session otherwise
      leaves the stale session def silently winning at bare-name call
      sites while the module runs its own version internally. Qualified
      access and module-internal resolution are unaffected.
    - **Addenda proven by the skeleton:** a module body has contract
      `( -- )` and runs stack-isolated (registration produces no values);
      `use` is idempotent and re-using a module moves it to the top of
      the shadow order; aliases and module names may not collide in
      either direction; a failed re-registration leaves the previous
      generation registered (registration commits only after the body
      succeeds — crash-only applied to the registry); temporary
      `def`/`set` inside a module body's isolated children stay dynamic
      and are never exported.

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
      contract — inputs via `cons`/env, never ambient stack) on its own
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
      dispatch never needs to be fast; (d) decision 9's cached "compiled
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
  homogeneous buffers: i64, f64, chars at tagged width 1/2/4, and
  interned-symbol u32 ids; one leaf-tag slot reserved for a future
  narrow-mask representation — d.23); specialization happens at
  construction and is semantically invisible except through printing
  (d.16). Every value supports structural equality, hashing, printing.
  Each heap value carries a precise atomic reference count ("or shared
  bit" struck by d.23) sufficient to answer "uniquely held?" — set at
  the enumerable sharing points (dup-family, env binding, list
  inclusion). Uniquely-held values may be mutated in place by the runtime
  (append into slack capacity; amortized O(1)); shared values copy first
  (d.1). Dicts: insertion-ordered maps, any value as key; dict hashing is
  order-insensitive to agree with d.22 equality. Tasks: write-once
  outcome cells with identity.

- **Frame machine.** One explicit evaluation loop; no evaluation
  recursion on the implementation call stack, ever (d.10). A unit =
  (frame stack, data stack, env reference). Frames hold pending
  combinator work; tail positions reuse frames (TCO); primrec/linrec are
  iterative frames. All control effects are frame operations: error =
  unwind the unit's frames wholesale; cancel = discard at a safe point;
  rollback = discard substack + frames. The machine can produce the
  ecl-level trace (qualified words + provenance) at any unwind point for
  error dicts (d.19) — the happy path pays nothing for traces, and
  guaranteed TCO means a trace shows the non-tail spine (d.23); host
  frames never appear.

- **Environment + registry.** Chained tables symbol → binding; a binding
  carries kind (word|value), visibility (public|private), body/value,
  doc, home module, and an effect-declaration slot (mandatory for module
  words, d.9). Envs are enumerable and reifiable (d.18: module construction,
  `which`, completion). Per-session module registry name → module;
  module-word execution resolves through registry indirection (hot
  reload). Binding writes are observable events (future cache
  invalidation hook).

- **Scheduler.** Units may execute concurrently and in parallel — the
  runtime must not assume a single thread of execution (no GIL-shaped
  design). spawn creates a unit; tasks are write-once cells (await
  blocks, idempotent, cached outcome; await-any; deadline timers for
  await-for). Every unit records spawned children; death or scope-end
  cancels unawaited children (d.20). Cancellation lands at safe points —
  frame boundaries and chunk boundaries inside kernels (kernels are
  otherwise safe-point deserts, d.23); discarding a unit is safe because
  units share nothing mutable.

- **Kernels.** Coarse primitives — pervasive arithmetic/comparison,
  `each`/`each2`/`fold`/`scan`/`for`, `where`/`at`/`raze`,
  take/drop/reverse/index, dict align/merge, string search/split —
  execute as single runtime loops over leaves, never per-element trips
  through the frame machine when data is specialized; generic spines fall
  back to recursive descent. These few dozen loops are the entire
  optimization surface (d.21): kernels over flat buffers get fast;
  per-token dispatch never needs to.

- **Boundary layers.** Reader: matched-delimiter grammar → values,
  provenance attached to every reader-produced token on the code plane
  (side tables — never on runtime values; code assembled at runtime via
  cons/compose has none, and error dicts omit position: d.22/d.23);
  the only code transform is locals desugaring; dict syntax constructs an
  inert value directly. Printer:
  representation-exposing, round-tripping (d.16). IO: UTF-8
  encode/decode at the edge, byte IO distinct from char IO (d.15),
  ordered within a unit (d.11); every host error converts to an error
  dict at this boundary — no host exception or host frame crosses into
  the language (d.19).

22. **Rulings forced by the walking skeleton.**
    - **Words ≠ symbols.** A bare word in code and a quoted symbol are
      distinct atoms: `(dup) first` yields the word, `'dup` the symbol,
      and they do not `match`. Words print bare, symbols quoted.
      `to-word`/`to-symbol` convert; `parse` remains the front door for
      code-from-text. (This reifies ec's `:quoted?` flag and extends
      decision 5's doctrine down to tokens.)
    - **Floats: ±inf are values, NaN is not.** `inf`/`-inf` are float
      literals (whole-token, like hex; the names leave the word
      namespace). Arithmetic propagates non-finite *operands* IEEE-style;
      producing a non-finite result from finite inputs is `'overflow`
      (silent overflow stays banned); any NaN-producing operation is
      `'domain`; division by zero is `'domain`. Float equality is numeric
      everywhere — `0.0` equals `-0.0`, and `=` and `match` agree on all
      numbers.
    - **Dict equality ignores insertion order**; storage and printing
      preserve it.
    - **Printing at unit end:** script files print only explicitly
      (`pp`/`prin`); `-e`, stdin, and calculator invocations print the
      final stack.
    - **`floor`/`ceil`/`round` return int64** (`'overflow` outside the
      range): their results are indices and mask material, and int-ness
      keeps integer pipelines integer — the efficiency tiebreak. `pow`
      stays float.
    - **Absence is absence** (amending decision 19): error dicts carry
      `'word` and source position only when known; handlers test with
      `has?`. There is no nil. External data models that reify null
      (JSON) map it at the boundary to the ordinary symbol `'null` —
      data, not language nil (`json.parse`/`json.emit` round-trip it;
      ruled during workstream-v1 planning).

23. **Interpreter-architecture rulings** (literature panel + adversarial
    review; the full architecture is ARCHITECTURE.md, research preserved
    in research/).
    - **Float folds are strictly sequential on every path.** Only exact
      reductions (integer, min/max, boolean) may be reassociated for
      SIMD or future kernel-internal parallelism. Fused and generic
      paths must be bit-identical — recognition is unobservable down to
      the last float bit. A documented `fsum` is the future escape valve
      if float-sum throughput ever matters.
    - **Reference counts are precise and atomic** (the Runtime section's
      former "or shared bit" option is struck — a sticky bit never
      recovers uniqueness, defeating decision 1's copy-once clause).
      Uniqueness = rc==1 with acquire ordering, one shared function.
      Push/pop perform no RC operations (the stack owns its values); the
      dup-family is the sole evaluator increment site. Publication edges
      (task-cell completion, binding writes, registry swaps) are
      release/acquire. The K-order ceiling (d.21) is honestly "K minus
      atomic-RC overhead" unless later measurement closes the gap.
    - **No cycle collector, ever.** Immutable bottom-up construction,
      words resolving by name (never heap pointer), and no closures make
      the value heap a DAG. Sole exception: a task returning its own
      handle into its outcome cell — a documented bounded leak, not
      machinery.
    - **Leaf set amended:** i64, f64, chars at width 1/2/4, and
      interned-symbol leaves; one reserved tag for a future narrow-mask
      representation. Leaf kinds are representation only, never
      semantics.
    - **Blockwise fault detection is licensed:** overflow/NaN checks may
      accumulate per block with a scalar rescan identifying the failing
      element — sound because crash-only rollback makes computation past
      the fault unobservable. When a kernel reuses its input buffer as
      output, the fault mask is tested before that block's stores.
    - **Env-write scope invariant:** only the session thread writes
      session-visible environments; unit bodies write only disposable
      child scopes (stating what d.18's tests already prove). The module
      registry is the one multi-writer table and takes an explicit
      synchronized swap; module words pin one registry generation for a
      whole body — no mixed-generation execution.
    - **Snapshot semantics are scoped to the recognition guard only:** a
      combinator may resolve its quotation's words once at entry to
      choose a fused kernel; the generic path keeps full per-application
      late binding. This deliberately does not amend decision 5. Any
      future cache holds the binding cell and re-reads its interior
      every execution — resolutions are never cached.
    - **`attempt` ≡ `spawn await` is observational equivalence** — a
      test property; `attempt` remains an in-machine boundary frame,
      never routed through the scheduler.
    - **par-each guarantees no cross-element rendezvous:** elements may
      run fully serially or chunked; a program whose elements must run
      concurrently to progress is already broken. This licenses a
      chunking [P] override of the prelude definition.
    - **Line budget (re-derived 2026-08-12 for the Zig host):**
      interpreter core ≤ ~9.5k lines excluding kernels, stdlib, and
      tests; kernels ≤ ~5k; stdlib modules ≤ ~2k. Budgeted per component
      so the ceiling binds where sprawl would appear — see
      ARCHITECTURE.md's table. Additions still displace within a
      component. The superseded ~5k figure was derived from the Rust
      skeleton's 4.6k, a baseline that does not transfer: different host
      (Zig costs lines for explicit allocators, error unions, and `zig
      fmt`), different data structures (the skeleton's boxed lists,
      uninterned symbols, and assoc-vector dicts are exactly what
      ARCHITECTURE.md disqualifies — flat leaves, interning, and precise
      atomic RC cost 3.8x on the value layer *by design*), and half the
      feature set (no concurrency, kernels, scheduler, modules-on-cells,
      or stdlib). The budget's real invariant is d.21's: coarse
      primitives, a few dozen kernels, no sprawling VM, never machine
      code. Lines are the proxy, not the point.
    - **The differential harness is a named v1 deliverable:** every
      kernel and idiom tested against the generic path for value
      equality, representation parity (d.16 makes brackets observable),
      error kind/payload equality, and bit-identical floats; the
      scheduler suite runs at 1 and N workers asserting identical
      outcomes.

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

- **All naming.** Settled — see VOCABULARY.md: Joy/Factor names for the
  stack half, K names for the array half; `pop` (stack) vs `drop`
  (sequence); `cons` not `curry`; `call` not `i`; Janet's `prin`/`print`
  convention; primrec/linrec dropped from core. The v1 combinator
  surface (ruled 2026-08-12) captures Joy's zoo and APCL's adaptors
  practically — control flow is the least intuitive element of
  concatenative programming for infix-trained users, so the common
  shapes get names: cleave family `bi`/`tri`/`bi2`/`both`,
  `times`/`cond`/`case`/`unless`, `infra`, and
  `filter`/`partition`/`any?`/`all?`. Most are [E] prelude; APCL's
  remaining adaptors reduce to stack words (see VOCABULARY.md's
  correspondence note). Every inline combinator is an
  idiom-recognition site (d.23). Recursion combinators stay dropped.
- **Grammar.** Settled — see GRAMMAR.md (companion spec: tokens, forms,
  units, round-trip).

## Open questions

None. Everything is settled above or explicitly deferred with its
constraints pre-written: the static effect checker bundle (decision 9),
pdict (decision 1), channels (decision 20), exactness
(decision 4). Host choice is deliberately absent: the Runtime section
specifies what any implementation must deliver, and nothing more.
