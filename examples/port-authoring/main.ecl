# The child scope joins resources and tasks if any operation raises an error.
[]
(
 tutorial.counter [] port.open 'counter set
 counter tutorial.increment 3 port.call io.pp
 counter tutorial.increment 4 port.call io.pp

 counter tutorial.echo [] port.begin 'exchange set
 exchange tutorial.input port.endpoint wrap
 (dup [1 2 3 4] port.write port.finish) @spawn 'writer set
 exchange tutorial.output port.endpoint 'output set
 # This example knows its four-byte bound; production collectors need an
 # explicit limit and must also detect early EOF.
 [] (dup len 4 <) (output 4 port.read cat) while io.pp
 output 4 port.read io.pp
 writer task.await result.or-raise pop
 exchange port.await
 exchange port.close
 counter port.close
) @spawn task.await result.or-raise pop
