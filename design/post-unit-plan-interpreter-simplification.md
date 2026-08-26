# Post-unit-plan interpreter simplification

Status: deferred; blocked on the complete unit-plan feature landing

## Execution barrier

These instructions describe a follow-up change. They must not be implemented
in the unit-plan patch or interleaved with its patch stack.

Work may begin only when all of the following are true on the base commit:

1. `design/unit-plan.md` is implemented in full, including its public behavior,
   ownership rules, static enforcement, documentation migration, and bounded
   work requirements.
2. The unit-plan change has landed as a complete commit or patch stack rather
   than existing only as uncommitted work in the shared tree.
3. `zig build precommit` passes for that landed base with standard input closed
   and its exit status captured directly.
4. The `cat` reproduction, raw reader-body attribution, seed preservation, and
   cross-archive witness rejection are passing through public runtime tests.

If any entry condition is absent, stop. Repair or finish unit-plan first. Do not
use this follow-up to complete, redesign, or compensate for a partial unit-plan
implementation.

The first simplification commit must have the complete unit-plan landing as an
ancestor. Record that prerequisite in the active gameplan so the dependency is
machine-reviewable rather than a convention about patch order.

The landed feature may still contain semantically redundant mechanisms that do
not violate its specification: descendant identity checks inside an already
admitted original body, duplicated constructor-input adapters, duplicated
bounded seed materializers, eager image scope allocation, and formatter
recognition of the former `with` idiom. Those are the inputs to this cleanup.
The landing may not defer any public semantics, ownership guarantee, witness
separation, or bounded-work requirement to this document.

## Objective

Remove the interpreter mechanisms that existed only because seed values and a
construction body were flattened into an ordinary quotation, and because
diagnostic reader identity was being used as a proxy for module-text
attribution.

The resulting interpreter must express these facts directly:

```text
UnitInput identifies one body and zero or more seeds.
Only the exact body root may admit construction attribution.
Only reader-text lineage grants that admission, and the archive decides it
internally: no proof of admission is a value a caller can hold or replay.
Admission stamps the complete body subtree.
Rejection performs no stamping and does not inspect descendants.
Seeds are initial stack values and are never construction text.
```

This is a representation and authority cleanup. It must not change the language
behavior specified by `design/unit-plan.md`.

## Invariants to preserve

1. A word resolves in the scope carried by the occurrence.
2. A witnessed original reader body is copied and every word in its complete
   reader-built subtree is stamped to the new image.
3. An unwitnessed body is executed unchanged. Nested witnessed fragments do not
   admit it, and the interpreter does not descend looking for them.
4. A stamped copy carries diagnostic source projections *and* reader-text
   lineage: it is the same reader text re-scoped, so a later constructor may
   re-stamp that exact copy to its own image. Nothing outside the scope-only
   construction rewrite acquires lineage. (Ruled 2026-08-26; this replaces the
   earlier non-transfer invariant, which made a construction nested inside a
   construction body resolve against the enclosing image. See
   `design/unit-plan.md`, Reader-text lineage.)
5. Lineage is valid only for the exact header and issuing Session archive, and
   no operation grants it to a header its caller chose.
6. Seeds retain their values, word scopes, ordering, and diagnostic provenance.
7. A raw quotation is exactly the empty-seed case of `UnitInput`.
8. `@each` places its element deepest in the child stack, below plan seeds.
9. Every consuming operation states and implements ownership on success and on
   every failure path.
10. User-sized seed materialization and body stamping remain bounded scheduler
    work.

## Simplification 1: make attribution a one-time root decision

The landed feature already makes one semantic admission decision at the
construction boundary. Consolidate that decision into the only representation
the later construction path can consume.

The boundary must ask the reader-witness authority to classify the exact body
root. The result must be a tagged or opaque capability, not a correlated
`bool`, identity number, archive pointer, and header tuple that callers can
mis-pair. The two outcomes own everything needed for their respective paths:

```text
runtime body     -> owned unchanged body
original body    -> owned body plus unforgeable stamping admission
```

After classification:

- The runtime-body branch transfers the original body directly into module
  execution. It performs no copy, traversal, source projection, or descendant
  identity query.
- The original-body branch mints the image scope and passes its admission to a
  bounded structural stamping driver.
- The stamping driver rewrites every word and traverses every supported nested
  container. It contains no archive-membership, child-identity, or provenance
  gate.
- The driver constructs its own output and projects source locations onto it,
  inheriting the input's reader-text lineage as part of the same commit. It
  never accepts a destination header from its caller.

Delete the nested-list `identityOf` test from `Machine.stampValue`. Delete any
comment, helper, or test that describes archive-wide code identity as the
admission rule. There must be no fallback that scans descendants when the root
is rejected.

The unit-plan landing must already have made stamping bounded. Do not replace
its cursor or driver with recursive traversal during this cleanup. Simplify the
bounded walker by deleting descendant admission state and queries while
retaining its exact next position and ordinary work budget.

