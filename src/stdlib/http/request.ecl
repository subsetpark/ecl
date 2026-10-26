### module http.request
# A request is a dict whose recognized fields are 'method, 'target, 'path,
# 'query, 'headers, 'body, 'peer, and 'params. Every field is optional, so the
# same value can describe overrides for an outbound http.get or http.post, a
# complete request consumed by http.send, or the complete request http.server
# hands a handler. These words build one, read its fields using empty defaults,
# and return updated copies.
[]
(
 ### defp type-error
 (message -- error : "Build a 'type error with the message.")
 ('type error.new swap error.with-message) 'type-error defp

 ### defp domain-error
 (message -- error : "Build a 'domain error with the message.")
 ('domain error.new swap error.with-message) 'domain-error defp

 ### defp string-list?
 (value -- bool : "Return 1 for a list of strings.")
 (dup type 'list match? ((str.str?) all?) (pop 0) if) 'string-list? defp

 ### defp header-pair?
 (pair -- bool :
  "Return 1 for a [name values] entry with a lowercased string name and a list of string values.")
 (dup first dup str.str? (dup str.lower match?) (pop 0) if (1 at string-list?) (pop 0) if)
 'header-pair? defp

 ### defp headers?
 (value -- bool : "Return 1 for a dict from ASCII-lowercased string names to lists of strings.")
 (dup type 'dict match? (dict.pairs (header-pair?) all?) (pop 0) if) 'headers? defp

 ### defp byte?
 (value -- bool : "Return 1 for an int in 0...255.")
 (dup type 'int match? (dup 0 >= swap 255 <= and) (pop 0) if) 'byte? defp

 ### defp bytes?
 (value -- bool : "Return 1 for a byte list.")
 (dup type 'list match? ((byte?) all?) (pop 0) if) 'bytes? defp

 ### defp params?
 (value -- bool : "Return 1 for a dict from string names to string values.")
 (dup type 'dict match? (dup dict.keys (str.str?) all? swap dict.vals (str.str?) all? and) (pop 0)
  if) 'params? defp

 ### defp string-field?
 (name request -- bool : "Return 1 when an optional request field is absent or a string.")
 (swap over over dict.has? (at str.str?) (pop pop 1) if) 'string-field? defp

 ### def valid?
 (value -- bool :
  "Return 1 for a partial or complete request dictionary containing only recognized fields: string
   `'method`, `'target`, `'path`, `'query`, and `'peer`; a `'headers` dictionary from
   ASCII-lowercased string names to lists of strings; a byte-list `'body`; and a `'params`
   dictionary from string names to string values. Every field is optional. Never raises.")
 (dup type 'dict match?
  (dup dict.keys ['method 'target 'path 'query 'headers 'body 'peer 'params] in? (1 match?) all?
   (dup ['method 'target 'path 'query 'peer] swap (string-field?) partial all?
    over 'headers {} dict.get headers? and
    over 'body [] dict.get bytes? and
    over 'params {} dict.get params? and
    nip)
   (pop 0)
   if)
  (pop 0)
  if) 'valid? def

 ### defp checked
 (request -- request : "Return a partial or complete request dict or raise 'type.")
 (dup valid? "expected a request dict with recognized, well-typed fields"
  type-error assert) 'checked defp

 ### defp checked-string
 (value message -- value : "Return a string or raise 'type with the message.")
 (|value message| value str.str? message type-error assert value) 'checked-string defp

 ### defp split-target
 (target -- path query : "Split a request target at its first `?`; the query is empty when absent.")
 ("?" split
  dup len 1 =
  (first "")
  (dup first swap rest "?" join)
  if) 'split-target defp

 ### def new
 (method target -- request :
  "Return a request with the method and target, `'path` and `'query` split from the target at its
   first `?` (`'query` `\"\"` when absent), `{}` headers, `[]` body, and `\"\"` peer. A non-string
   method or target is `'type`.")
 ("http.request.new expects a string target" checked-string
  swap "http.request.new expects a string method" checked-string swap
  dup split-target
  (|method target path query|
   'method method 'target target 'path path 'query query 'headers {} 'body [] 'peer "" 14 pack
   dict.from-flat)
  call) 'new def

 ### def header
 (request name -- values :
  "Return the list of values of a header, matching the name regardless of letter case, or `()` when
   it is absent. A non-request or non-string name is `'type`.")
 ("http.request.header expects a string header name" checked-string str.lower
  swap checked 'headers {} dict.get swap () dict.get) 'header def

 ### def header?
 (request name -- bool : "Return 1 when the request carries the header under any letter case.")
 (header len 0 >) 'header? def

 ### defp hex-digit?
 (char -- bool : "Return 1 for an ASCII hexadecimal digit.")
 (dup dup \0 >= swap \9 <= and
  over dup \a >= swap \f <= and or
  swap dup \A >= swap \F <= and or) 'hex-digit? defp

 ### defp decode-escape
 (part -- bytes : "Decode the leading %XX of a split part and append the rest as UTF-8.")
 (dup len 2 >= "http.request.query found a truncated percent escape" domain-error assert
  dup 2 take dup (hex-digit?) all?
  "http.request.query found a malformed percent escape" domain-error assert
  "0x" swap cat int wrap swap 2 drop bytes cat) 'decode-escape defp

 ### defp percent-decode
 (text -- text :
  "Decode %XX escapes into UTF-8 text; malformed escapes and invalid UTF-8 are 'domain.")
 ("%" split dup first bytes swap rest (decode-escape) each raze cat chars) 'percent-decode defp

 ### defp query-pair
 (params part -- params :
  "Decode one key=value part into the params dict; later keys replace earlier.")
 ("=" split dup first percent-decode swap rest "=" join percent-decode put) 'query-pair defp

 ### def query
 (request -- params :
  "Parse the request's `'query` string, such as `\"a=1&b=%2Fx&c\"`, into a dictionary from string
   keys to string values, such as `{\"a\" \"1\" \"b\" \"/x\" \"c\" \"\"}`: `&`-separated pairs, each
   split at its first `=`, a pair without `=` mapping its key to `\"\"`, empty pieces ignored, and a
   later duplicate key replacing an earlier one. `%XX` escapes are decoded in keys and values and
   the decoded text must be valid UTF-8; `+` is left as it is. An empty query is `{}`. A `%` not
   followed by two hexadecimal digits, or a decoded key or value that is not valid UTF-8, is
   `'domain`; a non-request is `'type`.")
 (checked 'query "" dict.get "&" split ("" match? not) filter {} (query-pair) fold) 'query def

 ### def param
 (request name -- value :
  "Return the route parameter bound under the name by `http.server.route`. A request without that
   parameter is `'domain`; a non-request or non-string name is `'type`.")
 ("http.request.param expects a string parameter name" checked-string
  (|request name|
   request checked 'params {} dict.get
   dup name dict.has? "http.request.param found no such route parameter" domain-error assert
   name at)
  call) 'param def

 ### def text
 (request -- string :
  "Return the body decoded as UTF-8 text. A body that is not valid UTF-8 is 'domain, as for chars.")
 (checked 'body [] dict.get chars) 'text def

 ### def json
 (request -- value :
  "Return the body parsed as JSON: `chars` then `json.parse`, so a body that is not UTF-8 or not
   JSON fails as they do.")
 (text json.parse) 'json def

 ### def with-header
 (request name value -- request :
  "Return the request with a value added under the ASCII-lowercased header name: a string or a list
   of strings, appended to the values already there. A non-string name or a bad value is `'type`.")
 (dup str.str? (wrap) () if
  dup string-list? "http.request.with-header expects a string or a list of strings" type-error
  assert
  swap "http.request.with-header expects a string header name" checked-string str.lower
  (|request value name|
   request checked 'headers {} dict.get name () dict.get value cat
   request 'headers {} dict.get name rolldown put
   request 'headers rolldown put)
  call) 'with-header def

 ### def with-body
 (request body -- request :
  "Return the request with a new body: a byte list as given, or a string encoded as UTF-8. Another
   kind is 'type.")
 (dup str.str? (bytes) () if
  dup bytes? "http.request.with-body expects a string or byte list" type-error assert
  swap checked 'body rolldown put) 'with-body def

 ### def with-param
 (request name value -- request :
  "Return the request with a route parameter bound under the name, as `http.server.route` does. A
   non-string name or value is `'type`.")
 ("http.request.with-param expects a string value" checked-string
  swap "http.request.with-param expects a string parameter name" checked-string swap
  (|request name value| request checked 'params {} dict.get name value put request 'params rolldown
   put)
  call) 'with-param def
) 'http.request @defm
