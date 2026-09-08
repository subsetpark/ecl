# The child scope owns the resource and exchange, including on failure.
[]
(
 portprobe.factory [] port.open 'resource set
 resource portprobe.rpc [] port.begin 'exchange set
 exchange portprobe.receiver port.endpoint 'events set

 events port.receive 'value at 'reply at 'first-reply set
 events port.receive 'value at io.pp
 events port.receive 'value at 'reply at 'second-reply set

 second-reply [2 20] port.send
 events port.receive 'value at io.pp
 first-reply [1 10] port.send
 events port.receive 'value at io.pp

 exchange port.result io.pp
 exchange port.close
 resource port.close
) @spawn task.await result.or-raise pop
