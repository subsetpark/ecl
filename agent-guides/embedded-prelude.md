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
  use a documentation-only annotation for quotation- or count-dependent
  effects.
- Treat the annotation docstring—not the navigation comment—as the reflective
  documentation authority.
- Enforce block layout only in the dedicated source audit, whose scanner must
  ignore apparent headers and definition syntax inside multiline strings.
