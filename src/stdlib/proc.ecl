### module proc
# Process policy is expressed through registered capabilities and structured tasks.
[]
(
 ### def spawn
 (spec -- resource :
  "Start the directly named, authorized executable with stdin, stdout, and stderr pipes. `spec` is a
   symbol-keyed dictionary:
   - `` `executable ``, required: an absolute path string.
   - `` `args ``: a list of argument strings, default `[]`; it excludes the executable name.
   - `` `cwd ``: an absolute path string without `.` or `..` components, default the host-configured
     starting directory.
   - `` `env ``: a string-to-string dictionary overlaid on the host's environment base, default
     `{}`.

   Strings must not contain NUL, and environment names must be nonempty and contain no `=`. There is
   no shell expansion or `PATH` search. Unknown fields, invalid values, or denied authority are ``
   `domain ``; wrong field types are `` `type ``; launch failures are `` `io ``.

   The child and its process group, pipe tasks, and spawning task-scope membership commit before the
   port becomes visible. The calling task scope owns the live child: scope closure cancels the
   process group and waits for reap even if a port value remains stored elsewhere. Returning or
   storing the port does not detach it; `@give` is the one way to change owner, and the unit it is
   given to kills the group when it ends. Use `proc.run` for bounded capture, or drain both output
   streams concurrently.")
 (proc.core.process swap port.open) `spawn def

 ### def stdin
 (resource -- fd :
  "The process's stdin as a writable byte endpoint for `fd.write` and `fd.finish`. Each call borrows
   a new endpoint value over the same pipe; the pipe closes with the process resource, so the value
   is `` `type `` to `fd.close`.")
 (proc.core.stdin port.endpoint) `stdin def

 ### def stdout
 (resource -- fd :
  "The process's stdout as a readable byte endpoint for `fd.read`, `fd.read-line`, `fd.read-all`,
   and the `io` readers. Each call borrows a new endpoint value over the same pipe, and a line
   reader's read-ahead belongs to the value, so read lines through one value. Drain stderr
   concurrently when it can fill, or use `proc.run` to capture both streams.")
 (proc.core.stdout port.endpoint) `stdout def

 ### def stderr
 (resource -- fd : "The process's stderr as a readable byte endpoint, with `stdout`'s contract.")
 (proc.core.stderr port.endpoint) `stderr def

 ### def write
 (resource bytes -- :
  "Queue exact stdin bytes, a list of integers in `0...255`, parking under bounded pressure. Convert
   text with `bytes`. Calls are serialized in scheduler-arrival order and each call's bytes remain
   contiguous. A non-list is `` `type ``; invalid byte elements are `` `domain ``; finished, closed,
   or broken stdin is `` `io ``. Acceptance does not mean all bytes have reached the child. Drain
   stdout and stderr concurrently to avoid pipe deadlock.")
 (swap stdin swap fd.write) `write def

 ### def close-input
 (resource -- :
  "Finish stdin after queued bytes have been written, sending EOF to the child. Idempotent. A
   concurrent or later write, including an empty write, is `` `io ``. Output remains readable; this
   does not wait for process exit or close the process resource.")
 (stdin fd.finish) `close-input def

 ### def read-stdout
 (resource max -- bytes :
  "Read at most positive integer `max` bytes from stdout, parking when no data is ready. Return
   exact integer bytes in `0...255`; `[]` means stable EOF, and later reads also return `[]`. Reads
   may be shorter than `max`. A non-integer maximum is `` `type ``; a nonpositive maximum is ``
   `domain ``; at most one stdout read may be pending, so overlap is `` `contract ``; pipe failure
   is `` `io ``. Use `chars` to decode UTF-8. Drain stderr concurrently when it can fill, or use
   `proc.run` to capture both streams.")
 (swap stdout swap fd.read) `read-stdout def

 ### def read-stderr
 (resource max -- bytes :
  "Read at most positive integer `max` bytes from stderr, parking when no data is ready. Return
   exact integer bytes in `0...255`; `[]` means stable EOF, and later reads also return `[]`. Reads
   may be shorter than `max`. A non-integer maximum is `` `type ``; a nonpositive maximum is ``
   `domain ``; at most one stderr read may be pending, so overlap is `` `contract ``; pipe failure
   is `` `io ``. Drain stdout concurrently when it can fill, or use `proc.run` to capture both
   streams.")
 (swap stderr swap fd.read) `read-stderr def

 ### def wait
 (resource -- termination :
  "Park until direct-child termination without draining stdout or stderr, and return the immutable
   terminal result:
   - `{kind exited code n}`;
   - `{kind signaled signal n}`;
   - `{kind stopped signal n}`; or
   - `{kind unknown status n}`.

   Any number of waiters and later calls receive the same dictionary. A nonzero exit code is
   ordinary termination data, not an ECL error. A pipe failure raises `` `io ``. Output pipes can
   fill and prevent exit, so drain both concurrently or use `proc.run`. Waiting requires an open
   resource; after closure, observe a previously completed exchange instead of admitting another
   wait. This leaves the resource open; use `port.close` to join cleanup.")
 (proc.core.wait [] port.call) `wait def

 ### def terminate
 (resource -- :
  "Request ordinary termination of the process group without waiting for exit, escalating to force
   termination during cleanup when needed. Idempotent and safe after natural exit while the resource
   remains open. Use `proc.wait` to observe termination and `port.close` to join cleanup.")
 (proc.core.terminate [] port.call pop) `terminate def

 ### def kill
 (resource -- :
  "Request force termination of the process group and arrange direct-child reap. Idempotent and safe
   after natural exit while the resource remains open. This does not wait for exit; use `proc.wait`
   to observe termination and `port.close` to join cleanup.")
 (proc.core.kill [] port.call pop) `kill def

 ### defp nonnegative
 (value -- value : "Validate a nonnegative integer option.")
 (dup type `int match? `type error.new "expected a nonnegative integer" error.with-message assert
  dup 0 >= `domain error.new "expected a nonnegative integer" error.with-message assert)
 `nonnegative defp

 ### defp capture-step
 (reader limit chunks size chunk -- reader limit chunks size chunk :
  "Accumulate one bounded output chunk.")
 (|reader limit chunks size chunk|
  reader limit chunks chunk append size chunk len +
  dup limit <= `overflow error.new "process capture limit exceeded" error.with-message assert
  reader 4096 fd.read) `capture-step defp

 ### defp capture
 (reader limit -- bytes : "Drain bounded chunks and reject capture overflow.")
 (|reader limit|
  reader limit [] 0 reader 4096 fd.read
  (dup len 0 >) (capture-step) while pop pop rollup pop pop raze) `capture defp

 ### defp await-all
 (tasks -- result : "Observe every task, propagating the first observed failure.")
 ({} (over len 0 >)
  (over task.await-any result.or-raise first swap (dict.merge) dip rollup (swap del) dip)
  while nip) `await-all defp

 ### defp run-result
 (fields -- result : "Return process results in a stable field order.")
 (|fields|
  `term fields `term at `stdout fields `stdout at `stderr fields `stderr at 6 pack dict.from-flat)
 `run-result defp

 ### defp run-streams
 (spec process stdout-limit stderr-limit -- result :
  "Concurrently feed, drain, and observe process exit.")
 (|spec process stdout-limit stderr-limit|
  process stdin spec `stdin [] dict.get pair
  (dup len 0 > (over swap fd.write) (pop) if fd.finish {}) @spawn
  process stdout stdout-limit pair
  (capture `stdout swap pair dict.from-flat) @spawn
  process stderr stderr-limit pair
  (capture `stderr swap pair dict.from-flat) @spawn
  process wrap (wait `term swap pair dict.from-flat) @spawn
  4 pack await-all run-result process port.close) `run-streams defp

 ### defp checked-limit
 (value maximum -- value : "Validate an optional capture bound against host policy.")
 (|value maximum| value nonnegative dup maximum <= `domain error.new
  "process capture limit exceeds host policy" error.with-message assert) `checked-limit defp

 ### defp run-limited
 (spec process limits -- result : "Resolve capture defaults from the registered policy operation.")
 (|spec process limits|
  spec process
  spec `stdout-limit limits `stdout at dict.get limits `stdout at checked-limit
  spec `stderr-limit limits `stderr at dict.get limits `stderr at checked-limit
  run-streams) `run-limited defp

 ### defp run-body
 (spec -- result : "Own a process through concurrent transport and joined cleanup.")
 (dup [stdin stdout-limit stderr-limit timeout-ms] dict.del spawn
  dup proc.core.capture-limits [] port.call run-limited) `run-body defp

 ### defp run-wait
 (task spec -- result : "Apply the optional task deadline and always join cancellation.")
 (dup `timeout-ms dict.has?
  (`timeout-ms at task.await-for)
  (pop task.await)
  if) `run-wait defp

 ### def run
 (spec -- result :
  "Spawn through the ordinary port controller, supply all stdin while draining stdout and stderr
   concurrently, wait for direct-child reap, join cleanup, and return `{term termination stdout
   stdout-bytes stderr stderr-bytes}`. `spec` takes the `proc.spawn` fields under the same path,
   string, and host-authority rules, plus these optional run-only fields, which `proc.spawn`
   rejects:
   - `` `stdin ``: a list of integer bytes in `0...255`, default `[]`; strings require explicit
     `bytes` conversion.
   - `` `stdout-limit ``: a nonnegative integer maximum of total captured stdout bytes, default the
     host stdout capture maximum.
   - `` `stderr-limit ``: a nonnegative integer maximum of total captured stderr bytes, default the
     host stderr capture maximum.
   - `` `timeout-ms ``: a nonnegative integer deadline in milliseconds covering spawn and execution;
     omitted means no process deadline, while scheduler cancellation remains effective.

   Each capture limit must be no larger than its host maximum, and zero permits only empty output on
   that stream. Stdin is finished after feeding, including when omitted. The result always contains
   all three keys: `` `term `` has the `proc.wait` shape, and `` `stdout `` and `` `stderr `` are
   byte lists, empty when nothing was captured. Nonzero exit codes are returned as data; inspect ``
   `term `` to decide whether the command succeeded, and decode output explicitly with `chars`.

   Capture overflow kills and cleans the process before raising `` `overflow ``. Deadline expiry
   does the same before raising `` `timeout ``; task cancellation raises `` `cancelled ``, also
   after joined cleanup. Wrong field types are `` `type ``; invalid values or denied authority are
   `` `domain ``; spawn, pipe, broken-input, and reap failures are `` `io ``. The deadline covers
   the child task that opens and runs the process. Output collectors enforce their limits
   independently; a failed collector cancels the remaining work and joins resource cleanup.
   Successful input acceptance is distinct from backend pipe completion, and a later broken pipe
   still fails the run.")
 (dup type `dict match? `type error.new "expected a process specification dict" error.with-message
  assert
  dup `stdin [] dict.get dup type `list match? `type error.new "expected a stdin byte list"
  error.with-message assert
  fd.bytes? `domain error.new "expected stdin bytes in 0...255" error.with-message assert
  dup `timeout-ms 0 dict.get nonnegative pop
  dup wrap (run-body) @spawn dup rolldown pair (run-wait) @attempt
  swap dup task.cancel task.await pop
  result.or-raise first
  dup `err dict.has?
  (dup `err at dup `kind at `timeout match?
   ("process deadline expired" error.with-message raise)
   (pop) if)
  when result.or-raise first) `run def
) `proc @defm
