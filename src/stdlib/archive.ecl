### module archive
# Inspection validates the complete hostile input before filesystem publication.
[]
(
 ### defp spread
 (: "Push inert arguments from a list.")
 (() with call) 'spread defp

 ### defp failed
 (fields -- : "Restore a public archive failure.")
 (spread
  (|outcome public|
   outcome 'err at 'word public put 'trace public wrap put raise) call) 'failed defp

 ### defp finish
 (outcome public -- value : "Restore the public archive word on an inspected result.")
 (pair dup first 'ok dict.has? (first 'ok at first) (failed) if) 'finish defp

 ### def open-tgz
 (bytes -- archive : "Validate a gzip tar for scope-owned member inspection.")
 (wrap (archive.core.open-tgz) @attempt 'archive.open-tgz finish) 'open-tgz def

 ### def next-member
 (archive -- metadata : "Advance to the next member, or return an empty dictionary at end.")
 (wrap (archive.core.next-member) @attempt 'archive.next-member finish) 'next-member def

 ### def read-member
 (archive maximum -- bytes :
  "Stream up to 65536 bytes from the selected member; empty bytes denote end.")
 (pair (archive.core.read-member) @attempt 'archive.read-member finish) 'read-member def

 ### def sha256
 (bytes -- lowercase-hex : "Hash an integer byte list with SHA-256.")
 (wrap (archive.core.sha256) @attempt 'archive.sha256 finish) 'sha256 def

 ### defp stream-step
 (archive writer chunk -- archive writer chunk : "Append one bounded inspected member chunk.")
 (|archive writer chunk| writer chunk fs.write-chunk archive writer archive 65536 read-member)
 'stream-step defp

 ### defp stream
 (archive writer -- : "Commit only after the selected member reaches EOF.")
 (|archive writer|
  archive writer archive 65536 read-member (dup empty? not) (stream-step) while
  pop pop pop writer fs.commit-file) 'stream defp

 ### defp file
 (archive stage path -- : "Own one unpublished file writer through success or failure.")
 (|archive stage path|
  stage path path.dirname fs.mkdirs
  stage path fs.open-writer
  dup archive swap pair (stream) @attempt swap port.close result.or-raise pop) 'file defp

 ### defp directory-member
 (fields -- archive stage destination paths : "Create an inspected empty directory.")
 (spread
  (|archive stage destination paths metadata|
   stage metadata 'path at fs.mkdirs archive stage destination paths) call) 'directory-member defp

 ### defp file-member
 (fields -- archive stage destination paths : "Extract and record one inspected file.")
 (spread
  (|archive stage destination paths metadata|
   archive stage metadata 'path at file
   archive stage destination paths metadata 'path at append) call)
 'file-member defp

 ### defp member
 (archive stage destination paths metadata -- archive stage destination paths :
  "Extract one validated member in archive order.")
 (5 pack dup last 'kind at 'directory match? (directory-member) (file-member) if) 'member defp

 ### defp extract
 (archive stage destination -- paths :
  "Reserve the result before publishing the completed private directory.")
 (|archive stage destination|
  archive stage destination [] archive next-member
  (dup {} match? not)
  (member (|archive stage destination paths| archive stage destination paths archive next-member)
   call) while pop
  (|archive stage destination paths| paths stage fs.commit-dir) call) 'extract defp

 ### defp staged
 (archive reservation destination -- paths :
  "Join staging rollback before releasing its reservation.")
 (|archive reservation destination|
  reservation destination fs.stage-dir
  dup archive swap destination 3 pack (extract) @attempt swap port.close result.or-raise first)
 'staged defp

 ### defp inspect
 (bytes reservation destination -- paths :
  "Inspect fully before constructing private extraction storage.")
 (|bytes reservation destination|
  bytes open-tgz dup reservation destination 3 pack (staged) @attempt
  swap port.close result.or-raise first) 'inspect defp

 ### defp validate-bytes
 (bytes -- : "Validate byte members with a bounded cursor and preserve the first error index.")
 (|bytes|
  bytes fs.core.byte-error-index
  dup bytes len =
  (pop)
  ('index swap pair dict.from-flat
   'domain error.new "archive.unpack-tgz expects integers from 0 through 255" error.with-message
   swap error.with-data raise) if) 'validate-bytes defp

 ### defp unpack
 (bytes root destination -- paths :
  "Retain the selected root and extraction admission until joined cleanup.")
 (|bytes root destination|
  destination str.str? {'kind 'type 'msg "expected a string destination path"} assert
  root fs.core.root-value
  {'kind 'type 'msg "expected a root symbol or directory resource"} assert
  bytes type 'list match? {'kind 'type 'msg "expected an integer byte list"} assert
  bytes validate-bytes
  destination path.valid-relative? destination "." match? not and
  {'kind 'domain 'msg "destination is not a canonical relative entry path" 'data
   {'reason 'invalid-path}} assert
  root fs.reserve dup bytes swap destination 3 pack (inspect) @attempt
  swap port.close result.or-raise first) 'unpack defp

 ### defp extraction-context
 (fields -- error : "Attach the original extraction root and destination.")
 (spread
  (|failure root destination|
   failure failure 'data at 'operation 'unpack-tgz put 'root root put 'path destination put
   error.with-data) call) 'extraction-context defp

 ### defp unpack-error
 (fields -- : "Attach extraction attribution and original root context.")
 (spread (|outcome root destination| outcome 'err at root destination 3 pack) call
  dup first 'data {} at-or 'reason dict.has? (extraction-context) (first) if
  'word 'archive.unpack-tgz put 'trace ['archive.unpack-tgz] put raise) 'unpack-error defp

 ### def unpack-tgz
 (bytes root destination -- regular-file-paths :
  "Validate and atomically extract a gzip tar into a previously absent destination beneath a root.")
 (|bytes root destination|
  bytes root destination 3 pack (unpack) @attempt root destination 3 pack
  dup first 'ok dict.has? (first 'ok at first) (unpack-error) if) 'unpack-tgz def
) 'archive @defm
