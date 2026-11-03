## http.request

### query

#### Examples

```ecl
"GET" "/?a=1&b=%2Fx&c" http.request.new http.request.query
# => {"a" "1" "b" "/x" "c" ""}
```
