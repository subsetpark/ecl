# Post-unit-plan interpreter simplification

Status: implemented 2026-08-26 on the complete unit-plan base `dc8c845`

## Implementation record

The required unit-plan landing is the direct base commit. The simplification
keeps its public language behavior and replaces only the redundant internal
protocols identified below:

- exact-root preparation now consumes the owned body and returns either that
  unchanged owner or an opaque source/archive-bound admission awaiting a scope;
- admitted traversal uses required descendant diagnostic projection rather
  than a second semantic admission gate;
- candidate images mint a stable `ScopeId` only in the admitted branch;
- an admitted re-scope cursor remains in one movable owner until `take()`
  transfers it into `ConstructionDriver`, so failed driver allocation cannot
  leave a second local cleanup armed for the same source;
- one non-struct `OwnedUnitInput` remains intact through child borrowing and
  fan-out movement, then consumes its halves into boundary states;
- one `SeedMaterializer` owns seed-list progress in both construction and child
  drivers; and
- formatter navigation recognizes only raw and nominal `seed` registration
  shapes, while `with` formats as ordinary composition.

The initialized-Session OOM tier includes a post-bootstrap sweep of the
minimal admitted `@defm` operation. It exhausts every allocation in that
operation, including pending `ConstructionDriver` allocation after the cursor
owns its source.

## Source-ingestion alignment

Implemented as a follow-up on the completed simplification base:

- `SpanArchive.SourceIngestCursor` is the single bounded read, root
  materialization, absorption, and temporary-retirement protocol;
- its exhaustive state union owns exactly the boxed reader, read outcome,
  materializer, absorber/root pair, or parsed-retirement capability valid in
  that phase; normal progress and abandonment consume the same variants;
- its public cursor is a movable opaque owner of heap-stable backing, and its
  consuming `take` operation permits relocation between any two advances
  without invalidating the absorber or parsed-retirement self-borrows;
- its adoption transition is the ownership authority on every exit, so an
  allocation failure after publication cannot leave the caller holding the
  archive-owned root;
- `SourceDriver` owns only its source storage, completion policy, and the
  archive cursor, and Session source enters the root scheduler before reading;
- embedded-prelude bootstrap remains the sole synchronous shell and drives the
  same cursor while `BuildingEnv` is unfinished;
- the former blocking `SpanArchive.absorb` adapter is gone, while the lower
  absorption cursor remains the archive phase used by ingestion and focused
  provenance tests; and
- the component allocation-failure sweep covers every ingestion allocation on
  both sides of archive adoption, while the initialized-Session sweep covers
  the prelude and scheduled public source paths; and
- parser failures use an owned `explicit_location` failure-site variant, so
  source provenance is neither borrowed from retiring driver storage nor
  truncated to an inline diagnostic buffer.

## Execution barrier

These instructions describe a follow-up change. Do not implement them in the
unit-plan patch or interleave them with that patch stack.

Work may begin only when all of the following are true on the base commit:

1. `design/unit-plan.md` is implemented in full, including public behavior,
   reader-text lineage, ownership, bounded work, static enforcement, and
   documentation migration.
2. The implementation containing the architecture named under **Landed
   baseline** is a complete landed commit or patch stack, not uncommitted work
   in a shared tree.
3. `zig build precommit` passes on that base with standard input closed and the
   command's exit status captured directly.
4. The public `cat` reproduction, literal-body attribution, seed preservation,
   nested-construction re-entrancy, and cross-archive rejection cases pass.
5. The bounded re-scope, identity-claim contention, cancellation, and
   live-proportional lineage-retention properties pass.

If any entry condition is absent, stop and repair unit-plan first. This
follow-up may remove redundancy exposed by the feature; it may not finish,
redesign, or compensate for an incomplete feature landing.

The first simplification commit must have the complete unit-plan landing as an
ancestor. Record that dependency in the active gameplan.

## Landed baseline

Treat the following as the starting architecture. Do not re-introduce an
earlier witness, mint, reservation, or privileged-handler design while trying
to simplify it.

- `unit-plan` is a nominal heap kind with private typed storage for one seed
  list and one body list. The raw constructor is private.
- `seed` is a dedicated binding kind carrying a root-derived opaque
  `UnitPlanSeal`. Generic core installers accept only ordinary validated names
  and cannot install, replace, or alias `seed` behavior.
- `Machine.popUnitInput` is the sole language-facing decoder for
  `quotation | unit-plan`; it returns `OwnedUnitInput`.
- All five constructors use that decoder. Child constructors describe initial
  operands with `InitialStack`; in-machine construction uses
  `ConstructionDriver`.
