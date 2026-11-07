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
  Include an effect whenever the successful stack effect is expressible: when
  a word consumes or leaves a variable number of values, put one `...` in that
  row where they sit, keeping every value whose position is known named. Use a
  documentation-only annotation only when no effect is expressible, and state
  the shape in the docstring. State the contract of an isolated quotation
  argument as that slot's nested effect, not in the docstring.
- Treat the annotation—not the navigation comment—as the documentation
  authority. `doc`, `which`, and `see` reflect it, and `design/STDLIB.md`
  renders the word's entry from it.
- A definition must follow every prelude word its body uses, because the
  prelude is evaluated one definition at a time against the core built so
  far. No further block order is enforced; `design/STDLIB.md` computes its
  entry order from dependency ranks.
- Enforce block structure in the dedicated source audit, whose scanner must
  ignore apparent headers and definition syntax inside multiline strings.
  Whitespace layout belongs to the formatter and its CI check.
