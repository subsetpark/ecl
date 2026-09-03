### module stdlib.test.http-request
[]
(
 'stdlib.test.support ('equal 'raises 'raises-containing 'documented) import

 ### defp multi-header-request
 (-- request :
  "Return a GET request carrying two X-Multi headers added under differing letter cases.")
 ("GET" "/" http.request.new
  "X-Multi" "one" http.request.with-header "x-multi" ("two" "three") http.request.with-header)
 'multi-header-request defp

 ### defp bound-request
 (-- request : "Return a request with the route parameter id bound to 42.")
 ("GET" "/users/42" http.request.new "id" "42" http.request.with-param)
 'bound-request defp

 ### defp posted
 (-- request : "Return a POST request whose body is the UTF-8 encoding of hé.")
 ("POST" "/" http.request.new "h\u{E9}" http.request.with-body)
 'posted defp

 ### test construction
 (-- : "Build a request from method and target, splitting path and query at the first ?.")
 ("GET" "/users/42?id=7&x=%2F" http.request.new
  {'method "GET" 'target "/users/42?id=7&x=%2F" 'path "/users/42" 'query "id=7&x=%2F"
   'headers {} 'body [] 'peer ""}
  equal
  "POST" "/x" http.request.new 'query at "" equal
  "GET" "/a?b?c" http.request.new dup 'path at "/a" equal 'query at "b?c" equal
  "GET" "/" http.request.new http.request.valid? 1 equal
  (5 "/" http.request.new) 'type "string method" raises-containing
  ("GET" 5 http.request.new) 'type "string target" raises-containing)
 'construction test

 ### test validity
 (-- : "Accept the request shape with or without route params and refuse each malformed shape.")
 ("GET" "/" http.request.new http.request.valid? 1 equal
  "GET" "/" http.request.new "id" "1" http.request.with-param http.request.valid? 1 equal
  {'method "GET" 'target "/" 'path "/" 'query "" 'headers {"host" ("h")} 'body [1 2] 'peer "p"}
  http.request.valid? 1 equal
  {'method "GET" 'target "/" 'path "/" 'query "" 'headers {"host" "h"} 'body [] 'peer "p"}
  http.request.valid? 0 equal
  {'method "GET" 'target "/" 'path "/" 'query "" 'headers {"Host" ("h")} 'body [] 'peer "p"}
  http.request.valid? 0 equal
  {'method "GET" 'target "/" 'path "/" 'query "" 'headers {} 'body "x" 'peer "p"}
  http.request.valid? 0 equal
  {'method "GET" 'target "/" 'path "/" 'query "" 'headers {} 'body [300] 'peer "p"}
  http.request.valid? 0 equal
  {'method 'get 'target "/" 'path "/" 'query "" 'headers {} 'body [] 'peer "p"} http.request.valid?
  0 equal
  {'method "GET" 'target "/" 'path "/" 'query "" 'headers {} 'body [] 'peer "p" 'params {"a" 1}}
  http.request.valid? 0 equal
  {'method "GET" 'target "/" 'path "/" 'headers {} 'body [] 'peer "p"} http.request.valid? 0 equal
  5 http.request.valid? 0 equal)
 'validity test

 ### test headers
 (-- : "Read and add headers under lowercased names, keeping repeated values in order.")
 (multi-header-request "X-MULTI" http.request.header ("one" "two" "three") equal
  multi-header-request 'headers at {"x-multi" ("one" "two" "three")} equal
  multi-header-request "host" http.request.header () equal
  multi-header-request "x-multi" http.request.header? 1 equal
  multi-header-request "host" http.request.header? 0 equal
  (multi-header-request 5 http.request.header) 'type "string header name" raises-containing
  (multi-header-request 5 "v" http.request.with-header) 'type "string header name" raises-containing
  (multi-header-request "x" 5 http.request.with-header)
  'type
  "string or a list of strings"
  raises-containing
  ({'method "GET"} "x" http.request.header) 'type "request dict" raises-containing)
 'headers test

 ### test query
 (-- : "Decode the query string into a dict, percent-decoding escapes and letting later keys win.")
 ("GET" "/?a=1&b=%2Fx&c&a=2" http.request.new http.request.query {"a" "2" "b" "/x" "c" ""} equal
  "GET" "/" http.request.new http.request.query {} equal
  "GET" "/?&&" http.request.new http.request.query {} equal
  "GET" "/?k=a=b" http.request.new http.request.query {"k" "a=b"} equal
  "GET" "/?a+b=c+d" http.request.new http.request.query {"a+b" "c+d"} equal
  "GET" "/?%C3%A9=%c3%a9" http.request.new http.request.query {"\u{E9}" "\u{E9}"} equal
  ("GET" "/?a=%2" http.request.new http.request.query) 'domain "truncated" raises-containing
  ("GET" "/?a=%zz" http.request.new http.request.query) 'domain "malformed" raises-containing
  ("GET" "/?a=%FF" http.request.new http.request.query) 'domain "valid UTF-8" raises-containing
  (5 http.request.query) 'type "request dict" raises-containing)
 'query test

 ### test params
 (-- : "Bind and read route parameters.")
 (bound-request "id" http.request.param "42" equal
  bound-request 'params at {"id" "42"} equal
  bound-request "name" "n" http.request.with-param "name" http.request.param "n" equal
  (bound-request "nope" http.request.param) 'domain "no such route parameter" raises-containing
  ("GET" "/" http.request.new "id" http.request.param) 'domain "no such route parameter"
  raises-containing
  (bound-request 5 http.request.param) 'type "string parameter name" raises-containing
  (bound-request "id" 5 http.request.with-param) 'type "string value" raises-containing)
 'params test

 ### test bodies
 (-- : "Replace and decode bodies as bytes, text, and JSON.")
 (posted 'body at [104 195 169] equal
  posted http.request.text "h\u{E9}" equal
  posted [97 98] http.request.with-body http.request.text "ab" equal
  posted "{\"a\":[1,null]}" http.request.with-body http.request.json {"a" (1 'null)} equal
  (posted [255] http.request.with-body http.request.text) 'domain "valid UTF-8" raises-containing
  (posted "{" http.request.with-body http.request.json) 'parse raises
  (posted [300] http.request.with-body) 'type "string or byte list" raises-containing
  (posted 7 http.request.with-body) 'type "string or byte list" raises-containing)
 'bodies test

 ### test documentation
 (-- : "Expose documentation for every http.request export.")
 (['http.request.valid? 'http.request.new 'http.request.header 'http.request.header?
   'http.request.query 'http.request.param 'http.request.text 'http.request.json
   'http.request.with-header 'http.request.with-body 'http.request.with-param]
  documented)
 'documentation test
) 'stdlib.test.http-request @defm
