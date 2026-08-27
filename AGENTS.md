# Agent Guidelines

## Tests

- Test externally observable program behavior through runtime or public interfaces.
- Never write a unit or integration test that reads or embeds another implementation
  source file merely to assert that particular substrings, symbols, imports, data
  structures, or call patterns are present or absent.
- Enforce source-level architecture and style constraints with the compiler, a linter,
  or dedicated build tooling—not by treating implementation text as test behavior.
- Inspect text in a test only when that text is itself a documented program input or
  output, such as parser input, formatter output, or a generated artifact contract.
- Do not add test-only accessors that expose a private table, dispatch choice, layout,
  field, or other representation merely so a test can inspect it. Enforce static
  completeness, size, and layout rules with production `comptime` validation or the
  source audit; keep runtime tests about observable results and errors.
- Never let a test read an ambient resource: standard input, a tty, the network,
  or the wall clock. An in-process test that reads real stdin blocks forever on
  whatever pipe the runner inherited, and the suite looks slow rather than hung.
  Prove a capability that genuinely needs a real stream against the built binary
  through an explicit pipe in `test/e2e.zig`, and keep the in-process test on the
  part that needs no stream — the mode gate, the claim, the error kind.
- Run every build, test, or script invocation with standard input closed
  (`< /dev/null`) and under a `timeout` shorter than whatever will give up on it
  first. Closing stdin turns an accidental blocking read into immediate EOF, and
  a timeout that fires later than its supervisor reports nothing about why the
  run died.
- **Read the exit code of the run you care about, not the one the shell happened
  to finish with.** Give that run its own invocation and capture its status
  immediately: `timeout 500 zig build test < /dev/null > run.log 2>&1; code=$?`.
  Appending a `tail`, `head`, or `grep` — or piping into one — replaces the
  status with the helper's. `grep` is the worst of them, because it exits 1 when
  it matches nothing: a clean run then reads as a failure, and a filtered summary
  of a *timed-out* run reads as success. Both have happened here. A `zig build
  test` that gave up at 900 seconds was recorded as passing because the
  invocation ended in `tail`, and the real `test_exit=124` sat unread; the wrong
  reading nearly retired a correct diagnosis of a hang.
- **A silent run is not a passing run.** The captured test runner prints nothing
  when everything passes, so an empty log is evidence about output and none at
  all about what executed. The fast-core tier selects by name prefix, so a new
  test file that nobody added to the filter list passes by never running, and the
  source audit will not notice either until the file is in its manifest. Prove a
  new test can fail before trusting it to pass: break its assertion on purpose,
  watch the tier report the failure, then put it back.
