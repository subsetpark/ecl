# Portable package-lock example

This project imports the source-only fixture package `a` and prints `42`. Its
version-controlled manifest and format-3 lock pin the complete dependency graph.
The local alias `smoke` does not rename the module `a`.

Run this workflow from the repository root. The seed script uses the maintained
application's public cache API to store the checked-in deterministic archive.
The illustrative HTTPS URL is never fetched; every synchronization below is
offline.

```sh
zig build -Doptimize=ReleaseSafe
export ECL_CACHE="$PWD/.zig-cache/pkg-example-cache"
./zig-out/bin/ecl --module-map apps/pkg/ecl.modules examples/pkg-smoke/seed-cache.ecl
cd examples/pkg-smoke
ECL=../../zig-out/bin/ecl
"$ECL" pkg sync --offline
"$ECL" main.ecl
"$ECL" pkg verify
"$ECL" pkg tree
"$ECL" pkg why a.answer
"$ECL" pkg vendor --offline
"$ECL" main.ecl
git diff --exit-code -- ecl.pkg ecl.lock
```

Both executions print `42`. Synchronization and vendoring preserve the portable
lock; generated dependency trees live in immutable local generations. The
interpreter loads only `ecl.modules`. A fresh checkout of the manifest and lock
reproduces the same graph when its pinned artifact is available. Dependency
changes require `ecl pkg update`; ordinary sync never silently updates a lock.
