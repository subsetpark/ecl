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
 (|requirement|
  requirement type 'dict match?
  {'kind 'type 'msg "a requirement is a dict"} assert
  requirement requirement-keys keys-exactly?
  {'kind 'domain 'msg "a requirement has exactly the keys 'version 'url 'hash"} assert
  requirement 'version at pkg.version.validate pop
  requirement 'url at pkg.name.url?
  {'kind 'domain 'msg "a requirement url is an https url"} assert
  requirement 'hash at pkg.name.hash?
  {'kind 'domain 'msg "a requirement hash is sha256- and 64 lowercase hex digits"} assert
  requirement)
 (requirement -- requirement : "Validate and return a package requirement.")
 'validate-requirement def

 ### def validate
 (|candidate|
  candidate type 'dict match?
  {'kind 'type 'msg "a manifest is a dict"} assert
  candidate pairs (pkg.data.assert-inert-entry) for
  candidate manifest-keys keys-exactly?
  {'kind 'domain
   'msg "a manifest has exactly the keys 'format 'name 'version 'requires"}
  assert
  candidate 'format at 1 match?
  {'kind 'domain 'msg "the only manifest format is 1"} assert
  candidate 'name at pkg.name.valid?
  {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
  candidate 'version at pkg.version.validate pop
  candidate 'requires at type 'dict match?
  {'kind 'type 'msg "manifest requirements are a dict from package name to requirement"} assert
  candidate 'requires at keys (pkg.name.valid?) all?
  {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
  candidate 'requires at vals (pkg.manifest.validate-requirement pop) for
  candidate 'name at wrap candidate 'requires at keys cat pkg.name.collides? not
  {'kind 'domain 'msg "no package may own another's name, its own included"} assert
  candidate)
 (candidate -- manifest :
  "Validate and return a manifest. Executable word values are rejected before structural checks.")
 'validate def

 ### def read
 (pkg.data.read-one pkg.manifest.validate)
 (text -- manifest : "Parse and validate a manifest without evaluating it.")
 'read def
 )
'pkg.manifest
@defm
