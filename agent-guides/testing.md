# Testing and Verification

Read this guide for every source or test change. The short rules in
[`AGENTS.md`](../AGENTS.md) always apply as well.

## Behavioral test boundaries

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
  part that needs no stream—the mode gate, the claim, the error kind.
- A golden transcript asserts behavior, not the coordinates behavior happens to
  carry. `test/reference_snapshots.zig` records errors raised inside
  `src/prelude.ecl`, whose `'data` reports a prelude line number; pinning that
  number makes every unrelated prelude edit fail the snapshot while proving
  nothing about the edit. Those positions use `ohsnap`'s embedded-regex form
  (`'line <^\d+$>`)—the anchors are required and the snapshot still fails if
  the field goes missing or non-numeric. Keep the kind, message, word, trace,
  and source file literal; regex only the coordinate.

## Running commands safely

- Run every build, test, or script invocation with standard input closed
  (`< /dev/null`) and under a `timeout` shorter than whatever will give up on it
  first. Closing stdin turns an accidental blocking read into immediate EOF, and
  a timeout that fires later than its supervisor reports nothing about why the
  run died.
- **Read the exit code of the run you care about, not the one the shell happened
  to finish with.** Give that run its own invocation and capture its status
  immediately: `timeout 500 zig build test < /dev/null > run.log 2>&1; code=$?`.
  Appending a `tail`, `head`, or `grep`—or piping into one—replaces the
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

## Test tiers

There are exactly three test tiers, and only the first one is the ordinary local
tier.

