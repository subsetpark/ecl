### module agent
# A task whose stack is its state. `serve` captures the stack it starts with
# and then applies each quotation sent to it, in arrival order, as an isolated
# unit over that state: a failing quotation changes nothing. `call` takes the
# top of the result stack as its reply and keeps the rest; `send` keeps the
# whole result stack and never replies. The server ends only by cancellation.
#
# This is the stateful-module idiom as an ordinary task:
# `[0 0] agent.start `rng set` then `(5 rand.int) rng agent.call`.
[]
(
 ### defp settle-ok
 (state result -- state reply :
  "Split a successful result stack into the new state and an ok reply, or keep the state and reply a
   domain error when the stack is empty.")
 (`ok at dup len 0 =
  (pop {kind domain msg "agent.call quotation left nothing to return"} result.err)
  (nip dup -1 drop swap last wrap result.ok)
  if) `settle-ok defp

 ### defp settle
 (state result -- state reply : "Decide the new state and the reply from one application's result.")
 (dup result.ok? (settle-ok) () if) `settle defp

 ### defp reply
 (reply address -- : "Send a reply, ignoring a caller whose helper has already gone.")
 (pair (task.send) @attempt pop) `reply defp

 ### defp apply-message
 (state message -- state :
  "Apply one message's quotation to the state as a unit, reply when the message carries a from
   address, and return the next state.")
 (|state message|
  state state message `quot at @attempt message
  dup `from dict.has?
  (`from at rollup settle rolldown reply)
  (pop dup result.ok? (nip `ok at) (pop) if)
  if) `apply-message defp

 ### def serve
 (: "Stack-polymorphic. Turn the current task into an agent whose state is the stack it has now,
     then serve until cancelled: receive a message, apply its quotation to the state as a unit, and
     reply when the message asks. Spawn it directly to keep the handle: `[[7 0]] (agent.serve)
     @spawn` serves `[7 0]`, and `task.cancel` on the handle ends it with `` `cancelled ``.")
 (stack dup len (swap pop) times (1) (task.receive apply-message) while) `serve def

 ### def start
 (state -- address :
  "Spawn a server whose stack holds the one value `state` and return its address. The server is
   owned by the spawning task scope, as any `@spawn` is.")
 (wrap (serve) @spawn task.address) `start def

 ### defp exchange
 (quotation address -- reply :
  "Send a request carrying a fresh reply helper's address and return the helper's reply; a refused
   send cancels the helper and re-raises its error.")
 (|quotation address|
  [] (task.receive) @spawn dup task.address
  {} `quot quotation put `from rolldown put
  address pair (task.send) @attempt
  dup result.ok? (pop task.await `ok at first) (swap task.cancel `err at raise) if) `exchange defp

 ### def call
 (quotation address -- result :
  "Apply a quotation to the agent's stack and return the top of the result stack; the agent keeps
   the rest. The quotation's own error is re-raised here and leaves the agent unchanged. A result
   stack with nothing on it is `` `domain ``. Replies travel through a helper task. A call to an
   agent that has ended raises `` `io ``; a call whose request was accepted never returns if the
   agent ends before replying.")
 (exchange dup result.ok? (`ok at first) (`err at raise) if) `call def

 ### defp check-deadline
 (milliseconds -- milliseconds :
  "Refuse a deadline task.await-for would refuse before any message is sent.")
 (dup type `int match?
  `type error.new "agent.call-for expected an integer millisecond duration" error.with-message
  assert
  dup 0 >=
  `domain error.new "agent.call-for duration must be nonnegative" error.with-message assert)
 `check-deadline defp

 ### def call-for
 (quotation address milliseconds -- result :
  "`agent.call` with a nonnegative int deadline in milliseconds, checked before anything is sent: a
   negative duration is `` `domain `` and a non-int is `` `type ``. When no reply arrives in time
   the call raises `` `timeout ``, whether the deadline passed while waiting for room in a full
   mailbox or for the reply; the quotation, if it was sent, still runs on the agent when its turn
   comes, and its reply is discarded.")
 (|quotation address milliseconds|
  milliseconds check-deadline pop
  quotation address pair (exchange) @spawn
  dup milliseconds task.await-for swap task.cancel
  dup result.ok? (`ok at first) (`err at raise) if
  dup result.ok? (`ok at first) (`err at raise) if) `call-for def

 ### def send
 (quotation address -- :
  "Apply a quotation to the agent's stack without waiting for a reply. The whole result stack
   becomes the new state; a failing quotation changes nothing and reports nothing.")
 (|quotation address| {} `quot quotation put address task.send) `send def
) `agent @defm
