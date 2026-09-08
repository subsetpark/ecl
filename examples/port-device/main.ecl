# The buffer stays dependent on the device through native worker completion.
[]
(
 portprobe.device [] port.open 'device set
 device portprobe.buffer 3 port.call 'buffer set
 buffer portprobe.compute [] port.begin 'exchange set
 1 portprobe.await-blocked
 device portprobe.device-status [] port.call io.pp

 buffer portprobe.buffer-update [2 9] port.call pop
 buffer portprobe.complete-work [] port.call pop
 exchange port.result io.pp
 exchange port.await
 exchange port.close
 device portprobe.device-status [] port.call io.pp

 buffer portprobe.compute [] port.begin 'cancelled set
 2 portprobe.await-blocked
 cancelled port.cancel
 cancelled wrap (port.await) @attempt 'err at 'kind at io.pp
 cancelled port.close
 device portprobe.device-status [] port.call io.pp
 device port.close
) @spawn task.await result.or-raise pop
