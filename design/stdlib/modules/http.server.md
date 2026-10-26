## http.server

HTTP/1.1 serving over `net` connections, defined in ECL. The module holds no
authority of its own: `@serve` takes a listener the program already obtained
through `net.listen`, so a Session that cannot bind cannot serve, and every
socket operation is one of the `net` words. The parsers, the response
renderer, and `route` take and return ordinary values and never touch a
connection, so they can be used and tested without a socket. Requests and
responses are the dictionaries `http.request` and `http.response` build and
read.

A request is the dictionary
`{'method 'target 'path 'query 'headers 'body 'peer}`:

- `'method` and `'target` are the first two tokens of the request line, as
  strings;
- `'path` and `'query` are the target split at the first `?`, undecoded;
  `'query` is `""` when the target has no `?`;
- `'headers` is a dictionary from ASCII-lowercased header name to the list of
  its trimmed values in arrival order, so a repeated header keeps every value;
- `'body` is the exact byte list named by `Content-Length`, `[]` when the
  request has none; and
- `'peer` is the peer's `address:port` formatted from `net.peer-address`,
  with an IPv6 address in brackets.

A response is the dictionary `{'status 'headers 'body}` with exactly those
keys: an integer status in `200...599`, since interim 1xx responses are not
served, with an empty body when the status is 204, 205, or 304; a headers
dictionary whose keys are
strings and whose values are a string or a list of strings, written once per
value in the given order and with the name as given; and a body that is a
string, written as UTF-8, or a byte list. The names `content-length`,
`connection`, and `transfer-encoding` are reserved in any letter case: the
server writes `Content-Length` and `Connection: close` itself, and a response
naming one of them is `'domain`. Header names must be nonempty HTTP tokens
and values may not contain CR, LF, NUL, or a control character other than
tab, so a value built from request data cannot split the response.

Framing is HTTP/1.1 with `Content-Length` bodies only; an HTTP/1.0 request is
answered the same way, and only HTTP/1.1 requests must carry one `Host`
header. A HEAD request is answered with the handler's status and headers and
no body. Any `Transfer-Encoding` header is answered 411 and a
version other than `HTTP/1.1` or `HTTP/1.0` is answered 505. There is no
keep-alive: every response carries `Connection: close`, and the connection is
closed once the response is written. TLS, chunked bodies, pipelining, and
upgrades belong to a proxy in front of the server.

The `@serve` configuration is a dictionary whose keys are all optional; `{}`
is valid. Each limit is an integer greater than zero.

- `'max-header-bytes` (default `32768`): the most bytes accepted before the
  CRLFCRLF that ends the head; more is 431.
- `'max-body-bytes` (default `1048576`): the largest `Content-Length`
  accepted; a larger one is 413 before any body byte is read.
- `'max-in-flight` (default `128`): the number of acceptor children, each
  handling one connection at a time.
- `'read-timeout-ms` (default `10000`): the deadline for reading one whole
  request, head and body; expiry is 408.
- `'on-failure` (default `(str io.eprint)`): a quotation `( error -- )`
  applied to the error dictionary of every request the server answers 500; a
  failure of the quotation itself is discarded.

The server answers a request it cannot serve with a minimal `text/plain`
response of the status below and then closes the connection:

- 400: a malformed request line; a header line without `:` or beginning with
  space or tab (obsolete folding); an HTTP/1.1 request without exactly one
  `Host` header of the form `uri-host [":" port]`; non-UTF-8 bytes in the
  head; a
  `Content-Length` that is not a digit string or whose repeated values
  differ; end of stream after some bytes arrived but before the head or the
  body is complete.
- 408: `'read-timeout-ms` elapses while the request is being read.
- 411: any `Transfer-Encoding` header.
- 413: `Content-Length` exceeds `'max-body-bytes`.
- 431: `'max-header-bytes` is exceeded before the head ends.
- 500: the handler fails, leaves other than exactly one value, or leaves a
  response `render-response` rejects.
- 505: a version other than `HTTP/1.1` or `HTTP/1.0`.

A peer that connects and closes without sending a byte, or that resets or
otherwise fails during the read or the write, is closed silently: nothing is
written and `'on-failure` is not applied.

The handler is a quotation with the contract `( request -- response )`. Each
request applies it as `[request] handler @attempt` in a fresh unit, so a
handler's failure is data to the server and the ambient stack never crosses
the boundary. A successful handler leaves exactly one value, and that value
must satisfy `render-response`. Any other outcome — a raised error, an empty
or multi-valued result, a malformed response — answers 500 and applies the
`'on-failure` quotation to the error dictionary (for a wrong result count, a
`'contract` error naming the observed count); the serving unit and every other
in-flight request are unaffected. Every response the server writes, whether
the handler's or its own, is validated in full before any byte is written.

`@serve` serves up to `'max-in-flight` connections at a time, each in a child
unit that owns its connection, so a connection is closed on every path.
Beyond that bound, and at the host's live-connection maximum, further
connections wait in the kernel backlog.

