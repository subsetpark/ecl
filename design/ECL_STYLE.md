# ECL authoring guide

This guide records conventions for first-party ECL source. It is not the
language specification: [`SPEC.md`](SPEC.md) defines behavior,
[`STDLIB.md`](STDLIB.md) enumerates the shipped vocabulary, and
[`INTERPRETER.md`](INTERPRETER.md) defines implementation invariants. Rules
enforced by `check-ecl` or the source audit are identified as requirements;
the rest are review conventions that may evolve as the vocabulary does.

## Optimize for stack phrases

Lay out code in phrases that express one stack transformation. Do not put
every term on its own line, and do not join unrelated transformations merely
because they fit within the formatter's width.

Prefer:

```ecl
state (['root 'name] at-path) ('root at minimum-map) bi
pair wrap
```

over:

```ecl
state
(['root 'name] at-path)
('root at minimum-map)
bi
pair
wrap
```

Use vertical layout when its shape carries information: one branch per line,
one computed dictionary field per line, or one stage per line in a longer
pipeline. Indent continuation lines one level beneath their enclosing
quotation or binder.

Keep `put` construction visibly staged when an existing collection, key, and
computed value coexist on the stack. Do not shorten it by changing the order
in which those operands are produced; a shorter spelling that updates the
nested value instead of its parent is still wrong.

Run the canonical formatter after editing. Formatting is a baseline, not a
substitute for choosing readable phrase boundaries in the source.

## Modules and definitions

A checked-in source module begins with a module navigation header and ends in
its own `@defm`. Embedded modules follow the same semantics and file structure
as user modules; the host does not concatenate fragments, synthesize facades,
or imply re-exports.

```ecl
### module example
# Small collection helpers.
(
 ### def singleton
 (value -- list : "Return a one-element list containing the value.")
 (wrap)
 'singleton def
 )
'example
@defm
```

The following rules are enforced for checked-in first-party source:

- A standard module's terminal form is `@defm`.
- Every prelude definition begins with the exact `### def <name>` navigation
  header, and the name matches its terminal quoted definition name. Standard
  modules use `### def <name>` for `def`/`set` and `### defp <name>` for
  `defp`/`setp`. A first-class test uses `### test <name>` and the name
  matches its terminal quoted `test` declaration.
- Every `def`/`defp` definition has a meaningful nonempty annotation
  docstring. State a fixed successful stack effect when one can be expressed.
  `set`/`setp` accept the same annotation-before-value position; an
  intentionally undocumented literal constant instead puts its concise
  explanatory comment immediately beneath the navigation header.
- The annotation, not the navigation comment, is reflective documentation.

Keep tests at the direct module construction root, beside definitions. Use a
meaningful annotation docstring for checked-in tests; the body may call private
module words without exporting a test-only facade. A test declaration is not a
definition and does not become callable application vocabulary.

Pass the definition body directly to `def` or `defp`. A body that only calls
another quotation adds no behavior:

```ecl
(x -- y : "Transform x into y.")
(foo bar)
'transform def
```

Do not write the reducible form `((foo bar) call) ... 'transform def`.
`call` belongs where a quotation is a runtime value selected or constructed
by the program.

Use `defp` for implementation details within one module. Cross-module calls
go through documented public words because ordinary ECL modules have no
privileged friendship relation. `import` permits shorter local spellings; it
does not promise to re-export the imported bindings.

## Use the dataflow vocabulary

Prefer a combinator that names the dataflow over repeating an input or
managing it by hand.

### Reused inputs

Use `bi` or `tri` when two or three independent quotations consume the same
input:

```ecl
state (['root 'name] at-path) ('root at minimum-map) bi
pair wrap
```

Use `keep` when the original input must remain beneath one quotation's
result. Use `both` for the same quotation over two inputs, and `bi2` for two
quotations over the same pair of inputs.

### Locals must change the flow

Do not bind locals when every bound name appears only at the beginning of the
quotation body, exactly once and in binding order. Removing that binder leaves
the same values in the same positions and makes the stack flow direct.

