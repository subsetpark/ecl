# Extraction validation

The package application is distributed as ECL sources and an SDK-only Git
extension. The interpreter has one runtime shape and reads only inert module
maps. The core-only and complete installations contain byte-identical
interpreter executables.

## Verification

The extraction was checked on Linux x86-64 with Zig 0.16.0:

- `zig build check` and `zig build precommit`, including architecture audits,
  whole-tree analysis, public module-map validation, application dispatch, and
  fast public behavior.
- `zig build test-e2e` and the focused loader suite, including lexical visibility,
  private registrations, failed artifact publication, native artifacts,
  concurrent loading, local discovery, and malformed-map refusal.
- `zig build test-pkg-app` and ReleaseSafe `test-pkg-contracts`,
  `test-pkg-generation`, `test-pkg-application`, `test-pkg-git`, and `test-ecl`.
  Package assertions use ECL's built-in testing interfaces. Host fixtures own
  servers, repositories, temporary directories, and separate processes.
- ReleaseSafe `test-git-extension` and `test-pkg-fetch`, including deterministic
  snapshots, moved tags, unavailable commits, partial consumption, stalled
  networking, cancellation, concurrent requests, teardown, and native limits.
- ReleaseSafe initialized-Session OOM sweeps selected by
  `-Doom-filter=: module map:` and `-Doom-filter=stdlib: archive`, plus direct
  allocation-failure probes in the public loader tests.
- `test-tsan` in the documented Ubuntu/glibc Docker environment for the changed
  runtime lifetimes. Earlier filesystem and Git extension steps also ran their
  focused OOM and Docker TSan gates.

Deliberately incorrect loader, Git-command, and generation-recovery assertions
failed their selected gates; the restored assertions passed. Generation tests
exercise rejection before publication and recovery after the root lock write
with the real sealed-generation validator. Installed command tests reproduce
old and updated graphs from only portable manifests and locks, then relocate
and vendor a checkout after removing its cache.

A separate core-only ReleaseSafe build succeeded with Docker networking
disconnected and libgit2 and mbedTLS removed from its dependency directory.
Neither dependency was fetched or recreated. CI also compares core-only and
complete interpreter bytes and checks their installed application layouts.
The full Linux matrix and macOS Git/native acceptance remain in CI; macOS was
not executed locally during this extraction.

## Distribution sizes

Measured September 12, 2026 on Linux x86-64/glibc, using Zig 0.16.0, the native
CPU target, ReleaseSafe, and the default unstripped debug information. These
are sums of installed regular-file lengths, not filesystem allocation or
compressed archive sizes. Optional SDK installation and test binaries are
outside both default-install measurements.

```sh
zig build -Doptimize=ReleaseSafe -Dapps=false --prefix /tmp/ecl-distribution-core
zig build -Doptimize=ReleaseSafe --prefix /tmp/ecl-distribution-complete
cmp /tmp/ecl-distribution-core/bin/ecl /tmp/ecl-distribution-complete/bin/ecl
```

| Installation or component | Files | Bytes |
| --- | ---: | ---: |
| Core-only installation | 2 | 26,810,253 |
| Complete installation | 28 | 38,070,929 |
| Interpreter, identical in both | 1 | 26,700,984 |
| Git native extension | 1 | 11,159,896 |
| Application sources, entry, descriptor, and map | 25 | 100,780 |

The interpreter SHA-256 was
`533a059fa3e8ae214111010d30dadf3062df74e7dea5faf0502b2a764f2ca8a8`.
Extraction separates the core from application dependencies. These measurements
do not establish a reduction in the combined distribution relative to its
previous implementation.