- Seed materialization is bounded. `ConstructionDriver` and
  `ChildSeedDriver` currently share the `advanceSeeds` algorithm but retain
  parallel ownership/progress state.
- `SpanArchiveOwner` and `SpanArchive` have separately allocated backing.
  Only the owner holds `HostOwner`, the code-retirement registration, blocking
  host reads, and teardown. Units receive the worker facade and bounded read,
  absorption, and re-scope cursors.
- `SpanArchive.prepareConstructionBody(body, scope)` makes the exact-root
  admission decision and returns either `unchanged` or an already-bound
  `RescopeCursor`. No portable witness or proof crosses the interface.
- Re-scoping is non-recursive native code driven by a shared
  `poll.WorkBudget`. Frames own initialized destination prefixes; list and dict
  publication is O(1); a dict shares scope-invariant hashes and copies its
  optional index in bounded slices.
- A re-scoped list is published through the archive's private lineage path.
  Identity acquisition is a scalar transaction with one claim attempt per
  cursor advance. Claim contention returns `pending`; alias publication returns
  `published` or `refused`; refusal becomes `InvalidProvenance`. A completed
  header remains owned in `ready_to_publish` while publication is pending.
- Reader absorption and the scope-only construction rewrite are the only two
  lineage mints. Rewritten copies inherit lineage so nested construction is
  re-entrant. Generic reconstruction never acquires lineage.
- Code retirement clears exact-header directory entries and recycles
  identities through the owner-held registration. Storage is proportional to
  live re-scoped headers rather than publication history.
- First-party source, primitive documentation, isolation guidance, and the
  formatter's nominal path use `seed`. Ordinary `with` remains composition,
  although the formatter still preserves a compatibility recognition path for
  the former `with ... @defm` shape.

The simplification must preserve every item above unless this document
explicitly identifies its present duplication as the thing to remove.

## Objective

Make the interpreter say the language rule once at each owning boundary:

```text
Unit input decides body versus seeds.
The archive admits or rejects the exact body root once.
Rejection executes the owned body unchanged and does no attribution work.
Admission authorizes one bounded scope-only rewrite of that bound source.
The rewrite traverses the complete reader-text subtree without re-deciding
admission at each descendant.
Seeds are initial operands and never construction text.
```

The target is less state and fewer parallel protocols, not a new unit-plan
implementation. Public language behavior remains exactly that of
`design/unit-plan.md`.

## Invariants

1. A word resolves in the scope carried by that occurrence.
2. Exact-root admission is the only semantic attribution decision.
3. An unadmitted root is executed unchanged. Its descendants are neither
   inspected nor used to recover attribution.
4. An admitted root is copied completely through reader-built quotations,
   lists, and dicts, and every word occurrence receives the target image's
   `ScopeId`.
5. The scope-only rewrite's copies retain diagnostic projection and reader-text
   lineage. A nested constructor may therefore re-scope its exact copied body
   against its own image.
6. Ordinary reconstruction loses lineage. No operation accepts a witness plus
   a caller-chosen destination header, and one archive never admits another's
   text.
7. Seeds retain identity, order, word scopes, and provenance. `@each` puts its
   element deepest, below the plan seeds.
8. Every input, cursor, builder, finished header, seed list, and candidate image
   has one explicit owner on success, failure, cancellation, and transfer.
9. Re-scoping, seed materialization, identity contention, partial teardown, and
   publication remain bounded scheduler work. No terminal step hides a
   user-sized copy, hash, rehash, duplicate scan, or release walk.
10. Lineage storage remains live-proportional and code-retirement registration
    remains owner-only, issuance-checked, and unavailable from the worker
    facade.
11. The privileged `seed` binding and `UnitPlanSeal` remain unavailable through
    generic installation, aliasing, reflection, native calls, or ordinary
    handlers.
12. A raw quotation remains the allocation-free empty-seed case.

## Simplification 1: separate root admission from descendant projection

The landed cursor correctly asks `prepareConstructionBody` once at the root,
but its nested-list traversal calls `admit` again. That second operation is
serving two different purposes:

- it appears to re-decide whether a nested value is construction text; and
- it obtains the source projection needed to publish the nested copied header.

After exact-root admission, the first purpose is redundant and obscures the
rule. The complete reader-text subtree is already the admitted unit. A
descendant query may still be needed as an implementation lookup for spans and
lineage publication, but it must no longer be a semantic gate that can silently
turn a nested reader container into shared runtime data.

Refactor the archive-side representation so these concepts are distinct:

