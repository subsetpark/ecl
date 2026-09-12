### module pkg.bundle
# Source-only package policy over the shared hostile-input archive parser.
[]
(
 ### defp require
 (condition -- : "Reject malformed or oversized source packages.")
 ('domain error.new "invalid source package archive" error.with-message assert) 'require defp

 ### defp read-step
 (archive maximum chunks size chunk -- archive maximum chunks size chunk :
  "Collect one bounded member chunk.")
 (|archive maximum chunks size chunk|
  archive maximum chunks chunk append size chunk len +
  dup maximum <= require archive 65536 archive.read-member) 'read-step defp

 ### defp contents
 (archive maximum -- bytes : "Read a member incrementally within an application-owned limit.")
 (|archive maximum|
  archive maximum [] 0 archive 65536 archive.read-member
  (dup empty? not) (read-step) while pop pop rollup pop pop raze) 'contents defp

 ### def member-bytes
 (archive maximum -- bytes : "Collect one package member through bounded shared-parser reads.")
 (contents) 'member-bytes def

 ### defp member-policy
 (metadata -- : "Reject native artifacts and reserve package control-file names.")
 (|metadata|
  metadata 'path at ".eclmod" str.ends? not require
  metadata 'path at ".ecl-package.tgz" match? not require
  metadata 'path at ".ecl-package.catalog" match? not require
  metadata 'path at "ecl.pkg" match?
  metadata ('kind at 'file match? require) partial when) 'member-policy defp

 ### defp manifest-member
 (state metadata -- state :
  "Read the single root manifest while retaining bounded archive metadata.")
 (|state metadata|
  metadata member-policy
  state 'count at 1 + dup 100000 <= require
  state swap 'count swap put
  metadata 'size at state 'size at + dup 67108864 <= require
  'size swap put
  metadata 'path at "ecl.pkg" match?
  state 'archive at (read-manifest) partial
  () if) 'manifest-member defp

 ### defp read-manifest
 (state archive -- state : "The root manifest must be a regular UTF-8 file.")
 (|state archive|
  state 'manifest at empty? require
  archive 16777216 contents chars pkg.manifest.read
  wrap state swap 'manifest swap put) 'read-manifest defp

 ### defp scan-manifest
 (archive -- manifest : "Find and validate one root manifest without executing package source.")
 (|archive|
  {} 'archive archive put 'manifest [] put 'size 0 put 'count 0 put
  archive archive.next-member
  (dup dict.size 0 >)
  (manifest-member dup 'archive at archive.next-member) while pop
  'manifest at dup len 1 = require first) 'scan-manifest defp

 ### defp selected?
 (metadata manifest -- bool : "Select only regular source files named by the manifest's globs.")
 (|metadata manifest|
  metadata 'kind at 'file match?
  manifest 'sources at metadata 'path at (pkg.glob.matches?) partial any? and) 'selected? defp

 ### defp exported?
 (declaration manifest -- bool : "Keep only module names explicitly exported by this package.")
 (|declaration manifest|
  manifest 'exports at declaration (match?) partial any?) 'exported? defp

 ### defp source-artifact
 (state metadata -- state :
  "Inspect one selected source without evaluation and retain its explicit exports.")
 (|state metadata|
  state 'artifacts at len 4096 < require
  state 'archive at 16777216 contents chars parse source.declarations (chars) each
  state 'manifest at (exported?) partial filter
  state metadata record-artifact) 'source-artifact defp

 ### defp record-artifact
 (exports state metadata -- state : "Retain one explicit ECL artifact mapping.")
 (|exports state metadata|
  state 'artifacts state 'artifacts at
  {'kind 'ecl} 'path metadata 'path at put 'exports exports put append put)
 'record-artifact defp

 ### defp inspect-member
 (state metadata -- state : "Inspect selected files and skip ordinary data members.")
 (|state metadata|
  state metadata metadata state 'manifest at selected?
  (source-artifact) (pop) if) 'inspect-member defp

 ### defp scan-sources
 (archive manifest -- artifacts :
  "Materialize the sealed package's explicit source-to-module mappings.")
 (|archive manifest|
  {} 'archive archive put 'manifest manifest put 'artifacts [] put
  archive archive.next-member
  (dup dict.size 0 >)
  (inspect-member dup 'archive at archive.next-member) while pop
  'artifacts at dup len 4096 <= require
  dup ('exports at) each raze dup distinct len swap len = require
  dup ('exports at) each raze sort manifest 'exports at sort match? require) 'scan-sources defp

 ### def inspect
 (bytes -- bundle :
  "Validate a source-only archive and return its manifest and explicit artifact table.")
 (dup archive.open-tgz dup scan-manifest swap port.close
  (|bytes manifest|
   bytes archive.open-tgz dup manifest scan-sources swap port.close
   manifest inspected)
  call) 'inspect def

 ### defp inspected
 (artifacts manifest -- bundle : "Return validated package metadata without retaining source code.")
 (|artifacts manifest| {} 'manifest manifest put 'artifacts artifacts put) 'inspected defp
) 'pkg.bundle @defm
