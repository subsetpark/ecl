# ecl — grammar

Companion to DESIGN.md; implements decisions 6, 8, 12, 15, 16, 17, 18.
The reader produces values (lists, atoms) with provenance; the only
parse-time transforms are the capped set: locals desugar and the dict
literal (decision 8).

## Source

- UTF-8, mandatory. Invalid UTF-8 is a parse error (`'parse`).
- Comments: `#` to end of line (outside strings). Shebang lines come free.
- Whitespace separates tokens: Unicode whitespace, plus **comma** —
  `,` is whitespace (Clojure rule), so pasted `[1, 2, 3]` just works.
- `;` is reserved: a parse error outside strings and comments. (Door
  kept open; currently means nothing.)
- `|` is a reserved delimiter character: legal only as the binder
  markers immediately after `(` or `[` (see Forms); anywhere else it is
  a parse error.
- Every token carries provenance (file, line, col), which flows into
  error dicts' `'trace` (decision 19).

## Tokens

Delimiters `( ) [ ] { }`, string literals, and *atoms*: maximal runs of
non-whitespace, non-delimiter, non-reserved characters, classified
**whole-token, in this order**:

1. **Number** — the entire token parses as a number, else it isn't one
   (so `2dup`, `1+` are words; `-3` is a number; `-` is a word).
   - int64: optional sign; decimal digits with optional `_` separators
     between digits (`1_000_000`); or `0x` + hex digits.
   - float64: `digits . digits`, optional exponent (`e`/`E`, optional
     sign); or `digits` + exponent. Digits required on both sides of
     `.` — `.5` and `5.` are not numbers (avoids colliding with
     qualified symbols). The tokens `inf`, `+inf`, `-inf` are float
     literals (whole-token, so the names leave the word namespace); NaN
     has no literal — it does not exist (DESIGN decision 22).
2. **Char** — `\` + one character (`\a`), a name (`\space`, `\tab`,
   `\newline`), or `\u{...}` hex codepoint. Clojure-style.
3. **Quoted symbol** — `'` + symbol. `'` is reserved token-initially and
   banned inside symbols.
4. **Word** — anything else: a symbol, evaluated by lookup.

**Symbols**: one or more segments joined by `.` — the dot is the module
qualification separator and nothing else (decision 18: `stats.mean`;
quotable: `'stats.mean`). Leading, trailing, or doubled dots are parse
errors. Segment characters: anything except whitespace, the six
delimiters, `"`, `#`, `'`, `\`, `.`, `,`, `;`, `|`. Unicode letters are
legal; words-not-glyphs is culture, not enforcement.

**Strings**: `"..."`, may span newlines. Escapes: `\\`, `\"`, `\n`,
`\t`, `\u{...}`. A string is a rank-1 char vector (decision 15).

## Forms

```
program  :=  form*
form     :=  list | dict | atom
list     :=  "(" binder? form* ")"  |  "[" binder? form* "]"
dict     :=  "{" form* "}"
binder   :=  "|" name+ "|"           # names: distinct unqualified symbols
```

- `( )` and `[ ]` both construct the same kind of value — a list of the
  (unevaluated) enclosed forms. Brackets quote; nothing inside runs at
  read time. The pair choice is free per pair; **pairs must match**:
  `[1 2 3)` is a parse error (decision 16).
- `{ body }` desugars at read time to the two forms `( body ) dict-of`
  (decision 17). `{}` is the empty dict.
- The binder is the locals sugar (decision 6), Rust/Ruby-style:
  `(|lo hi| hi lo - rand lo +)`, `(|x| x x *) each`. Legal only
  immediately after `(` or `[`; desugared to point-free code before the
  list value exists — the stored list contains no binder. Bind order:
  leftmost name = deepest value (`10 20 (|lo hi| …)` gives `lo`=10,
  `hi`=20 — names read in argument order). Names must be distinct;
  the empty binder `(||)` is a parse error.

## Units

The unit (decisions 7, 20 — the thing that crashes whole and rolls
back) is delimited by the reader:

- **REPL**: one logical line = one unit. The reader auto-continues
  (continuation prompt) while a delimiter or string is open, so a unit
  is the complete forms of one possibly-continued line.
- **Script file** (CLI invocation): the whole file is a single unit. A
  failing script dies whole — error dict to stderr, nonzero exit.
  Crash-only for processes means the process actually crashes.
- **`load`**: the loaded file is one unit inside the calling session;
  it fails atomically.

## Round-trip

The printer (decision 16) emits only forms this grammar reads, and
reading printed output yields the same value. The grammar is closed
under printing; `{k v}` dict printing, `[...]`/`(...)` representation
display, and string/char escapes are all re-readable.
