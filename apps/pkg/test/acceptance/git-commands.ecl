### module pkg.test.git-commands
[]
(
 ### defp equal
 (actual expected -- : "Compare package behavior through public interfaces.")
 (match? {'kind 'user 'msg "Git package command assertion failed"} assert) 'equal defp

 ### defp invoke
 (arguments -- result : "Launch an installed application with the caller's real project state.")
 (|arguments| {'timeout-ms 180000 'stdout-limit 65536 'stderr-limit 65536}
  'executable host.executable put 'args arguments put proc.run) 'invoke defp

 ### defp command
 (arguments -- : "Require a successful installed package command.")
 (["pkg"] swap cat invoke dup 'term at {'kind 'exited 'code 0} match?
  swap str 'user error.new swap error.with-message assert) 'command defp

 ### defp seed-archive
 (-- : "Supply a pinned archive source independently of Git and the application resolver.")
 (args 4 at fs.open-dir "valid.tgz.hex" fs.read-text str.trim
  ("0123456789abcdef" swap find) each dup len 2 div 2 pair reshape
  (|pair| pair first 16 * pair 1 at +) each
  (|bytes| pkg.project.cache-path bytes pkg.fetch.hash bytes pkg.cache.write) call) 'seed-archive
 defp

 ### defp locked
 (-- lock : "Read the portable project lock through the application parser.")
 ('cwd "ecl.lock" fs.read-text pkg.resolution.read) 'locked defp

 ### defp check-commit
 (commit -- : "Require an exact Git selection alongside an archive selection.")
 (locked ['packages "alpha" 'source 'commit] at-path equal
  locked ['packages "sample" 'source 'kind] at-path 'archive equal) 'check-commit defp

 ### defp runnable
 (answer -- : "Load through the project's active runtime map in a new interpreter.")
 (str "alpha.answer " swap cat " = {'kind 'user 'msg \"wrong active dependency\"} assert" cat
  ["-e"] swap wrap cat invoke 'term at {'kind 'exited 'code 0} equal) 'runnable defp

 ### test initial
 (-- : "Resolve mixed sources explicitly and start the installed app from broken project state.")
 (["init" "consumer"] command
  'cwd "ecl.lock" fs.read-text
  ["add"] args 1 at wrap cat ["--tag" "release"] cat command
  'cwd "ecl.lock" fs.read-text equal
  ["pkg" "sync" "--offline"] invoke 'term at 'code at 1 equal
  seed-archive ["update" "--offline"] command
  args 2 at check-commit 42 runnable
  "[] ((999) 'answer def) 'pkg.command @defm" 'cwd "src/conflict.ecl" fs.publish-text
  "broken map" 'cwd "ecl.modules" fs.publish-text
  ["sync" "--offline"] command
  ["verify"] command
  args 2 at check-commit 42 runnable
  'cwd "ecl.lock" fs.read-text 'cwd "ecl.modules" fs.read-text
  "corrupt lock" 'cwd "ecl.lock" fs.publish-text
  ["pkg" "sync" "--offline"] invoke 'term at 'code at 1 equal
  'cwd "ecl.modules" fs.read-text equal
  ["update" "--offline"] command
  'cwd "ecl.lock" fs.read-text equal ["verify"] command)
 'initial test

 ### test reproduce-old
 (-- : "Reproduce only the portable manifest and lock after a tag moves and caches are absent.")
 ('cwd ".ecl" fs.exists? 0 equal
  'cwd "ecl.modules" fs.exists? 0 equal
  'cwd "ecl.lock" fs.read-text
  seed-archive ["sync"] command
  'cwd "ecl.lock" fs.read-text equal
  args 2 at check-commit 42 runnable ["verify"] command)
 'reproduce-old test

 ### test moved
 (-- : "Honor the old lock until an explicit update, and preserve state on unavailable commits.")
 ('cwd "ecl.lock" fs.read-text
  ["sync" "--offline"] command
  'cwd "ecl.lock" fs.read-text equal
  args 2 at check-commit 42 runnable
  ["add"] args 1 at wrap cat ["--tag" "release"] cat command
  'cwd "ecl.lock" fs.read-text 'cwd "ecl.modules" fs.read-text
  ["pkg" "sync" "--offline"] invoke 'term at 'code at 1 equal
  'cwd "ecl.modules" fs.read-text equal 'cwd "ecl.lock" fs.read-text equal
  ["update" "--offline"] command
  args 3 at check-commit 99 runnable
  'cwd "ecl.pkg" fs.read-text 'cwd "ecl.lock" fs.read-text 'cwd "ecl.modules" fs.read-text
  ["pkg" "add"] args 1 at wrap cat ["--commit" "ffffffffffffffffffffffffffffffffffffffff"] cat
  invoke 'term at 'code at 1 equal
  'cwd "ecl.modules" fs.read-text equal 'cwd "ecl.lock" fs.read-text equal
  'cwd "ecl.pkg" fs.read-text equal ["verify"] command)
 'moved test

 ### test reproduce-new
 (-- : "Reproduce the updated portable graph and vendor without cache dependence.")
 ('cwd ".ecl" fs.exists? 0 equal
  'cwd "ecl.lock" fs.read-text
  ["sync" "--offline"] command
  'cwd "ecl.lock" fs.read-text equal
  args 3 at check-commit 99 runnable ["verify"] command)
 'reproduce-new test

 ### test vendor
 (-- : "Vendor the active sealed graph after removal of the shared download cache.")
 (["vendor" "--offline"] command
  'cwd "ecl.modules" fs.read-text pkg.layout.from-reference "vendor/" str.starts? 1 equal
  99 runnable ["verify"] command)
 'vendor test

 ### def run
 (-- : "Select one fixture phase and run its assertions using ECL's built-in test interface.")
 (tests ('name at chars args first match?) filter
  dup len 1 = {'kind 'user 'msg "Git command phase was not registered"} assert
  first @test result.or-raise pop) 'run def
) 'pkg.test.git-commands @defm
