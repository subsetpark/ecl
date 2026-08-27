# Prompt: source-ingestion review and typestate remediation

You are working in `/Users/zax/code-src/ecl`. Read and obey the repository's
`AGENTS.md` instructions before acting. Preserve the existing unstaged source-ingestion
work; do not discard or overwrite unrelated changes.

## Objective

Finish the source-ingestion OOM fix and remove the related family of invalidly
representable phase records. Preserve externally observable behavior while replacing
correlated phase enums, booleans, and mutually exclusive optional payloads with tagged
unions whose variants own exactly the data valid in that phase.

Treat this as an architectural remediation, not a field-reordering exercise. Where the
scope is too large for one safe patch, prepare and execute a dependency-ordered patch
series. Keep every intermediate patch compiling and behaviorally coherent.

Use these existing implementations as the primary patterns:

- `machine.ResolutionCursor.Work` for one active phase cursor plus persistent context;
- `modules.Registry.RegistrationCursor.State` for a publication protocol whose variants
  own phase-specific leases, builders, and candidates;
- `machine.NativeContinuation` and `scheduler_core.Wait` for exhaustive lifecycle and
  arbitration states.

## Required findings to address

### 1. Preserve complete source provenance in Session parse errors

The new Session ingestion path reports parse locations through
`EclErr.setLocation`. That method stores at most 384 source-name bytes, whereas the old
`Session.runUnit` path passed a `spans.LocatedSpan` directly to error materialization and
preserved the complete `source_name`.

Fix this without restoring a second parsing/absorption pipeline. A direct
`Session.runUnit` call with a source name longer than 384 bytes must produce an error dict
whose `'source` field exactly equals the supplied name. Preserve the allocation and
ownership rules of scheduled source loading, including owned module paths that may be
retired while an error is materialized.

Add an externally observable regression test through `Session.runUnit`; do not test
implementation text or expose a private buffer.

### 2. Make `SpanArchive.SourceIngestCursor` a tagged ownership state

Replace the current record of `reader_state`, `parsed`, `materializer`, `root`,
`root_header`, `absorber`, `incomplete`, `parsed_retirement`, `phase`, and
`retirement_phase` with an ownership-bearing tagged representation.

The representation must make these rules structural:

- before archive adoption, the cursor owns the materialized root and releases it on
  abandonment;
- after adoption, the archive owns the root and cursor teardown cannot release it;
- reader and parsed retirement can resume from every partially completed phase;
- complete and incomplete outcomes cannot coexist;
- active advancement and abandonment cannot silently drive independent phase tags out of
  sync;
- every successful transition consumes the prior variant and constructs the next one.

Retain one source-ingestion pipeline for synchronous prelude installation and scheduled
runtime/Session ingestion.

### 3. Convert the highest-risk correlated state records

Audit surrounding call sites and convert the following records to tagged state. Keep
persistent context outside the union and place only phase-specific ownership inside it.

#### Evaluator terminal state

- `machine.Unit`: `pending`, `last_error`, `source_incomplete`, and `exit_status` are
  mutually exclusive evaluator outcomes. Replace them with an exhaustive terminal/error
  state. Preserve the distinction between an error being unwound and a materialized root
  error, and update all producers, consumers, scheduler teardown, and Session outcome
  extraction.

#### Wait setup and delivery

- `scheduler.WaitSet`: close the outer lifecycle around setup `request`/`cancel_cursor`,
  delivery `delivery_reason`/`park_result`, discard, and completion. Do not duplicate the
  winner already carried by `scheduler_core.Wait` unless an owned materialization phase
  genuinely requires it.

This is production scheduler lifetime work. Exercise the real scheduler path, and run the
Docker-only Linux/x86_64 `test-tsan` gate exactly as prescribed by `AGENTS.md`; never run
TSan natively on macOS.

#### Registry lookup, mutation, and loading

- `modules.Registry.RemovalCursor`
- `modules.Registry.AliasCursor`
- `modules.Registry.AcquireCursor`
- `modules.Registry.BeginLoadingCursor`

Model lookup cursors, directory leases, cloned maps, maintenance work, reservations,
barrier ownership, transfer, and completion in variants. Follow
`RegistrationCursor.State`; publication variants must own exactly the metadata valid at
that point, and retries must consume the prior state rather than nulling a field list.

#### Module and native loading

- `machine.AutoLoadDriver`
- `machine.NativeLoadDriver`
- `machine.ModuleCompletionDriver`
- `native_module.LoadCursor`
- `native_descriptor.ValidateCursor`

Represent validation, document/effect construction, candidate creation, registration,
commit, and completed ownership as variants. Pay attention to driver size: `AutoLoadDriver`
is on a common resolution path, so measure its size before and after and add an explained
representation ceiling if one is needed.

#### Transactional filesystem publication