- **There are exactly three test tiers, and only the first one is yours.**
  - **Local: `zig build precommit`.** Roughly 80 seconds after a source change.
    It lints (when `zlint` is on PATH), checks Zig formatting and the
    checked-in ECL source conventions (`check-ecl`: canonical formatting, and a
    standard module's terminal form is `@defm`), runs the architecture audit,
    builds the binary, semantically analyzes *every* test root with codegen
    suppressed, and then executes the fast core of the suite
    (`zig build test-precommit` alone).
    Run it before every commit and after every patch in a stack. Iterate faster
    still with `zig build` plus real behavior against `./zig-out/bin/ecl`, and
    `zig build check` when all you need is "does the tree still compile".
  - **CI: `.github/workflows/ci.yml`.** Pull requests run the Debug precommit
    tier and one complete ReleaseSafe suite, with the public formatter, native
    SDK rejection, PTY, and standalone native acceptance surfaces. Pushes to
    master and manual runs add the full Debug suite, bounded fuzz campaigns,
    eight-worker concurrency, differential, TSan, and ReleaseFast snapshots.
    Each optimization mode owns one long-lived job so its later tiers reuse its
    Zig cache and emitted artifacts. Do not run this locally. `zig build test`
    alone is a five-minute round trip after a one-line change, and re-running
    the matrix by hand replaces CI's evidence with a slower copy of it.
    Use the authenticated GitHub CLI to list, inspect, and manage workflow
    runs; do not scrape the Actions website or guess run URLs. Start with
    `gh run list --workflow ci.yml --limit <n>` and inspect a selected run with
    `gh run view <run-id> --log-failed`.
  - **Release candidate.** The exhaustive initialized-Session `zig build
    test-oom` sweep and the complete ReleaseFast suite, run once against a
    candidate commit.
  Run a single CI gate locally only when you have a specific reason to expect
  *that* gate to fail — a scheduler lifetime change wants `test-tsan`, a new
  allocation site in an initialized Session wants `test-oom`. Reach for the
  reason first, not the matrix.
- The precommit tier's fast-core filter list lives in `build.zig` beside its
  measured justification. A test that costs more than about a second belongs
  outside it; when you add one, either keep it in an already-excluded family or
  say in the filter comment why the budget grew. Analysis is separate from
  execution on purpose: excluding a test from the fast core must never exclude
  it from compiling.
- Reviewers do not rerun the test suites: running the gates is the implementer's
  job, and a reviewer's rerun measures the shared working tree — a moving target
  during patch execution — rather than the change under review. Review by reading
  the diff and by executing targeted inputs against `./zig-out/bin/ecl` to test
  suspected findings empirically; verify a finding reproduces before reporting
  it. The testing *layer* is in scope for review like any other code: whether the
  new tests assert the ruled contracts, whether coverage reaches the edges the
  policy names, and whether a passing suite would actually catch the regression
  in question. Never report a performance observation from a Debug binary: the
  default `zig build` output runs the DebugAllocator, whose per-allocation
  machinery can be hundreds of times slower on allocation-heavy paths and can
  fabricate a convincing per-operation "defect" with clean-looking scaling
  curves. Rebuild with `-Doptimize=ReleaseSafe` before timing anything.
- Keep focused allocator failure sweeps in the normal suite. Consolidate exhaustive
  initialized-Session coverage in `src/tests/oom_test.zig`, run by `zig build test-oom`, so
  the embedded prelude is not bootstrapped independently for every runtime surface.
- Choose a test's allocator deliberately; `src/tests/test_heap.zig` is the policy and the
  table of what each one provides. The choice decides which assertions are even possible,
  and the wrong choice does not fail — it passes, having tested less:
  - **Allocation failure is injected only by `checkAllAllocationFailures` probes.** Every
    ordinary test runs each allocation once and it succeeds. Component-level probes sit
    next to their component (`list.zig`, `dict.zig`, `env.zig`, `equal.zig`, and the
    reader, formatter, line-editor, registry, and native-validation probes); none of them
    bootstraps a Session. `oom_test` is the only sweep over a *fully initialized* Session,
    so any surface reachable only through a live one — words, prelude, modules, scheduler,
    reflection, loader — has no allocation-failure coverage unless a snippet in that
    enumerated probe reaches it, however well the behavioral suites cover it.
  - **An `oom_test` snippet must be the smallest program that reaches its paths.** The
    sweep replays a snippet once per allocation point, so its cost is quadratic in how
    much the snippet allocates and every snippet pays into one shared wall clock. Reach a
    path with 2 elements, not 40: volume adds no new allocation sites. Note the gate's
    own baseline is over ten minutes regardless — background it with a generous timeout,
    and do not read a timeout as evidence about any one snippet.
  - **Bounded-memory claims need `DebugAllocator{.enable_memory_limit}`**, the only
    allocator populating `total_requested_bytes`. Assert a measured delta against a warmed
    baseline, never a fixed number, and set `requested_memory_limit` to force failure at a
    budget. Do not move these tests onto a shared session heap: it makes the assertion
    unwriteable rather than wrong.
  - **Leak detection is universal; leak attribution is not.** Every test allocator detects
    leaks. Only `std.testing.allocator` reports the allocation site, at ~19x on session
    bootstrap because it traces every allocation. Default to the traceless session heap and
    raise `stack_trace_frames` when you actually have a leak to chase — one edit restores
    attribution everywhere, and the leak is never in the suite you predicted.
- A session must own every value it will free, and no compiler checks it. Building a heap
  value with one allocator and handing it to a session backed by another (`define`,
  `pushOwned`, `publishTop`, `publishModule`) aborts with "Invalid free" deep inside
  `heap.freePayload`, far from the line at fault. Suites that pass only source strings to a
  session may use the shared session heap; suites that mix host-built values in stay on
  `std.testing.allocator`, where value and session already agree.
- **`test-tsan` is the only gate that finds scheduler lifetime bugs**, so run it for any
  change that alters *when* modules load, *when* tasks park, or how long scheduler objects
  live — not only for edits to `scheduler.zig`. A real use-after-free in
  `WaitSet.advanceSetup` sat green under `zig build test`, `test-workers` at 1 and 8, and
  `test-oom`; it fired only once a module auto-load inside racing children widened the
  window. When TSan does crash, isolate with a counterfactual run — remove the suspected
  trigger with the fix still absent — before claiming a cause.
- **Never run `zig build test-tsan` directly on macOS. It is Docker-only, without
  exception.** Zig 0.16's native arm64 macOS sanitizer runtime segfaults *before `main`*:
  `libclang_rt.tsan_osx_dynamic.dylib` faults in `__tsan::InitializePlatform` →
  `get_dyld_hdr` → `dyld_shared_cache_iterate_text_swift` with `EXC_BAD_ACCESS`, during
  dyld's initializer phase. Confirmed on Darwin 25.6.0, 2026-08-25.

  This produces a uniquely misleading failure, so treat any native-macOS TSan result as
  **no information at all**, never as evidence: the tier exits 139 with no output, every
  `--test-filter` fails identically, and the exit code is independent of what the working
  tree contains. Two false conclusions were drawn from it in one session — "the pin-only
  variant SEGVs, so the tier discriminates" and "the real implementation SEGVs, so patch 5
  regressed" — before anyone checked. The 30-second refutation, worth running before
  interpreting *any* TSan crash: pass a filter that matches no test. If it still SEGVs, the
  binary is dying in startup and no test is involved.

  Run it in the same Linux/x86_64 Alpine environment used by CI; the Linux/arm64 runtime
  may in turn fail while unmapping shadow memory under Docker Desktop. Keep the checkout
  read-only and caches container-local:

  Copy the checkout to a writable directory inside the container rather than
  building in the read-only mount: suites that call `std.testing.tmpDir` create
  their directory under the working directory, so a read-only `-w /work` aborts
  them with `ReadOnlyFileSystem` before any race can be observed.

  ```sh
  docker run --rm --platform linux/amd64 \
    -v "$PWD":/work:ro alpine:latest sh -euxc '
      apk add --no-cache curl xz linux-headers
      curl -fsSLo /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
      echo "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00  /tmp/zig.tar.xz" | sha256sum -c -
      mkdir -p /tmp/zig
      tar -C /tmp/zig --strip-components=1 -xf /tmp/zig.tar.xz
      mkdir -p /build && cp -a /work/. /build/ && cd /build
      /tmp/zig/zig build --cache-dir /tmp/ecl-cache --global-cache-dir /tmp/ecl-global test-tsan
    '
  ```
- Treat a model-only property as specification evidence, not proof of the production
  implementation. Concurrency and reclamation acceptance must exercise the real
  publisher, leases/cursors, mutation path, and retirement domain through public or
  production-connected interfaces.
- For snapshot reclamation, run real readers that repeatedly acquire, resolve through,
  and release production leases while real writers publish and the same domain reclaims.
  Assert stable observable values and, after delayed readers release and retirement
  settles, memory bounded independently of update count. Run that path under TSan and
  retain a counting-allocator delayed-reader property covering Shape and Directory
  histories, alias churn, and distinct-module publication.
- Keep gameplan proof traceability exact: every `testMap` row names exactly one existing
  test in its declared file and exactly one introducing and implementing patch entry.
  Reject duplicate, stale, missing, or mismatched ledger entries.
- Exercise every operation of an opaque public capability through its real factory,
  registration, or runtime path so Zig analyzes lazily reached method bodies. A type
  declaration compiling without any caller is not proof that its public surface works.
- Keep line-editor coverage claims aligned with the seam actually exercised. Fuzz the
  production edit buffer and viewport projection, and query Session completion before
  the first Unit. Use the real Debug and ReleaseSafe artifacts under a PTY for redraw,
  raw-mode queue preservation, EOF/error handling, history, and terminal restoration;
  an in-process model cannot prove compiler-codegen or kernel termios behavior.
- Put a cross-cutting rule at the boundary that owns it, not in each caller. Escaping
  belongs to the sink that writes to the terminal, lexical state to the tokenizer that
  parses source, and the cursor/scalar invariant to the single splice that changes
  bytes. A policy attached to one producer will be missing from the next one, and a
  postcondition restated in ten operations will be forgotten by one of them.
- Enforce a repository rule in the type system, then the audit, then nowhere. A source
  denylist naming one forbidden identifier is the weakest form: pass a capability whose
  surface lacks the operation instead. Reserve audit checks for what the compiler cannot
  see, and make them fail closed — parse strictly into a typed value first, because a
  check that skips fields it cannot read reports success on exactly the inputs it
  failed to inspect.
- A `pub` struct with a private field type is not encapsulated: Zig's inferred struct
  literals let external code construct it field by field. Use an opaque handle when a
  representation must only come from its factory.
- A container that hands out a slice of its storage and also grows that storage must
  own every mutation argument before it writes; a caller passing a borrow back in is
  legitimate. Put that staging in one shared storage type rather than in each container,
  and fuzz the self-aliasing case: this defect appeared independently in two containers
  before the primitive existed.
- Prefer letting the terminal report its own state over modelling it. Character width is
  data no in-process property can validate, so keep it out of any path where being wrong
  breaks correctness rather than appearance.
- Declare every `extern "c"` function with the same variadic shape as its C prototype.
  A non-variadic declaration of a variadic function such as `ioctl` passes arguments
  in registers the callee never reads on AArch64, silently corrupting unrelated
  memory; prefer the existing `std.c` declaration over a local `extern` block.

## Embedded prelude

- Write every `src/prelude.ecl` definition as a readable block beginning with the
  exact navigation comment `### def <name>`.
- Make `<name>` match the definition's terminal quoted name. Ordinary explanatory
  comments attached to a definition belong immediately after its navigation header
  and before the body quotation; the header begins the complete definition block.
- Give every prelude definition a meaningful, nonempty annotation docstring. Include
  an effect when the successful stack effect is fixed and expressible; use a
  documentation-only annotation for quotation- or count-dependent effects.
- Treat the annotation docstring—not the navigation comment—as the reflective
  documentation authority.
- Enforce block layout only in the dedicated source audit, whose scanner must ignore
  apparent headers and definition syntax inside multiline strings.

## Structural invariants

- This application is still in its design phase. When a defect exposes a weak ownership,
  lifetime, publication, scheduling, or authority seam, revise the representation and
  architectural invariant rather than preserving the seam with a field reorder, extra
  assertion, naming convention, special-case drain, or source-audit exception.
- Prefer nominal IDs, opaque handles, validated factories, capability values,
  typestate transitions, and tagged unions over correlated raw fields, booleans,
  debug assertions, naming conventions, or comments.
- Make invalid ownership, publication metadata, environment phase, stack-window,
  and continuation-mode states unrepresentable where Zig permits it. Use `comptime`
  validation for static registries and exhaustive switches for state machines.
- Give consuming APIs an explicit ownership contract on both success and failure.
  Transfer ownership through moved/consumed capabilities or tagged results; never make
  a caller infer whether a failed append, publication, or transition retained or
  destroyed its input.
- Update the gameplan and `design/INTERPRETER.md` when introducing or revising a
  structural invariant. Acceptance must show that every producer and consumer uses the
  new seam and that invalid states are unavailable in all build modes.
- Raise a representation ceiling when a strong type boundary honestly needs the
  space. Never weaken or compress away the type boundary merely to satisfy a
  historical frame-size limit; update and explain the ceiling.

## Ownership, lifetime, and capabilities

- Define one lifetime protocol for provisional and published generations, Units, tasks,
  scopes, descendants, drivers, pins, leases, and cursors. Do not duplicate teardown
  ordering assumptions between owners or rely on a unique-refcount assertion to stand
  in for quiescence.
- Keep an embedded owner alive until every descendant has propagated its parent release.
  Encode `waiting-for-children`, scope teardown, environment teardown, pin release, and
  final destruction as one exhaustive typestate, releasing dependents before their
  lifetime guards.
- A pin, lease, cursor, handle, or callback-owned value that releases through a
  reclamation domain must not outlive that domain. Shutdown must first close new lifetime
  creation, then join/adopt outstanding owners, settle their retirement, and only then
  destroy the issuing domain.
- Separate observation, execution, and mutation into distinct nominal capabilities.
  Upgrading requires a distinct owner-issued authority and consumes the source
  capability. Observation APIs return metadata or pinned cursors, not raw homes,
  mutable scopes, ownership factories, or an implicit path to greater authority.
- Give Session-facing and registered-native callers only opaque semantic facades. Do not
  expose raw `Env`, `Registry`, Unit, module-home, reclamation-domain, wake-control,
  queue, or manual-advancement aliases when a narrower operation can express the
  contract. A lower-level API is valid only when its caller explicitly owns the
  corresponding lifetime and reclamation root.
- Private authority types may appear in signatures, but untrusted callers must be unable
  to construct or obtain their values or factories. Keep private runtime primitive
  bindings unreachable through public dictionaries, reflection, shadowing, and
  higher-order combinators; grant trusted builtins only the narrow operation they need.
- Each reclamation root mints or owns exactly one opaque host authority, and subordinate
  objects derive allocator and retirement-domain access from that owner. Bind mutation
  authority separately to its issuer. Use opaque/private backing state so neither
  authority can be forged, substituted, or retargeted after construction. Never accept
  a separately correlated allocator/domain/host tuple, and never rely on a debug
  assertion or audit alone to reject a mismatch in optimized builds.
- Scheduler-attached state may enqueue or advance bounded retirement only. Blocking
  destruction requires owner-derived host authority that worker-visible types cannot
  obtain; reaching the final reference never grants permission to traverse a user-sized
  graph synchronously.
- Make retirement settlement inseparable from public mutation authority. Every public
  mutation operation, blocking or resumable, settles or explicitly transfers its
  retirement work on every exit path, and opaque Session APIs must not expose lower-level
  mutable aliases that bypass that postcondition.
- Every cursor borrowing snapshot-owned storage owns the corresponding snapshot lease
  for its complete lifetime and, when that storage belongs to a generation, an
  independent generation pin. Releasing the originating lease must not invalidate an
  independent cursor.

## Bounded work and scheduling

- Route every user-sized traversal, cleanup, and terminal unwind through `WorkContext`
  cursors or bounded chunks. Use exact-size materialization for known results and fixed
  chunks plus one polled materialization pass for unknown results; do not introduce
  relocating or rehashing storage into cancellable paths.
- Treat reclamation and terminal cleanup as ordinary resumable scheduler work. A final
  reader, writer, reference, task, or generation may detach and enqueue work, but may not
  hide an unbounded traversal inside one nominal scheduler step.
- Cooperative and worker-pool executors use one arbitration policy for ready work,
  cancellation, wait delivery, teardown, and retirement. Bound consecutive service of
  every class so neither a continuously ready task nor a reclamation backlog can starve
  the other classes or make cancellation latency scale with a whole retired graph.
- Cold and idle Sessions must not strand retirement. Root completion and every public
  blocking turn must settle or transfer the backlog even before the worker pool starts
  and while a sole worker is busy.
- Treat task-tree registration, publication, and cancellation as one protocol. Publish
  stable task state before making a spawn reachable, register it atomically with its
  tree, prevent a cancelled ready task from dispatching, and keep cancellation
  allocation-free. Snapshot passes carry a mutation epoch and restart count/collection
  when the tree changes.
- Capture an absolute deadline before lazy timer startup and store deadline precedence
  in the wait-arbitration state. Completion, cancellation, timer insertion, and timer
  wake revalidate against that same deadline before committing a winner; already-expired
  or terminal waits must not start timer infrastructure unnecessarily.

## Publication and reclamation

- Represent task publication and other multi-phase handoffs as tagged states whose
  variants own exactly the metadata valid in that phase. Transitions consume one state
  and construct the next; do not coordinate publication with nullable fields and flags.
- Give every lock-free multi-field publication one documented happens-before protocol.
  Publish initialized payload/count metadata before reachable heads, and capture a
  generation/version before any dependent shape derived from it. Readers must announce
  and validate using the same ordering used by replacement and reclamation. Use
  sequential consistency when correctness depends on a single total order across
  independent reader/writer atomics; weakening it requires an explicit proof.
- Binding, Shape, Directory, module-generation, and analogous snapshot publishers use
  one explicit reader/writer handoff that prevents early reclamation under every final-
  reader/later-writer interleaving.
- Read terminal task state under the same lock or tagged publication transition that
  makes it terminal; never infer completion from independently nullable fields.
- Publication locks protect validation, state transition, and O(1) detachment only.
  After unlocking, enqueue typed bounded retirement; never allocate for, walk, destroy,
  or call into the shared retirement domain while holding a publication lock.
- After delayed leases drain and bounded retirement is serviced, residual retired memory
  must be bounded by current or peak simultaneously live state rather than total
  publication/reload history. Document any retention or backpressure bound while readers
  remain, recycle fixed retirement records where appropriate, and prove the residual
  bound with delayed readers and repeated public updates.

## Architectural enforcement

- Recursively enumerate every first-party Zig source and require exactly one production
  or verification classification. Derive all production audits from that exhaustive
  classification; never maintain a narrower hardcoded source subset that new files can
  evade.
- Enforce source-level boundaries primarily with types, opaque state, `comptime`, and
  exhaustive switching. Use AST-aware build tooling over every classified production
  file for constraints Zig cannot express; method-name lists, literal-loop detection,
  comments, debug assertions, and behavioral tests are not substitutes for a closed
  type or capability seam.
- Make the audit follow semantic ownership and blocking-destruction boundaries, including
  indirect helpers and every destructor spelling, rather than recognizing only selected
  names or direct loops.
- Treat source-audit output as the classification authority. Update
  `design/INTERPRETER.md`, the workstream, and the gameplan in the same change whenever
  classifications, reachability rules, or proof claims move.
