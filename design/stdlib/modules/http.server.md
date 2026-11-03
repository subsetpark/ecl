## http.server

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
