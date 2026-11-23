## http.request

### query

#### Examples

```ecl
{query "a=1&b=%2Fx&c"} http.request.query
# => {"a" "1" "b" "/x" "c" ""}
```
