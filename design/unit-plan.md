# Unit plans and explicit unit seeding

Status: implementation revised to the settled authority, archive-ownership,
checked-registration, and bounded-claim invariants. The language rule is
settled. One clause was corrected during implementation and re-ruled: see
Reader-text lineage.

## Purpose

A unit constructor must know which quotation is its body before it can apply
module-text attribution. Flattening seed captures and a body into one quotation
destroys that distinction: `with` and arbitrary runtime composition can produce
the same value, while the language requires them to have different attribution.

This feature keeps seeds and body structurally separate until the unit boundary.
It adds a first-class nominal `unit-plan` value constructed by `seed`. Ordinary
quotations, `partial`, `with`, and all generic list composition retain their
existing meanings.

## Surface

### `seed`

```ecl
values body seed
```

`seed` has effect:

```text
( values quotation -- unit-plan )
```

`values` must be a list and `quotation` must be a list usable as code. `seed`
consumes both inputs and returns an immutable opaque unit plan owning the exact
two values separately. It does not execute, stamp, copy, parse, or otherwise
transform either input.

`type` reports `'unit-plan` for a plan. A plan cannot be read from source,
serialized as ECL data, called, concatenated, indexed, or mistaken for a list.
It remains an ordinary first-class value for stack movement, `dup`, `pop`,
storage, selection, and passage between words.

### `unseed`

```ecl
plan unseed
```

`unseed` has effect:

```text
( unit-plan -- values quotation )
```

It consumes one plan reference and returns the exact seeds and body held by
that plan. This is the metaprogramming escape hatch: a program may unpack a
plan, transform either ordinary value, and seal the result into another plan.

### Unit constructors

The input accepted by a unit constructor is the tagged sum:

```text
UnitInput = unseeded quotation | unit-plan
```

A raw quotation means an empty seed list. This preserves concise unseeded
construction and the existing spellings:

```ecl
(q) @attempt
(q) @spawn
(body) @module
(body) 'name @defm
```

A plan supplies explicit seeds:

```ecl
values (q) seed @attempt
values (q) seed @spawn
list values (q) seed @each
values (body) seed @module
values (body) seed 'name @defm
```

For `@each`, the iterated element remains deepest in each child stack, below
the plan's shared seeds. `@defm` remains exactly construction followed by
registration; its name remains above the raw quotation or plan.

Every constructor consumes its `UnitInput`. A failed constructor owns and
releases everything it consumed on every failure path.

## Execution

For a raw quotation, a constructor uses an empty seed list and that quotation
as the body. For a plan, it uses the plan's stored fields.

The new Unit's operand stack is initialized from the seed list in list order,
then the body is executed. Seeds are values, not code contributed to the body:
even when a seed is itself a reader-built quotation, none of its contents is
part of the construction body's text.

`@attempt`, `@spawn`, and `@each` otherwise retain their existing scope,
contract, cancellation, and result rules. A plan is a shared input protocol;
it is not itself a Unit and `seed` is not a unit constructor.

## Module-text attribution

Two independent facts determine attribution:

1. The `UnitInput` identifies the exact body value, separately from its seeds.
2. The reader archive decides whether that exact body header carries
   reader-text lineage.

The second fact is *admission*, and it is the archive's own: nothing about it
is expressible as a value a caller can carry.

### Reader-text lineage

The governing rule (ruled 2026-08-26):

> Reader-text lineage survives only the interpreter's scope-only construction
> rewrite. A later constructor may re-stamp that exact rewritten body to its own
> image. Ordinary runtime reconstruction loses the lineage.

Lineage is not the same thing as being an original header. There are exactly two
mints: absorbing a reader result, and the construction rewrite attesting the copy
it just produced.

The rule is forced. A nested `@module` or `@defm` inside a construction body is
handed *the outer rewrite's copy* of its own body, because the rewrite copies.
Deny lineage to that copy and the inner construction's words name the enclosing
image — `(1 'x setp ( -- n ) ((2 'x setp ( -- n ) (x) 'get def) 'm @defm x)
'probe def …)` reads `1` where the language requires `2` — and the retention
soak that bounds per-reload memory fails as well.

