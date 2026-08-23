# Package manager smoke project

This is ecl's checked-in package-manager consumer. It depends on the public
source-only `smoke` package, imports it through `ecl.lock`, and prints `42`.
The manifest and lock are committed so an unrelated package operation can be
checked for byte-stable output.

Build ecl from the repository root, then run the complete workflow here:

```sh
cd examples/pkg-smoke
ECL=../../zig-out/bin/ecl

"$ECL" pkg add smoke 1.0.0 \
  https://github.com/subsetpark/ecl-pkg-smoke/releases/download/v1.0.0/smoke-1.0.0.tgz
"$ECL" pkg sync
"$ECL" main.ecl
"$ECL" pkg sync --offline
"$ECL" pkg tree
"$ECL" pkg why smoke.answer
"$ECL" pkg verify
git diff --exit-code -- ecl.pkg ecl.lock
```

The successful transcript is:

```text
added smoke 1.0.0
synced 1 packages
42
synced 1 packages
example.pkg-smoke
example.pkg-smoke -> smoke 1.0.0
smoke.answer: example.pkg-smoke -> smoke 1.0.0
verified 1 packages
```

The first two commands use the network. Everything from `main.ecl` through
`pkg verify` uses the immutable store entry selected by the checked-in lock.