## Simplification 2: narrow the reader/archive authority surface

Diagnostic identity and construction attribution must have separate APIs and
separate minting authority.

After all production consumers use the root-classification seam:

- Remove `SpanArchive.identityOf` from the machine-facing surface if it has no
  remaining non-attribution consumer.
- Do not expose a raw provenance namespace merely so arbitrary machine code can
  manufacture archive-associated code. Give the admitted stamping operation
  only the narrow construction capability it needs.
- Replace raw span aliasing in the construction path with a semantic
  source-projection-and-lineage operation private to the re-scoping cursor,
  which supplies its own destination header.
- Keep code identities, span indexes, and source projections internally where
  diagnostics still require them. Do not delete diagnostic provenance merely
  because it no longer decides attribution.

Enforce witness minting and non-transfer with opaque capability types first.
Use `comptime` validation or the exhaustive production source audit only for
properties Zig cannot express. Do not add runtime tests that read source files
or test-only accessors exposing witness tables, code identities, or archive
layout.

## Simplification 3: normalize every constructor through one owned input

The landed feature may initially decode the tagged input at more than one
constructor adapter. Consolidate those paths into one consuming decoder:

```text
raw quotation -> empty seeds, quotation body
unit-plan      -> stored seeds, stored body
```

Its result must be one nominal owned value whose destructor covers both fields
until they are transferred. Constructors must not independently inspect the
heap tag, unpack plans, or recreate ownership cleanup.

Route `@attempt`, `@spawn`, `@each`, `@module`, and `@defm` through this decoder.
`@defm` continues to consume its name in the specified stack order, then uses
the same constructor-input path as `@module`.

Keep the five constructors' lifecycle behavior distinct. This cleanup does not
merge attempt boundaries, module publication, task spawning, parallel joining,
or registration. It unifies only their input and initial-stack protocol.

## Simplification 4: use one bounded initial-stack materializer

Consolidate the landed bounded seed-initialization paths behind the existing
explicit child `InitialStack` seam rather than retaining separate in-machine
and child-task plan mechanisms.

The materializer must support:

- no seeds;
- a plan's ordered seed list;
- the `@each` element followed by a plan's ordered seeds.

It must retain or consume every value according to one documented ownership
contract, preserve list order, yield on large inputs, and unwind partially
materialized stacks without leaks. Child tasks must own the references they
need independently of the parent plan and of sibling children.

Use the same materializer when opening an in-machine isolated boundary. Record
the caller's stack length as the new floor, materialize seeds above it, and
execute the body with that floor. Do not implement plan seeding by synthesizing
or executing `literal`, `partial`, `with`, or another quotation.

The combinator contract machinery's existing use of the term `seeded` is a
different invariant. Do not merge `StackWindow`/contract arity state with the
unit-plan initial-stack capability merely because both involve initial values.

## Simplification 5: make image scope allocation conditional

An unwitnessed runtime body receives no newly stamped word occurrences.
Therefore the construction path must not eagerly mint a stable image `ScopeId`
solely for stamping that will not occur.

Create the image and its execution home in both branches. Mint the image scope
cell and anchor reference only in the admitted stamping branch, or lazily at a
later operation that genuinely needs a stable `ScopeId`. Preserve image homes,
definition ownership, publication, reload isolation, and qualified dispatch;
those are independent of whether this body contributed stamped occurrences.

Before deleting any unconditional scope allocation, audit every consumer of the
cell and express the distinction in types. If a non-stamping consumer genuinely
requires it, give that consumer an explicit lazy request rather than restoring
unconditional allocation. Acceptance must demonstrate that unstamped anonymous
and registered images still execute, define, publish, reload, and retire
correctly.

## Simplification 6: remove recognition of `with` as constructor metadata

Once first-party source and documentation use `seed`, remove interpreter-adjacent
code that treats ordinary `with` composition as nominal unit seeding.

In particular:

- Formatter recognition of a syntactically evident seeded `@defm` must key on
  `seed`, not infer intent from neighboring lists and `with`.
- Remove the `with`-specific backward seed-list heuristic when it has no other
  formatter use.
- Isolation guidance must recommend the corresponding `seed` spelling.
- Centralize the common guidance text so the five constructors supply only the
  constructor-specific phrase and `@each` ordering note.
- Primitive documentation and reflective effects must describe `UnitInput`, not
  a quotation secretly prepared through composition.

The old `values body with @constructor` spelling remains valid ordinary ECL:
`with` returns a runtime-built quotation and the constructor accepts that raw
quotation. It need not receive special formatter navigation or diagnostic
status. Do not reject, reinterpret, or nominalize it.

## Simplification 7: delete obsolete synthetic seeding, not composition

No constructor may generate or execute capture quotations for nominal plan
seeds. Remove dead helpers, branches, comments, examples, and allocation-failure
cases that exist solely for that path after production references are gone.

