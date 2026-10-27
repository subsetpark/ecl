## archive

### sha256
`( bytes -- lowercase-hex )` — Return the SHA-256 digest of an integer byte
list. Every item must be an integer in `0..255`; strings are not byte vectors
and are not coerced.

#### Examples

```ecl
[1 2 3 4] archive.sha256
# => "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a"
```

### unpack-tgz
`( bytes root destination -- regular-file-paths )` — Validate and atomically
unpack a gzip-compressed tar byte list beneath a previously absent
`destination`, a canonical relative path under a named Session filesystem root
or scope-owned directory resource (see [`fs`](#fs)). Extraction owns its
directory lease until publication or rollback completes. The destination must
name a child entry, not `.`. Return normalized regular-file paths in archive
order. Unsafe, linked, special, duplicate, malformed, or over-limit members
are `` `domain ``; invalid byte items are `` `domain ``; wrong container kinds are
`` `type ``; an unknown root or a non-canonical destination is `` `domain `` carrying the `fs` failure data; an
exhausted operation quota is `` `overflow ``; filesystem and destination
conflicts are `` `io ``. Failure never publishes a partial destination. See the
environment's [`archive` contract](ENVIRONMENT.md#byte-lists-and-archives)
for the complete format, limit, containment, and publication contract.

### open-tgz
`( bytes -- archive )` — Validate a gzip tar with the same hostile-input parser
and limits as `unpack-tgz`, then return a scope-owned archive resource without
filesystem writes. No manifest or package identity is required. The resource
retains the validated uncompressed document until `port.close` or scope exit;
cleanup is joined and advances incrementally through member storage.
The limits apply per document. Scope ownership governs lifetime and joined
cleanup; it does not impose an aggregate heap budget on retained archives.

### next-member
`( archive -- metadata )` — Select the next archive member and return
`{path string kind symbol size int}` in archive order. Kinds are `` `file `` and
`` `directory ``; size is the content length in bytes. `{}` denotes stable end.
Advancing skips unread contents of the previous member. Metadata owns its path
independently of later cursor operations or closure.

### read-member
`( archive maximum -- bytes )` — Read up to `maximum` bytes from the selected
member, advancing its content position. The maximum must be an integer from
1 through 65,536. `[]` denotes end of that member, a directory, or no selected
member. Reads copy bounded chunks into independently owned values; concurrent
reads consume distinct chunks, with unspecified completion order. Coordinate
member advancement with reads when using the archive across tasks. Operations
on a closed archive raise `` `io ``.