`@serve` does not return. The serving unit ends only when it is cancelled,
failing `'cancelled`, or when an acceptor's `net.accept` fails, in which case
that error is raised from `@serve`. Abortive listener closure cancels an admitted
accept; graceful shutdown may instead report backend closure as `'io`. Admission
after closure raises `'io`. Either ending cancels and quiesces every acceptor,
reader, and handler child by the ordinary scope rules and closes every
connection those children own. The listener itself is untouched: `@serve`
never calls `net.close` on the listener it was given, which stays the
caller's to close explicitly or through its own scope and may be served
again.

#### Examples

```ecl
{'address "127.0.0.1" 'port 8080} net.listen 'l def

([["GET" "/health" (pop 200 "ok" http.response.text)]
  ["GET" "/users/:id" ("id" http.request.param 200 swap http.response.text)]]
 http.server.route)
'handler def

l {'read-timeout-ms 5000} (handler) http.server.@serve
```

### @serve
`( listener config handler -- )` — *Unit constructor*, contract
`( request -- response )` enforced per request. Validate the arguments,
fill the configuration defaults, and serve the listener until the unit ends.
A non-port listener, a non-dictionary
configuration, or a non-quotation handler is `'type`; an unknown
configuration key or a limit that is not greater than zero is `'domain`; a
limit that is not an integer or an `'on-failure` that is not a quotation is
`'type`. Validation completes before any request is accepted. The word fails
`'cancelled` when the serving unit is cancelled and re-raises an acceptor's
`'io` failure of `net.accept`; it never closes the listener.

### content-length
`( headers -- int )` — Return the request body length named by a parsed
headers dictionary: `0` when `content-length` is absent, otherwise the
integer every occurrence spells, leading zeros allowed. A value that is not a
nonempty digit string, or repeated values that differ, is `'domain` with
`'data {'status 400}`; a value too large for a 64-bit integer exceeds every
body limit and is `'domain` with `'data {'status 413}`. A non-dictionary is
`'type`.

### parse-headers
`( lines -- dict )` — Parse a list of header-line strings into a dictionary
from ASCII-lowercased name to the list of trimmed values in arrival order,
so `("Host: a" "host: b")` yields `{"host" ("a" "b")}`. The name is the text
before the first `:`, the value the rest with surrounding whitespace removed.
A line without `:`, or one beginning with space or tab, is `'domain` with
`'data {'status 400}`. A non-list or a non-string line is `'type`.

### parse-request-line
`( line -- dict )` — Parse a request line into
`{'method 'target 'path 'query 'version}`: three space-separated tokens,
`'path` and `'query` the target split at the first `?` undecoded, `'query`
`""` when there is no `?`. Any other token count is `'domain` with
`'data {'status 400}`; a version other than `HTTP/1.1` or `HTTP/1.0` is
`'domain` with `'data {'status 505}`. A non-string is `'type`.

#### Examples

```ecl
"GET /a?b=1 HTTP/1.1" http.server.parse-request-line
# => {'method "GET" 'target "/a?b=1" 'path "/a" 'query "b=1" 'version "HTTP/1.1"}
```

### render-response
`( response -- bytes )` — Validate a response dictionary and return the exact
bytes the server writes for it: `HTTP/1.1 <status> <reason>` CRLF, one
`name: value` line per header value in the given order with the name as
given, `Content-Length: <n>` CRLF (omitted for 204 and 304, whose length is
not the empty body's), `Connection: close` CRLF,
CRLF, then the body bytes. The reason phrase comes from a fixed table covering 200, 201,
204, 301, 302, 304, 400, 401, 403, 404, 405, 408, 411, 413, 431, 500, 503,
and 505 and is empty for any other status, with the space before it always
written. A non-dictionary is `'type`. Keys other than exactly `'status`,
`'headers`, and `'body`; a status that is not an integer in `200...599`; a
nonempty body with status 204, 205, or 304; a
headers value that is not a dictionary, a header name that is not a nonempty
string of HTTP token characters, a header value that is neither a string nor
a list of strings or that contains CR, LF, NUL, or a control character other
than tab, a header whose lowercased name is `content-length`, `connection`,
or `transfer-encoding`;
or a body that is neither a string nor a list of integers in `0...255` is
`'domain`.

#### Examples

```ecl
{'status 200 'headers {"set-cookie" ("a=1" "b=2")} 'body "ok"}
http.server.render-response chars
# => "HTTP/1.1 200 OK\u{D}\u{A}set-cookie: a=1\u{D}\u{A}set-cookie: b=2\u{D}\u{A}Content-Length: 2\u{D}\u{A}Connection: close\u{D}\u{A}\u{D}\u{A}ok"
```

### route
`( request routes -- response )` — *Inline.* Dispatch a request over a list
of `[method pattern handler]` rows. A pattern is a slash path whose segments
must equal the request's `'path` segments one for one, except that a segment
beginning with `:` binds any nonempty path segment under its name in a
string dictionary. The first row whose pattern and method both match has the
request, with `'params` set to that dictionary, passed to its handler, which
is applied inline with the contract `( request -- response )`; middleware is
`compose`. When some pattern matches but no matching row's method does, the
result is `405 "method not allowed" text` with an `allow` header joining the
matching rows' methods with `,`; when no pattern matches, the result is
`not-found`. Every row is checked before any comparison: a row that is not a
list of three elements is `'shape`, and a non-string method, non-string
pattern, or non-quotation handler is `'type`.
