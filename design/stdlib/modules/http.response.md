## http.response

Words over the response dictionary `{status headers body}`: the value
`http.get`, `http.post`, and `http.send` return and the value an `http.server`
handler leaves. They build a response, read its headers by name regardless of
letter case, classify its status, and return updated copies. `valid?` accepts
every well-shaped value; the wire rules a server enforces (no 1xx, reserved
header names, no CR or LF) belong to `http.server.render-response`. A word
given a value that is not a response dictionary, a status outside `100...599`,
or a name that is not a string is `` `type ``.

### class

### header

### header?

### json

### new

### not-found

### ok?

### redirect

### text

### valid?

### with-body

### with-header

### with-headers

### with-status
