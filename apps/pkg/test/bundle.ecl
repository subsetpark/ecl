### module pkg.test.bundle
[]
(
 ### defp equal
 (actual expected -- : "Compare archive policy results.")
 (match? {'kind 'user 'msg "package archive assertion failed"} assert) 'equal defp

 ### defp fixture
 (name -- bytes : "Decode a checked-in inert archive fixture.")
 ("apps/pkg/test/fixtures/" swap cat ".tgz.hex" cat 'cwd swap fs.read-text str.trim
  ("0123456789abcdef" swap find) each
  dup len 2 div 2 pair reshape (|pair| pair first 16 * pair 1 at +) each) 'fixture defp

 ### defp rejected
 (name -- : "Require archive layout or source validation to fail through the public API.")
 (fixture wrap (pkg.bundle.inspect) @attempt result.err? 1 equal) 'rejected defp

 ### test source-inspection
 (-- : "Inspect literal exports without executing package source, retaining data files.")
 ("valid" fixture pkg.bundle.inspect
  dup 'manifest at 'name at "sample" equal
  'artifacts at [{'kind 'ecl 'path "src/api.ecl" 'exports ["sample.api"]}] equal
  'cwd "package-source-executed" fs.exists? 0 equal
  "private-duplicates" fixture pkg.bundle.inspect 'artifacts at
  ('exports at) each raze ["sample.api"] equal)
 'source-inspection test

 ### test rejected-layouts
 (-- : "Package policy rejects native payloads, missing exports, duplicates, and malformed source.")
 (["missing-manifest" "missing-export" "duplicate-export" "native" "malformed-source" "reserved"
   "symlink" "traversal"]
  (rejected) for)
 'rejected-layouts test
) 'pkg.test.bundle @defm