Do not remove or specialize `literal`, `partial`, `with`, `cat`, `compose`,
`cons`, `append`, `raze`, slicing, reversal, or generic list construction. They
remain public homoiconic composition operations, and their runtime-built
results must continue preserving the scopes already carried by their words.

## Patch sequence

Keep every patch buildable and behavior-preserving. Use this order unless the
landed representation makes two adjacent steps inseparable:

1. Make the landed root-classification result nominal and move every module
   constructor consumer onto it without deleting the old archive API yet.
2. Remove descendant admission state from the landed bounded stamping driver
   and activate the unchanged-body fast path.
3. Consolidate constructor decoding and initial-stack materialization across
   all five constructors.
4. Make image scope allocation conditional and prove image lifetime behavior.
5. Simplify formatter recognition, diagnostics, primitive metadata, and
   first-party implementation comments.
6. Delete now-unused identity/provenance authority, helpers, and obsolete tests;
   update architectural documentation and the active gameplan.

Do not combine a semantic repair discovered during this work with a cleanup
patch. If the landed unit-plan behavior is wrong or incomplete, stop, repair
the feature against `design/unit-plan.md`, establish a new passing baseline,
and only then resume this sequence.

## Verification

Tests must observe public runtime or formatter behavior. They must not inspect
implementation source text, private witness tables, identities, fields, helper
names, or call patterns.

Retain or add public coverage for:

1. Literal reader bodies stamp words through quotations, list literals, and
   dict literals.
2. Runtime-built roots are unchanged even when every child is reader-built.
3. A rejected root containing a very large reader-built fragment is not
   admitted through that fragment.
4. Span projection preserves exact error locations in a stamped copy, and that
   copy is admissible for a construction nested inside it, while no runtime
   reconstruction of it is.
5. Raw quotations and empty-seed plans behave identically in all five
   constructors.
6. Multiple plan seeds preserve order; `@each` keeps its element deepest.
7. Parent plan, sibling tasks, cancellation, and allocation failures do not
   invalidate or leak child seed values.
8. Unstamped anonymous and registered images define, execute, publish, reload,
   and retire without an eagerly minted stamping scope.
9. Formatter navigation recognizes the nominal `seed` spelling; ordinary
   `with` composition remains valid and formats as ordinary code.
10. Isolation errors recommend `seed` for each constructor.

Place allocation-failure coverage deliberately. Component-level failure probes
belong beside the new decoder, plan-opening, materializer, and stamping driver.
Add the smallest initialized-Session snippet to `src/tests/oom_test.zig` only
for paths unreachable without a live Session. Do not multiply seeds or body
elements merely to add volume.

After each patch, run the local tier with standard input closed and capture the
status of that invocation immediately:

```sh
timeout 500 zig build precommit < /dev/null > run.log 2>&1; code=$?
```

Inspect `code` before inspecting `run.log`. Do not run the complete local CI
matrix. If the change alters scheduler lifetime or when tasks become reachable,
run the Docker-only Linux/x86_64 TSan gate for that specific reason, following
`AGENTS.md` exactly.

For every new runtime test, prove the selected tier executes it by temporarily
breaking its assertion, observing the intended tier fail, and restoring it.

## Documentation and architectural enforcement

Update `design/INTERPRETER.md` in the patch that establishes each revised
structural invariant. Update the active gameplan and `design/workstream-v1.md`
when their dependency, implementation, or proof claims move. `design/SPEC.md`
must not acquire implementation detail; change it only if stale pre-unit-plan
language remains after the feature landing.

Static enforcement must establish, without source-substring tests, that:

- only reader absorption can mint an original witness;
- source projection cannot mint or transfer one;
- only an admitted exact root can obtain stamping authority;
- the stamping driver has no descendant admission operation;
- all `UnitInput`, initial-stack, and attribution variants are handled
  exhaustively;
- generic list/dict/code builders cannot obtain witness-minting authority.

Prefer closed types and opaque capabilities. Use the exhaustive production
source audit only where the compiler cannot express the rule, and make the
audit fail closed on every classified production file.

## Completion criteria

This follow-up is complete only when all of the following are simultaneously
true:

- The machine makes exactly one attribution decision per module body, at the
  exact root.
- The stamping traversal contains no archive identity or admission query.
- The rejected-root path performs no stamping copy or descendant traversal.
- The machine-facing archive surface exposes no generic identity lookup used
  as semantic authority.
- Every unit constructor consumes the same nominal owned decoded input.
- Every constructor uses the same bounded seed materialization protocol.
- No nominal seed is implemented by generated quotation execution.
- Images with no stamped occurrences do not eagerly allocate a scope solely
  for stamping.
- Formatter and diagnostics assign no special seeding meaning to `with`.
- Public composition words retain their general behavior.
- `zig build precommit` passes, the required targeted behavior passes, and any
  reason-triggered specialized gate passes.
- `design/INTERPRETER.md`, the active gameplan, and the workstream describe the
  final seams and their enforcement accurately.
