### module stdlib.test.agent
[]
(
 `stdlib.test.support
 (equal raises documented)
 import

 ### test roundtrip
 (-- : "Advance agent state exactly as explicit threading would and reply with the top.")
 ([0 0] agent.start
  (|g| g (100 rand.int) agent.call g (100 rand.int) agent.call pair) call
  [0 0] 100 rand.int swap 100 rand.int nip pair equal
  [7 0] agent.start
  (|h| h (dup) agent.call [7 0] equal h (dup) agent.call [7 0] equal) call)
 `roundtrip test

 ### test state-isolation
 (-- : "Re-raise a failing quotation in the caller and leave the agent's stack as it was.")
 ([7 0] agent.start
  (|g|
   g ((1 0 div) agent.call) cons `domain raises
   g (dup) agent.call [7 0] equal
   g ((pop) agent.call) cons `domain raises
   g (dup) agent.call [7 0] equal
   g ((pop pop) agent.call) cons `underflow raises
   g (dup) agent.call [7 0] equal) call)
 `state-isolation test

 ### test send
 (-- : "Apply without a reply, keeping the whole result stack and dropping a failure.")
 ([7 0] agent.start
  (|g|
   g (pop 9) agent.send g (dup) agent.call 9 equal
   g (1 0 div) agent.send g (dup) agent.call 9 equal
   g (2) agent.send g (+) agent.call 11 equal) call)
 `send test

 ### test call-for
 (-- : "Bound a call by a deadline; a late reply is `timeout and the agent keeps serving.")
 ([7 0] agent.start
  (|g|
   g (dup 1 +) 1000 agent.call-for [8 1] equal
   g ((100 clock.sleep 1) 20 agent.call-for) cons `timeout raises
   g ((1 +) -1 agent.call-for) cons `domain raises
   g ((1 +) `x agent.call-for) cons `type raises
   g (dup) agent.call [7 0] equal) call)
 `call-for test

 ### test dead-agent
 (-- : "Refuse a call to an ended agent as `io rather than waiting.")
 ([[7 0]] (agent.serve) @spawn
  (|server|
   server task.cancel server task.await pop
   server task.address
   (|g|
    g ((dup) agent.call) cons `io raises
    g ((dup) 100 agent.call-for) cons `io raises) call) call)
 `dead-agent test

 ### test call-for-full-mailbox
 (-- : "Bound the send phase too: a call to a slow agent with a full mailbox is `timeout.")
 ([7 0] agent.start
  (|g|
   g (200 clock.sleep) agent.send
   g 16 (dup (dup pop) agent.send) times pop
   g ((1 +) 20 agent.call-for) cons `timeout raises) call)
 `call-for-full-mailbox test

 ### test direct-serve
 (-- : "Spawn agent.serve directly to keep a handle; any entry stack is the state.")
 ([[7 0]] (agent.serve) @spawn
  (|server|
   server task.address (dup) agent.call [7 0] equal
   server task.cancel server task.await `err at `kind at `cancelled equal) call
  [1 2 3] (agent.serve) @spawn task.address
  (|sum| sum (+ + dup) agent.call 6 equal sum (dup) agent.call 6 equal) call)
 `direct-serve test

 ### test documentation
 (-- : "Require documentation for every agent word.")
 ((agent.serve agent.start agent.call agent.call-for agent.send) documented)
 `documentation test
) `stdlib.test.agent @defm
