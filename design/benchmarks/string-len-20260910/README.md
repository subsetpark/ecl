# String identity and length-map benchmark evidence

The `baseline/` and `updated/` directories preserve the original four runs
(one warmup, then three measurements), process logs, generated ECL workloads,
and executable SHA-256 hashes in `table-breakdown.json`. The baseline is
`18be833`; the updated source is `cc41a0d`. These measurements used Zig 0.16.0,
ReleaseSafe, macOS 26.6.2 arm64, and `ECL_WORKERS=1`. No new timings were taken
when archiving these artifacts.

`result-equivalence.json` and its log preserve the aggregate and full serialized
join output sizes, SHA-256 hashes, and process exit statuses for both versions.
The CSV inputs are not included. `inputs.json` records the sizes and SHA-256
hashes of the benchmark host's retained files at archival time. Reproduction
requires those files: `metal_bands.csv` (183,397 data rows) and
`all_bands_discography.csv` (636,801 data rows). No public download location is
recorded; the raw measurements remain inspectable without the datasets.

The original Python scripts are included with only their host-specific paths
replaced by environment parameters. With Zig 0.16.0 and Python 3.11 or newer,
run from the repository root, setting the data directory to your input location:

```sh
export ECL_BENCH_DATA=/absolute/path/to/csv-inputs
export ECL_BENCH_ROOT="$PWD/design/benchmarks/string-len-20260910"
export ECL_BENCH_WORK="$(mktemp -d)"
git worktree add --detach "$ECL_BENCH_WORK/baseline" 18be833
git worktree add --detach "$ECL_BENCH_WORK/updated" cc41a0d
(cd "$ECL_BENCH_WORK/baseline" && timeout 500 zig build -Doptimize=ReleaseSafe < /dev/null)
(cd "$ECL_BENCH_WORK/updated" && timeout 500 zig build -Doptimize=ReleaseSafe < /dev/null)
export ECL_BENCH_BASELINE="$ECL_BENCH_WORK/baseline/zig-out/bin/ecl"
export ECL_BENCH_UPDATED="$ECL_BENCH_WORK/updated/zig-out/bin/ecl"
ECL_BENCH_BINARY="$ECL_BENCH_BASELINE" ECL_BENCH_OUTPUT="$ECL_BENCH_WORK/results/baseline" \
  timeout 750 python3 "$ECL_BENCH_ROOT/baseline/measure.py" < /dev/null
ECL_BENCH_BINARY="$ECL_BENCH_UPDATED" ECL_BENCH_OUTPUT="$ECL_BENCH_WORK/results/updated" \
  timeout 750 python3 "$ECL_BENCH_ROOT/updated/measure.py" < /dev/null
ECL_BENCH_OUTPUT="$ECL_BENCH_WORK/results" \
  timeout 750 python3 "$ECL_BENCH_ROOT/compare-results.py" < /dev/null
```

Run each command separately and check its exit status before continuing. Finish
both builds before timing and avoid concurrent builds or tests. Rebuilt binary
hashes and timings may differ with host and toolchain details; output hashes
should match for identical inputs. Results go to the temporary working directory
so reproduction does not overwrite the archived evidence.
