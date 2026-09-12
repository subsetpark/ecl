### module pkg.transaction
# Application-owned recovery of the separate portable-lock and module-map writes.
[]
(
 ### defp require
 (condition -- : "Reject a conflicting or malformed publication transaction.")
 ('domain error.new "package publication recovery conflict" error.with-message assert) 'require defp

 ### defp read-one
 (text -- data : "Parse exactly one inert record without executing source.")
 (pkg.data.read-one) 'read-one defp

 ### defp snapshot
 (project path -- snapshot : "Observe absence or the exact bytes of a text file.")
 (over over fs.exists? (fs.read-text wrap) (pop pop []) if) 'snapshot defp

 ### defp snapshot?
 (value -- bool : "Recognize an absent or present text snapshot.")
 (dup type 'list match?
  ((len 1 <=) ((str.str?) all?) bi and) (pop 0) if) 'snapshot? defp

 ### defp validate
 (record -- record : "Validate the closed recovery-record schema.")
 (|record|
  record type 'dict match? require
  record dict.keys (str) each sort
  ['format 'manifest 'lock-before 'map-before 'lock-after 'generation] (str) each sort match?
  require
  record 'format at 1 match? require
  record 'manifest at str.str? require
  record 'lock-before at snapshot? require
  record 'map-before at snapshot? require
  record 'lock-after at str.str? require
  record 'generation at pkg.layout.generation? require
  record) 'validate defp

 ### defp generation-path
 (record -- path : "Resolve the immutable generation beneath the project.")
 ('generation at) 'generation-path defp

 ### defp reference
 (record -- text : "Render the complete root module-map reference.")
 (generation-path pkg.layout.reference) 'reference defp

 ### defp expected
 (actual previous proposed -- : "Refuse unrelated edits while allowing idempotent replay.")
 (|actual previous proposed| actual previous match? actual proposed match? or require) 'expected
 defp

 ### defp check
 (project record validate-generation -- : "Check all inputs before either root write.")
 (|project record validator|
  project "ecl.pkg" fs.read-text record 'manifest at match? require
  project "ecl.lock" snapshot record 'lock-before at record 'lock-after at wrap expected
  project "ecl.modules" snapshot record 'map-before at record reference wrap expected
  project record generation-path "/ecl.lock" cat fs.read-text
  record 'lock-after at match? require
  project record generation-path validator call) 'check defp

 ### def prepare
 (project generation lock-text validate-generation -- :
  "Persist a recovery record for a published generation before changing either root file.")
 (|project generation lock-text validator|
  {'format 1}
  'manifest project "ecl.pkg" fs.read-text put
  'lock-before project "ecl.lock" snapshot put
  'map-before project "ecl.modules" snapshot put
  'lock-after lock-text put
  'generation generation put
  validate project swap validator prepare-checked) 'prepare def

 ### defp prepare-checked
 (project record validator -- : "Validate the candidate and create an absent recovery record.")
 (|project record validator|
  project record validator check
  record str "\n" cat project ".ecl/publication.ecl" fs.create-text) 'prepare-checked defp

 ### defp replay
 (project record validator -- : "Complete lock publication, activation, and journal retirement.")
 (|project record validator|
  project record validator check
  record 'lock-after at project "ecl.lock" fs.publish-text
  record reference project "ecl.modules" fs.publish-text
  project ".ecl/publication.ecl" fs.remove-file) 'replay defp

 ### def recover
 (project validate-generation -- :
  "Finish a pending transaction under the caller's project mutation lock without resolving
   sources.")
 (|project validator|
  project validator
  project ".ecl/publication.ecl" fs.exists?
  (recover-present) (pop pop) if) 'recover def

 ### defp recover-present
 (project validator -- : "Read and replay the already selected recovery record.")
 (|project validator|
  project project ".ecl/publication.ecl" fs.read-text read-one validate validator replay)
 'recover-present defp
) 'pkg.transaction @defm
