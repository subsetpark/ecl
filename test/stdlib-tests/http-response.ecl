### module stdlib.test.http-response
[]
(
 'stdlib.test.support ('equal 'raises 'raises-containing 'documented) import

 ### defp cookie-response
 (-- response : "Return a response whose headers repeat a name under differing letter cases.")
 ({'status 200 'headers {"X" "a" "Set-Cookie" ("b" "c") "x" "d"} 'body ""})
 'cookie-response defp

 ### defp greeting
 (-- response : "Return the 200 text response hi.")
 (200 "hi" http.response.text)
 'greeting defp

 ### test validity
 (-- : "Accept every well-shaped response dict and refuse each malformed shape without raising.")
 ({'status 200 'headers {} 'body ""} http.response.valid? 1 equal
  {'status 599 'headers {"X" "a" "Y" ("b" "c")} 'body [1 255]} http.response.valid? 1 equal
  {'status 100 'headers {} 'body ""} http.response.valid? 1 equal
  {'status 99 'headers {} 'body ""} http.response.valid? 0 equal
  {'status 600 'headers {} 'body ""} http.response.valid? 0 equal
  {'status "200" 'headers {} 'body ""} http.response.valid? 0 equal
  {'status 200 'headers {} 'body 7} http.response.valid? 0 equal
  {'status 200 'headers {} 'body [256]} http.response.valid? 0 equal
  {'status 200 'headers {'x "a"} 'body ""} http.response.valid? 0 equal
  {'status 200 'headers {"x" 1} 'body ""} http.response.valid? 0 equal
  {'status 200 'headers () 'body ""} http.response.valid? 0 equal
  {'status 200 'headers {} 'body "" 'extra 1} http.response.valid? 0 equal
  {'status 200 'headers {}} http.response.valid? 0 equal
  5 http.response.valid? 0 equal
  "x" http.response.valid? 0 equal)
 'validity test

 ### test constructors
 (-- : "Build well-formed responses with the documented statuses, headers, and bodies.")
 (204 http.response.new {'status 204 'headers {} 'body ""} equal
  200 "hi" http.response.text
  {'status 200 'headers {"content-type" ("text/plain; charset=utf-8")} 'body "hi"} equal
  201 {"a" (1 'null)} http.response.json
  {'status 201 'headers {"content-type" ("application/json")} 'body "{\"a\":[1,null]}"} equal
  "/there" http.response.redirect {'status 302 'headers {"location" ("/there")} 'body ""} equal
  http.response.not-found
  {'status 404 'headers {"content-type" ("text/plain; charset=utf-8")} 'body "not found"} equal
  204 http.response.new http.response.valid? 1 equal
  200 "hi" http.response.text http.response.valid? 1 equal
  201 {} http.response.json http.response.valid? 1 equal
  "/x" http.response.redirect http.response.valid? 1 equal
  http.response.not-found http.response.valid? 1 equal
  (99 http.response.new) 'type "int status" raises-containing
  ("200" http.response.new) 'type "int status" raises-containing
  ("200" "hi" http.response.text) 'type "int status" raises-containing
  (200 5 http.response.text) 'type "string body" raises-containing
  ("201" {} http.response.json) 'type "int status" raises-containing
  (5 http.response.redirect) 'type "string location" raises-containing)
 'constructors test

 ### test headers
 (-- : "Read headers by name regardless of letter case, as lists, in dictionary order.")
 (cookie-response "set-cookie" http.response.header ("b" "c") equal
  cookie-response "SET-COOKIE" http.response.header ("b" "c") equal
  cookie-response "x" http.response.header ("a" "d") equal
  cookie-response "nope" http.response.header () equal
  cookie-response "Set-Cookie" http.response.header? 1 equal
  cookie-response "nope" http.response.header? 0 equal
  (cookie-response 5 http.response.header) 'type "string header name" raises-containing
  ({'status 200} "x" http.response.header) 'type "response dict" raises-containing)
 'headers test

 ### test status
 (-- : "Classify statuses.")
 (200 http.response.new http.response.class 2 equal
  204 http.response.new http.response.ok? 1 equal
  301 http.response.new http.response.class 3 equal
  404 http.response.new http.response.ok? 0 equal
  http.response.not-found http.response.class 4 equal
  ({'status 200} http.response.class) 'type "response dict" raises-containing)
 'status test

 ### test updaters
 (-- : "Return updated copies with a new status, body, or headers, leaving the original unchanged.")
 (greeting 201 http.response.with-status 'status at 201 equal
  greeting 'status at 200 equal
  greeting [1 2] http.response.with-body 'body at [1 2] equal
  greeting "bye" http.response.with-body 'body at "bye" equal
  greeting "X" "d" http.response.with-header 'headers at
  {"content-type" ("text/plain; charset=utf-8") "X" ("d")} equal
  greeting "X" "d" http.response.with-header "X" ("e" "f") http.response.with-header 'headers at "X"
  at
  ("d" "e" "f") equal
  {'status 200 'headers {"x" ""} 'body ""} "x" "v" http.response.with-header 'headers at
  {"x" ("" "v")} equal
  greeting "Content-Type" "z" http.response.with-header "content-type" http.response.header
  ("text/plain; charset=utf-8" "z") equal
  greeting {"X" "z" "content-type" "y"} http.response.with-headers 'headers at
  {"content-type" "y" "X" "z"} equal
  (greeting 99 http.response.with-status) 'type "int status" raises-containing
  (greeting 7 http.response.with-body) 'type "string or byte list" raises-containing
  (greeting 5 "d" http.response.with-header) 'type "string header name" raises-containing
  (greeting "X" 5 http.response.with-header) 'type "string or a list of strings" raises-containing
  (greeting {'x "a"} http.response.with-headers) 'type "dict of headers" raises-containing
  (5 "X" "d" http.response.with-header) 'type "response dict" raises-containing)
 'updaters test

 ### test documentation
 (-- : "Expose documentation for every http.response export.")
 (['http.response.valid? 'http.response.new 'http.response.text 'http.response.json
   'http.response.redirect 'http.response.not-found 'http.response.header 'http.response.header?
   'http.response.class 'http.response.ok? 'http.response.with-status 'http.response.with-body
   'http.response.with-header 'http.response.with-headers]
  documented)
 'documentation test
) 'stdlib.test.http-response @defm
