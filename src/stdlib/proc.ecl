### module proc
# Process policy is expressed through registered capabilities and structured tasks.
[]
(
 ### def spawn
 (spec -- resource :
  "Start an authorized executable with stdin, stdout, and stderr pipes. spec is a symbol-keyed dict:
   required 'executable is an absolute path string; optional 'args is a list of argument strings
   (default []), 'cwd is an absolute path string without . or .. components (default the
   host-configured starting directory), and 'env is a string-to-string dict overlaid on the host's
   environment base (default {}). Strings must not contain NUL; environment names must be nonempty
   and contain no =. There is no shell expansion or PATH search; 'args excludes the executable name.
   Unknown fields, invalid values, or denied authority are 'domain; wrong field types are 'type;
   launch failures are 'io. The calling task scope owns the process group and joins cleanup when it
   ends; retaining the port does not detach it. Use proc.run for bounded capture, or drain both
   output streams concurrently.")
 (proc.core.process swap port.open) 'spawn def

 ### def write
 (resource bytes -- :
  "Accept a list of integer stdin bytes in 0...255, parking under bounded pressure. Convert text
   with bytes. Calls stay contiguous in FIFO order. A non-list is 'type; invalid byte elements are
   'domain; finished or broken stdin is 'io. Acceptance does not mean all bytes have reached the
   child. Drain stdout and stderr concurrently to avoid pipe deadlock.")
 (swap proc.core.stdin port.endpoint swap port.write) 'write def

 ### def close-input
 (resource -- :
  "Finish stdin after accepted bytes drain, sending EOF to the child. Idempotent. Subsequent writes,
   including empty writes, fail with 'io. Output remains readable; this does not wait for process
   exit or close the process resource.")
 (proc.core.stdin port.endpoint port.finish) 'close-input def

 ### def read-stdout
 (resource max -- bytes :
  "Read at most positive integer max bytes from stdout, parking until data or EOF. Return exact
   integer bytes in 0...255; [] means stable EOF, including on later reads. Reads may be shorter
   than max. A non-integer max is 'type; max <= 0 is 'domain; overlapping stdout reads are
   'contract; pipe failure is 'io. Use chars to decode UTF-8. Drain stderr concurrently when it can
   fill, or use proc.run to capture both streams.")
 (swap proc.core.stdout port.endpoint swap port.read) 'read-stdout def

 ### def read-stderr
 (resource max -- bytes :
  "Read at most positive integer max bytes from stderr, parking until data or EOF. Return exact
   integer bytes in 0...255; [] means stable EOF, including on later reads. Reads may be shorter
   than max. A non-integer max is 'type; max <= 0 is 'domain; overlapping stderr reads are
   'contract; pipe failure is 'io. Drain stdout concurrently when it can fill, or use proc.run to
   capture both streams.")
 (swap proc.core.stderr port.endpoint swap port.read) 'read-stderr def

 ### def wait
 (resource -- termination :
  "Wait for direct-child termination without draining stdout or stderr. Return {'kind 'exited 'code
   n}, {'kind 'signaled 'signal n}, {'kind 'stopped 'signal n}, or {'kind 'unknown 'status n}. A
   nonzero exit code is ordinary result data. Repeated waiters receive the same result while the
   resource is open; pipe failures are 'io. Output pipes can fill and prevent exit, so drain both
   concurrently or use proc.run. This leaves the resource open; use port.close to join cleanup.")
 (proc.core.wait [] port.call) 'wait def

 ### def terminate
 (resource -- :
  "Request ordinary process-group termination without waiting for exit. Idempotent and safe after
   natural exit while the resource remains open. Cleanup escalates to force termination when needed.
   Use proc.wait to observe termination and port.close to join cleanup.")
 (proc.core.terminate [] port.call pop) 'terminate def

 ### def kill
 (resource -- :
  "Request force termination of the process group and arrange direct-child reap. Idempotent and safe
   after natural exit while the resource remains open. Does not wait for exit; use proc.wait to
   observe termination and port.close to join cleanup.")
 (proc.core.kill [] port.call pop) 'kill def

 ### defp nonnegative
 (value -- value : "Validate a nonnegative integer option.")
 (dup type 'int match? 'type error.new "expected a nonnegative integer" error.with-message assert
  dup 0 >= 'domain error.new "expected a nonnegative integer" error.with-message assert)
 'nonnegative defp

 ### defp byte?
 (value -- bool : "Recognize an exact byte.")
 (dup type 'int match? (dup 0 >= swap 255 <= and) (pop 0) if) 'byte? defp

 ### defp capture-step
 (reader limit chunks size chunk -- reader limit chunks size chunk :
  "Accumulate one bounded output chunk.")
 (|reader limit chunks size chunk|
  reader limit chunks chunk append size chunk len +
  dup limit <= 'overflow error.new "process capture limit exceeded" error.with-message assert
  reader 4096 port.read) 'capture-step defp

 ### defp capture
 (reader limit -- bytes : "Drain bounded chunks and reject capture overflow.")
 (|reader limit|
  reader limit [] 0 reader 4096 port.read
  (dup len 0 >) (capture-step) while pop pop rollup pop pop raze) 'capture defp

 ### defp collect
 (tasks -- result : "Observe every task, propagating the first observed failure.")
 ({} (over len 0 >)
  (over task.await-any result.or-raise first swap (dict.merge) dip rollup (swap del) dip)
  while nip) 'collect defp

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
  4 pack collect run-result process port.close) 'run-streams defp

 ### defp checked-limit
 (value maximum -- value : "Validate an optional capture bound against host policy.")
 (|value maximum| value nonnegative dup maximum <= 'domain error.new
  "process capture limit exceeds host policy" error.with-message assert) 'checked-limit defp

 ### defp run-limited
 (spec process limits -- result : "Resolve capture defaults from the registered policy operation.")
 (|spec process limits|
  spec process
  spec 'stdout-limit limits 'stdout at at-or limits 'stdout at checked-limit
  spec 'stderr-limit limits 'stderr at at-or limits 'stderr at checked-limit
  run-streams) 'run-limited defp

 ### defp run-body
 (spec -- result : "Own a process through concurrent transport and joined cleanup.")
 (dup ['stdin 'stdout-limit 'stderr-limit 'timeout-ms] dict.del spawn
  dup proc.core.capture-limits [] port.call run-limited) 'run-body defp

 ### defp run-wait
 (task spec -- result : "Apply the optional task deadline and always join cancellation.")
 (dup 'timeout-ms dict.has?
  ('timeout-ms at task.await-for)
  (pop task.await)
  if) 'run-wait defp

 ### def run
 (spec -- result :
  "Run a process with concurrent stdin feeding and bounded stdout/stderr capture, then join cleanup.
   spec is a symbol-keyed dict with required 'executable (absolute path string), optional 'args
   (argument strings, default []), 'cwd (absolute path without . or .. components, default the
   host-configured starting directory), and 'env (string-to-string environment overlay, default {}).
   These obey proc.spawn's path, string, and host-authority rules. Additional optional fields:
   'stdin is a list of integer bytes in 0...255 (default []); 'stdout-limit and 'stderr-limit are
   nonnegative integer byte limits, each defaulting to its host-policy maximum and never exceeding
   it; 'timeout-ms is a nonnegative integer deadline covering spawn and execution (omitted means no
   deadline). Stdin is finished after feeding. Return {'term termination 'stdout byte-list 'stderr
   byte-list}; termination has proc.wait's shape, including {'kind 'exited 'code n}. Nonzero exit
   codes do not raise. Decode output explicitly with chars. Capture overflow raises 'overflow,
   deadline expiry raises 'timeout, and cancellation raises 'cancelled, after joined cleanup. Wrong
   field types are 'type; invalid values or denied authority are 'domain; launch, pipe, or reap
   failures are 'io. Run-only fields are rejected by proc.spawn.")
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
  when result.or-raise first) 'run def
) 'proc @defm
