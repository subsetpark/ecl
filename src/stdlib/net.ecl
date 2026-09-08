### module net
# TCP operations compose registered capabilities with the common port API.
[]
(
 ### def listen
 (config -- listener : "Bind a host-authorized TCP listener in the calling scope.")
 (net.core.listener swap port.open)
 'listen def

 ### def accept
 (listener -- connection : "Accept an independent connection into the calling scope.")
 (net.core.accept [] port.call)
 'accept def

 ### def local-address
 (resource -- address : "Return the local address of an open listener or connection.")
 (net.core.local-address [] port.call)
 'local-address def

 ### def peer-address
 (connection -- address : "Return the peer address of an open connection.")
 (net.core.peer-address [] port.call)
 'peer-address def

 ### def read
 (connection max -- bytes : "Read a positive chunk of exact bytes, or [] at stable EOF.")
 (swap net.core.input port.endpoint swap port.read)
 'read def

 ### def write
 (connection bytes -- : "Accept a complete byte list in FIFO order under bounded pressure.")
 (swap net.core.output port.endpoint swap port.write)
 'write def

 ### def close
 (resource -- : "Perform graceful shutdown and join resource cleanup. Idempotent.")
 (port.shutdown)
 'close def
) 'net @defm
