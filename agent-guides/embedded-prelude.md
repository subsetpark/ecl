# Embedded Prelude

Read this guide before changing `src/prelude.ecl` or the source audit that
validates its layout. The short rules in [`AGENTS.md`](../AGENTS.md) always
apply as well.

- Write every `src/prelude.ecl` definition as a readable block beginning with
  the exact navigation comment `### def <name>`.
- Make `<name>` match the definition's terminal quoted name. Ordinary
  explanatory comments attached to a definition belong immediately after its
  navigation header and before the body quotation; the header begins the
  complete definition block.
- Give every prelude definition a meaningful, nonempty annotation docstring.
  Include an effect when the successful stack effect is fixed and expressible;
  when only the before row is fixed, declare it with a `...` after row. Use a
  documentation-only annotation only when the before row is not fixed, and
  state the shape in the docstring.
- Treat the annotation—not the navigation comment—as the documentation
  authority. `doc`, `which`, and `see` reflect it, and `design/STDLIB.md`
  renders the word's entry from it.
- Order definition blocks by dependency depth, then by codepoint name: a
  definition follows every prelude word its body uses, and definitions at the
  same depth sort as `cmp` sorts their names. Mutually recursive definitions
  cannot follow one another, so each such group shares one depth and its
  members sort by name. `zig build check-stdlib`, part
  of `precommit`, refuses a prelude out of this order.
- Enforce block structure in the dedicated source audit, whose scanner must
  ignore apparent headers and definition syntax inside multiline strings.
  Whitespace layout belongs to the formatter and its CI check.