```text
root admission        = optional, semantic, performed exactly once
descendant projection = required within an admitted traversal, diagnostic
```

The admitted result must be a root-bound executable capability, not a portable
claim of lineage. It owns or borrows the exact source header and the archive
state needed to build and attest only its own output. It must not expose an
identity, archive entry, namespace, boolean witness, or operation that accepts
a destination header supplied by its caller.

Within an admitted traversal:

- every supported nested container is traversed according to structure;
- no descendant can cause a fallback to “share unchanged” merely because a
  second admission lookup returned null;
- any lookup retained solely to project spans is named and typed as projection,
  not admission;
- failure to find projection for a descendant that the admitted representation
  says belongs to the reader subtree is `InvalidProvenance` or an equivalent
  explicit invariant failure, never semantic rejection;
- lineage publication continues to build the destination internally and keeps
  the landed `pending | published | refused` distinction.

Do not replace the cursor with recursive traversal. Preserve its frame stack,
builders, `ready_to_publish` state, shared `WorkBudget`, one-attempt identity
transaction, O(1) publication, and exact abandonment cleanup.

If the archive can carry descendant projection directly from the parent span
structure without an identity lookup, prefer that. If the existing exact-header
directory remains the honest source, retain the lookup but make its non-semantic
role explicit. Do not delete diagnostic identity merely to make the traversal
look purer.

## Simplification 2: decide admission before minting an image ScopeId

`Machine.moduleOwned` currently creates the candidate image, eagerly calls
`scopeIdForOwned`, and then calls `prepareConstructionBody(body, scope)`. An
unadmitted runtime body receives no rewritten word, so that eager stable
`ScopeId` and its anchor/cell retention exist solely for work that never occurs.
This is observable resource behavior, not merely one unnecessary call: scope
cells are Env-lifetime directory entries, so minting one for every short-lived
unadmitted image makes residual memory proportional to construction history.

Change preparation into two consuming stages:

```text
prepare exact body -> unchanged owned body
                   | admitted root-bound rewrite awaiting a target ScopeId
admitted + ScopeId -> bounded RescopeCursor
```

The intermediate admitted value is not a witness. It is bound to its exact
source and archive, can only be consumed once to start the archive's own
rewrite, and still cannot attest a caller-chosen output.

Then make module construction branch as follows:

- `unchanged`: retain no rewrite capability, mint no image `ScopeId` for
  attribution, and transfer the original body directly to the boundary;
- `admitted`: obtain the candidate image's stable `ScopeId`, consume the
  root-bound capability into the bounded cursor, and continue through the
  existing construction driver.

The candidate image, execution home, module scope, registration behavior, and
durable state still exist in both branches. Only the stable cell/id used to
label rewritten occurrences becomes conditional. If another consumer truly
needs that id, expose an explicit lazy request at that consumer; do not restore
unconditional allocation.

Express the distinction with a tagged state owned by the construction path.
Do not coordinate it with nullable scope ids, booleans, and separately held
source headers. Preserve candidate-image ownership on every allocation failure.

## Simplification 3: keep decoded unit input owned through handoff

The landing already centralized decoding in `Machine.popUnitInput`; do not
rebuild that work. Simplify what happens after it.

Today `OwnedUnitInput` can be converted into a raw `UnitInput` tuple, after
which `releaseUnitInput` duplicates the destructor and several call sites
manually split body and seeds into driver fields. Replace that parallel
ownership protocol with one nominal consuming handoff.

The result should make these states explicit:

