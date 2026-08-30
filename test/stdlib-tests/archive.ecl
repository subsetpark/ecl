### module stdlib.test.archive
(
 'stdlib.test.support ('equal 'raises-word 'documented) import

 ### defp raises-at-index
 (quotation kind index -- : "Assert an archive byte failure identifies its item index.")
 (|quotation kind index|
  quotation @attempt
  dup result.err? 1 equal
  'err at
  dup 'kind at kind equal
  'data at 'index at index equal)
 'raises-at-index defp

 ### test sha256
 (-- : "Match SHA-256 known-answer vectors, including high unsigned bytes.")
 ([] archive.sha256
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  equal
  [97 98 99] archive.sha256
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  equal
  [97 98 99 100 98 99 100 101 99 100 101 102 100 101 102 103
   101 102 103 104 102 103 104 105 103 104 105 106 104 105 106 107
   105 106 107 108 106 107 108 109 107 108 109 110 108 109 110 111
   109 110 111 112 110 111 112 113]
  archive.sha256
  "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
  equal
  [0 127 128 255] archive.sha256
  "89273d2f70b93285bb7ddb4bcee86a5347ca7159352e3cbdd20c23e9d1e507d3"
  equal)
 'sha256 test

 ### test invalid-bytes
 (-- : "Reject non-byte containers and identify the first invalid byte.")
 ((42 archive.sha256) 'type 'archive.sha256 raises-word
  ([0 -1] archive.sha256) 'domain 1 raises-at-index
  ([255 256] archive.sha256) 'domain 1 raises-at-index
  ([0 1.5] archive.sha256) 'domain 1 raises-at-index)
 'invalid-bytes test

 ### test documentation
 (-- : "Require documentation for every archive export.")
 (('archive.sha256 'archive.unpack-tgz) documented)
 'documentation test
) 'stdlib.test.archive @defm