Lineage cannot be handed out, only inherited, and no proof of it is a value that
crosses an API. A portable proof would say only that the reader wrote *some*
body, nothing about a destination header a caller chose, and it could be replayed
against a second archive. So the archive owns admission and its application
together. Preparation consumes the exact owned body before any image scope is
minted and returns either the unchanged owner or an opaque admitted root bound
to that source and archive. Consuming the admitted root with the target scope
starts the archive's bounded cursor; that cursor builds its own destination,
and the span-and-lineage commit is private to it. The cursor remains in one
movable owner until construction-driver installation consumes it, including
the allocation-failure path. A generic
reconstruction — `cat`, `compose`, `cons`, `append`, `raze`, slicing, reversal,
`with` — never enters the rewrite, so it has no lineage, and neither has a value
another Session's archive read.

Lineage storage is proportional to live re-scoped headers, not to identities ever
issued. A rewritten body's directory slot is cleared and its identity recycled
after its final reference retires, through an O(1), allocation-free notification
on the reclamation domain the archive shares. Recycling is ABA-safe by
construction: an identity becomes reusable only after no live owner can present
its former header, and admission additionally requires the exact header recorded
in the directory slot.

The notification is owned by the host-side archive owner, not by the archive
facade used during execution. One reclamation root can bind one archive owner;
binding produces an issuance-naming registration held only by that owner. A
second binding is unavailable or rejected in every build mode, and a copied or
stale receipt cannot detach a later issuance. Detachment occurs only after
execution has quiesced, so it cannot race a retirement callback.

Identity assignment is a scalar transaction. The directory page for one
candidate exists before the candidate is claimed. A transaction then either
publishes that identity to one exact header or returns it on abandonment. It
does not expose an identity and a separate `commit` operation that callers must
keep correlated. A racing loser returns `pending` after one attempt and retries
on a later scheduler slice; it never spins inside one nominal step. Repeated
failed construction or absorption therefore consumes neither identity capacity
nor an unbounded scheduler turn.

When `@module` or `@defm` consumes a body:

- If the exact root header is admitted by the current archive, every word
  occurrence in the complete reader-built subtree rooted there is copied with
  the new image's `ScopeId`. Traversal includes nested quotations, list
  literals, and dict literals.
- If the root is not admitted, no word is re-scoped and re-scoping does not
  descend into the value. Lineage carried by nested fragments does not grant
  admission through a runtime-built root.
- Seeds are never traversed or re-scoped.
- The re-scoped body is a new copy carrying the same reader-text lineage, so a
  construction nested inside it re-scopes its own body against its own image.
  Nothing outside that rewrite can obtain lineage.

Thus the construction predicate is exact:

```text
reader built this occurrence inside the designated body
```

Archive-wide membership, source-range coincidence, child identity, and the
operation history of a runtime list are not substitutes for lineage.

All word resolution after attribution is unchanged: a word resolves in the
scope carried by that occurrence.

## Ordinary quotation composition

`partial` and `with` remain ordinary quotation-producing words with their
existing normative ECL definitions. `cat`, `compose`, `cons`, `append`,
`raze`, slicing, reversal, and every other generic reconstruction produce
ordinary runtime-built values and never acquire reader-text lineage.

The former seeded-constructor idiom is therefore replaced:

```ecl
# Former, information-losing spelling
values (body) with @module

# Nominal spelling
values (body) seed @module
```

The old spelling remains a valid application of `with` followed by a unit
constructor, but its flattened quotation is runtime-built. In accordance with
the general attribution rule, `@module` and `@defm` leave all of its existing
word scopes unchanged. Documentation and first-party source must use `seed`
when seeds and a construction body are intended.

## Required examples

A caller-authored behavior is a seed and keeps the caller's scope:

```ecl
10 'k set
[(k *)] ('scale def ( -- n ) (4 scale) 'go def) seed 'm @defm
m.go
# 40
```

A reader-built literal body names its image through every nested container:

```ecl
((99) 'k defp {'a (k)} 'd setp ( -- n ) (d 'a at call) 'go def) 'm @defm
m.go
# 99
```

