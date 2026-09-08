# The task scope owns the session, transaction, cursor, and exchanges.
[]
(
 portprobe.storage [] port.open 'session set
 session portprobe.transaction [] port.call 'transaction set
 transaction portprobe.transaction-write 40 port.call pop
 transaction portprobe.commit [] port.call io.pp
 session portprobe.storage-status [] port.call io.pp
 session portprobe.durable [] port.call io.pp
 transaction port.close

 session portprobe.query [1 2] port.call 'cursor set
 cursor portprobe.rows [] port.begin 'exchange set
 exchange portprobe.row port.endpoint 'rows set
 rows port.receive 'value at io.pp
 rows port.receive 'value at io.pp
 rows port.receive 'kind at io.pp
 exchange port.result pop
 exchange port.close
 cursor port.close
 session port.close
) @spawn task.await result.or-raise pop