```text
decoded input owned together
|- borrowed for one child launch; owner remains with caller
|- transferred to fan-out state; that state owns body and optional seeds
`- transferred to boundary construction; that state owns body and optional seeds
```

Requirements:

- `popUnitInput` remains the only tag inspection for all five constructors.
- The plan object may be released after decoding because the decoded owner has
  independent references to its two halves.
- No public constructor accepts a raw pair of owned header pointers whose
  failure contract must be remembered separately.
- The destructor for an untransferred decoded input is written once.
- Moving the body and seeds into a child, fan-out driver, or construction driver
  consumes the corresponding ownership exactly once.
- Do not merge the five constructors' distinct lifecycle semantics. This is
  only their common input and ownership protocol.

Delete dead conveniences exposed by the landing—such as unused count or
initial-stack adapters—rather than preserving a second vocabulary for the same
handoff.

## Simplification 4: give seed materialization one state machine

The landing correctly shares the element-copying algorithm in `advanceSeeds`,
but `ConstructionDriver` and `ChildSeedDriver` still each own a seed list and a
parallel progress counter. Extract one nominal bounded seed materializer that
owns:

- the retained seed list;
- the next index;
- its consuming/finished state.

Its one advance operation appends at most the granted construction quantum in
list order. It must reserve capacity for the slice before adding any member, so
allocation failure adds no partial member from that slice. An earlier prefix is
ordinary stack ownership and is released by boundary or Unit teardown.

Use that same materializer as:

- the final phase of in-machine `@attempt`, `@module`, and `@defm`
  construction; and
- the first work installed in child Units for `@spawn` and `@each`.

The surrounding drivers may remain distinct because they own different
lifecycle transitions. They should embed or own the same materializer rather
than restating its fields and completion test.

Preserve these ordering facts:

- a boundary opens before its seeds are placed, but its body cannot execute
  until materialization completes because the work driver is serviced first;
- a child Unit receives the `@each` element immediately and deepest, then the
  materializer appends plan seeds above it before code runs;
- creating many `@each` children never copies the whole shared seed list in the
  parent's spawn slice.

Do not combine this with `StackWindow` or combinator contract state merely
because those mechanisms also use the word “seeded.”

## Simplification 5: retire the former `with` metadata path

The formatter now recognizes nominal `seed`, but
`moduleRegistrationInfo` still treats `with` as if it carried constructor
metadata and `precedingSeedList` still preserves the old phrase's navigation
shape.

Remove that compatibility inference. Formatter recognition of a seeded module
registration must be based on the explicit sequence:

```text
values-list body seed 'name @defm
```

A bare `body 'name @defm` remains recognized. A phrase using `with` remains
valid ECL and formats as ordinary composition followed by a constructor; it no
longer earns nominal seed metadata or special navigation solely from that
shape.

Delete `precedingSeedList` if it has no independent formatter purpose. Remove
comments, fixtures, snapshots, or guidance that describe `with` as constructor
seeding metadata. Do not remove or specialize `with`, `partial`, `literal`,
`cat`, `compose`, `cons`, `append`, `raze`, slicing, reversal, or generic
list construction.

## Simplification 6: narrow names and surfaces to the final concepts

After the preceding changes, remove only mechanisms made unreachable by them.
In particular:

- make the archive's raw construction namespace accessor private if its only
  remaining use is inside archive-owned readers/builders;
- remove duplicate admission helpers after exact-root preparation is the sole
  semantic gate;
- remove obsolete raw input release helpers and duplicate seed progress fields;
- remove stale comments that call every provenance lookup “admission” or imply
  that a runtime-built root can be recovered by inspecting descendants;
- retain `SpanArchiveOwner`/`SpanArchive` backing separation,
  `requireOpaqueWorkerFacade`, owner-only blocking reads, and owner-only
  registration/teardown;
- retain absorption cursors, diagnostic location/source cursors, exact-header
  indexing, scalar identity transactions, and retirement recycling wherever
  they still serve their own contracts.

Do not broaden a worker facade for convenience. If a new synchronous wrapper is
needed only by bootstrap or a blocking Session turn, put it on the host owner;
execution keeps the bounded cursor surface.

## Patch sequence

Keep every patch buildable and behavior-preserving. Use this order unless the
landed representation makes two adjacent steps inseparable:

1. Split descendant source projection from semantic admission inside the
   existing re-scope cursor. Preserve the current external preparation API and
   all publication states while doing so.
2. Introduce the root-bound, pre-scope preparation state; move image `ScopeId`
   minting into its admitted branch and delete eager attribution-only minting.
3. Keep decoded unit input under one consuming owner through boundary, child,
   and fan-out handoff; delete the raw duplicate teardown path.
4. Extract the shared bounded seed-materializer state and embed it in the two
   lifecycle-specific drivers.
5. Remove `with`-specific formatter metadata recognition and update its public
   formatter fixtures/snapshots.
6. Delete newly dead helpers and narrow archive/machine surfaces. Update
   `design/INTERPRETER.md`, the active gameplan, and the workstream to describe
   the final representations and proof boundaries.

Do not mix a semantic repair discovered during this work into a cleanup patch.
If the landed behavior is wrong or incomplete, stop, repair unit-plan against
`design/unit-plan.md`, establish a new passing baseline, and resume from it.

## Verification

Tests must observe public runtime or formatter behavior. They must not inspect
implementation source, private indexes, identities, fields, helper names, or
call patterns. Static architecture belongs in types, `comptime` validation, and
the exhaustive source audit where the compiler cannot express it.

Retain the landed unit-plan suite and add only coverage that distinguishes the
simplified paths:

