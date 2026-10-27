## error

Errors are ordinary dictionaries. Construction and inspection do not raise
unless an operation's own input violates its contract; control effects remain
core words.

### kind-in?

### kind?

### new

### valid?

### with-data

### with-message

#### Examples

```ecl
'io error.new "unavailable" error.with-message
# => {'kind 'io 'msg "unavailable"}
```
