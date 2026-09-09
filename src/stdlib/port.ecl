### module port
# Common resource operations and compositions. Calls observe their result
# under an error boundary and join exchange cleanup before returning it.
[]
(
 ### def open
 (factory config -- resource : "Initialize a registered resource in the calling scope.")
 (port.core.open)
 'open def

 ### def begin
 (resource operation request -- exchange : "Admit an operation with bounded structured parameters.")
 (port.core.begin)
 'begin def

 ### def endpoint
 (source selector -- endpoint : "Borrow an attenuated endpoint supported by its source.")
 (port.core.endpoint)
 'endpoint def

 ### def read
 (readable max -- bytes : "Read a positive byte chunk, or [] at stable EOF.")
 (port.core.read)
 'read def

 ### def write
 (writable bytes -- : "Accept a complete byte list in FIFO order under bounded pressure.")
 (port.core.write)
 'write def

 ### def send
 (sender message -- :
  "Atomically enqueue one bounded structured message, including an empty value.")
 (port.core.send)
 'send def

 ### def receive
 (receiver -- event :
  "Receive {'kind 'message 'value value} or {'kind 'eof}; one receiver may wait.")
 (port.core.receive)
 'receive def

 ### def finish
 (writable -- : "Finish input after admitted writes. Idempotent.")
 (port.core.finish)
 'finish def

 ### def await
 (exchange -- : "Observe completion without consuming the result or draining output.")
 (port.core.await)
 'await def

 ### def result
 (exchange -- value : "Wait and claim a result once; a later claim raises 'contract.")
 (port.core.result)
 'result def

 ### def cancel
 (exchange -- : "Request cancellation. Completion remains observable.")
 (port.core.cancel)
 'cancel def

 ### def shutdown
 (resource -- :
  "Perform registered graceful shutdown and join cleanup. Unsupported resources raise 'domain.")
 (port.core.shutdown)
 'shutdown def

 ### def close
 (resource-or-exchange -- : "Abort and join cleanup. Idempotent.")
 (port.core.close)
 'close def

 ### def call
 (resource operation request -- value :
  "Begin an operation, claim its result, and close the exchange. Use only when no additional
   streaming input or output is required. Close the exchange before returning or re-raising its
   error.")
 (begin dup wrap (result) @attempt swap close result.or-raise first)
 'call def
) 'port @defm
