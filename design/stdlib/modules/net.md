## net

### listen

#### Examples

Bind an ephemeral port and read back the assigned address:

```ecl
{address "127.0.0.1" port 0} net.listen
dup net.local-address
swap net.close
# Leaves {address "127.0.0.1" port n}, where n is the assigned port.
```

A one-connection greeting server, which blocks until a peer connects. The
first close drains and closes the connection; the second closes the listener.

```ecl
{address "127.0.0.1" port 8080} net.listen
dup net.accept
dup "hello\n" bytes net.write
net.close
net.close
```
