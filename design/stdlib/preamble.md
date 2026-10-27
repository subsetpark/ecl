# ecl — core and standard library reference

Every public binding below ships in the core image or embedded standard
library, one entry per word. Prelude and core come first; standard-library
modules then appear by module name. Each section is layered by dependency: a
word defined in ecl appears after every word of its section that its definition
uses, directly or through private helpers, so builtins and leaf definitions
open the section and each later layer builds only on earlier ones. Mutually
recursive definitions share a layer. Within a layer, words are ordered by
codepoint — the language's own string ordering (`cmp`) — so symbol-spelled
words precede letter-spelled ones. An entry gives the word's successful stack
effect followed by its semantics. For a word defined in ecl, the entry is the
definition's own annotation, the same effect and documentation that `which`,
`see`, and `doc` reflect; words without a declared effect state their shape in
documentation.
At module boundaries, declared output contracts are checked when the invocation
completes, including any deferred work. The language rules behind those effects live in the
[`language specification`](SPEC.md); this document owns the exhaustive list of
what ships.
Conventions:

- Words marked **pervasive** follow
  [Pervasion and conformability](SPEC.md#pervasion-and-conformability).
- "Equivalent to `…`" names a word defined in ecl itself; the definition
  is normative and `see` renders it.
- Words applying quotations are marked *inline* or *unit constructor*
  (see [Application contexts](SPEC.md#application-contexts)); a unit constructor states the contract
  required of its quotation, enforced at each application.
- An effect ending in `...` declares a fixed before row and a variable
  after row (see [Definition annotations](SPEC.md#definition-annotations)) and is the word's real declared
  effect. A typographic `…` *inside* an effect is only an informal picture.
- Indexing is 0-based throughout: `range` counts from 0, `at` indexes
  from 0, `where` and `grade` produce 0-based indices, and `find` returns
  the length on a miss.
- Booleans are the ints 0 and 1; a word requiring a boolean rejects every
  other value.
- Predicate words end in `?`. Symbolic comparisons (`=`, `<>`, `<`, `<=`,
  `>`, `>=`) and the boolean combinators `and`, `or`, and `not` keep their
  conventional spellings.
- Example blocks are complete expressions unless their surrounding text says
  otherwise. A `# =>` comment shows the value or values left for the command
  printer; it is not part of the word's behavior.
