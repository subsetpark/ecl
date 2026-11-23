### module tar
(: "Hostile-input-safe tar reading and extraction. Binary payloads are ordinary lists of integers in
    `0...255`; compressed archives pass through [`gzip`](#gzip) first. `unpack` validates the whole
    archive before touching the filesystem, then publishes through the [`fs`](#fs) staging words.")
(
 `tar.core [read] import

 ### defp install
 (stage member -- stage :
  "Create one validated member beneath the stage: a directory, or a file and its missing parents.")
 (|stage member|
  stage member `path at dup path.dirname member `kind at `directory match? (pop) (nip) if fs.mkdirs
  stage member `path at member `bytes at
  member `kind at `file match? (fs.create-bytes) (pop pop pop) if
  stage) `install defp

 ### defp publish
 (members stage -- : "Create every member beneath the stage, then publish the stage.")
 ((install) fold fs.commit-dir) `publish defp

 ### def unpack
 (root destination bytes -- regular-file-paths :
  "Validate and atomically unpack a tar byte list beneath a previously absent `destination`, a
   canonical relative path under a filesystem root or directory resource. Return normalized
   regular-file paths in archive order.")
 (|root destination bytes|
  bytes tar.core.read root destination fs.stage-dir
  over over pair (publish) cat @attempt swap port.close result.or-raise pop
  (`kind at `file match?) filter (`path at) each) `unpack def
) `tar @defm
