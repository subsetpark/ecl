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
- Keep focused allocator failure sweeps in the normal suite. Consolidate exhaustive
  initialized-Session coverage in `src/tests/oom_test.zig`, run by `zig build test-oom`, so
  the embedded prelude is not bootstrapped independently for every runtime surface.

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

- Prefer nominal IDs, opaque handles, validated factories, capability values,
  typestate transitions, and tagged unions over correlated raw fields, booleans,
  debug assertions, naming conventions, or comments.
- Make invalid ownership, publication metadata, environment phase, stack-window,
  and continuation-mode states unrepresentable where Zig permits it. Use `comptime`
  validation for static registries and exhaustive switches for state machines.
- Route every user-sized traversal through `WorkContext` cursors or bounded chunks.
  Use exact-size materialization for known results and fixed chunks plus one polled
  materialization pass for unknown results; do not introduce relocating or rehashing
  storage into cancellable paths.
- Enforce the remaining source-level boundaries with AST-aware build tooling over
  every classified production file. Behavioral tests remain public-interface tests.
- Raise a component or representation ceiling when a strong type boundary honestly
  needs the space. Never weaken or compress away the type boundary merely to satisfy
  a historical line-count or frame-size limit; update and explain the ceiling.

## Line budgets

- Apply component and total line ceilings only to shipped business-logic Zig.
- Exclude test-only sources, inline `test` declarations, fixtures, build/source-audit
  verification tooling, and all target-language ECL from every line ceiling.
- Keep excluded Zig exactly classified and report it separately, but do not cap it.
  Do not move shipped behavior into an excluded file to evade a business-logic budget.