A runtime-built body is not turned back into module text merely because its
children came from the reader:

```ecl
7 'k set
((k) 'geta) (def) cat 'm @defm
m.geta
# 7
```

Seeding the same runtime-built body changes only its initial stack, not its
attribution:

```ecl
7 'k set
[] ((k) 'geta) (def) cat seed 'm @defm
m.geta
# 7
```

## Representation and authority

`unit-plan` is a new nominal heap kind with private backing state, and both of
its slots are typed as lists, so a plan holding anything else is unrepresentable
rather than asserted against.

Only `seed` may mint one, and the raw constructor is private: the public heap
surface exposes no allocator-plus-headers factory. The cross-module operation is
an opaque `UnitPlanSeal` issued by one `HostOwner`. Its `seal` method derives the
allocator and reclamation root from that owner and accepts only the two typed
list handles already established by `Machine.popList` and
`Machine.popQuotation`. Allocation failure leaves both stack owners intact;
success transfers both references into the plan before the result is committed
to the stack.

The seal is deliberately narrower than the former handler-level mint. `Env`
derives it from the same `HostOwner` that constructs the core and uses it only
for canonical seed-binding installation; no primitive installer or primitive
handler receives it. The runtime binding has a dedicated
`seed: *const UnitPlanSeal` variant, and Machine dispatches that variant to its
private seed implementation. The full `Binding` union is never accepted by a
public generic installer. Public installation surfaces are separated by kind:
ordinary core quotation, ordinary builtin handler, and `installSeed`. The last
takes the name as a `comptime` parameter, accepts only `seed`, and records its
one-time state in the target core rather than in the copyable builder. Core
finalization requires that state to be installed. Every generic surface first
constructs a private validated `OrdinaryCoreName` that rejects `seed`: runtime
quotation installation returns `PrivilegedCoreName`, while compile-time builtin
installation fails compilation. Consequently neither another name nor another
handler can acquire or replace seed behavior.

The compiler boundary is the opaque seal plus the closed installation surface.
A source audit may verify reachability the compiler genuinely cannot express,
but factory-name or call-site counting is not an authority boundary. Untrusted
ECL and native callers can neither construct a plan, retarget one, nor obtain its
backing state.

Plan contents inherit the existing Session invariant that every heap value on a
Session stack belongs to that Session's reclamation root. The seal makes the
plan header's allocator/root correlation structural; it does not pretend that
an untagged `Value` proves the allocation origin of an imported list. If that
repository-wide invariant is later made structural, it requires domain-tagged
heap headers or an opaque Session-owned host value at the public push boundary,
not a unit-plan-specific wrapper.

### Host ownership and the execution facade

`SessionCore` remains the aggregate owner; extracting a separate
`ConstructionRoot` is not a prerequisite. Ownership has this shape:

```text
SessionCore
|- HostOwner
|- SpanArchiveOwner -- registration and teardown only
|  `- SpanArchiveView -- reader, admission, and re-scoping only
|- Env
|- Registry
`- Scheduler
```

`SpanArchiveOwner.init` takes `*HostOwner` directly. No operation converts
`HostCleanup`, a release domain, or a worker facade back into `HostOwner`.
Its backing is physically split: `SpanArchiveOwnerState` contains the owner,
receipt, and a pointer to a separately allocated runtime, while
`SpanArchiveState` contains only the release domain and lineage/index runtime.
`SpanArchiveOwner` points to the former; the `SpanArchive` worker view points
directly to the latter, which is not recoverably embedded in the owner state.
`SpanArchiveOwner` alone stores the retirement registration, performs blocking
synchronous reads, and exposes `deinit`; Units and scheduler work receive only
the worker view. The view may advance bounded reads, absorb, locate, prepare an
exact root, and re-scope, but it cannot recover host ownership, register,
detach, drain, or destroy the archive. `requireOpaqueWorkerFacade` enforces
that backing shape.

The retirement registration itself is one tagged state, not a nullable callback
correlated with a separate counter:

```text
CodeRetirementSlot = vacant(last issuance)
                   | attached(issuance, callback)
```

