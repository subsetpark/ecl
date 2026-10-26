### module stdlib.test.agent
[]
(
 'stdlib.test.support
 ('equal 'raises 'documented)
 import

 ### test roundtrip
 (-- : "Advance agent state exactly as explicit threading would and reply with the top.")
 ([0 0] agent.start
  (|g| (100 rand.int) g agent.call (100 rand.int) g agent.call pair) call
  [0 0] 100 rand.int swap 100 rand.int nip pair equal
  [7 0] agent.start
  (|h| (dup) h agent.call [7 0] equal (dup) h agent.call [7 0] equal) call)
 'roundtrip test

 ### test state-isolation
 (-- : "Re-raise a failing quotation in the caller and leave the agent's stack as it was.")
 ([7 0] agent.start
  (|g|
   g ((1 0 div) swap agent.call) partial 'domain raises
   (dup) g agent.call [7 0] equal
   g ((pop) swap agent.call) partial 'domain raises
   (dup) g agent.call [7 0] equal
   g ((pop pop) swap agent.call) partial 'underflow raises
   (dup) g agent.call [7 0] equal) call)
 'state-isolation test

 ### test send
 (-- : "Apply without a reply, keeping the whole result stack and dropping a failure.")
 ([7 0] agent.start
  (|g|
   (pop 9) g agent.send (dup) g agent.call 9 equal
   (1 0 div) g agent.send (dup) g agent.call 9 equal
   (2) g agent.send (+) g agent.call 11 equal) call)
 'send test

 ### test call-for
 (-- : "Bound a call by a deadline; a late reply is 'timeout and the agent keeps serving.")
 ([7 0] agent.start
  (|g|
   (dup 1 +) g 1000 agent.call-for [8 1] equal
   g ((100 clock.sleep 1) swap 20 agent.call-for) partial 'timeout raises
   g ((1 +) swap -1 agent.call-for) partial 'domain raises
   g ((1 +) swap 'x agent.call-for) partial 'type raises
   (dup) g agent.call [7 0] equal) call)
 'call-for test

 ### test direct-serve
 (-- : "Spawn agent.serve directly to keep a handle; any entry stack is the state.")
 ([[7 0]] (agent.serve) @spawn
  (|server|
   (dup) server task.address agent.call [7 0] equal
   server task.cancel server task.await 'err at 'kind at 'cancelled equal) call
  [1 2 3] (agent.serve) @spawn task.address
  (|sum| (+ + dup) sum agent.call 6 equal (dup) sum agent.call 6 equal) call)
 'direct-serve test

 ### test documentation
 (-- : "Require documentation for every agent word.")
 (('agent.serve 'agent.start 'agent.call 'agent.call-for 'agent.send) documented)
 'documentation test
) 'stdlib.test.agent @defm
