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