Attachment computes a checked nonzero `u64` successor before publishing the
callback. Detachment consumes a receipt only when it names the attached
issuance, then returns the slot to `vacant(issuance)`. Exhaustion is refused
before mutation. Session preserves its established teardown order: scheduler
quiescence precedes archive-owner detachment and destruction.

Reader-text lineage is distinct from span identity. The archive must expose only
these semantic operations to the machine:

- decide admission for an exact owned body, returning a root-bound consuming
  operation rather than a portable result;
- require descendant source projections for diagnostics after admission;
- re-scope an admitted body, producing the copy itself and attesting only that
  copy.

No operation takes a proof of lineage together with a caller-chosen destination
header — no proof crosses the API at all — so lineage cannot be granted to a
value the archive did not build. Generic heap builders have no
lineage-assignment authority. This is enforced by opaque capability types, not
by naming, assertions, or a source denylist.

Exact-root rejection returns the owned body unchanged and performs no
descendant lookup or attribution traversal. Exact-root admission is the only
semantic decision. During the admitted traversal, nested reader containers use
required diagnostic projection; a missing projection is `InvalidProvenance`,
never a fallback that shares a descendant unchanged.

Lineage storage must settle proportional to live re-scoped headers rather than
to identities ever issued. A rewritten body's directory slot is cleared and its
identity recycled after final-reference retirement through the archive owner's
unique registration. Both absorption and re-scoping use the same private
`IdentityTransaction`; the transaction owns rollback and performs publication
itself, so callers cannot forget to correlate a raw identity with a later
commit. Alias publication reports `published` or `refused`; the enclosing
cursor separately represents claim loss as `pending`, and refusal propagates as
`InvalidProvenance`. No success result can leave the header unindexed.

## Bounded work and ownership

Inspecting a plan and obtaining its two stored handles is O(1). Both user-sized
halves of opening a unit — putting a plan's seeds on the stack they seed, and
re-scoping a reader body — run through bounded cursors as ordinary resumable
scheduler work. No nominal scheduler step may recursively walk the complete
body, copy a whole seed list, or multiply either by the number of children a
fan-out starts per turn.

`Machine.popUnitInput` returns one nominal non-struct owner and is the only
quotation/plan decoder. Its raw-quotation representation carries only the body
pointer and allocates nothing; its seeded representation owns both pointers.
Child launch borrows it, fan-out moves it, and boundary construction consumes
its halves into later typed owners. There is no public raw body/seeds tuple or
second destructor. One `SeedMaterializer` owns the retained seed list and next
index in both construction and child drivers, reserving each slice before its
first append.

Module construction prepares the body before requesting an image `ScopeId`.
Only the admitted branch mints one and begins re-scoping. The unchanged branch
executes the original body in its existing scopes and retains no
attribution-only cell or anchor.

One caller-issued work budget is shared by the complete re-scoping traversal,
including nested containers and dictionary-index copying. Every frame owns its
destination builder from its first written element, its initialized length is
the exact prefix it owns, and publishing a completed list or dictionary is O(1).
Re-scoping changes only word scope, which is excluded from word equality and
hashing, so a rewritten dictionary may share the source's immutable hash list;
any optional index copy remains budgeted. Abandonment releases precisely the
initialized prefixes and any partial index.

Identity acquisition is bounded as part of that same rule. One attempt may
choose a candidate, prepare its fixed directory page, and try to claim it. If a
concurrent publication wins, the attempt returns `pending`; it does not retry in
a local loop. A completed re-scope frame retains its finished header in an
explicit `ready_to_publish` stage across such a yield. Absorption likewise
retains its current span entry until the transaction publishes or determines
that the exact header was indexed already.

The plan's two owned values are released through the Session's release domain.
There is no session-lifetime side table entry for a plan, so live plan memory is
bounded by simultaneously live plans rather than the number ever created.
Plans cannot outlive the Session reclamation domain that issued their heap
storage.

## Errors and reflection

- `seed` reports the ordinary type error unless given a values list followed by
  a quotation.
