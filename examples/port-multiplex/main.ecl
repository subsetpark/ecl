[]
(
 portprobe.multiplex [] port.open 'connection set
 connection portprobe.channel 1 port.call 'channel set
 channel portprobe.channel-stream [] port.begin 'exchange set
 exchange portprobe.channel-input port.endpoint 'input set
 exchange portprobe.channel-output port.endpoint 'output set
 input [] port.send
 output port.receive 'value at io.pp

 connection portprobe.disconnect [] port.begin 'failure set
 failure wrap (port.await) @attempt 'err at 'kind at io.pp
 connection port.close
 failure portprobe.disconnect-event port.endpoint port.receive 'value at io.pp
 exchange wrap (port.await) @attempt 'err at 'kind at io.pp
 exchange port.close
 failure port.close
) @spawn task.await result.or-raise pop
