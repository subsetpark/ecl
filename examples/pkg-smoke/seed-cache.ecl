# Run from the repository root with the package application's module map.
'cwd "test/fixtures/pkg/runtime-valid.tgz.hex" fs.read-text str.trim
("0123456789abcdef" swap find) each
dup len 2 div 2 pair reshape
(|pair| pair first 16 * pair 1 at +) each
(|bytes| pkg.project.cache-path bytes pkg.fetch.hash bytes pkg.cache.write) call
