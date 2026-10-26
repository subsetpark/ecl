## test.default

The bundled runner is ordinary ECL policy over the closed `tests` / `@test`
substrate. Projects may replace it with any public qualified runner word.

### run
`( -- )` — Discover canonical tests, invoke them sequentially in deterministic
module/name order, print one `ok` or `FAIL` line for every result, continue
after ordinary test failures, and request process status 1 if any failed.