- `stdlib/archive.UnpackDriver`
- `stdlib/pkg_store.WriteLockDriver`

Encode provisional resources, created staging state, committed publication, rollback, and
cleanup as explicit states. A failed operation must have one unambiguous owner for every
file, path, entry, value, and cleanup cursor. Do not preserve `created`/`committed` as
side-band booleans once the variant can express them.

### 4. Convert the remaining clear phase-work records

Apply the same rule to these lower-risk but still invalidly representable records. Small
related records may share a patch, but do not combine unrelated subsystems merely to
reduce patch count.

#### Reader and lowering

- `binder.LowerCursor`
- `reader_cursor.StringBuilder`
- `reader_cursor.CollectionBuilder`
- `reader_cursor.ReadCursor`

#### Definition and reflection

- `definition_prims.DefineDriver`
- `definition_prims.WhichDriver`
- `definition_prims.SeeDriver`
- `module_prims.WordsDriver`
- `reflection.ActionPlan`

#### Error construction and unwind

- `machine.OrdinaryErrorCursor`
- `machine.RaisedErrorCursor`
- `machine.FailureDriver`

#### Other resumable I/O

- `machine.FileSourceDriver`
- `machine.StandardInputDriver`
- `stdlib/http.RequestDriver`
- `stdlib/pkg_store.VerifyDriver`
- `stdlib/pkg_store.GcDriver`

#### Mechanical materialization

- `native_descriptor.DocumentBuild`
- `native_descriptor.EffectBuild`
- `kernel_dict_text.FormatDriver`
- `kernel_order.GradeDriver`
- `native_call.ListBuild`
- `native_call.DictBuild`

#### Construction

- `machine.ConstructionDriver`

For each record, first verify which payloads are truly mutually exclusive. Do not move
independently valid or intentionally simultaneous data into artificial variants. In
particular, do not convert these solely because they contain optionals:

- binding metadata whose effect, documentation, compiled quotation, and source may
  independently coexist;
- `kernel_order.GroupDriver` arrays allocated together for the same operation;
- `machine.TaskJoinTeardown` inputs that may all be owned simultaneously and are merely
  released in bounded order;
- intrusive-list links, optional caches, and observational metadata where absence is a
  genuine independent value.

## Representation requirements

- Prefer `union(enum)` state payloads over a phase enum plus nullable fields.
- Give each owning variant a `deinit`/retirement operation that is exhaustive over the
  union.
- Make transitions consume or move ownership; do not copy an owning variant and then
  clear its old fields piecemeal.
- Keep resumable retirement bounded. A final reference may enqueue work but may not hide
  a user-sized traversal in one scheduler step.
- Keep synchronous bootstrap and scheduled execution on the same production cursor.
- Do not add test-only accessors for private phase state.
- Use `comptime` size/shape validation where a static representation ceiling matters.
- Update `design/INTERPRETER.md`, the applicable workstream, and the source-ingestion
  gameplan when a structural invariant or proof claim changes.

## Verification

Test behavior through public/runtime interfaces. At minimum cover:

- complete source ingestion, incomplete source, and parse failure;
- OOM at every allocation point before and after archive adoption;
- cancellation during reader, materialization, absorption, parsed retirement, and before
  activation;
- exact long source-name provenance in Session parse errors;
- stack rollback and definition persistence across Session failures;
- prelude installation and module source/native loading;
- registry alias, acquisition, loading, registration, and removal retry/abandonment;
- wait activation, pre-activation selection, cancellation, timeout, task completion,
  discard, and delayed cleanup;
- filesystem staging success, collision, partial failure, rollback, and cleanup;
- public operation of every opaque capability so Zig analyzes lazily reached methods.

Follow the repository test policy exactly:

1. Iterate with `zig build`, targeted behavior against `./zig-out/bin/ecl`, and
   `zig build check` as appropriate.
2. Run `zig build precommit` after every patch, with stdin closed and an explicit timeout;
   capture and inspect the command's own exit status before displaying its log.
3. Do not run `zig build test` or reproduce the CI matrix locally.
4. Run a focused gate only when the change gives a specific reason. The WaitSet and
   scheduler-lifetime work requires Docker `test-tsan`; allocation changes reachable from
   an initialized Session require the existing release-candidate `test-oom` sweep only at
   the candidate stage unless a smaller component probe is appropriate.
5. Prove each newly added test can fail before trusting its passing result.

## Completion criteria

The work is complete only when:

- the full source-name regression is fixed without reintroducing dual ingestion paths;
- every listed record has either been converted or has a documented, code-specific reason
  why its optional fields are independently valid rather than mutually exclusive;
- all ownership transitions and abandonment paths are exhaustive in all build modes;
- design documentation matches the implemented invariants;
- the required local and focused gates pass with correctly captured exit codes; and
- the final report lists conversions, justified exclusions, behavioral evidence, and any
  CI-only residual risk.
