### module pkg.fetch
# Network source policy, expressed only in the maintained application.
[]
(
 ### def hash
 (bytes -- hash : "Compute the portable archive hash.")
 (archive.sha256 "sha256-" swap cat) 'hash def

 ### def checked
 (bytes expected -- bytes : "Require the exact pinned archive bytes.")
 (over hash match?
  'domain error.new "downloaded package hash does not match ecl.lock" error.with-message assert)
 'checked def

 ### defp success
 (response -- bytes : "Accept only successful archive responses.")
 (dup 'status at dup 200 >= swap 300 < and
  'io error.new "package download returned a non-success HTTP status" error.with-message assert
  'body at) 'success defp

 ### def archive
 (url -- bytes : "Fetch an HTTPS archive through the public bounded HTTP facility.")
 (dup pkg.name.url?
  'domain error.new "package archives require HTTPS URLs without credentials" error.with-message
  assert
  'target swap pair dict.from-flat http.get-bytes success) 'archive def

 ### defp chunk
 (reader chunks size bytes -- reader chunks size bytes : "Consume one bounded Git output chunk.")
 (|reader chunks size bytes|
  reader chunks bytes append size bytes len +
  dup 67108864 <=
  'overflow error.new "Git package archive exceeds 64 MiB" error.with-message assert
  reader 65536 port.read) 'chunk defp

 ### defp collect
 (reader -- bytes : "Drain a native byte endpoint before requesting its structured result.")
 (|reader| reader [] 0 reader 65536 port.read
  (dup empty? not) (chunk) while pop pop swap pop raze) 'collect defp

 ### defp collect-exchange
 (resource exchange -- snapshot :
  "Join the native invocation before returning its commit and archive.")
 (|resource exchange|
  exchange git.output port.endpoint collect
  exchange port.result swap pair
  exchange port.close resource port.close) 'collect-exchange defp

 ### def git
 (url selector revision -- snapshot :
  "Resolve a tag or exact commit through the independent Git extension.")
 (|url selector revision|
  {} 'url url put 'selector selector put 'revision revision put
  'ca-file "ECL_GIT_CA_FILE" pkg.project.environment put
  'scratch pkg.project.temporary put
  'export-bytes 67108864 put
  git.snapshot [] port.open swap
  (|resource request| resource resource git.fetch request port.begin collect-exchange) call) 'git
 def

 ### def requirement
 (requirement -- bytes : "Fetch the already selected source without resolving a tag again.")
 (|requirement|
  requirement 'source at
  dup 'kind at 'archive match?
  ('url at archive)
  (dup 'url at swap 'commit at 'commit swap git 1 at)
  if
  requirement 'hash at checked) 'requirement def
) 'pkg.fetch @defm
