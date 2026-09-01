# Engineering Boundaries

Read this guide when designing or reviewing an implementation boundary. The
short rules in [`AGENTS.md`](../AGENTS.md) always apply as well.

- Put each cross-cutting rule at its owning boundary so callers do not repeat it.
  Escaping belongs to the sink that writes to the terminal, lexical state to
  the tokenizer that parses source, and the cursor/scalar invariant to the
  single splice that changes bytes. A policy attached to one producer will be
  missing from the next one, and a postcondition restated in ten operations
  will be forgotten by one of them.
- Enforce a repository rule in the type system, then the audit, then nowhere. A
  source denylist naming one forbidden identifier is the weakest form: pass a
  capability whose surface lacks the operation instead. Reserve audit checks
  for what the compiler cannot see, and make them fail closed—parse strictly
  into a typed value first, because a check that skips fields it cannot read
  reports success on exactly the inputs it failed to inspect.
- A `pub` struct with a private field type is not encapsulated: Zig's inferred
  struct literals let external code construct it field by field. Use an opaque
  handle when a representation must only come from its factory.
- A container that hands out a slice of its storage and also grows that storage
  must own every mutation argument before it writes; a caller passing a borrow
  back in is legitimate. Put that staging in one shared storage type rather
  than in each container, and fuzz the self-aliasing case: this defect appeared
  independently in two containers before the primitive existed.
- Prefer letting the terminal report its own state over modelling it. Character
  width is data no in-process property can validate, so keep it out of any path
  where being wrong breaks correctness rather than appearance.
- Declare every `extern "c"` function with the same variadic shape as its C
  prototype. A non-variadic declaration of a variadic function such as `ioctl`
  passes arguments in registers the callee never reads on AArch64, silently
  corrupting unrelated memory; prefer the existing `std.c` declaration over a
  local `extern` block.
