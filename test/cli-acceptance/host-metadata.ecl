### module cli.test.host-metadata
# Host metadata is independent of environment spelling. Independence from the
# argument-vector spelling of the executable lives in test/e2e.zig, because a
# process specification always passes the executable path as argv[0].
[]
(
 `cli.test.support (expect install invocation succeeds write) import

 ### defp metadata
 (binary program -- output :
  "Run one program in the Unicode caller directory with bogus PWD and PATH.")
 (wrap "host-metadata/caller λ" invocation `env {"PWD" "/unrelated" "PATH" "/absent"} put
  "metadata program" succeeds str.trim) `metadata defp

 ### test 'metadata ignores PWD and PATH'
 (-- : "Report the captured working directory and the OS-reported executable path.")
 ("host-metadata" install
  `cwd "host-metadata/caller λ" fs.mkdirs
  "{format 1 local \"local\" scopes {\"local\" {root \".\" visible [] sources [] artifacts []}}}"
  "host-metadata/caller λ/map" write
  dup "host.cwd json.emit io.prin" metadata
  host.cwd "host-metadata/caller λ" pair path.join json.emit "host.cwd" expect
  dup "host.executable json.emit io.prin" metadata
  over json.emit "host.executable" expect
  "{args [\"check-map\" \"map\"] timeout-ms 5000} `executable host.executable put proc.run `term at `code at"
  metadata "0" "nested check-map through host.executable" expect) `'metadata ignores PWD and PATH'
 test
) `cli.test.host-metadata @defm
