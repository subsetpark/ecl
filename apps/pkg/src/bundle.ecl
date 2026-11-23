### module pkg.bundle
# Source-only package policy over the shared hostile-input archive parser.
(
 ### defp require
 (condition -- : "Reject malformed or oversized source packages.")
 (`domain error.new "invalid source package archive" error.with-message assert) `require defp

 ### defp contents
 (member maximum -- bytes : "Return one member's contents within an application-owned limit.")
 (|member maximum| member `bytes at dup len maximum <= require) `contents defp

 ### defp member-policy
 (member -- : "Reject native artifacts and reserve package control-file names.")
 (|member|
  member `path at ".eclmod" str.ends? not require
  member `path at ".ecl-package.tgz" match? not require
  member `path at ".ecl-package.catalog" match? not require
  member `path at "ecl.pkg" match?
  member (`kind at `file match? require) cons when) `member-policy defp

 ### defp manifest-member
 (state member -- state : "Bound the package's members and keep the single root manifest.")
 (|state member|
  member member-policy
  state `count at 1 + dup 100000 <= require
  state swap `count swap put
  member `bytes at len state `size at + dup 67108864 <= require
  `size swap put
  member `path at "ecl.pkg" match?
  member (read-manifest) cons
  () if) `manifest-member defp

 ### defp read-manifest
 (state member -- state : "The root manifest must be a regular UTF-8 file.")
 (|state member|
  state `manifest at empty? require
  member 16777216 contents chars pkg.manifest.read
  wrap state swap `manifest swap put) `read-manifest defp

 ### defp scan-manifest
 (members -- manifest : "Find and validate one root manifest without executing package source.")
 ({} `manifest [] put `size 0 put `count 0 put (manifest-member) fold
  `manifest at dup len 1 = require first) `scan-manifest defp

 ### defp selected?
 (member manifest -- bool : "Select only regular source files matched by the manifest's globs.")
 (|member manifest|
  member `kind at `file match?
  manifest `sources at member `path at (pkg.glob.matches?) cons any? and) `selected? defp

 ### defp source-artifact
 (state member -- state :
  "Inspect one selected source without evaluation; every module it declares is an export the package
   owns.")
 (|state member|
  state `artifacts at len 4096 < require
  member 16777216 contents chars parse source.declarations (chars) each
  dup state `manifest at `name at (swap pkg.name.owns?) cons all? require
  state member record-artifact) `source-artifact defp

 ### defp record-artifact
 (exports state member -- state : "Retain one explicit ECL artifact mapping.")
 (|exports state member|
  state `artifacts state `artifacts at
  {kind ecl} `path member `path at put `exports exports put append put)
 `record-artifact defp

 ### defp inspect-member
 (state member -- state : "Inspect selected files and skip ordinary data members.")
 (|state member|
  state member member state `manifest at selected?
  (source-artifact) (pop) if) `inspect-member defp

 ### defp scan-sources
 (members manifest -- artifacts :
  "Materialize the sealed package's explicit source-to-module mappings.")
 (|members manifest|
  members {} `manifest manifest put `artifacts [] put (inspect-member) fold
  `artifacts at dup len 4096 <= require
  dup (`exports at) each raze dup distinct len swap len = require)
 `scan-sources defp

 ### def inspect
 (bytes -- bundle :
  "Validate a source-only archive and return its manifest and explicit artifact table.")
 (268435456 gzip.decompress-within tar.read dup scan-manifest
  (|members manifest| members manifest scan-sources manifest inspected) apply) `inspect def

 ### defp inspected
 (artifacts manifest -- bundle : "Return validated package metadata without retaining source code.")
 (|artifacts manifest| {} `manifest manifest put `artifacts artifacts put) `inspected defp
) `pkg.bundle @defm
