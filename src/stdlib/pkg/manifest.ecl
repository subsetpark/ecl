### module pkg.manifest
# Validate and read package manifests.
(
 ### defp manifest-keys
 # Required manifest keys.
 ['format 'name 'version 'requires]
 'manifest-keys setp

 ### defp requirement-keys
 # Required package-requirement keys.
 ['version 'url 'hash]
 'requirement-keys setp

 ### def validate-requirement
 (requirement -- requirement : "Validate and return a package requirement.")
 (|requirement|
  requirement type 'dict match?
  'type error.new "a requirement is a dict" error.with-message assert
  requirement requirement-keys dict.keys-exactly?
  'domain error.new "a requirement has exactly the keys 'version 'url 'hash" error.with-message
  assert
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
  'domain error.new "a manifest has exactly the keys 'format 'name 'version 'requires"
  error.with-message
  assert
  candidate 'format at 1 match?
  'domain error.new "the only manifest format is 1" error.with-message assert
  candidate 'name at pkg.name.valid?
  'domain error.new "a package name is dot-joined lowercase segments" error.with-message assert
  candidate 'version at pkg.version.validate pop
  candidate 'requires at type 'dict match?
  'type error.new "manifest requirements are a dict from package name to requirement"
  error.with-message assert
  candidate 'requires at dict.keys (pkg.name.valid?) all?
  'domain error.new "a package name is dot-joined lowercase segments" error.with-message assert
  candidate 'requires at dict.vals (pkg.manifest.validate-requirement pop) for
  candidate 'name at wrap candidate 'requires at dict.keys cat pkg.name.collides? not
  'domain error.new "no package may own another's name, its own included" error.with-message assert
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
   requirement 'version at str
   requirement 'url at str
   requirement 'hash at str)
  infra
  "{{'version {} 'url {} 'hash {}}}" str.format)
 'render-requirement defp

 ### defp render-requirement-entry
 (pair -- text : "Render one manifest requirement while retaining dictionary order.")
 (wrap ((first str) (1 at render-requirement) bi) infra "{} {}" str.format)
 'render-requirement-entry defp

 ### defp render-requirements
 (requirements -- text : "Render manifest requirements in their retained insertion order.")
 (dict.pairs (render-requirement-entry) each " " join wrap "{{{}}}" str.format)
 'render-requirements defp

 ### def write
 (manifest -- text :
  "Validate and render a manifest, retaining requirement insertion order and ending in newline.")
 (pkg.manifest.validate
  wrap
  (|manifest|
   manifest 'name at str
   manifest 'version at str
   manifest 'requires at render-requirements)
  infra
  "{{'format 1 'name {} 'version {} 'requires {}}}\n" str.format)
 'write def
 ) 'pkg.manifest @defm