1. Literal bodies still re-scope through quotations, lists, and dicts.
2. Runtime-built roots remain unchanged even when every child is reader-built.
3. A rejected root containing a very large reader-built fragment completes
   without traversing that fragment for attribution.
4. Nested construction remains re-entrant for raw and seeded inner bodies.
5. A stamped copy keeps exact error locations and is admitted again, while an
   ordinary reconstruction of it is not.
6. Cross-archive preparation rejects the exact foreign header.
7. Raw quotations and empty-seed plans behave identically in all five
   constructors.
8. Multiple seeds preserve order; `@each` keeps its element deepest; child
   seeding yields and cancellation can interrupt it.
9. Allocation failure and abandonment at every decoded-input transfer,
   re-scope frame, identity publication, and seed-materializer phase leak
   neither values nor identity capacity.
10. Repeated unadmitted anonymous and registered images define, execute,
    publish, reload, and retire with warmed residual memory bounded independently
    of construction count, proving that no attribution-only `ScopeId` cell is
    minted for each image.
11. Formatter navigation recognizes raw and nominally seeded `@defm` phrases;
    the former `with` spelling formats as ordinary code.
12. Repeated re-scope-and-release remains bounded by peak live copies, not
    construction history.

Use the existing real concurrency cases for peer progress during large
re-scopes/seeding and cancellation of a sibling mid-seed. Do not replace them
with a model. If a patch changes when child tasks become reachable, how long a
driver lives, or when archive-owned memory retires, run the Docker-only
Linux/x86_64 TSan gate for that specific reason, following `AGENTS.md`.

Choose allocation-failure coverage deliberately. Component-level failure
probes belong beside the owning decoder, cursor, transaction, or materializer.
Add the smallest initialized-Session snippet to `src/tests/oom_test.zig` only
for a path unavailable without a live Session.

After each patch, run the local tier with standard input closed and capture the
status of that command itself:

```sh
timeout 500 zig build precommit < /dev/null > run.log 2>&1; code=$?
```

Inspect `code` before inspecting `run.log`. Do not run the complete CI matrix
locally. Prove every new runtime test is selected by temporarily breaking its
assertion, observing the intended tier fail, and restoring it.

## Architectural enforcement

The final representation must establish, without source-substring tests, that:

- generic core installation cannot express the privileged `seed` binding;
- only the root-derived seal can construct a unit plan and ordinary handlers
  cannot obtain it;
- all five constructors decode through the same input boundary;
- an unadmitted root has no operation that traverses descendants for
  attribution;
- an admitted rewrite is bound to one exact source/archive and cannot attest a
  caller-supplied destination;
- descendant projection cannot become a second semantic admission gate;
- the re-scope state machine handles `pending`, `published`, and `refused`
  exhaustively;
- the seed materializer has one owner and one progress state across both uses;
- worker archive state cannot recover host registration, blocking cleanup, or
  teardown authority;
- all new tagged ownership and preparation states are switched exhaustively.

Use opaque or closed capabilities and consuming tagged transitions first. Use
the exhaustive production source audit only for a property Zig cannot express,
and make it fail closed over every classified production file. Do not add a
source-name or call-site count for a boundary the type system can close.

Update `design/INTERPRETER.md` in the patch that changes each structural
invariant. Update `design/workstream-v1.md` and the active gameplan when their
implementation or proof claims move. Change `design/SPEC.md` only if the
simplification exposes stale language text; implementation detail does not
belong there.

## Completion criteria

This follow-up is complete only when all of the following are simultaneously
true:

- The archive makes one semantic admission decision for the exact body root.
- The admitted traversal has no descendant semantic admission or unchanged
  fallback; descendant provenance access, if retained, is projection only.
- The rejected-root branch performs no attribution copy, descendant traversal,
  or attribution-only `ScopeId` allocation.
- A re-scoped copy remains lineage-bearing and nested construction remains
  re-entrant.
- Tri-state alias publication, one-attempt identity acquisition, bounded
  finalization, and live-proportional recycling remain intact.
- Every constructor enters through `popUnitInput`, and decoded body/seed
  ownership has one destructor and explicit consuming handoffs.
- In-machine and child seeding use one bounded materializer state machine.
- No constructor synthesizes or executes a quotation to implement plan seeds.
- Formatter metadata assigns no special seeding meaning to `with`.
- Public composition words retain their general homoiconic behavior.
- The owner/view split and privileged seed-binding boundary remain enforced by
  types in every build mode.
- `zig build precommit` passes, required targeted behavior passes, and every
  reason-triggered specialized gate passes.
- `design/INTERPRETER.md`, the active gameplan, and the workstream describe the
  final seams and their enforcement accurately.
