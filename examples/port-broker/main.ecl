[]
(
 portprobe.broker [] port.open 'broker set
 broker portprobe.deliver [] port.begin 'exchange set
 exchange portprobe.deliveries port.endpoint port.receive 'value at
 dup 'payload at len io.pp
 'delivery at 'old set
 exchange port.result pop
 exchange port.close

 broker portprobe.redeliver [] port.call 'next set
 old wrap (portprobe.acknowledge [] port.call) @attempt 'err at 'kind at io.pp
 old port.close
 next portprobe.delivery-info [] port.call io.pp
 next portprobe.acknowledge [] port.call io.pp
 broker portprobe.broker-status [] port.call io.pp
 broker port.close
) @spawn task.await result.or-raise pop
