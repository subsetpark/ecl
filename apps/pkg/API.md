# Package data APIs

These modules ship with the package application and use its module map.
They are ordinary ECL sources, available within that application.

## pkg.data

Pure structural helpers shared by the package-format modules.

### assert-inert-entry
`( pair -- )` — Discard an inert dict entry, or raise `'domain` with its key
when its value recursively contains an executable word.

### read-one
`( text -- form )` — Parse exactly one form without evaluating it. Unreadable
text is `'parse`; zero or multiple forms are `'shape`.

#### Examples

```ecl
"[1 2]" pkg.data.read-one
# => [1 2]
```

### sorted-entries
`( dict -- pairs )` — Return a dict's entries in ascending key order.

## pkg.name

### valid?
`( value -- bool )` — Test the canonical dot-joined lowercase package-name
grammar without raising.

### hash?
`( value -- bool )` — Test for `sha256-` followed by exactly 64 lowercase
hexadecimal digits.

### url?
`( value -- bool )` — Test for a nonempty HTTPS URL without credentials.

### commit?
`( value -- bool )` — Test for a full 40-digit lowercase hexadecimal Git commit ID.

### owns?
`( package-name module-name -- bool )` — Return 1 when a package owns a module
name: the name itself, or a name continuing after a `.` boundary. `foo` owns
`foo.bar` and does not own `foobar`. A non-string is `'type`; a malformed
canonical name is `'domain`.

#### Examples

```ecl
"foo" "foo.bar" pkg.name.owns?
# => 1
```

### collides?
`( names -- bool )` — Return 1 when any two canonical names overlap under
`pkg.name.owns?`.

## pkg.version

### validate
`( candidate -- parts )` — Validate a package version and return its core
fields and prerelease identifiers. A non-string is `'type`; a spelling outside
the supported SemVer grammar is `'domain`.

### less?
`( left right -- bool )` — Return 1 when the left version precedes the right
under Semantic Versioning 2.0.0 §11. Both operands are validated.

#### Examples

```ecl
"1.2.0" "1.10.0" pkg.version.less?
# => 1
```

### max
`( versions -- version )` — Return the greatest member of a nonempty list of
version strings. The empty list is `'shape`; a non-list or non-string member is
`'type`; every member is validated before comparison.

## pkg.manifest

### validate-source
`( source -- source )` — Validate an exact archive source (`kind`, `url`) or
Git source (`kind`, `url`, `commit`). URLs use HTTPS without credentials;
commits contain exactly 40 lowercase hexadecimal digits.

### write-source
`( source -- text )` — Render a validated source in canonical field order.

### validate-requirement
`( requirement -- requirement )` — Validate and return one exact target
package, minimum version, tagged source, and hash declaration.

### validate
`( candidate -- manifest )` — Return a manifest unchanged, or raise. A non-dict
is `'type`; an undeclared key, unsupported format, malformed name, version,
hash, or URL, self-requirement, ownership collision, or executable word value
is `'domain`. Sources are distinct safe portable glob strings. Exports are distinct,
exact, package-owned module names; exporting a parent does not export its
children. Private module names are visible only within their defining file. Requirement keys are local
aliases and do not rewrite module names.

### read
`( text -- manifest )` — Parse one form with `pkg.data.read-one`, validate it,
and never evaluate it.

### write
`( manifest -- text )` — Validate a manifest and render its stable one-line
form with a terminal newline, preserving requirement dictionary insertion
order.
