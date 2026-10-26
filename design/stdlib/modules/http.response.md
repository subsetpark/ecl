## http.response

Words over the response dictionary `{'status 'headers 'body}`: the value
`http.get`, `http.post`, and `http.send` return and the value an `http.server`
handler leaves. They build a response, read its headers by name regardless of
letter case, classify its status, and return updated copies. `valid?` accepts
every well-shaped value; the wire rules a server enforces (no 1xx, reserved
header names, no CR or LF) belong to `http.server.render-response`. A word
given a value that is not a response dictionary, a status outside `100...599`,
or a name that is not a string is `'type`.

### class
`( response -- int )` — Return the status class: 2 for `200...299`, 4 for
`400...499`, and so on.

### header
`( response name -- values )` — Return every value of a header as a list,
matching the name regardless of letter case and in dictionary order; a string
value counts as one. `()` when the header is absent.

### header?
`( response name -- bool )` — Return 1 when the response carries the header
under any letter case.

### json
`( status value -- response )` — Return a response whose body is the value
rendered with `json.emit` and whose headers are
`{"content-type" ("application/json")}`. A value `json.emit` rejects fails as
`json.emit` does.

### new
`( status -- response )` — Return `{'status status 'headers {} 'body ""}`.

### not-found
`( -- response )` — Return `404 "not found" text`.

### ok?
`( response -- bool )` — Return 1 for a status in `200...299`.

### redirect
`( location -- response )` — Return a 302 response with
`{"location" (location)}` as its headers and an empty body. A non-string
location is `'type`.

### text
`( status string -- response )` — Return a response with the string as its
body and `{"content-type" ("text/plain; charset=utf-8")}` as its headers. A
non-string body is `'type`.

### valid?
`( value -- bool )` — Return 1 for a response dictionary: exactly `'status`,
`'headers`, and `'body`, with an integer status in `100...599`, a headers
dictionary from string names to a string or a list of strings, and a string
or byte-list body. Never raises.

### with-body
`( response body -- response )` — Return the response with a new string or
byte-list body; another kind is `'type`.

### with-header
`( response name value -- response )` — Return the response with a value
added under the header name exactly as given: a string or a list of strings,
appended to any values already under that name; an existing string value,
even the empty string, counts as one.

### with-headers
`( response headers -- response )` — Return the response with a headers
dictionary merged over its own; a right-hand name replaces a left-hand one
exactly. A value that is not a dictionary of string names to header values is
`'type`.

### with-status
`( response status -- response )` — Return the response with a new status.
