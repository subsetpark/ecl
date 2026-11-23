### module agent
(: "An agent is a stateful task that evaluates quotations it receives and responds with the top
    operand on its stack.

    To spawn a new agent, apply `agent.start` to some initial value. Quotations sent to the
    resulting address via `agent.send` will be applied to the state. Sending a quotation via `call`
    or `call-for` will apply the quotation, wait for a response, and then push the response onto the
    calling stack.")
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
 (swap pair (task.send) cat @attempt pop) `reply defp

 ### defp apply-message
 (state message -- state :
  "Apply one message's quotation to the state as a unit, reply when the message carries a from
   address, and return the next state.")
 (|state message|
  state state message `quot at cat @attempt message
  dup `from has?
  (`from at rollup settle rolldown reply)
  (pop dup result.ok? (nip `ok at) (pop) if)
  if) `apply-message defp

 ### def serve
 (: "Turn the current task into an agent whose state is the current stack, then serve until
     cancelled: receive a message, apply its quotation to the state as a unit, and optionally
     reply.")
 (stack dup len (swap pop) times (1) (task.receive apply-message) while) `serve def

 ### def start
 (state -- address : "Spawn a task initialized with `state` and return its address.")
 ((serve) cons @spawn task.address) `start def

 ### defp exchange
 (address quotation -- reply :
  "Send a request carrying a fresh reply helper's address and return the helper's reply; a refused
   send cancels the helper and re-raises its error.")
 (|address quotation|
  (task.receive) @spawn dup task.address
  {} `quot quotation put `from rolldown put
  address swap pair (task.send) cat @attempt
  dup result.ok? (pop task.await `ok at first) (swap task.cancel `err at raise) if) `exchange defp

 ### def call
 (address quotation -- result :
  "Apply `quotation` to the agent's stack in a unit and return the top value. Errors are
   re-raised.")
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
 (address quotation milliseconds -- result :
  "Apply `quotation` to the agent's stack in a unit and wait up to `milliseconds` for the response.
   Errors are re-raised.")
 (|address quotation milliseconds|
  milliseconds check-deadline pop
  address quotation pair (exchange) cat @spawn
  dup milliseconds task.await-for swap task.cancel
  dup result.ok? (`ok at first) (`err at raise) if
  dup result.ok? (`ok at first) (`err at raise) if) `call-for def

 ### def send
 (address quotation -- : "Apply `quotation` to the agent's stack in a unit.")
 (|address quotation| address {} `quot quotation put task.send) `send def
) `agent @defm
