### module stdlib.test.http-server
[]
(
 'stdlib.test.support
 ('equal 'raises 'raises-containing 'raises-data 'documented)
 import

 ### defp crlf
 (-- string : "Return the CR LF line terminator.")
 ("\u{D}\u{A}")
 'crlf defp

 ### test request-line
 (-- :
  "Split the request line into method, target, path, query, and version, or refuse it with a
   status.")
 ("GET /a?b=1 HTTP/1.1" http.server.parse-request-line
  {'method "GET" 'target "/a?b=1" 'path "/a" 'query "b=1" 'version "HTTP/1.1"} equal
  "POST /x?a=1?b HTTP/1.0" http.server.parse-request-line
  dup 'path at "/x" equal dup 'query at "a=1?b" equal 'version at "HTTP/1.0" equal
  "GET / HTTP/1.1" http.server.parse-request-line 'query at "" equal
  ("GET /a" http.server.parse-request-line) 'domain 'status 400 raises-data
  ("GET /a HTTP/1.1 extra" http.server.parse-request-line) 'domain 'status 400 raises-data
  ("" http.server.parse-request-line) 'domain 'status 400 raises-data
  ("GET /a HTTP/2.0" http.server.parse-request-line) 'domain 'status 505 raises-data
  ("GET /a HTTP/1.1" bytes http.server.parse-request-line) 'type "expects a string"
  raises-containing
  (5 http.server.parse-request-line) 'type "expects a string" raises-containing)
 'request-line test

 ### test headers
 (-- :
  "Lowercase header names, keep repeated values in order, trim values, and refuse malformed lines.")
 (("Host: a" "host: b" "X-Y:  v  " "Empty:") http.server.parse-headers
  {"host" ("a" "b") "x-y" ("v") "empty" ("")} equal
  () http.server.parse-headers {} equal
  (("nocolon") http.server.parse-headers) 'domain 'status 400 raises-data
  ((" folded: x") http.server.parse-headers) 'domain 'status 400 raises-data
  (("\tfolded: x") http.server.parse-headers) 'domain 'status 400 raises-data
  ((": novalue") http.server.parse-headers) 'domain 'status 400 raises-data
  (("Bad Name: x") http.server.parse-headers) 'domain 'status 400 raises-data
  (("") http.server.parse-headers) 'domain 'status 400 raises-data
  ((7) http.server.parse-headers) 'type "every header line to be a string" raises-containing
  ("Host: a" http.server.parse-headers) 'type "every header line to be a string" raises-containing
  (5 http.server.parse-headers) 'type "expects a list" raises-containing)
 'headers test

 ### test content-length
 (-- : "Read the body length from the header dict or refuse a malformed one with status 400.")
 ({} http.server.content-length 0 equal
  {"content-length" ("5")} http.server.content-length 5 equal
  {"content-length" ("5" "5")} http.server.content-length 5 equal
  {"content-length" ("0")} http.server.content-length 0 equal
  ({"content-length" ("5" "6")} http.server.content-length) 'domain 'status 400 raises-data
  ({"content-length" ("x")} http.server.content-length) 'domain 'status 400 raises-data
  ({"content-length" ("-1")} http.server.content-length) 'domain 'status 400 raises-data
  ({"content-length" ("")} http.server.content-length) 'domain 'status 400 raises-data
  {"content-length" ("005")} http.server.content-length 5 equal
  {"content-length" ("1234567890123456789")} http.server.content-length 1234567890123456789 equal
  {"content-length" ("9223372036854775807")} http.server.content-length 9223372036854775807 equal
  ({"content-length" ("9223372036854775808")} http.server.content-length) 'domain 'status 413
  raises-data
  ({"content-length" ("99999999999999999999")} http.server.content-length) 'domain 'status 413
  raises-data
  (5 http.server.content-length) 'type "expects a header dict" raises-containing)
 'content-length test

 ### test render-response
 (-- : "Serialize well-formed responses exactly and refuse every malformed shape before writing.")
 ({'status 200 'headers {"set-cookie" ("a=1" "b=2")} 'body "ok"} http.server.render-response chars
  ["HTTP/1.1 200 OK" "set-cookie: a=1" "set-cookie: b=2" "Content-Length: 2" "Connection: close" ""
   "ok"]
  crlf join
  equal
  {'status 299 'headers {"X-One" "1"} 'body [1 2 255]} http.server.render-response
  ["HTTP/1.1 299 " "X-One: 1" "Content-Length: 3" "Connection: close" "" ""] crlf join bytes
  [1 2 255] cat
  equal
  {'status 204 'headers {} 'body ""} http.server.render-response chars
  ["HTTP/1.1 204 No Content" "Content-Length: 0" "Connection: close" "" ""] crlf join
  equal
  {'status 200 'headers {} 'body "hé"} http.server.render-response chars
  ["HTTP/1.1 200 OK" "Content-Length: 3" "Connection: close" "" "hé"] crlf join
  equal
  ({'status 200 'headers {"Content-Length" "3"} 'body "ok"} http.server.render-response)
  'domain
  "content-length, connection, or transfer-encoding"
  raises-containing
  ({'status 200 'headers {"connection" ("keep-alive")} 'body "ok"} http.server.render-response)
  'domain
  "content-length, connection, or transfer-encoding"
  raises-containing
  ({'status 200 'headers {"Transfer-Encoding" "chunked"} 'body "ok"} http.server.render-response)
  'domain
  "content-length, connection, or transfer-encoding"
  raises-containing
  ({'status 600 'headers {} 'body "ok"} http.server.render-response) 'domain "100...599"
  raises-containing
  ({'status 99 'headers {} 'body "ok"} http.server.render-response) 'domain "100...599"
  raises-containing
  ({'status "200" 'headers {} 'body "ok"} http.server.render-response) 'domain "100...599"
  raises-containing
  ({'status 200 'headers {} 'body 7} http.server.render-response) 'domain "body must be"
  raises-containing
  ({'status 200 'headers {} 'body [1 256]} http.server.render-response) 'domain "body must be"
  raises-containing
  ({'status 200 'headers {} 'body "" 'x 1} http.server.render-response) 'domain "exactly"
  raises-containing
  ({'status 200 'headers {}} http.server.render-response) 'domain "exactly" raises-containing
  ({'status 200 'headers {'x "1"} 'body ""} http.server.render-response) 'domain "names must be"
  raises-containing
  ({'status 200 'headers {"" "1"} 'body ""} http.server.render-response) 'domain "names must be"
  raises-containing
  ({'status 200 'headers {"Bad Name" "1"} 'body ""} http.server.render-response) 'domain
  "names must be" raises-containing
  ({'status 200 'headers {"X:Y" "1"} 'body ""} http.server.render-response) 'domain "names must be"
  raises-containing
  ({'status 200 'headers {"X" "a\u{D}\u{A}Evil: yes"} 'body ""} http.server.render-response)
  'domain
  "without CR, LF"
  raises-containing
  ({'status 200 'headers {"X" ("ok" "a\u{A}b")} 'body ""} http.server.render-response)
  'domain
  "without CR, LF"
  raises-containing
  ({'status 200 'headers {"X" "a\u{0}b"} 'body ""} http.server.render-response) 'domain
  "without CR, LF" raises-containing
  ({'status 200 'headers {"X" "a\u{7F}b"} 'body ""} http.server.render-response) 'domain
  "without CR, LF" raises-containing
  {'status 200 'headers {"X-Ok_1!" ("a\tb" "c d")} 'body ""} http.server.render-response chars
  ["HTTP/1.1 200 OK" "X-Ok_1!: a\tb" "X-Ok_1!: c d" "Content-Length: 0" "Connection: close" "" ""]
  crlf join
  equal
  ({'query "next=%0D%0AX-Evil:%20yes"} http.server.query "next" at http.server.redirect
   http.server.render-response)
  'domain
  "without CR, LF"
  raises-containing
  ({'status 200 'headers {"x" 1} 'body ""} http.server.render-response) 'domain "values must be"
  raises-containing
  ({'status 200 'headers ("x") 'body ""} http.server.render-response) 'domain "headers must be"
  raises-containing
  (5 http.server.render-response) 'type "must be a dict" raises-containing)
 'render-response test

 ### test constructors
 (-- : "Build well-formed responses with the documented statuses, headers, and bodies.")
 (200 "hi" http.server.text
  {'status 200 'headers {"content-type" ("text/plain; charset=utf-8")} 'body "hi"} equal
  201 {"a" (1 'null)} http.server.json
  {'status 201 'headers {"content-type" ("application/json")} 'body "{\"a\":[1,null]}"} equal
  204 http.server.empty {'status 204 'headers {} 'body ""} equal
  "/there" http.server.redirect {'status 302 'headers {"location" ("/there")} 'body ""} equal
  http.server.not-found
  {'status 404 'headers {"content-type" ("text/plain; charset=utf-8")} 'body "not found"} equal
  200 "hi" http.server.text http.server.render-response len 0 > 1 equal
  201 {"a" 1} http.server.json http.server.render-response len 0 > 1 equal
  204 http.server.empty http.server.render-response len 0 > 1 equal
  "/x" http.server.redirect http.server.render-response len 0 > 1 equal
  http.server.not-found http.server.render-response len 0 > 1 equal
  ("200" "hi" http.server.text) 'type "int status" raises-containing
  (200 5 http.server.text) 'type "string body" raises-containing
  ("201" {} http.server.json) 'type "int status" raises-containing
  ("204" http.server.empty) 'type "int status" raises-containing
  (5 http.server.redirect) 'type "string location" raises-containing)
 'constructors test

 ### test route
 (-- : "Dispatch on method and pattern, bind :name segments, and answer 405 or 404 otherwise.")
 ({'method "GET" 'path "/users/42"}
  [["GET" "/users/:id" ('params at "id" at)] ["POST" "/users" (pop "posted")]]
  http.server.route
  "42" equal
  {'method "POST" 'path "/users"}
  [["GET" "/users/:id" ('params at "id" at)] ["POST" "/users" (pop "posted")]]
  http.server.route
  "posted" equal
  {'method "GET" 'path "/"} [["GET" "/" ('params at)]] http.server.route {} equal
  {'method "GET" 'path "/a/b"} [["GET" "/:x/:y" ('params at)]] http.server.route {"x" "a" "y" "b"}
  equal
  {'method "GET" 'path "/users"}
  [["GET" "/users/:id" ('params at)] ["POST" "/users" (pop 1)] ["PUT" "/users" (pop 2)]]
  http.server.route
  dup 'status at 405 equal
  dup 'headers at "allow" at ("POST, PUT") equal
  'headers at "content-type" at ("text/plain; charset=utf-8") equal
  {'method "GET" 'path "/nope"} [["GET" "/users/:id" ('params at)]] http.server.route 'status at 404
  equal
  {'method "GET" 'path "/users/"} [["GET" "/users/:id" ('params at)]] http.server.route 'status at
  404 equal
  {'method "GET" 'path "/x"} [] http.server.route 'status at 404 equal
  ({'method "GET" 'path "/x"} [["GET" "/x"]] http.server.route) 'shape "three elements"
  raises-containing
  ({'method "GET" 'path "/x"} [[5 "/x" (1)]] http.server.route) 'type "methods must be"
  raises-containing
  ({'method "GET" 'path "/x"} [["GET" 5 (1)]] http.server.route) 'type "patterns must be"
  raises-containing
  ({'method "GET" 'path "/x"} [["GET" "/x" 1]] http.server.route) 'type "handlers must be"
  raises-containing
  ({'method "GET" 'path "/x"} 5 http.server.route) 'type "list of rows" raises-containing)
 'route test

 ### test query
 (-- : "Decode the query string into a dict, percent-decoding escapes and letting later keys win.")
 ({'query "a=1&b=%2Fx&c&a=2"} http.server.query {"a" "2" "b" "/x" "c" ""} equal
  {'query ""} http.server.query {} equal
  {'query "&&"} http.server.query {} equal
  {'query "k=a=b"} http.server.query {"k" "a=b"} equal
  {'query "a+b=c+d"} http.server.query {"a+b" "c+d"} equal
  {'query "%C3%A9=%c3%a9"} http.server.query {"é" "é"} equal
  ({'query "a=%2"} http.server.query) 'domain "truncated" raises-containing
  ({'query "a=%zz"} http.server.query) 'domain "malformed" raises-containing
  ({'query "a=%FF"} http.server.query) 'domain "valid UTF-8" raises-containing
  ({'query 5} http.server.query) 'type "string 'query" raises-containing)
 'query test

 ### test documentation
 (-- : "Expose documentation for every http.server export.")
 (['http.server.parse-request-line 'http.server.parse-headers 'http.server.content-length
   'http.server.render-response 'http.server.text 'http.server.json 'http.server.empty
   'http.server.redirect 'http.server.not-found 'http.server.route 'http.server.query]
  documented)
 'documentation test
) 'stdlib.test.http-server @defm
