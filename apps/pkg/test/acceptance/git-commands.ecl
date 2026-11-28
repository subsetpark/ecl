### module pkg.test.git-commands
(
 ### defp equal
 (actual expected -- : "Compare package behavior through public interfaces.")
 (match? {kind user msg "Git package command assertion failed"} assert) `equal defp

 ### defp forwarded
 (-- env : "Forward only the startup settings the installed application reads.")
 (["ECL_CACHE" "XDG_CACHE_HOME" "HOME" "TMPDIR" "ECL_GIT_CA_FILE" "ECL_PATH" "ECL_WORKERS"] {}
  (|acc name| acc name name pkg.project.environment dup empty? (pop pop) (put) if) fold)
 `forwarded defp

 ### defp invoke
 (arguments -- result : "Launch an installed application with the caller's real project state.")
 (|arguments| {timeout-ms 180000 stdout-limit 65536 stderr-limit 65536}
  `executable host.executable put `args arguments put `env forwarded put proc.run) `invoke defp

 ### defp command
 (arguments -- : "Require a successful installed package command.")
 (["pkg"] swap cat invoke dup `term at {kind exited code 0} match?
  swap str `user error.new swap error.with-message assert) `command defp

 ### defp seed-archive
 (-- : "Supply a pinned archive source independently of Git and the application resolver.")
 (args 4 at fs.open-dir "valid.tgz.hex" fs.read-text str.trim
  ("0123456789abcdef" swap find) each dup len 2 div 2 pair reshape
  (|pair| pair first 16 * pair 1 at +) each
  (|bytes| pkg.project.cache-path bytes pkg.fetch.hash bytes pkg.cache.write) apply) `seed-archive
 defp

 ### defp locked
 (-- lock : "Read the portable project lock through the application parser.")
 (`cwd "ecl.lock" fs.read-text pkg.resolution.read) `locked defp

 ### defp check-commit
 (commit -- : "Require an exact Git selection alongside an archive selection.")
 (locked [packages "alpha" source commit] at-path equal
  locked [packages "sample" source kind] at-path `archive equal) `check-commit defp

 ### defp runnable
 (answer -- : "Load the installed dependency in a new interpreter.")
 (str "alpha.answer " swap cat " = {kind user msg \"wrong active dependency\"} assert" cat
  ["-e"] swap wrap cat invoke `term at {kind exited code 0} equal) `runnable defp

 ### defp installed
 (-- text : "Read the installed dependency's source, which a failed command leaves unchanged.")
 (`cwd ".ecl/packages/alpha/src/alpha.ecl" fs.read-text) `installed defp

 ### defp initial
 (-- : "Resolve mixed sources explicitly; project modules never replace the application's.")
 (["init" "consumer"] command
  `cwd "ecl.lock" fs.read-text
  ["add"] args 1 at wrap cat ["--tag" "release"] cat command
  `cwd "ecl.lock" fs.read-text equal
  ["pkg" "sync" "--offline"] invoke `term at `code at 1 equal
  seed-archive ["update" "--offline"] command
  args 2 at check-commit 42 runnable
  `cwd "src/conflict.ecl" "((999) `answer def) `pkg.command @defm" fs.publish-text
  ["sync" "--offline"] command
  ["verify"] command
  args 2 at check-commit 42 runnable
  `cwd "ecl.lock" fs.read-text installed
  `cwd "ecl.lock" "corrupt lock" fs.publish-text
  ["pkg" "sync" "--offline"] invoke `term at `code at 1 equal
  installed equal
  ["update" "--offline"] command
  `cwd "ecl.lock" fs.read-text equal ["verify"] command)
 `initial defp

 ### defp reproduce-old
 (-- : "Reproduce only the portable manifest and lock after a tag moves and caches are absent.")
 (`cwd ".ecl" fs.exists? 0 equal
  `cwd "ecl.lock" fs.read-text
  seed-archive ["sync"] command
  `cwd "ecl.lock" fs.read-text equal
  args 2 at check-commit 42 runnable ["verify"] command)
 `reproduce-old defp

 ### defp moved
 (-- : "Honor the old lock until an explicit update, and preserve state on unavailable commits.")
 (`cwd "ecl.lock" fs.read-text
  ["sync" "--offline"] command
  `cwd "ecl.lock" fs.read-text equal
  args 2 at check-commit 42 runnable
  ["add"] args 1 at wrap cat ["--tag" "release"] cat command
  `cwd "ecl.lock" fs.read-text installed
  ["pkg" "sync" "--offline"] invoke `term at `code at 1 equal
  installed equal `cwd "ecl.lock" fs.read-text equal
  ["update" "--offline"] command
  args 3 at check-commit 99 runnable
  `cwd "ecl.pkg" fs.read-text `cwd "ecl.lock" fs.read-text installed
  ["pkg" "add"] args 1 at wrap cat ["--commit" "ffffffffffffffffffffffffffffffffffffffff"] cat
  invoke `term at `code at 1 equal
  installed equal `cwd "ecl.lock" fs.read-text equal
  `cwd "ecl.pkg" fs.read-text equal ["verify"] command)
 `moved defp

 ### defp reproduce-new
 (-- : "Reproduce the updated portable graph.")
 (`cwd ".ecl" fs.exists? 0 equal
  `cwd "ecl.lock" fs.read-text
  ["sync" "--offline"] command
  `cwd "ecl.lock" fs.read-text equal
  args 3 at check-commit 99 runnable ["verify"] command)
 `reproduce-new defp

 ### defp relocated
 (-- : "Reinstall a relocated project from its kept archives without the shared download cache.")
 (["sync" "--offline"] command
  99 runnable ["verify"] command)
 `relocated defp

 ### def run
 (-- : "Run the fixture phase the first argument selects.")
 ({"initial" (initial) "reproduce-old" (reproduce-old) "moved" (moved)
   "reproduce-new" (reproduce-new) "relocated" (relocated)}
  args first at apply) `run def
) `pkg.test.git-commands @defm
