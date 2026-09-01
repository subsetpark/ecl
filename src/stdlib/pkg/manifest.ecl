### module pkg.manifest
# Validate and read package manifests.
[]
(
 ### defp manifest-keys
 # Required manifest keys.
 ['format 'name 'version 'exports 'requires]
 'manifest-keys setp

 ### defp requirement-keys
 # Required package-requirement keys.
 ['package 'version 'url 'hash]
 'requirement-keys setp

 ### defp glob-segment-valid?
 (segment -- bool : "Return 1 for one safe portable glob segment.")
 (|segment|
  segment len 0 >
  segment "." match? not and
  segment ".." match? not and
  segment dup "**" match?
  (pop 1)
  ("**" str.contains? not)
  if
  and)
 'glob-segment-valid? defp

 ### defp glob-valid?
 (candidate -- bool : "Return 1 for a nonempty portable package-relative glob.")
 (dup str.str?
  (|candidate|
   candidate len 0 >
   candidate "\\" str.contains? not and
   candidate "/" split (glob-segment-valid?) all? and)
  (pop 0)
  if)
 'glob-valid? defp

 ### defp export-globs-valid?
 (candidate -- bool : "Return 1 for a nonempty list of distinct portable globs.")
 (dup type 'list match?
  (|candidate|
   candidate empty? not
   candidate (glob-valid?) all? and
   candidate distinct len candidate len = and)
  (pop 0)
  if)
 'export-globs-valid? defp

 ### defp export-owned?
 (pair package -- bool : "Return 1 when one export namespace belongs to its package.")
 (|pair package| package pair first pkg.name.owns?)
 'export-owned? defp

 ### def validate-requirement
 (requirement -- requirement : "Validate and return a package requirement.")
 (|requirement|
  requirement type 'dict match?
  'type error.new "a requirement is a dict" error.with-message assert
  requirement requirement-keys dict.keys-exactly?
  'domain error.new "a requirement has exactly the keys 'package 'version 'url 'hash"
  error.with-message
  assert
  requirement 'package at pkg.name.valid?
  'domain error.new "a requirement package is a canonical package name" error.with-message assert
  requirement 'version at pkg.version.validate pop
  requirement 'url at pkg.name.url?
  'domain error.new "a requirement url is an https url" error.with-message assert
  requirement 'hash at pkg.name.hash?
  'domain error.new "a requirement hash is sha256- and 64 lowercase hex digits" error.with-message
  assert
  requirement)
 'validate-requirement def

 ### def validate
 (candidate -- manifest :
  "Validate and return a manifest. Executable word values are rejected before structural checks.")
 (|candidate|
  candidate type 'dict match?
  'type error.new "a manifest is a dict" error.with-message assert
  candidate dict.pairs (pkg.data.assert-inert-entry) for
  candidate manifest-keys dict.keys-exactly?
  'domain error.new "a manifest has exactly the keys 'format 'name 'version 'exports 'requires"
  error.with-message
  assert
  candidate 'format at 1 match?
  'domain error.new "the only manifest format is 1" error.with-message assert
  candidate 'name at pkg.name.valid?
  'domain error.new "a package name is dot-joined lowercase segments" error.with-message assert
  candidate 'version at pkg.version.validate pop
  candidate 'exports at type 'dict match?
  'type error.new "manifest exports are a dict from module namespace to glob list"
  error.with-message assert
  candidate 'exports at dict.keys (pkg.name.valid?) all?
  'domain error.new "an export namespace is a canonical module name" error.with-message assert
  candidate 'exports at dict.pairs candidate 'name at (export-owned?) partial all?
  'domain error.new "a package owns every namespace it exports" error.with-message assert
  candidate 'exports at dict.vals (export-globs-valid?) all?
  'domain error.new "manifest export values are nonempty distinct portable glob lists"
  error.with-message assert
  candidate 'requires at type 'dict match?
  'type error.new "manifest requirements are a dict from local alias to requirement"
  error.with-message assert
  candidate 'requires at dict.keys (pkg.name.valid?) all?
  'domain error.new "a package name is dot-joined lowercase segments" error.with-message assert
  candidate 'requires at dict.vals (pkg.manifest.validate-requirement pop) for
  candidate 'requires at dict.vals ('package at) each
  dup distinct len swap len =
  'domain error.new "a consumer requires a package under only one local alias" error.with-message
  assert
  candidate 'name at wrap candidate 'requires at dict.vals ('package at) each cat
  pkg.name.collides? not
  'domain error.new "no package may require itself or a package whose name it owns"
  error.with-message assert
  candidate)
 'validate def

 ### def read
 (text -- manifest : "Parse and validate a manifest without evaluating it.")
 (pkg.data.read-one pkg.manifest.validate)
 'read def

 ### defp render-requirement
 (requirement -- text : "Render one exact requirement in canonical field order.")
 (|requirement|
  requirement wrap
  (|requirement|
   requirement 'package at str
   requirement 'version at str
   requirement 'url at str
   requirement 'hash at str)
  infra
  "{{'package {} 'version {} 'url {} 'hash {}}}" str.format)
 'render-requirement defp

 ### defp render-requirement-entry
 (pair -- text : "Render one manifest requirement while retaining dictionary order.")
 (wrap ((first str) (1 at render-requirement) bi) infra "{} {}" str.format)
 'render-requirement-entry defp

 ### defp render-requirements
 (requirements -- text : "Render manifest requirements in their retained insertion order.")
 (dict.pairs (render-requirement-entry) each " " join wrap "{{{}}}" str.format)
 'render-requirements defp

 ### defp render-export-entry
 (pair -- text : "Render one export namespace and its glob list.")
 ((first str) (1 at str) bi 2 pack "{} {}" str.format)
 'render-export-entry defp

 ### defp render-exports
 (exports -- text : "Render exports in retained insertion order.")
 (dict.pairs (render-export-entry) each " " join wrap "{{{}}}" str.format)
 'render-exports defp

 ### def write
 (manifest -- text :
  "Validate and render a manifest, retaining requirement insertion order and ending in newline.")
 (pkg.manifest.validate
  wrap
  (|manifest|
   manifest 'name at str
   manifest 'version at str
   manifest 'exports at render-exports
   manifest 'requires at render-requirements)
  infra
  "{{'format 1 'name {} 'version {} 'exports {} 'requires {}}}\n" str.format)
 'write def
) 'pkg.manifest @defm
