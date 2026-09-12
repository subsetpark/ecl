### module pkg.generation
# Immutable project installations built through ordinary directory resources.
[]
(
 ### defp active-value
 (project -- generation : "Read the optional active generation as inert application data.")
 ('directory at "ecl.modules" fs.read-text pkg.layout.from-reference) 'active-value defp

 ### defp optional-active
 (result -- generation : "Ignore missing or malformed previous state when building a replacement.")
 (dup result.ok? ('ok at first)
  ('err at dup 'kind at ['io 'domain 'syntax 'type 'shape 'parse] swap (match?) partial any?
   (pop "") (raise) if) if) 'optional-active defp

 ### def active
 (project -- generation : "Capture the previous generation once; startup repair is never required.")
 (wrap (active-value) @attempt optional-active) 'active def

 ### def start
 (project location offline -- work : "Own a private candidate and its exact-download pins.")
 (|project location offline|
  location pkg.layout.generation?
  'domain error.new "invalid generation destination" error.with-message assert
  project 'directory at location path.dirname fs.mkdirs
  project 'directory at location fs.stage-dir
  project location offline 3 pack (started) with call) 'start def

 ### defp started
 (stage project location offline -- work :
  "Create the private generation's controlled directories.")
 (|stage project location offline|
  stage "downloads" fs.mkdirs stage "archives" fs.mkdirs stage "packages" fs.mkdirs
  {} 'downloads stage "downloads" fs.child-dir put
  'project project 'directory at put 'active project active put
  'cache pkg.project.cache-path put 'offline offline put
  {} swap 'context swap put 'stage stage put 'project project put 'location location put) 'started
 defp

 ### defp install
 (state name -- state :
  "Validate and install one selected package without retaining archive payloads.")
 (|state name|
  state 'work at 'context at state 'lock at 'packages at name at pkg.obtain.requirement
  state name pair (install-bytes) with call) 'install defp

 ### defp install-bytes
 (bytes state name -- state : "Seal the exact source bytes and unpack only a validated package.")
 (|bytes state name|
  bytes pkg.bundle.inspect
  state name bytes 3 pack (install-bundle) with call) 'install-bytes defp

 ### defp install-bundle
 (bundle state name bytes -- state :
  "Record inspected exports after a successful confined extraction.")
 (|bundle state name bytes|
  state 'lock at bundle 'manifest at pkg.resolution.check-manifest
  bytes state ['work 'stage] at-path
  "archives/" state 'lock at 'packages at name at 'hash at pkg.cache.filename cat fs.create-bytes
  bytes state ['work 'stage] at-path "packages/" name cat archive.unpack-tgz pop
  state 'bundles state 'bundles at name bundle put put) 'install-bundle defp

 ### def finish
 (work manifest-text lock-text -- :
  "Validate and publish a complete immutable generation before activation.")
 (|work manifest-text lock-text|
  lock-text pkg.resolution.read manifest-text pkg.manifest.read pkg.resolution.compatible
  {} swap 'lock swap put 'work work put 'bundles {} put
  dup 'lock at 'packages at dict.keys sort swap (install) fold
  'bundles at work manifest-text lock-text 3 pack (publish) with call) 'finish def

 ### defp publish
 (bundles work manifest-text lock-text -- :
  "Write snapshots and validate the eventual map before directory publication.")
 (|bundles work manifest-text lock-text|
  manifest-text pkg.manifest.read lock-text pkg.resolution.read bundles
  work 'location at pkg.layout.local-root pkg.map.build
  dup work 'project at 'path at work 'location at "/ecl.modules" cat pair path.join pkg.map.validate
  str "\n" cat work 'stage at "ecl.modules" fs.create-text
  manifest-text work 'stage at "ecl.pkg" fs.create-text
  lock-text work 'stage at "ecl.lock" fs.create-text
  work ['context 'downloads] at-path port.close
  work 'stage at "downloads" fs.remove-tree
  work 'stage at fs.commit-dir) 'publish defp
) 'pkg.generation @defm
