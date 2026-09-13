### module fs
# Confined resources and atomic publication compose the bundled native SDK module.
[]
(
 ### defp spread
 (: "Push a list's values as inert arguments.")
 (() with call) 'spread defp

 ### defp trim-trace
 (trace public -- trace : "Keep attribution beginning at the public filesystem word.")
 (|trace public|
  trace trace public find drop public pair
  dup first empty? (last wrap) (first) if) 'trim-trace defp

 ### defp add-context
 (fields -- error : "Attach filesystem context to a portable native reason.")
 (spread
  (|failure operation context|
   failure failure 'data {} at-or context dict.merge 'operation operation put error.with-data)
  call) 'add-context defp

 ### defp decorate
 (failure operation public context -- error : "Restore public attribution and root context.")
 (|failure operation public context|
  failure 'word public put
  failure 'trace [] at-or public trim-trace 'trace swap put
  operation context 3 pack
  dup first 'data {} at-or 'reason dict.has? (add-context) (first) if) 'decorate defp

 ### defp finish-error
 (fields -- : "Raise a native failure at its public filesystem boundary.")
 (spread
  (|outcome operation public context|
   outcome 'err at operation public context decorate raise) call) 'finish-error defp

 ### defp finish
 (fields -- value : "Return one internal result or raise its annotated failure.")
 (dup first 'ok dict.has? (first 'ok at first) (finish-error) if) 'finish defp

 ### defp run-unary
 (root path operation public quotation -- value : "Run a filesystem operation under its context.")
 (|root path operation public quotation|
  root path pair quotation @attempt operation public
  'root root 'path path 4 pack dict.from-flat 4 pack finish) 'run-unary defp

 ### defp run-write
 (payload root path operation public quotation -- value :
  "Retain write error context through cleanup.")
 (|payload root path operation public quotation|
  payload root path 3 pack quotation @attempt operation public
  'root root 'path path 4 pack dict.from-flat 4 pack finish) 'run-write defp

 ### defp checked-unary
 (root path -- root path : "Validate path and root types before native marshalling.")
 (|root path|
  path fs.core.string-value {'kind 'type 'msg "expected a string path"} assert
  root fs.core.root-value
  {'kind 'type 'msg "expected a root symbol or directory resource"} assert root path)
 'checked-unary defp

 ### defp canonical
 (path -- path : "Check lexical confinement before beginning a child operation.")
 (dup path.valid-relative?
  {'kind 'domain 'msg "path is not a canonical relative path" 'data {'reason 'invalid-path}} assert)
 'canonical defp

 ### defp byte-error
 (payload index -- : "Report the first malformed byte with its original index.")
 (|payload index|
  'type error.new "byte list members must be integers from 0 through 255" error.with-message
  'index index pair dict.from-flat error.with-data raise) 'byte-error defp

 ### defp checked-bytes
 (payload -- payload : "Validate byte members through a bounded SDK value cursor.")
 (dup type 'list match? {'kind 'type 'msg "expected a byte list to write"} assert
  dup fs.core.byte-error-index over len over = (pop) (byte-error) if) 'checked-bytes defp

 ### defp request
 (root path operation -- value : "Own a request through result observation and joined cleanup.")
 (|root path operation|
  root path checked-unary pop pop
  fs.core.request operation root path 3 pack port.open
  dup wrap (fs.core.execute-request [] port.call) @attempt swap port.close result.or-raise first)
 'request defp

 ### defp collect-step
 (resource selector chunks chunk -- resource selector chunks chunk : "Retain one bounded batch.")
 (|resource selector chunks chunk|
  resource selector chunks chunk append resource selector [] port.call) 'collect-step defp

 ### defp collect
 (resource selector -- values : "Collect bounded batches and materialize once.")
 (|resource selector|
  resource selector [] resource selector [] port.call
  (dup empty? not) (collect-step) while pop
  (|resource selector chunks| chunks raze) call) 'collect defp

 ### defp read-body
 (root path -- bytes : "Retain one root loan and admission through the complete read.")
 (checked-unary 1 rollup 3 pack fs.core.reader swap port.open
  dup wrap (fs.core.read-chunk collect) @attempt swap port.close result.or-raise first)
 'read-body defp

 ### defp decode-error
 (outcome -- : "Translate invalid file UTF-8 to the filesystem error vocabulary.")
 ('err at dup 'kind at 'domain match?
  (pop {'kind 'io 'msg "file is not valid UTF-8" 'data {'reason 'invalid-utf8}})
  () if raise) 'decode-error defp

 ### defp read-text-body
 (root path -- string : "Decode a completely read file as UTF-8.")
 (read-body wrap (chars) @attempt dup 'ok dict.has? ('ok at first) (decode-error) if)
 'read-text-body defp

 ### defp list-body
 (root path -- entries : "Collect under one admission, then order by Unicode names.")
 (checked-unary 1 rollup 3 pack fs.core.listing swap port.open
  dup wrap (fs.core.list-batch collect) @attempt swap port.close result.or-raise first
  dup ('name at) each grade at) 'list-body defp

 ### defp derive-named
 (fields -- resource : "Construct a resource beneath a configured root.")
 (spread (|root path factory selector| factory 1 root path 3 pack port.open) call) 'derive-named
 defp

 ### defp admission-error
 (failure -- : "Give closed resource admission the portable filesystem I/O reason.")
 (dup 'kind at 'io match? over 'data {} at-or 'reason dict.has? not and
  (dup 'data {} at-or 'reason 'io put error.with-data) () if raise) 'admission-error defp

 ### defp admitted
 (outcome -- resource : "Preserve initialized child errors and classify closed admission.")
 (dup 'ok dict.has? ('ok at first) ('err at admission-error) if) 'admitted defp

 ### defp derive-resource
 (fields -- resource : "Inherit the selected resource's staging lifetime.")
 (spread
  (|root path factory selector|
   root selector 1 root path 3 pack 3 pack (port.call) @attempt admitted) call)
 'derive-resource defp

 ### defp derive
 (root path factory selector -- resource : "Validate and derive a directory-like child.")
 (|root path factory selector|
  root path checked-unary canonical pop pop
  root path factory selector 4 pack dup first type 'symbol match?
  (derive-named) (derive-resource) if) 'derive defp

 ### defp child-body
 (root path -- directory : "Open an independently owned confined directory.")
 (fs.core.directory fs.core.derive-directory derive) 'child-body defp

 ### defp stage-body
 (root path -- stage : "Create a private staging directory.")
 (checked-unary canonical dup "." match? not
  {'kind 'domain 'msg "expected a relative entry path" 'data {'reason 'invalid-path}} assert
  fs.core.stage fs.core.derive-stage derive) 'stage-body defp

 ### defp cursor-body
 (root path -- cursor : "Open independent incremental enumeration.")
 (fs.core.cursor fs.core.derive-cursor derive) 'cursor-body defp

 ### defp host-body
 (root path -- directory : "Open an absolute host directory without filesystem admission.")
 (|root path|
  path fs.core.string-value {'kind 'type 'msg "expected an absolute host directory path"} assert
  fs.core.directory 0 root path 3 pack port.open) 'host-body defp

 ### defp lock-body
 (root path -- lock : "Keep admission while waiting for an advisory lock.")
 (checked-unary 1 rollup 3 pack fs.core.lock swap port.open) 'lock-body defp

 ### defp write-step
 (writer payload offset -- writer payload offset : "Send at most 65536 exact bytes.")
 (|writer payload offset|
  writer fs.core.write-chunk payload payload len offset - 65536 min range offset + at wrap
  port.call pop writer payload offset 65536 +) 'write-step defp

 ### defp write-stream
 (writer payload -- value : "Send a complete payload and explicitly commit.")
 (0 (over len over >) (write-step) while
  (|writer payload offset| writer fs.core.commit-file [] port.call) call) 'write-stream defp

 ### defp write-validated
 (payload root path mode -- value : "Own private storage through publication or rollback.")
 (|payload root path mode|
  fs.core.writer mode root path payload len 4 pack port.open
  dup payload pair (write-stream) @attempt swap port.close result.or-raise first)
 'write-validated defp

 ### defp write-bytes-body
 (payload root path mode -- value : "Validate bytes before root admission.")
 (|payload root path mode|
  root path checked-unary pop pop payload checked-bytes root path mode write-validated)
 'write-bytes-body defp

 ### defp write-text-body
 (payload root path mode -- value : "Encode UTF-8 before root admission.")
 (|payload root path mode|
  root path checked-unary pop pop
  payload fs.core.string-value {'kind 'type 'msg "expected a string to write"} assert
  payload bytes root path mode write-validated) 'write-text-body defp

 ### defp pair-body
 (source-root source-path destination-root destination-path mode -- value :
  "Join copy or rename cleanup.")
 (|source-root source-path destination-root destination-path mode|
  destination-root destination-path checked-unary pop pop
  source-root source-path checked-unary pop pop
  fs.core.pair-request mode source-root source-path destination-root destination-path 5 pack
  port.open
  dup wrap (fs.core.execute-pair [] port.call) @attempt swap port.close result.or-raise first)
 'pair-body defp

 ### defp copy-body
 (source-root source-path destination-root destination-path -- value : "Copy under one admission.")
 ('copy pair-body) 'copy-body defp

 ### defp rename-body
 (root source-path destination-path -- value : "Rename within one root.")
 (|root source-path destination-path|
  destination-path fs.core.string-value {'kind 'type 'msg "expected a string destination path"}
  assert
  root source-path checked-unary pop pop root source-path root destination-path 'rename pair-body)
 'rename-body defp

 ### defp run-port
 (resource operation public quotation -- value : "Preserve public resource-operation attribution.")
 (|resource operation public quotation|
  resource wrap quotation @attempt operation public {} 4 pack finish) 'run-port defp

 ### defp writer-named
 (root path -- writer : "Open an absent-file writer beneath a configured root.")
 (|root path| fs.core.writer 'create root path 3 pack port.open) 'writer-named defp

 ### defp writer-resource
 (root path -- writer : "Attach a streaming writer to its staging lifetime.")
 (|root path| root fs.core.derive-writer 'create root path 3 pack 3 pack (port.call) @attempt
  admitted) 'writer-resource defp

 ### defp writer-body
 (root path -- writer : "Create private storage for an absent file.")
 (checked-unary canonical dup "." match? not
  {'kind 'domain 'msg "expected a relative entry path" 'data {'reason 'invalid-path}} assert
  over type 'symbol match? (writer-named) (writer-resource) if) 'writer-body defp

 ### defp reserve-body
 (root path -- reservation : "Retain one root and admission for a filesystem composition.")
 (checked-unary 1 rollup 3 pack fs.core.reservation swap port.open) 'reserve-body defp

 ### defp chunk-body
 (payload writer path -- value : "Validate and append one bounded byte chunk.")
 (|payload writer path| payload checked-bytes pop writer fs.core.write-chunk payload wrap port.call)
 'chunk-body defp

 ### def stat
 (root path -- value : "Perform confined filesystem stat with structured errors.")
 (|root path| root path 'stat 'fs.stat ('stat request) run-unary) 'stat def

 ### def lstat
 (root path -- value : "Perform confined filesystem lstat with structured errors.")
 (|root path| root path 'lstat 'fs.lstat ('lstat request) run-unary) 'lstat def

 ### def exists?
 (root path -- value : "Perform confined filesystem exists? with structured errors.")
 (|root path| root path 'exists? 'fs.exists? ('exists request) run-unary) 'exists? def

 ### def mkdir
 (root path -- : "Perform confined filesystem mkdir with structured errors.")
 (|root path| root path 'mkdir 'fs.mkdir ('mkdir request) run-unary pop) 'mkdir def

 ### def mkdirs
 (root path -- : "Perform confined filesystem mkdirs with structured errors.")
 (|root path| root path 'mkdirs 'fs.mkdirs ('mkdirs request) run-unary pop) 'mkdirs def

 ### def remove-file
 (root path -- : "Perform confined filesystem remove-file with structured errors.")
 (|root path| root path 'remove-file 'fs.remove-file ('remove_file request) run-unary pop)
 'remove-file def

 ### def remove-dir
 (root path -- : "Perform confined filesystem remove-dir with structured errors.")
 (|root path| root path 'remove-dir 'fs.remove-dir ('remove_dir request) run-unary pop) 'remove-dir
 def

 ### def remove-tree
 (root path -- : "Perform confined filesystem remove-tree with structured errors.")
 (|root path| root path 'remove-tree 'fs.remove-tree ('remove_tree request) run-unary pop)
 'remove-tree def

 ### def read-bytes
 (root path -- bytes : "Perform confined filesystem read-bytes through scope-owned resources.")
 (|root path| root path 'read-bytes 'fs.read-bytes (read-body dup empty? (pop "" bytes) () if)
  run-unary) 'read-bytes def

 ### def read-text
 (root path -- string : "Perform confined filesystem read-text through scope-owned resources.")
 (|root path| root path 'read-text 'fs.read-text (read-text-body) run-unary) 'read-text def

 ### def list
 (root path -- entries : "Perform confined filesystem list through scope-owned resources.")
 (|root path| root path 'list 'fs.list (list-body) run-unary) 'list def

 ### def child-dir
 (root path -- directory : "Perform confined filesystem child-dir through scope-owned resources.")
 (|root path| root path 'child-dir 'fs.child-dir (child-body) run-unary) 'child-dir def

 ### def stage-dir
 (root path -- stage : "Perform confined filesystem stage-dir through scope-owned resources.")
 (|root path| root path 'stage-dir 'fs.stage-dir (stage-body) run-unary) 'stage-dir def

 ### def open-list
 (root path -- cursor : "Perform confined filesystem open-list through scope-owned resources.")
 (|root path| root path 'open-list 'fs.open-list (cursor-body) run-unary) 'open-list def

 ### def lock
 (root path -- lock : "Perform confined filesystem lock through scope-owned resources.")
 (|root path| root path 'lock 'fs.lock (lock-body) run-unary) 'lock def

 ### def open-writer
 (root path -- writer : "Perform confined filesystem open-writer through scope-owned resources.")
 (|root path| root path 'open-writer 'fs.open-writer (writer-body) run-unary) 'open-writer def

 ### def create-bytes
 (payload root path -- : "Atomically create a complete file from bytes.")
 (|payload root path|
  payload root path 'create-bytes 'fs.create-bytes ('create write-bytes-body) run-write pop)
 'create-bytes def

 ### def create-text
 (payload root path -- : "Atomically create a complete file from text.")
 (|payload root path|
  payload root path 'create-text 'fs.create-text ('create write-text-body) run-write pop)
 'create-text def

 ### def replace-bytes
 (payload root path -- : "Atomically replace a complete file from bytes.")
 (|payload root path|
  payload root path 'replace-bytes 'fs.replace-bytes ('replace write-bytes-body) run-write pop)
 'replace-bytes def

 ### def replace-text
 (payload root path -- : "Atomically replace a complete file from text.")
 (|payload root path|
  payload root path 'replace-text 'fs.replace-text ('replace write-text-body) run-write pop)
 'replace-text def

 ### def publish-bytes
 (payload root path -- : "Atomically publish a complete file from bytes.")
 (|payload root path|
  payload root path 'publish-bytes 'fs.publish-bytes ('publish write-bytes-body) run-write pop)
 'publish-bytes def

 ### def publish-text
 (payload root path -- : "Atomically publish a complete file from text.")
 (|payload root path|
  payload root path 'publish-text 'fs.publish-text ('publish write-text-body) run-write pop)
 'publish-text def

 ### def open-dir
 (host-path -- directory : "Open an absolute host directory as a scope-owned resource.")
 (|host-path| 'host host-path 'open-dir 'fs.open-dir (host-body) run-unary) 'open-dir def

 ### def next-entry
 (cursor -- entry : "Read one name/kind dictionary, or an empty dictionary at end.")
 ('next-entry 'fs.next-entry (fs.core.next-entry [] port.call) run-port) 'next-entry def

 ### def commit-dir
 (stage -- : "Seal, publish an absent destination, and join staging cleanup.")
 (|stage|
  stage 'commit-dir 'fs.commit-dir (fs.core.commit-directory [] port.call) run-port pop
  stage port.close) 'commit-dir def

 ### def copy
 (source-root source-path destination-root destination-path -- :
  "Copy a regular file to an absent destination.")
 (|source-root source-path destination-root destination-path|
  source-root source-path destination-root destination-path 4 pack (copy-body) @attempt 'copy
  'fs.copy
  'source-root source-root 'source-path source-path 'destination-root destination-root
  'destination-path destination-path 8 pack dict.from-flat 4 pack finish pop) 'copy def

 ### def rename
 (root source-path destination-path -- : "Rename an entry within one root without replacement.")
 (|root source-path destination-path|
  root source-path destination-path 3 pack (rename-body) @attempt 'rename 'fs.rename
  'root root 'path source-path 4 pack dict.from-flat 4 pack finish pop) 'rename def

 ### def reserve
 (root -- reservation :
  "Retain a selected root and one filesystem admission through a composition.")
 (|root| root "." 'reserve 'fs.reserve (reserve-body) run-unary) 'reserve def

 ### def write-chunk
 (writer bytes -- : "Append at most 65536 bytes; the transfer limit covers the complete stream.")
 (|writer payload| payload writer "." 'write-chunk 'fs.write-chunk (chunk-body) run-write pop)
 'write-chunk def

 ### def commit-file
 (writer -- : "Seal and publish a completed streaming file, then join its cleanup.")
 (|writer|
  writer 'commit-file 'fs.commit-file (fs.core.commit-file [] port.call) run-port pop
  writer port.close) 'commit-file def
) 'fs @defm
