### module pkg.test.transaction
[]
(
 ### defp equal
 (actual expected -- : "Compare publication state through public file operations.")
 (match? {kind user msg "publication assertion failed"} assert) `equal defp

 ### setp old-lock
 "{format 3 root \"project\" root-requires {} packages {} requires {\"project\" {}}}\n"
 `old-lock setp

 ### setp new-lock
 "{format 3 root \"project\" packages {} requires {\"project\" {}} root-requires {}}\n"
 `new-lock setp

 ### setp old-map
 "{format 1 local \"project\" scopes {\"project\" {root \".\" visible [] sources [] artifacts []}}}\n"
 `old-map setp

 ### setp generation
 ".ecl/generations/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
 `generation setp

 ### defp validate-generation
 (project path -- : "Supply an independent application validator to the transaction protocol.")
 ("/validated" cat fs.read-text "accepted" equal) `validate-generation defp

 ### defp fixture
 (-- project lock : "Own a private project fixture and its mutation lock through the test scope.")
 (`cwd "apps/pkg/test/fixtures/publication-unused" fs.stage-dir
  (|project|
   project generation fs.mkdirs
   project "ecl.pkg"
   "{format 2 name \"project\" version \"0.1.0\" sources [] exports [] requires {}}\n"
   fs.create-text
   project "ecl.lock" old-lock fs.create-text
   project "ecl.modules" old-map fs.create-text
   project generation "/ecl.lock" cat new-lock fs.create-text
   project generation "/validated" cat "accepted" fs.create-text
   project project ".ecl/mutation.lock" fs.lock)
  call) `fixture defp

 ### defp prepare
 (project -- : "Persist the proposed generation before changing either root file.")
 (generation new-lock (validate-generation) pkg.transaction.prepare) `prepare defp

 ### defp recover
 (project -- : "Replay with the same mandatory application validator.")
 ((validate-generation) pkg.transaction.recover) `recover defp

 ### defp roots
 (project expected-lock expected-map -- : "Read the exact root-file publication state.")
 (|project expected-lock expected-map|
  project "ecl.lock" fs.read-text expected-lock equal
  project "ecl.modules" fs.read-text expected-map equal) `roots defp

 ### defp boundary
 (state -- : "Resume each prefix of the separate atomic lock and map writes.")
 (fixture 3 pack
  (|state project lock|
   project prepare project old-lock old-map roots
   state 1 >= project "ecl.lock" new-lock 3 pack (fs.publish-text) cat when
   state 2 >= project "ecl.modules" generation pkg.layout.reference 3 pack
   (fs.publish-text) cat when
   project recover project recover
   project new-lock generation pkg.layout.reference roots
   project ".ecl/publication.ecl" fs.exists? 0 equal
   project generation "/ecl.lock" cat fs.read-text new-lock equal
   lock port.close project port.close)
  cat call) `boundary defp

 ### test interruption-boundaries
 (-- : "Recovery is idempotent before publication, between root writes, and after activation.")
 ([0 1 2] (boundary) for) `interruption-boundaries test

 ### test initial-publication
 (-- : "Recover initial creation of both root files from an absent state.")
 (fixture
  (|project lock|
   project "ecl.lock" fs.remove-file project "ecl.modules" fs.remove-file
   project prepare project recover
   project new-lock generation pkg.layout.reference roots
   project ".ecl/publication.ecl" fs.exists? 0 equal
   lock port.close project port.close) call) `initial-publication test

 ### defp conflict
 (path -- : "Refuse edits to any transaction input without changing either root file.")
 (fixture 3 pack
  (|path project lock|
   project prepare
   project path "unrelated edit" fs.publish-text
   project "ecl.lock" fs.read-text project "ecl.modules" fs.read-text pair
   project wrap (recover) @attempt result.err? 1 equal
   project "ecl.lock" fs.read-text project "ecl.modules" fs.read-text pair equal
   project path fs.read-text "unrelated edit" equal
   project ".ecl/publication.ecl" fs.exists? 1 equal
   lock port.close project port.close)
  cat call) `conflict defp

 ### test refuses-conflicts
 (-- :
  "Manifest, root, journal, snapshot, and validator changes cannot be overwritten by recovery.")
 (["ecl.pkg" "ecl.lock" "ecl.modules" ".ecl/publication.ecl"]
  generation "/ecl.lock" cat append generation "/validated" cat append
  (conflict) for) `refuses-conflicts test
) `pkg.test.transaction @defm
