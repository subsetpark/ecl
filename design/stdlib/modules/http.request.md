## http.request

Words over partial or complete request dictionaries. Recognized optional
fields are `'method`, `'target`, `'path`, `'query`, `'headers`, `'body`,
`'peer`, and `'params`. `http.server` handlers receive every field except
`'params`, which `http.server.route` may add; outbound `http.get` and
`http.post` accept partial values and apply their documented defaults, while
`http.send` consumes a complete value. The words here build a complete
request, read absent headers/query/body using empty defaults, and return
updated copies; the original is never changed. A word given a malformed
request dictionary, or a name that is not a string, is `'type`.

### header
`( request name -- values )` — Return the list of values of a header, matching
the name regardless of letter case, or `()` when it is absent.

### header?
`( request name -- bool )` — Return 1 when the request carries the header under
any letter case.

### json
`( request -- value )` — Return the body parsed as JSON: `chars` then
`json.parse`, failing as they do.

### new
`( method target -- request )` — Return a request with the method and target,
`'path` and `'query` split from the target at its first `?` (`'query` `""`
when absent), `{}` headers, `[]` body, and `""` peer. A non-string method or
target is `'type`.

### param
`( request name -- value )` — Return the route parameter bound under the name.
A request without that parameter is `'domain`.

### query
`( request -- dict )` — Return the request's `'query` string as a dictionary
from string keys to string values: `&`-separated pairs, each split at its
first `=`, a pair without `=` mapping its key to `""`, empty pieces ignored,
and a later duplicate key replacing an earlier one. `%XX` escapes are decoded
in keys and values and the decoded text must be valid UTF-8; `+` is left as
it is. An empty query is `{}`. A `%` not followed by two hexadecimal digits,
or a decoded key or value that is not valid UTF-8, is `'domain`.

#### Examples

```ecl
"GET" "/?a=1&b=%2Fx&c" http.request.new http.request.query
# => {"a" "1" "b" "/x" "c" ""}
```

### text
`( request -- string )` — Return the body decoded as UTF-8 text; a body that
is not valid UTF-8 is `'domain`, as for `chars`.

### valid?
`( value -- bool )` — Return 1 for a partial or complete request dictionary
containing only recognized fields: string method, target, path, query, and
peer; a headers dictionary from ASCII-lowercased string names to lists of
strings; a byte-list body; and a params dictionary from string names to string
values. Every field is optional. Never raises.

### with-body
`( request body -- request )` — Return the request with a new body: a byte
list as given, or a string encoded as UTF-8. Another kind is `'type`.

### with-header
`( request name value -- request )` — Return the request with a value added
under the ASCII-lowercased name: a string or a list of strings, appended to
the values already there. A bad value is `'type`.

### with-param
`( request name value -- request )` — Return the request with a route
parameter bound under the name, as `route` does. A non-string value is
`'type`.
