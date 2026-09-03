# Agent Guidelines

This file contains the evergreen rules for every change. Detailed guidance is
split by subject; read each linked guide whose scope intersects the task before
editing or running its specialized gates. The linked guides are required
normative guidance.

## Detailed guidance

- [Testing and verification](agent-guides/testing.md): tests, allocators, local
  and CI tiers, performance measurements, OOM coverage, TSan, PTY coverage, and
  proof traceability. Read for every source or test change.
- [Engineering boundaries](agent-guides/engineering.md): where cross-cutting
  rules belong, type-system versus audit enforcement, opaque Zig APIs,
  self-aliasing storage, terminal facts, and C ABI declarations. Read when
  designing or reviewing an implementation boundary.
- [Embedded prelude](agent-guides/embedded-prelude.md): required block layout,
  navigation comments, annotations, and audit behavior. Read before changing
  `src/prelude.ecl` or its scanner.
- [Runtime architecture](agent-guides/runtime-architecture.md): structural
  invariants, ownership and capabilities, bounded work and scheduling,
  publication and reclamation, and architectural enforcement. Read before any
  change touching those concerns.

When several subjects apply, read all relevant guides. Keep detailed procedures
in those guides rather than expanding this index with incident-specific history.

## Core rules

- Test externally observable behavior through runtime or public interfaces. Do
  not inspect implementation source text in a behavioral test, add test-only
  representation accessors, or use an implementation as its own oracle.
- Enforce a repository rule in the type system first, then the source audit for
  what types cannot express. Runtime tests prove behavior through public
  interfaces; source audits prove source shape.
- Prefer nominal IDs, opaque handles, validated factories, capabilities,
  typestate, tagged unions, `comptime` validation, and exhaustive switches.
  Make invalid ownership, phase, publication, and continuation states
  unrepresentable where Zig permits it.
- Give consuming APIs an explicit ownership contract on success and failure.
  A Session must own every value it will free; never correlate an allocator,
  reclamation domain, or authority with raw independent fields.
- Route user-sized traversal, cleanup, and unwind through bounded resumable work.
  Do not hide an unbounded walk or destruction behind one scheduler step.
- Put each cross-cutting invariant at the boundary that owns it. Do not repeat a
  policy across callers or preserve a weak seam with assertions, naming rules,
  special cases, or audit exceptions.
- This application is still in its design phase. When a defect exposes a weak
  ownership, lifetime, publication, scheduling, or authority seam, revise the
  representation and document the invariant in `design/INTERPRETER.md`.
- Design documents keep one altitude each. `design/SPEC.md` states observable
  contracts, `design/STDLIB.md` states what a program observes of a word
  (shapes, limits, failures), and `design/INTERPRETER.md` states invariants and
  the representation that carries them. Write a change at the level of the
  surrounding section; do not transcribe every mechanism, name, or status code.
  Implementation narrative belongs in code comments.
- Run every build, test, or script with stdin closed and under a bounded timeout.
  Capture the command's exit status immediately, before `tail`, `grep`, or any
  other helper. A silent command is not evidence that the intended test ran.
- The local source-change gate is `zig build precommit`. Use `zig build check`
  and targeted public behavior for iteration; do not run the full CI matrix
  locally without a specific gate-related reason.
- Never report performance from a Debug binary. Use at least ReleaseSafe and
  record the target, optimization mode, workload, and repeated measurements.
- Never run `zig build test-tsan` natively on macOS. The Zig 0.16 arm64 macOS
  sanitizer runtime crashes before `main`; use the Docker procedure in the
  testing guide.