- `unseed` reports the ordinary type error for anything but a unit plan.
- A constructor reports its existing quotation type error when its input is
  neither a quotation nor a unit plan.
- Failures raised while executing the body retain the body's source location
  when one exists. Seed values retain their own source and scope behavior.
- `type` reports `'unit-plan`; reflective word listings document `seed` and
  `unseed`. A plan exposes no synthetic word body or module environment.

## Acceptance

Public behavioral coverage must prove:

1. Raw literal bodies stamp top-level words and words nested through
   quotations, lists, and dicts.
2. Every seed remains unchanged, including reader-built quotations and dicts.
3. The `cat` reproduction above returns `7`.
4. Other runtime body reconstruction, including `compose` and `raze`, does not
   acquire attribution.
5. Wrapping a runtime-built body in a plan does not acquire attribution.
6. A raw reader body and the same body in a plan stamp identically.
7. `unseed` returns the exact values and body, and unpack-transform-reseed
   behaves according to whether the transformed body still carries lineage.
8. One reader body may be duplicated and used for two images; each image gets
   an independent re-scoped copy while the original remains reusable.
9. A generic reconstruction cannot acquire lineage however its parts were
   built, and a construction nested inside a re-scoped body still re-scopes its
   own body against its own image.
10. One archive never admits another archive's text, asked directly.
11. Allocation failure at plan creation, unpacking, Unit initialization, and
    body re-scoping leaks neither owned memory nor identity capacity and obeys
    the consuming ownership contract.
12. Empty seeds, an empty body, and large seed/body inputs preserve ordering,
    bounded scheduling, cancellation, and constructor postconditions.
13. Repeated re-scope-and-release cycles settle to memory bounded by peak live
    copies rather than total copies, and a disabled retirement/recycling path
    makes that property fail.
14. `seed` rejects either incorrectly typed input without projecting an
    unchecked union tag, allocation failure leaves both inputs owned by the
    Machine, and success transfers both references exactly once.
15. A generic core installer cannot express the seed binding, another spelling
    cannot acquire seed behavior, and the target core admits exactly one
    canonical seed installation even through copied builders.
16. Worker-facing archive code cannot obtain host ownership, registration, or
    teardown authority; a second registration is refused and a stale receipt
    cannot detach a later issuance.
17. A concurrent identity-claim loser yields after one attempt, while failure or
    abandonment during absorption and re-scoping returns every uncommitted
    identity.

Static enforcement must prove that reader absorption and the construction
rewrite are the only mints of reader-text lineage, that no operation attests a
caller-chosen header, that only `seed` can mint a plan, that generic
construction cannot acquire lineage, and that all consumers handle the new value
and input variants exhaustively. It must additionally prove that the privileged
seed binding is unique in the target core, the full binding union cannot cross a
generic installation boundary, general primitive handlers cannot obtain the
seal, worker archive facades cannot obtain host ownership, and one archive owner
exclusively owns the reclamation root's code-retirement registration. The source
audit is secondary enforcement for constraints the type graph cannot express;
it must not substitute identifier counting for any of these boundaries.

## Architectural implementation order

1. Close the binding installation surface and introduce the root-derived opaque
   `UnitPlanSeal` used only by the dedicated seed binding.
2. Make the raw unit-plan constructor private and remove factory call-site
   counting as an authority claim.
3. Split `SpanArchiveOwner` from `SpanArchiveView`; make initialization consume
   host-side access directly and remove every cleanup-to-owner upgrade.
4. Give identity acquisition a one-attempt result and make the private
   transaction perform publication rather than exposing `identity` plus
   `commit`.
5. Replace the retirement callback/counter pair with the tagged, checked
   issuance state.
6. Reconcile `design/INTERPRETER.md`, the workstream, and the post-landing
   simplification plan only after these representations have landed.

## Documentation changes required with implementation

Implementation of this feature must update `design/SPEC.md`,
`design/INTERPRETER.md`, `design/workstream-v1.md`, the active gameplan, the
primitive reference, and every first-party seeded-constructor example. The old
claim that unit constructors are seeded by composing `with` must be replaced by
the nominal unit-plan protocol.
