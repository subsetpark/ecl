## path

Lexical operations over slash-separated path strings. Every argument and
result is a string of Unicode scalar values; the separator is always `/`, and
no word reads the filesystem, consults the working directory, follows links,
or applies drive-letter, backslash, case-folding, or Unicode-normalization
rules. Normalization is lexical: it never proves that a path stays within a
directory, which is why `fs` accepts only the canonical grammar and enforces
containment at its directory handles.

### absolute?
`( path -- bool )` — Return 1 exactly when the path begins with `/`.

### basename
`( path -- name )` — Return the last element after trailing slashes are
removed: `/` for a path of only slashes and `.` for an empty path.

### components
`( path -- components )` — Normalize the path and return its non-separator
components as a list of strings. `.` and `/` yield an empty list; retained
leading `..` components remain; absoluteness is observable only through
`absolute?`.

### dirname
`( path -- path )` — Return the normalized portion before the last slash, or
`.` when the path has no slash. `dirname` of `/a` is `/`.

### extension
`( path -- extension )` — Return the suffix from the final dot of the last
element, including the dot (`.gz` for `x/y.tar.gz`, `.bashrc` for `.bashrc`,
`.` for `a.`), or the empty string when that element has no dot.

### join
`( segments -- path )` — Join a list of strings with `/` and normalize the
result. Empty segments are ignored; an empty or all-empty list yields `.`. A
non-list or a non-string member is `'type`.

### normalize
`( path -- path )` — Lexically clean a path: collapse repeated separators and
`.` components, resolve each `..` against a preceding component, keep leading
`..` components in a relative path, clamp an absolute path at `/`, and return
`.` for an empty result. Absolute paths remain absolute and relative paths
remain relative.

### relative?
`( path -- bool )` — The complement of `absolute?`.

### valid-relative?
`( path -- bool )` — Return 1 when the string is a canonical relative path in
the `fs` grammar: `.` alone, or nonempty components separated by single
slashes with no `.`, `..`, or NUL component and no leading or trailing slash.
This predicate never normalizes; normalize first when accepting untrusted
text.
