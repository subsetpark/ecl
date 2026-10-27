## source

### declarations
`( quotation -- list )` — Inspect parsed source without executing it. Return
the symbols immediately preceding top-level `@defm` words, in source order.
Preserve duplicate names and report literal spellings without validating
namespace or export policy. Ignore computed names and declarations inside
quotations, lists, dictionaries, strings, or comments. This reports syntactic
declarations, not proof that executing the source would register a module.
Like other quotation operations, this accepts a list (`'type` otherwise).
Use `parse` to inspect text, with its ordinary parse failures. Inspection is
cancellable.

```ecl
"[] () 'example @defm" parse source.declarations
# => ('example)
```
