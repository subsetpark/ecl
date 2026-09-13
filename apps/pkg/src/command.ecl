### module pkg.command
# The installed application's command-line interface uses only public ECL APIs.
[]
(
 ### defp require
 (condition -- : "Reject unsupported package command arguments.")
 ('domain error.new
  "usage: ecl pkg init [name] | add <name> <version> <https-url> | add <https-git-url> --tag|--commit <revision> | sync|update|vendor [--offline] | verify | tree | why <module> | gc <retained-lock>..."
  error.with-message assert) 'require defp

 ### defp offline
 (arguments -- bool : "Recognize the single optional offline flag.")
 (dup len 1 <= require dup empty? (pop 0)
  (first "--offline" match? dup require) if) 'offline defp

 ### defp project-close
 (project -- : "Release the application-owned project directory.")
 ('directory at port.close) 'project-close defp

 ### defp read-lock
 (project -- lock : "Read portable project resolution independently of the active runtime map.")
 ('directory at "ecl.lock" fs.read-text pkg.resolution.read) 'read-lock defp

 ### defp synchronize
 (arguments update vendor -- :
  "Run explicitly selected resolution policy and publish an immutable generation.")
 (|arguments update vendor|
  arguments offline pkg.project.find
  update vendor pair (synchronize-project) with call) 'synchronize defp

 ### defp synchronize-project
 (offline project update vendor -- :
  "Coordinate generation publication while preserving caller process context.")
 (|offline project update vendor|
  vendor project (read-lock pop) partial when
  project update offline vendor pkg.install.synchronize
  project read-lock 'packages at dict.size wrap "synced {} packages" str.format io.print
  project project-close) 'synchronize-project defp

 ### defp sync
 (arguments -- : "Honor the portable root lock.")
 (0 0 synchronize) 'sync defp

 ### defp update
 (arguments -- : "Explicitly resolve the manifest's dependency graph again.")
 (1 0 synchronize) 'update defp

 ### defp vendor
 (arguments -- : "Publish an equivalent self-contained generation beneath vendor/.")
 (0 1 synchronize) 'vendor defp

 ### defp init
 (arguments -- : "Initialize an ordinary local-source project and portable empty lock.")
 (dup len 1 <= require dup empty? (pop host.cwd path.basename) (first) if
  dup pkg.name.valid? require
  {} 'path host.cwd put 'directory host.cwd fs.open-dir put
  (|name project|
   project pkg.project.lock name project initialize port.close project project-close) call) 'init
 defp

 ### defp absent
 (path directory -- : "Never overwrite pre-existing project state during initialization.")
 (swap fs.exists? not 'domain error.new "pkg init requires absent project state files"
  error.with-message assert)
 'absent defp

 ### defp initialize
 (name project -- : "Validate the local map before publishing initial project state.")
 (|name project|
  ["ecl.pkg" "ecl.lock" "ecl.modules"] project 'directory at (absent) partial for
  project 'directory at "src" fs.mkdirs
  {'format 2 'version "0.1.0" 'sources ["src/**/*.ecl"] 'exports [] 'requires {}} 'name name put
  project (initialize-manifest) partial call) 'initialize defp

 ### defp initialize-manifest
 (manifest project -- :
  "Create manifest, lock, and usable local-source map without package bootstrap.")
 (|manifest project|
  manifest {} pkg.solver.resolve
  manifest project pair (initialize-lock) with call) 'initialize-manifest defp

 ### defp initialize-lock
 (lock manifest project -- :
  "Publish the initial inert map only after validating it at the root document path.")
 (|lock manifest project|
  manifest lock {} "." pkg.map.build
  dup project 'path at "ecl.modules" pair path.join pkg.map.validate
  manifest pkg.manifest.write project 'directory at "ecl.pkg" fs.create-text
  lock pkg.resolution.write project 'directory at "ecl.lock" fs.create-text
  str "\n" cat project 'directory at "ecl.modules" fs.create-text
  manifest 'name at wrap "initialized ecl.pkg for {}" str.format io.print) 'initialize-lock defp

 ### defp tree
 (arguments -- : "Show selected dependency edges from the portable root lock.")
 (empty? require pkg.project.find dup read-lock pkg.report.tree io.prin project-close) 'tree defp

 ### defp why
 (arguments -- : "Explain one selected module owner.")
 (dup len 1 = require first pkg.project.find
  (|module project| project read-lock module pkg.report.why io.prin project project-close) call)
 'why defp

 ### defp verify
 (arguments -- : "Verify the active generation without recovery or other writes.")
 (empty? require pkg.project.find dup pkg.install.verify
  "verified active generation" io.print project-close) 'verify defp

 ### defp gc
 (arguments -- : "Collect only unretained shared downloads, never project generations.")
 (pkg.gc.run wrap "removed {} cached archives" str.format io.print) 'gc defp

 ### defp archive-requirement
 (arguments -- requirement bytes :
  "Fetch an explicitly declared archive and validate its claimed identity.")
 (|arguments|
  arguments first pkg.name.valid? require arguments 1 at pkg.version.validate pop
  arguments 2 at pkg.fetch.archive
  arguments (archive-bytes) partial call) 'archive-requirement defp

 ### defp archive-bytes
 (bytes arguments -- requirement bytes :
  "Hash only a validated source package with the requested name and version.")
 (|bytes arguments|
  bytes pkg.bundle.inspect 'manifest at
  dup 'name at arguments first match? require 'version at arguments 1 at match? require
  {} 'package arguments first put 'version arguments 1 at put
  'source {'kind 'archive} 'url arguments 2 at put put 'hash bytes pkg.fetch.hash put bytes)
 'archive-bytes defp

 ### defp git-requirement
 (arguments -- requirement bytes :
  "Resolve an explicit Git selector and obtain identity from the source manifest.")
 (|arguments|
  arguments 1 at ["--tag" "--commit"] swap (match?) partial any? require
  arguments first arguments 1 at "--tag" match? ('tag) ('commit) if arguments 2 at pkg.fetch.git
  arguments first (git-snapshot) partial call) 'git-requirement defp

 ### defp git-snapshot
 (snapshot url -- requirement bytes :
  "Record both the resolved full commit and deterministic archive hash.")
 (|snapshot url|
  snapshot 1 at pkg.bundle.inspect 'manifest at ['name 'version] dict.take
  'package over 'name at put 'name del
  'source {'kind 'git} 'url url put 'commit snapshot first put put
  'hash snapshot 1 at pkg.fetch.hash put snapshot 1 at) 'git-snapshot defp

 ### defp add
 (arguments -- :
  "Explicitly edit the manifest; a changed dependency graph then requires pkg update.")
 (dup len 3 = require pkg.project.find
  (|arguments project|
   project pkg.project.lock project pkg.install.recover
   arguments first pkg.name.url?
   arguments (git-requirement) partial arguments (archive-requirement) partial if
   project (record) partial call port.close project project-close) call) 'add defp

 ### defp record
 (requirement bytes project -- :
  "Cache validated bytes and atomically publish one manifest dependency edit.")
 (|requirement bytes project|
  requirement pkg.manifest.validate-requirement pop
  pkg.project.cache-path requirement 'hash at bytes pkg.cache.write
  project pkg.project.manifest
  'requires over 'requires at requirement 'package at requirement put put
  pkg.manifest.write project 'directory at "ecl.pkg" fs.publish-text
  requirement 'package at requirement 'version at pair "added {} {}; run pkg update to resolve"
  str.format io.print)
 'record defp

 ### def main
 (arguments -- :
  "Dispatch an installed package application command independently of project loading.")
 (dup empty? not require
  dup first
  {"init" (init) "add" (add) "sync" (sync) "update" (update) "vendor" (vendor)
   "verify" (verify) "tree" (tree) "why" (why) "gc" (gc)}
  (|arguments command commands|
   commands command dict.has? require arguments 1 drop commands command at call) call) 'main def
) 'pkg.command @defm