Prefer:

```ecl
(pkg.name.owns?)
```

over:

```ecl
(|left right| left right pkg.name.owns?)
```

Use locals when they make a real dataflow change visible: a value is reused,
arguments are reordered, or a name is referenced after intervening work. The
point is not to avoid binders; it is to avoid binders that only repeat the
quotation's input stack.

### Captures

Use `partial` for one captured value. For several captures, collect them once
and use `with`:

```ecl
state package version requirer 4 pack (catalog-manifest) with
```

Do not build a chain of `partial` applications for the same quotation.
Reusable captures are explicit: a binder local may not cross a quotation
boundary by name. Construct a new quotation with `partial` or `with`, then bind
the captured value inside it.

An operator's declared input and a unit constructor's values operand are
parameter passing, not capture. Pass those values directly rather than
constructing a different quotation merely to move them across the boundary.

### Nested and sibling lookup

Use `at-path` for a genuine path through nested containers:

```ecl
state ['root 'name] at-path
catalog package version 3 pack at-path
```

Do not use `at-path` to describe sibling fields. Factor a sibling projection
when it has a domain meaning:

```ecl
### defp manifest-node
(manifest -- node : "Return a manifest's [name version] identity.")
(['name 'version] swap (swap at) partial each)
'manifest-node defp
```

The list argument to `at` is one dictionary key; it is not a vectorized
dictionary projection.

### Collected construction

`infra` is the structured equivalent of placing a marker on the stack and
collecting every result above it. Seed its isolated stack with the values the
construction needs, bind those values inside, and collect the resulting list:

```ecl
state wrap
(|state|
 'format 1
 'root state ['root 'name] at-path
 'packages state selected-packages
 'requires state resolved-requires)
infra dict.from-flat
```

This is preferable to a raw sentinel: the quotation supplies a lexical
boundary, errors cannot strand a marker, and program data cannot collide with
it. Use `pair` for two values and `pack` when a literal count is itself the
clearest description; do not retain a distant count solely to delimit a long
computed region.

Use `dict.from-lists` when keys and values already exist as parallel lists. Use
`dict.from-flat` when the natural intermediate form is alternating key and value
entries. Use `dict.from-pairs` when the natural form is a list of `[key value]`
associations. Use literal dictionaries for inert fixed data, not for
expressions that must execute. Dictionary observation and transformation words
such as `dict.keys`, `dict.has?`, and `dict.merge` stay qualified; `put` and
`del` remain bare because both are polymorphic over lists and dictionaries.

## Names should expose structure

Name binder locals for their role: `entry`, `requirement`, `manifest`, or
`state` is more useful than `x` when the value has a stable meaning. Short
algebraic names remain appropriate for genuinely generic combinators.

Locals shadow words. Do not name a local `pair`, `first`, or `at` merely by
habit if the body also needs to execute that word. Renaming the local is
clearer than replacing a normal word with a lower-level spelling.

Do not hand-lower readable ECL to defend against hypothetical caller imports
or `use` state. A module is authored against its own lexical and module
environment; whether another module is cold or already loaded is not an
observable language distinction.

## Documentation and comments

Write neutral, concrete documentation. Begin with the observable operation:
"Return", "Validate", "Raise", "Read", or "Write" are usually enough. Name
important constraints and error behavior, but do not narrate the
implementation or advertise the abstraction.

Use comments for decisions that are not evident from the stack program:
format compatibility, a deliberate validation boundary, or why a stricter
contract exists. Do not translate each line of code into prose. Put a
definition's explanatory comments immediately after its `### def` or
`### defp` header and before its annotation.

## Verification

Format and check checked-in ECL through the repository tooling:

```sh
timeout 120 zig build check-ecl < /dev/null
timeout 500 zig build precommit < /dev/null
```

Tests exercise public runtime behavior and documented text output. They do not
read implementation source to assert that a preferred word, import, or call
pattern appears. Source conventions belong in the formatter, compiler,
source audit, or review.
