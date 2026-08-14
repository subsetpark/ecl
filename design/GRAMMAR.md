# ecl — grammar

Companion to DESIGN.md; implements decisions 6, 8, 12, 15, 16, 17, 18.
The reader produces values (lists, dicts, atoms) with provenance; the only
parse-time code transform is the capped locals desugaring (decision 6).

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

The exact decimal form `<task:N>` (ASCII digits, no sign) is reserved as an
unparseable runtime display marker wherever an atom may occur. The same bytes
inside a string literal are ordinary character data.

**Symbols**: one or more segments joined by `.` — the dot is the module
qualification separator and nothing else (decision 18: `stats.mean`;
quotable: `'stats.mean`). Leading, trailing, or doubled dots are parse
errors. Segment characters: anything except whitespace, the six
delimiters, `"`, `#`, `'`, `\`, `.`, `,`, `;`, `|`. Unicode letters are
legal; words-not-glyphs is culture, not enforcement.

**Strings**: `"..."`, may span newlines. Escapes: `\\`, `\"`, `\n`,
`\t`, `\u{...}`. A string is a rank-1 char vector (decision 15). Raw
newlines, indentation, and blank lines inside the quotes are literal; there is
no triple-quoted, dedented, or margin-stripped string form.

## Forms

```
program  :=  form*
form     :=  list | dict | atom
list     :=  "(" binder? form* ")"  |  "[" binder? form* "]"
dict     :=  "{" (form form)* "}"
binder   :=  "|" name+ "|"           # names: distinct unqualified symbols
```

- `( )` and `[ ]` both construct the same kind of value — a list of the
  (unevaluated) enclosed forms. Brackets quote; nothing inside runs at
  read time. The pair choice is free per pair; **pairs must match**:
  `[1 2 3)` is a parse error (decision 16).
- `{ k v ... }` constructs one inert dict value at read time (decision 17).
  Adjacent top-level forms are key/value pairs; neither form is evaluated,
  so bare words are stored as word values. An odd form count or duplicate
  key is a parse error. `{}` is the empty dict. Use `dict-of` with an
  explicitly constructed flat list when entries require computation.
- The binder is the locals sugar (decision 6), Rust/Ruby-style:
  `(|lo hi| hi lo - rand lo +)`, `(|x| x x *) each`. Legal only
  immediately after `(` or `[`; desugared to point-free code before the
  list value exists — the stored list contains no binder. Bind order:
  leftmost name = deepest value (`10 20 (|lo hi| …)` gives `lo`=10,
  `hi`=20 — names read in argument order). Names must be distinct;
   the empty binder `(||)` is a parse error. The exact names `--` and `:` are
   namespace-reserved and therefore parse errors in a binder; punctuation in a
   longer otherwise-valid name remains legal.

## Definition annotations

Definition annotations add no grammar: they are ordinary quotation values
interpreted by `def`/`defp` immediately beneath the quoted name.

```
(body) 'name def
(body) (before -- after) 'name def
(body) (: "Documentation.") 'name def
(body) (before -- after : "Documentation.") 'name def
```

A quotation is an annotation candidate only when it contains a top-level word
`--` or `:`. Nested occurrences and quoted symbols are inert. Recognized
annotations are never reinterpreted as bodies after a validation error. Module
definitions require the effect portion; top-level definitions do not. `set`
and `setp` always treat their value as data.

The exact word spellings `--` and `:` remain readable and reifiable so programs
can construct annotations. They are reserved only when introducing a namespace
binding (definition, value, local, module, alias, export, or native entry).

Documentation strings are normalized when `def`/`defp` publishes the binding:
source indentation and soft prose wrapping are removed, paragraph boundaries
become one blank line, and Markdown `- ` items remain distinct with indented
continuations folded into the item. This is specific to recognized annotations;
all ordinary string contents retain their exact decoded codepoints.

## Source formatting

`ecl fmt <file|->` reads valid source without evaluating it and writes canonical
source to stdout. Its formatter CST retains trivia, comments, delimiters, atom
spellings, and complete string tokens in source order. Generic delimited forms
use uniform structural alignment. Space-separated items pack into locally
grouped runs up to 100 columns; continuation lines begin immediately inside
the opening delimiter. Existing physical newlines remain hard boundaries, and
a comment or multiline child breaks only its local run rather than forcing
every surrounding item onto a separate line. There are no first-word Lisp
layout rules.

Comments force physical line boundaries while remaining attached to their
neighboring forms. Strings are indivisible and byte-preserved except for a
string in a structurally valid doc annotation immediately followed by
`'name def`/`defp`; that position uses paragraph-aware word filling. Formatting
is idempotent. Re-reading preserves program structure and all ordinary literal
values; the docstring exception preserves the canonical definition semantics
described above. An indivisible token or preserved comment may exceed the
100-column target.

`#` introduces comments. The exact `### def <name>` navigation comment marks
definition blocks: every literal body / optional annotation / quoted
name / `def` or `defp` block is introduced by `### def <name>`, with exactly
one empty line after preceding material. At the start of a file or container,
the otherwise meaningless leading empty line is omitted. Existing `# def` or
`### def` navigation comments are canonicalized to `### def`; other comments
are preserved. The navigation header begins the definition block. Ordinary
explanatory comments attached to that definition follow the header and precede
the literal body.
Recognition is a CST pattern, never evaluation or name resolution, and is
disabled for words directly contained by syntactic dictionary literals.

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
