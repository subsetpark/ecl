### module proc
# Process policy is expressed through registered capabilities and structured tasks.
[]
(
 ### def spawn
 (spec -- resource : "Start an authorized executable in the calling scope.")
 (proc.core.process swap port.open)
 'spawn def

 ### def write
 (resource bytes -- : "Accept exact stdin bytes under bounded pressure.")
 (swap proc.core.stdin port.endpoint swap port.write)
 'write def

 ### def close-input
 (resource -- : "Finish stdin after accepted bytes. Idempotent.")
 (proc.core.stdin port.endpoint port.finish)
 'close-input def

 ### def read-stdout
 (resource max -- bytes : "Read stdout bytes, or [] at stable EOF.")
 (swap proc.core.stdout port.endpoint swap port.read)
 'read-stdout def

 ### def read-stderr
 (resource max -- bytes : "Read diagnostic bytes, or [] at stable EOF.")
 (swap proc.core.stderr port.endpoint swap port.read)
 'read-stderr def

 ### def wait
 (resource -- termination : "Wait for process termination without draining its output.")
 (proc.core.wait [] port.call)
 'wait def

 ### def terminate
 (resource -- : "Request process-group termination on the control lane.")
 (proc.core.terminate [] port.call pop)
 'terminate def

 ### def kill
 (resource -- : "Force process-group termination on the control lane.")
 (proc.core.kill [] port.call pop)
 'kill def

 ### defp nonnegative
 (value -- value : "Validate a nonnegative integer option.")
 (dup type 'int match? 'type error.new "expected a nonnegative integer" error.with-message assert
  dup 0 >= 'domain error.new "expected a nonnegative integer" error.with-message assert)
 'nonnegative defp

 ### defp byte?
 (value -- bool : "Recognize an exact byte.")
 (dup type 'int match? (dup 0 >= swap 255 <= and) (pop 0) if)
 'byte? defp

 ### defp capture-step
 (reader limit chunks size chunk -- reader limit chunks size chunk :
  "Accumulate one bounded output chunk.")
 (|reader limit chunks size chunk|
  reader limit chunks chunk append size chunk len +
  dup limit <= 'overflow error.new "process capture limit exceeded" error.with-message assert
  reader 4096 port.read)
 'capture-step defp

 ### defp capture
 (reader limit -- bytes : "Drain bounded chunks and reject capture overflow.")
 (|reader limit|
  reader limit [] 0 reader 4096 port.read
  (dup len 0 >) (capture-step) while pop pop rollup pop pop raze)
 'capture defp

 ### defp collect
 (tasks -- result : "Observe every task, propagating the first observed failure.")
 ({} (over len 0 >)
  (over task.await-any result.or-raise first swap (dict.merge) dip rollup (swap del) dip)
  while nip)
 'collect defp

 ### defp run-result
 (fields -- result : "Return process results in a stable field order.")
 (|fields|
  'term fields 'term at 'stdout fields 'stdout at 'stderr fields 'stderr at 6 pack dict.from-flat)
 'run-result defp

 ### defp run-streams
 (spec process stdout-limit stderr-limit -- result :
  "Concurrently feed, drain, and observe process exit.")
 (|spec process stdout-limit stderr-limit|
  process proc.core.stdin port.endpoint spec 'stdin [] at-or pair
  (dup len 0 > (over swap port.write) (pop) if port.finish {}) @spawn
  process proc.core.stdout port.endpoint stdout-limit pair
  (capture 'stdout swap pair dict.from-flat) @spawn
  process proc.core.stderr port.endpoint stderr-limit pair
  (capture 'stderr swap pair dict.from-flat) @spawn
  process wrap (wait 'term swap pair dict.from-flat) @spawn
  4 pack collect run-result process port.close)
 'run-streams defp

 ### defp checked-limit
 (value maximum -- value : "Validate an optional capture bound against host policy.")
 (|value maximum| value nonnegative dup maximum <= 'domain error.new
  "process capture limit exceeds host policy" error.with-message assert)
 'checked-limit defp

 ### defp run-limited
 (spec process limits -- result : "Resolve capture defaults from the registered policy operation.")
 (|spec process limits|
  spec process
  spec 'stdout-limit limits 'stdout at at-or limits 'stdout at checked-limit
  spec 'stderr-limit limits 'stderr at at-or limits 'stderr at checked-limit
  run-streams)
 'run-limited defp

 ### defp run-body
 (spec -- result : "Own a process through concurrent transport and joined cleanup.")
 (dup ['stdin 'stdout-limit 'stderr-limit 'timeout-ms] dict.del spawn
  dup proc.core.capture-limits [] port.call run-limited)
 'run-body defp

 ### defp run-wait
 (task spec -- result : "Apply the optional task deadline and always join cancellation.")
 (dup 'timeout-ms dict.has?
  ('timeout-ms at task.await-for)
  (pop task.await)
  if)
 'run-wait defp

 ### def run
 (spec -- result : "Run with concurrent bounded capture, an optional deadline, and joined cleanup.")
 (dup type 'dict match? 'type error.new "expected a process specification dict" error.with-message
  assert
  dup 'stdin [] at-or dup type 'list match? 'type error.new "expected a stdin byte list"
  error.with-message assert
  (byte?) all? 'domain error.new "expected stdin bytes in 0...255" error.with-message assert
  dup 'timeout-ms 0 at-or nonnegative pop
  dup wrap (run-body) @spawn dup rolldown pair (run-wait) @attempt
  swap dup task.cancel task.await pop
  result.or-raise first
  dup 'err dict.has?
  (dup 'err at dup 'kind at 'timeout match?
   ("process deadline expired" error.with-message raise)
   (pop) if)
  when result.or-raise first)
 'run def
) 'proc @defm
