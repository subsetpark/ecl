## http.request

Words over partial or complete request dictionaries. Recognized optional
fields are `` `method ``, `` `target ``, `` `path ``, `` `query ``, `` `headers ``, `` `body ``,
`` `peer ``, and `` `params ``. `http.server` handlers receive every field except
`` `params ``, which `http.server.route` may add; outbound `http.get` and
`http.post` accept partial values and apply their documented defaults, while
`http.send` consumes a complete value. The words here build a complete
request, read absent headers/query/body using empty defaults, and return
updated copies; the original is never changed. A word given a malformed
request dictionary, or a name that is not a string, is `` `type ``.

### query

#### Examples

```ecl
"GET" "/?a=1&b=%2Fx&c" http.request.new http.request.query
# => {"a" "1" "b" "/x" "c" ""}
```
