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
`{method target path query headers body peer}`:

- `` `method `` and `` `target `` are the first two tokens of the request line, as
  strings;
- `` `path `` and `` `query `` are the target split at the first `?`, undecoded;
  `` `query `` is `""` when the target has no `?`;
- `` `headers `` is a dictionary from ASCII-lowercased header name to the list of
  its trimmed values in arrival order, so a repeated header keeps every value;
- `` `body `` is the exact byte list named by `Content-Length`, `[]` when the
  request has none; and
- `` `peer `` is the peer's `address:port` formatted from `net.peer-address`,
  with an IPv6 address in brackets.

A response is the dictionary `{status headers body}` with exactly those
keys: an integer status in `200...599`, since interim 1xx responses are not
served, with an empty body when the status is 204, 205, or 304; a headers
dictionary whose keys are
strings and whose values are a string or a list of strings, written once per
value in the given order and with the name as given; and a body that is a
string, written as UTF-8, or a byte list. The names `content-length`,
`connection`, and `transfer-encoding` are reserved in any letter case: the
server writes `Content-Length` and `Connection: close` itself, and a response
naming one of them is `` `domain ``. Header names must be nonempty HTTP tokens
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

- `` `max-header-bytes `` (default `32768`): the most bytes accepted before the
  CRLFCRLF that ends the head; more is 431.
- `` `max-body-bytes `` (default `1048576`): the largest `Content-Length`
  accepted; a larger one is 413 before any body byte is read.
- `` `max-in-flight `` (default `128`): the number of acceptor children, each
  handling one connection at a time.
- `` `read-timeout-ms `` (default `10000`): the deadline for reading one whole
  request, head and body; expiry is 408.
- `` `on-failure `` (default `(str io.eprint)`): a quotation `( error -- )`
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
- 408: `` `read-timeout-ms `` elapses while the request is being read.
- 411: any `Transfer-Encoding` header.
- 413: `Content-Length` exceeds `` `max-body-bytes ``.
- 431: `` `max-header-bytes `` is exceeded before the head ends.
- 500: the handler fails, leaves other than exactly one value, or leaves a
  response `render-response` rejects.
- 505: a version other than `HTTP/1.1` or `HTTP/1.0`.

A peer that connects and closes without sending a byte, or that resets or
otherwise fails during the read or the write, is closed silently: nothing is
written and `` `on-failure `` is not applied.

The handler is a quotation with the contract `( request -- response )`. Each
request applies it as `[request] handler @attempt` in a fresh unit, so a
handler's failure is data to the server and the ambient stack never crosses
the boundary. A successful handler leaves exactly one value, and that value
must satisfy `render-response`. Any other outcome — a raised error, an empty
or multi-valued result, a malformed response — answers 500 and applies the
`` `on-failure `` quotation to the error dictionary (for a wrong result count, a
`` `contract `` error naming the observed count); the serving unit and every other
in-flight request are unaffected. Every response the server writes, whether
the handler's or its own, is validated in full before any byte is written.

`@serve` serves up to `` `max-in-flight `` connections at a time, each in a child
unit that owns its connection, so a connection is closed on every path.
Beyond that bound, and at the host's live-connection maximum, further
connections wait in the kernel backlog.

`@serve` does not return. The serving unit ends only when it is cancelled,
failing `` `cancelled ``, or when an acceptor's `net.accept` fails, in which case
that error is raised from `@serve`. Abortive listener closure cancels an admitted
accept; graceful shutdown may instead report backend closure as `` `io ``. Admission
after closure raises `` `io ``. Either ending cancels and quiesces every acceptor,
reader, and handler child by the ordinary scope rules and closes every
connection those children own. The listener itself is untouched: `@serve`
never calls `net.close` on the listener it was given, which stays the
caller's to close explicitly or through its own scope and may be served
again.

#### Examples

```ecl
{address "127.0.0.1" port 8080} net.listen `l def

([["GET" "/health" (pop 200 "ok" http.response.text)]
  ["GET" "/users/:id" ("id" http.request.param 200 swap http.response.text)]]
 http.server.route)
`handler def

l {read-timeout-ms 5000} (handler) http.server.@serve
```

### parse-request-line

#### Examples

```ecl
"GET /a?b=1 HTTP/1.1" http.server.parse-request-line
# => {method "GET" target "/a?b=1" path "/a" query "b=1" version "HTTP/1.1"}
```

### render-response

#### Examples

```ecl
{status 200 headers {"set-cookie" ("a=1" "b=2")} body "ok"}
http.server.render-response chars
# => "HTTP/1.1 200 OK\u{D}\u{A}set-cookie: a=1\u{D}\u{A}set-cookie: b=2\u{D}\u{A}Content-Length: 2\u{D}\u{A}Connection: close\u{D}\u{A}\u{D}\u{A}ok"
```
