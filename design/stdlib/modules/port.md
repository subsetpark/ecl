## port

#### Operations

| Word | Effect | Contract |
|---|---|---|
| `port.open` | `( factory config -- resource )` | Initialize a resource and publish it into the calling scope. Failure joins cleanup through that scope. |
| `port.begin` | `( resource operation request -- exchange )` | Admit a registered operation on its declared FIFO lane, parking while admission capacity is full. |
| `port.call` | `( resource operation request -- value )` | Begin, claim the result, and close the exchange. Requires no additional streaming input or output. |
| `port.endpoint` | `( source selector -- endpoint )` | Borrow a direction-specific endpoint supported by its resource or permitted by its exchange's operation. Supports registered byte and message endpoints; a byte endpoint is an fd for the `fd` words. |
| `port.send` | `( sender message -- )` | Enqueue one complete structured message atomically, parking under pressure. Empty values are valid messages. |
| `port.receive` | `( receiver -- event )` | Return `{kind message value value}` or `{kind eof}`. Overlapping receivers raise `` `contract ``. |
| `port.finish` | `( sender -- )` | Finish a message sender after accepted sends, so its receiver sees `{kind eof}`. Idempotent; later sends raise `` `io ``. Byte endpoints finish with `fd.finish`. |
| `port.await` | `( exchange -- )` | Wait for successful completion or raise the terminal error. Repeatable; does not drain output. |
| `port.result` | `( exchange -- value )` | Wait and claim the terminal result once. A later successful-result claim raises `` `contract ``. |
| `port.cancel` | `( exchange -- )` | Request cancellation idempotently. Completion remains observable and waits for controller return. |
| `port.shutdown` | `( resource -- )` | Stop new admission, perform registered graceful shutdown, and join cleanup. Unsupported resources raise `` `domain ``. Repeated calls observe the same outcome. |
| `port.close` | `( resource-or-exchange -- )` | Abort and join cleanup. Idempotent for every resource and exchange. |
