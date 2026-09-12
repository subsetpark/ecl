# Package manifest and source conventions

These contracts belong to the maintained package application. The portable
format-3 lock and publication protocol are specified in [README.md](README.md).

### Versions

A package version is a string with this grammar:

```text
version     := core ("-" prerelease)?
core        := num "." num "." num
num         := "0" | [1-9] [0-9]*
prerelease  := ident ("." ident)*
ident       := [0-9A-Za-z-]+
```

A numeric prerelease identifier has no leading zero. Build metadata is outside
the grammar, so any `+` makes the version malformed.

Precedence follows Semantic Versioning 2.0.0 section 11:

1. Compare major, minor, and patch numerically.
2. A prerelease precedes the same core version without a prerelease.
3. Compare prerelease identifiers from left to right. Numeric identifiers
   precede alphanumeric identifiers; numeric identifiers compare numerically;
   alphanumeric identifiers compare by ECL string order.
4. When every shared identifier is equal, the shorter prerelease precedes the
   longer one.

The admitted grammar has a strict total order. Minimal version selection
chooses among minimum versions declared by reachable manifests.

### Manifest

`ecl.pkg` has this shape:

```ecl
{'format 2
 'name "my.proj"
 'version "0.1.0"
 'sources ["src/**/*.ecl"]
 'exports ["my.proj"]
 'requires
 {"statistics" {'package "foo"
                 'version "1.2.0"
                 'source {'kind 'archive 'url "https://example.com/foo-1.2.0.tgz"}
                 'hash "sha256-<64 lowercase hex digits>"}}}
```

`'format` is the integer `2`. `'name` is the package's canonical name, and
`'version` is its version. `'sources` lists portable source-file globs, and
`'exports` lists exact public module names. `'requires` maps consumer-local aliases to requirements.

A requirement contains exactly `'package`, `'version`, `'source`, and `'hash`.
The version is a minimum. Sources are tagged dictionaries: an archive has
`'kind 'archive` and `'url`; Git has `'kind 'git`, `'url`, and `'commit`.
URLs use HTTPS without credentials. Git commits are full 40-character lowercase
hexadecimal identifiers. The hash has the
form `sha256-` followed by 64 lowercase hexadecimal digits. Aliases do not
change ECL module names.

Format 1 is rejected. To migrate, wrap each former URL in an archive source
dictionary, set the manifest format to 2, and explicitly update the lock with `ecl pkg update`.

Every dictionary key is declared by the format. A requirement cannot target
the containing manifest's package. One consumer cannot target the same
package through multiple aliases. Selected package names cannot overlap under
the ownership rule below.

Manifest values may contain ints, floats, chars, symbols, strings, lists, and
dictionaries. An executable word anywhere in the value raises `'domain`.
Comments are accepted by the reader and omitted by manifest rewrites.

### Package names and exports

A canonical package name contains dot-separated segments. Each segment
matches `[a-z][a-z0-9-]*`. Every package name is also a valid module name.

Package `foo` owns module namespaces `foo` and `foo.<rest>`. The ownership
boundary is a dot, so `foo` owns `foo.bar` and excludes `foobar`.

The source list contains distinct portable globs. Globs use relative
`/`-separated paths and support `*`, `?`, and a whole-segment
`**`. They exclude absolute paths, backslashes, and empty, `.`, or `..`
segments. A glob may match no files; overlapping globs
select a file only once. An empty source list is valid.

Exports are distinct, exact, package-owned module names. Exporting a module
does not export its dotted children. Each export must have one top-level
literal declaration in the selected source files: a module-name symbol
followed by `@defm`. A source file may export several modules, and every
export maps to exactly one source file. File and directory names do not
determine module names.

Other registrations in a selected file are private to that file. They may
use unrelated names and may be constructed dynamically with `@module` and
`register`. Modules and their tests can use their defining file's private
registrations. Other files cannot access those registrations, including files
in the same package. Two files may independently register the same private
name.

Calling an exported module preserves the called code's defining-file
visibility. Loading another file does not add its private registrations to
the caller's environment. Module-authored quotations and module handles keep
their defining-file context when passed elsewhere; passing such a value
explicitly is distinct from making its private module name public.