- **Local: `zig build precommit`.** Roughly 80 seconds after a source change.
  It lints (when `zlint` is on PATH), checks Zig formatting and the checked-in
  ECL source conventions (`check-ecl`: canonical formatting, and a standard
  module's terminal form is `@defm`), runs the architecture audit, builds the
  binary, semantically analyzes *every* test root with codegen suppressed, and
  then executes the fast core of the suite (`zig build test-precommit` alone).
  Run it before every commit and after every patch in a stack. Iterate faster
  still with `zig build` plus real behavior against `./zig-out/bin/ecl`, and
  `zig build check` when all you need is “does the tree still compile.”
- **CI: `.github/workflows/ci.yml`.** Pull requests run the Debug precommit
  tier and one complete ReleaseSafe suite, with the public formatter, native
  SDK rejection, PTY, and standalone native acceptance surfaces. Pushes to
  master and manual runs add the full Debug suite, bounded fuzz campaigns,
  eight-worker concurrency, differential, TSan, and ReleaseFast snapshots.
  Each optimization mode owns one long-lived job so its later tiers reuse its
  Zig cache and emitted artifacts. Do not run this locally. `zig build test`
  alone is a five-minute round trip after a one-line change, and re-running
  the matrix by hand replaces CI's evidence with a slower copy of it.
  Use the authenticated GitHub CLI to list, inspect, and manage workflow runs;
  do not scrape the Actions website or guess run URLs. Start with
  `gh run list --workflow ci.yml --limit <n>` and inspect a selected run with
  `gh run view <run-id> --log-failed`.
- **Release candidate: `.github/workflows/release-candidate.yml`.** A manual
  exhaustive superset of the pull-request and post-merge matrices, plus the
  initialized-Session OOM sweeps and complete ReleaseFast suite, run once
  against a candidate commit. Core, standard-library, package, and host OOM
  families use independent runners and wall-clock budgets, and the dominant
  package-sync operation partitions its allocation ordinals across four more
  runners. The unified local entry point remains `zig build test-oom`. It is
  the single workflow that exercises every test surface.

Run a single CI gate locally only when you have a specific reason to expect
that gate to fail—a scheduler lifetime change wants `test-tsan`, a new
allocation site in an initialized Session wants `test-oom`. Reach for the
reason first, not the matrix.

- The precommit tier's fast-core filter list lives in `build.zig` beside its
  measured justification. A test that costs more than about a second belongs
  outside it; when you add one, either keep it in an already-excluded family or
  say in the filter comment why the budget grew. Analysis is separate from
  execution on purpose: excluding a test from the fast core must never exclude
  it from compiling.
- Reviewers do not rerun the test suites: running the gates is the implementer's
  job, and a reviewer's rerun measures the shared working tree—a moving target
  during patch execution—rather than the change under review. Review by reading
  the diff and by executing targeted inputs against `./zig-out/bin/ecl` to test
  suspected findings empirically; verify a finding reproduces before reporting
  it. The testing *layer* is in scope for review like any other code: whether the
  new tests assert the ruled contracts, whether coverage reaches the edges the
  policy names, and whether a passing suite would actually catch the regression
  in question.
- Never report a performance observation from a Debug binary: the default
  `zig build` output runs the DebugAllocator, whose per-allocation machinery can
  be hundreds of times slower on allocation-heavy paths and can fabricate a
  convincing per-operation “defect” with clean-looking scaling curves. Rebuild
  with `-Doptimize=ReleaseSafe` before timing anything.

## Allocators, OOM, and ownership in tests

- Keep focused allocator failure sweeps in the normal suite. Consolidate exhaustive
  initialized-Session coverage in `src/tests/oom_test.zig`, run together by
  `zig build test-oom`. `zig build test-oom-core` and `zig build test-oom-surfaces`
  are the independently schedulable subsets; `-Doom-filter=<substring>` narrows
  the latter to one named surface family. Split logical module and host surfaces
  so unrelated snippets never become prefixes of one another's ordinal replay,
  but do not bootstrap a Session independently for every word in one module.
- Choose a test's allocator deliberately; `src/tests/test_heap.zig` is the policy and the
  table of what each one provides. The choice decides which assertions are even possible,
  and the wrong choice does not fail—it passes, having tested less:
  - **Allocation failure is injected only by `checkAllAllocationFailures` probes.** Every
    ordinary test runs each allocation once and it succeeds. Component-level probes sit
    next to their component (`list.zig`, `dict.zig`, `env.zig`, `equal.zig`, and the
    reader, formatter, line-editor, registry, and native-validation probes); none of them
    bootstraps a Session. `oom_test` is the only sweep over a *fully initialized* Session,
    so any surface reachable only through a live one—words, prelude, modules, scheduler,
    reflection, loader—has no allocation-failure coverage unless a snippet in that
    enumerated probe reaches it, however well the behavioral suites cover it.
  - **An `oom_test` snippet must be the smallest program that reaches its paths.** The
    sweep replays a snippet once per allocation point, so its cost is quadratic in how
    much the snippet allocates and every snippet pays into one shared wall clock. Reach a
    path with 2 elements, not 40: volume adds no new allocation sites. Note the gate's
    own baseline is over ten minutes regardless—background it with a generous timeout,
    and do not read a timeout as evidence about any one snippet.
  - **Bounded-memory claims need `DebugAllocator{.enable_memory_limit}`**, the only
    allocator populating `total_requested_bytes`. Assert a measured delta against a warmed
    baseline, never a fixed number, and set `requested_memory_limit` to force failure at a
    budget. Do not move these tests onto a shared session heap: it makes the assertion
    unwriteable rather than wrong.
  - **Leak detection is universal; leak attribution is not.** Every test allocator detects
    leaks. Only `std.testing.allocator` reports the allocation site, at about 19x on session
    bootstrap because it traces every allocation. Default to the traceless session heap and
    raise `stack_trace_frames` when you actually have a leak to chase—one edit restores
    attribution everywhere, and the leak is never in the suite you predicted.
- A session must own every value it will free, and no compiler checks it. Building a heap
  value with one allocator and handing it to a session backed by another (`define`,
  `pushOwned`, `publishTop`, `publishModule`) aborts with “Invalid free” deep inside
  `heap.freePayload`, far from the line at fault. Suites that pass only source strings to a
  session may use the shared session heap; suites that mix host-built values in stay on
  `std.testing.allocator`, where value and session already agree.

## TSan

- **`test-tsan` is the only gate that finds scheduler lifetime bugs**, so run it for any
  change that alters *when* modules load, *when* tasks park, or how long scheduler objects
  live—not only for edits to `scheduler.zig`. A real use-after-free in
  `WaitSet.advanceSetup` sat green under `zig build test`, `test-workers` at 1 and 8, and
  `test-oom`; it fired only once a module auto-load inside racing children widened the
  window. When TSan does crash, isolate with a counterfactual run—remove the suspected
  trigger with the fix still absent—before claiming a cause.
- **Run Zig 0.16's bundled Linux TSan against glibc, not Alpine/musl.** On
  GitHub-hosted runners the musl binary leaves multiple TSan libc interceptors
  unresolved and crashes before an ECL test body executes. Confirming
  backtraces reach address zero from `___interceptor_sigaltstack`,
  `___interceptor_sigemptyset`, `___interceptor_dl_iterate_phdr`, and
  `___interceptor_sched_getaffinity`. CI therefore runs only the TSan gate in a
  dedicated Ubuntu container; do not weaken the test runner by disabling each
  intercepted feature. ASLR and Docker seccomp counterfactuals also left the
  hosted crash unchanged.
- **Never run `zig build test-tsan` directly on macOS. It is Docker-only, without
  exception.** Zig 0.16's native arm64 macOS sanitizer runtime segfaults *before `main`*:
  `libclang_rt.tsan_osx_dynamic.dylib` faults in `__tsan::InitializePlatform` →
  `get_dyld_hdr` → `dyld_shared_cache_iterate_text_swift` with `EXC_BAD_ACCESS`, during
  dyld's initializer phase. Confirmed on Darwin 25.6.0, 2026-08-25.

  This produces a uniquely misleading failure, so treat any native-macOS TSan result as
  **no information at all**, never as evidence: the tier exits 139 with no output, every
  `--test-filter` fails identically, and the exit code is independent of what the working
  tree contains. Two false conclusions were drawn from it in one session—“the pin-only
  variant SEGVs, so the tier discriminates” and “the real implementation SEGVs, so patch 5
  regressed”—before anyone checked. The 30-second refutation, worth running before
  interpreting *any* TSan crash: pass a filter that matches no test. If it still SEGVs, the
  binary is dying in startup and no test is involved.

  Run it in the same Linux/x86_64 glibc environment used by CI; the Linux/arm64 runtime
  may in turn fail while unmapping shadow memory under Docker Desktop. Keep the checkout
  read-only and caches container-local. Copy the checkout to a writable directory inside
  the container rather than building in the read-only mount: suites that call
  `std.testing.tmpDir` create their directory under the working directory, so a read-only
  `-w /work` aborts them with `ReadOnlyFileSystem` before any race can be observed.

  ```sh
  timeout 25m docker run --rm --platform linux/amd64 \
    -v "$PWD":/work:ro ubuntu:24.04 bash -euxo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends ca-certificates curl libc6-dev xz-utils
      curl -fsSLo /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
      echo "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00  /tmp/zig.tar.xz" | sha256sum -c -
      mkdir -p /tmp/zig
      tar -C /tmp/zig --strip-components=1 -xf /tmp/zig.tar.xz
      mkdir -p /build && cp -a /work/. /build/ && cd /build
      timeout 20m /tmp/zig/zig build --cache-dir /tmp/ecl-cache \
        --global-cache-dir /tmp/ecl-global test-tsan < /dev/null
    '
  ```

## Specialized proof surfaces

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
- Keep gameplan proof traceability exact while executing an active gameplan: every
  `testMap` row names exactly one existing test in its declared file and exactly one
  introducing and implementing patch entry. Reject duplicate, stale, missing, or
  mismatched ledger entries. A gameplan is a planning input, not a repository artifact
  that implementation must add or maintain.
- Exercise every operation of an opaque public capability through its real factory,
  registration, or runtime path so Zig analyzes lazily reached method bodies. A type
  declaration compiling without any caller is not proof that its public surface works.
- Keep line-editor coverage claims aligned with the seam actually exercised. Fuzz the
  production edit buffer and viewport projection, and query Session completion before
  the first Unit. Use the real Debug and ReleaseSafe artifacts under a PTY for redraw,
  raw-mode queue preservation, EOF/error handling, history, and terminal restoration;
  an in-process model cannot prove compiler-codegen or kernel termios behavior.
