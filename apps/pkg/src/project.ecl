### module pkg.project
# Application-owned project discovery and coordination over public directories.
[]
(
 ### defp missing-environment
 (error -- value : "Default only the documented absent-environment case.")
 (dup 'kind at 'io match?
  (pop "") (raise) if) 'missing-environment defp

 ### def environment
 (name -- value : "Read an optional startup environment setting; empty means absent.")
 (wrap (getenv) @attempt dup result.ok?
  ('ok at first) ('err at missing-environment) if) 'environment def

 ### def absolute
 (path -- path : "Resolve a user path against the caller's captured working directory.")
 (dup path.absolute? () (host.cwd swap pair path.join) if path.normalize) 'absolute def

 ### defp found
 (path directory -- project : "Retain the discovered directory and its explicit host path.")
 (|path directory| {} 'path path put 'directory directory put) 'found defp

 ### defp parent
 (path directory -- project : "Release one discovery handle before inspecting its parent.")
 (port.close dup path.dirname
  over over match? not
  'io error.new "cannot find ecl.pkg in this directory or its parents" error.with-message assert
  nip find-at) 'parent defp

 ### def find-at
 (path -- project : "Find the nearest project manifest without consulting locks or maps.")
 (absolute dup fs.open-dir
  dup "ecl.pkg" fs.exists?
  (found) (parent) if) 'find-at def

 ### def find
 (-- project : "Discover the caller's project independently of runtime module resolution.")
 (host.cwd find-at) 'find def

 ### def manifest
 (project -- manifest : "Read the root project manifest as inert data.")
 ('directory at "ecl.pkg" fs.read-text pkg.manifest.read) 'manifest def

 ### def lock
 (project -- resource :
  "Acquire the application's project mutation lock with joined scope ownership.")
 ('directory at dup ".ecl" fs.mkdirs ".ecl/mutation.lock" fs.lock) 'lock def

 ### defp cache-xdg
 (-- path : "Select the conventional user cache fallback.")
 ("XDG_CACHE_HOME" environment dup empty?
  (pop "HOME" environment dup empty? () ("/.cache/ecl/pkg" cat) if)
  ("/ecl/pkg" cat) if) 'cache-xdg defp

 ### def cache-path
 (-- path : "Choose a shared download-cache path; an empty result disables this optimization.")
 ("ECL_CACHE" environment dup empty? (pop cache-xdg) when
  dup empty? not (absolute) when) 'cache-path def

 ### def open-created
 (path -- directory :
  "Create an explicitly selected absolute directory through confined operations.")
 (absolute "/" fs.open-dir
  (|path root| root path 1 drop dup empty? (pop ".") when fs.mkdirs root port.close
   path fs.open-dir) call) 'open-created def

 ### def generation-id
 (-- identifier :
  "Create a collision-resistant local generation name independent of portable locks.")
 (rand.entropy rand.entropy rand.entropy rand.entropy 4 pack str bytes archive.sha256)
 'generation-id def

 ### def temporary
 (-- path : "Select the caller's explicit temporary directory or the system convention.")
 ("TMPDIR" environment dup empty? (pop "/tmp") when absolute) 'temporary def
) 'pkg.project @defm
