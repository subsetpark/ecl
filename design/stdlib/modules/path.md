## path

Lexical operations over slash-separated path strings. Every argument and
result is a string of Unicode scalar values; the separator is always `/`, and
no word reads the filesystem, consults the working directory, follows links,
or applies drive-letter, backslash, case-folding, or Unicode-normalization
rules. Normalization is lexical: it never proves that a path stays within a
directory, which is why `fs` accepts only the canonical grammar and enforces
containment at its directory handles.
