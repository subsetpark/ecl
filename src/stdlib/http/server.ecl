### module http.server
# HTTP/1.1 framing, response construction, and routing over `net` connections.
# The module holds no host authority of its own: `@serve` reaches sockets only
# through the listener its caller bound. Framing failures are `'domain` errors
# whose `'data` carries the `'status` the server answers with, so the connection
# handler maps any such error to a minimal response without a second vocabulary.
[]
(
 ### defp crlf
 # String literals have no `\r` escape, so the line terminator is spelled out.
 (-- string : "Return the CR LF line terminator.")
 ("\u{D}\u{A}")
 'crlf defp

 ### defp framing-error
 (status message -- : "Raise a 'domain error whose data carries the response status.")
 (|status message|
  'domain error.new message error.with-message
  'status status pair dict.from-flat error.with-data raise)
 'framing-error defp

 ### defp domain-error
 (message -- error : "Build a 'domain error with the message.")
 ('domain error.new swap error.with-message)
 'domain-error defp

 ### defp type-error
 (message -- error : "Build a 'type error with the given message.")
 ('type error.new swap error.with-message)
 'type-error defp

 ### defp checked-string
 (value message -- value : "Return a string or raise 'type with the message.")
 (|value message| value str.str? message type-error assert value)
 'checked-string defp

 ### defp split-target
 (target -- path query : "Split a request target at its first `?`; the query is empty when absent.")
 ("?" split
  dup len 1 =
  (first "")
  (dup first swap rest "?" join)
  if)
 'split-target defp

 ### defp supported-version?
 (version -- bool : "Return 1 for the two request versions the server answers.")
 (dup "HTTP/1.1" match? swap "HTTP/1.0" match? or)
 'supported-version? defp

 ### def parse-request-line
 (line -- request-line :
  "Parse `METHOD TARGET VERSION` into {'method 'target 'path 'query 'version}, splitting the target
   at its first `?` without decoding. A line without exactly three space-separated tokens raises
   'domain with {'status 400}; a version other than HTTP/1.1 or HTTP/1.0 raises 'domain with
   {'status 505}.")
 ("http.server.parse-request-line expects a string" checked-string
  " " split
  dup len 3 = () (400 "malformed request line" framing-error) if
  dup 2 at supported-version? () (505 "unsupported HTTP version" framing-error) if
  (|tokens| tokens 0 at tokens 1 at tokens 1 at split-target tokens 2 at) call
  (|method target path query version|
   'method method 'target target 'path path 'query query 'version version 10 pack dict.from-flat)
  call)
 'parse-request-line def

 ### defp blank?
 (char -- bool : "Return 1 for a space or horizontal tab.")
 (dup \space = swap \tab = or)
 'blank? defp

 ### defp header-line
 (headers line -- headers :
  "Fold one `name: value` line into the dict of lowercased names to value lists.")
 (dup str.str? () (400 "malformed header line" framing-error) if
  dup len 0 = (400 "malformed header line" framing-error) when
  dup first blank? (400 "obsolete line folding" framing-error) when
  dup ":" str.contains? not (400 "malformed header line" framing-error) when
  dup ":" str.index-of
  (|line index| line index take line index 1 + drop str.trim) call
  swap dup str.lower swap dup str.trim match? not (400 "malformed header name" framing-error) when
  dup len 0 = (400 "malformed header name" framing-error) when
  dup (blank?) any? (400 "malformed header name" framing-error) when
  swap
  (|headers name value| headers name value wrap value (append) partial dict.update-or) call)
 'header-line defp

 ### def parse-headers
 (lines -- headers :
  "Fold a list of `name: value` lines into a dict from ASCII-lowercased name to a list of trimmed
   values in arrival order. A line without a colon, with an empty or whitespace-padded name, or
   beginning with a space or tab raises 'domain with {'status 400}.")
 (dup type 'list match?
  "http.server.parse-headers expects a list of header lines" type-error assert
  {} (header-line) fold)
 'parse-headers def

 ### defp digit?
 (char -- bool : "Return 1 for an ASCII decimal digit.")
 (dup \0 >= swap \9 <= and)
 'digit? defp

 ### defp decimal?
 (text -- bool : "Return 1 for a nonempty string of at most eighteen ASCII digits.")
 (dup len dup 0 > swap 18 <= and swap (digit?) all? and)
 'decimal? defp

 ### def content-length
 (headers -- length :
  "Return the request body length from a lowercased header dict: 0 when content-length is absent,
   the integer when every occurrence is the same string of decimal digits, otherwise 'domain with
   {'status 400}.")
 (dup type 'dict match? "http.server.content-length expects a header dict" type-error assert
  "content-length" [] at-or
  dup len 0 =
  (pop 0)
  (dup first dup decimal? () (400 "malformed Content-Length" framing-error) if
   swap over (match?) partial all? () (400 "conflicting Content-Length values" framing-error) if
   int)
  if)
 'content-length def

 ### defp reason
 (status -- text : "Return the reason phrase for a known status code, or the empty string.")
 ([200 ("OK")
   201 ("Created")
   204 ("No Content")
   301 ("Moved Permanently")
   302 ("Found")
   304 ("Not Modified")
   400 ("Bad Request")
   401 ("Unauthorized")
   403 ("Forbidden")
   404 ("Not Found")
   405 ("Method Not Allowed")
   408 ("Request Timeout")
   411 ("Length Required")
   413 ("Content Too Large")
   431 ("Request Header Fields Too Large")
   500 ("Internal Server Error")
   503 ("Service Unavailable")
   505 ("HTTP Version Not Supported")
   ("")]
  case)
 'reason defp

 ### defp reserved-header?
 (name -- bool : "Return 1 for a header the server writes itself.")
 (str.lower
  dup "content-length" match? over "connection" match? or swap "transfer-encoding" match? or)
 'reserved-header? defp

 ### defp header-values?
 (value -- bool : "Return 1 for a string or a list of strings.")
 (dup str.str? (pop 1) (dup type 'list match? ((str.str?) all?) (pop 0) if) if)
 'header-values? defp

 ### defp checked-header
 (pair -- : "Validate one [name values] header entry.")
 (dup first str.str? "http.server response header names must be strings" domain-error assert
  dup first reserved-header? not
  "http.server response may not set content-length, connection, or transfer-encoding" domain-error
  assert
  1 at header-values?
  "http.server response header values must be a string or a list of strings" domain-error assert)
 'checked-header defp

 ### defp byte?
 (value -- bool : "Return 1 for an int in 0...255.")
 (dup type 'int match? (dup 0 >= swap 255 <= and) (pop 0) if)
 'byte? defp

 ### defp body?
 (value -- bool : "Return 1 for a string or a byte list.")
 (dup str.str? (pop 1) (dup type 'list match? ((byte?) all?) (pop 0) if) if)
 'body? defp

 ### defp checked-response
 (response -- response : "Validate a response dict in full before anything is written.")
 (dup type 'dict match? "http.server response must be a dict" type-error assert
  dup ['status 'headers 'body] dict.keys-exactly?
  "http.server response needs exactly 'status, 'headers, and 'body" domain-error assert
  dup 'status at dup type 'int match? (dup 100 >= swap 599 <= and) (pop 0) if
  "http.server response status must be an int in 100...599" domain-error assert
  dup 'headers at dup type 'dict match? "http.server response headers must be a dict" domain-error
  assert
  dict.pairs (checked-header) for
  dup 'body at body? "http.server response body must be a string or a byte list" domain-error assert)
 'checked-response defp

 ### defp header-lines
 (headers -- lines : "Render one `name: value` line per header value in dictionary order.")
 (dict.pairs
  (dup first swap 1 at dup str.str? (wrap) () if
   swap ": " cat (swap cat) partial each)
  each
  raze)
 'header-lines defp

 ### defp body-bytes
 (body -- bytes : "Encode a string body as UTF-8; a byte list is returned unchanged.")
 (dup str.str? (bytes) () if)
 'body-bytes defp

 ### def render-response
 (response -- bytes :
  "Validate a response in full and serialize it: the HTTP/1.1 status line with a reason phrase for
   known codes, one line per header value in given order, Content-Length, Connection: close, and the
   body. A non-dict is 'type; other than exactly 'status, 'headers, and 'body, a status outside
   100...599, a non-string header name or value, a reserved header (content-length, connection,
   transfer-encoding), or a body that is neither a string nor a byte list is 'domain.")
 (checked-response
  dup 'body at body-bytes swap
  dup 'status at dup reason pair "HTTP/1.1 {} {}" str.format
  swap 'headers at header-lines cons
  over len wrap "Content-Length: {}" str.format append
  "Connection: close" append "" append "" append
  crlf join bytes swap cat)
 'render-response def

 ### defp checked-status
 (status -- status : "Return an int status or raise 'type.")
 (dup type 'int match? "http.server response constructors expect an int status" type-error assert)
 'checked-status defp

 ### def text
 (status string -- response : "Build a text/plain UTF-8 response with the given status and body.")
 ("http.server.text expects a string body" checked-string swap checked-status swap
  (|status body|
   'status status 'headers {"content-type" ("text/plain; charset=utf-8")} 'body body 6 pack
   dict.from-flat)
  call)
 'text def

 ### def json
 (status value -- response :
  "Build an application/json response whose body renders the value with json.emit.")
 (swap checked-status swap
  (|status value|
   'status status 'headers {"content-type" ("application/json")} 'body value json.emit 6 pack
   dict.from-flat)
  call)
 'json def

 ### def empty
 (status -- response : "Build a response with no headers and an empty body.")
 (checked-status 'status swap 'headers {} 'body "" 6 pack dict.from-flat)
 'empty def

 ### def redirect
 (location -- response : "Build a 302 response whose location header names the target.")
 ("http.server.redirect expects a string location" checked-string
  (|location| 'status 302 'headers "location" location wrap pair dict.from-flat 'body "" 6 pack
   dict.from-flat)
  call)
 'redirect def

 ### def not-found
 (-- response : "Build the 404 text response `not found`.")
 (404 "not found" text)
 'not-found def

 ### defp checked-route
 (row -- : "Validate one [method pattern handler] route row.")
 (dup type 'list match? "http.server.route expects [method pattern handler] rows" type-error assert
  dup len 3 = 'shape error.new "http.server.route rows have exactly three elements"
  error.with-message assert
  dup 0 at str.str? "http.server.route methods must be strings" type-error assert
  dup 1 at str.str? "http.server.route patterns must be strings" type-error assert
  2 at type 'list match? "http.server.route handlers must be quotations" type-error assert)
 'checked-route defp

 ### defp segment-ok?
 (pair -- bool : "Return 1 when a [path-segment pattern-segment] pair matches.")
 (dup first swap 1 at
  (|actual expected| expected ":" str.starts? actual len 0 > and actual expected match? or) call)
 'segment-ok? defp

 ### defp match-pattern
 (path pattern -- bool params :
  "Match a slash path against a pattern; params bind `:name` segments.")
 ("/" split swap "/" split swap
  over over len swap len =
  (zip dup (segment-ok?) all? swap (1 at ":" str.starts?) filter (dup 1 at 1 drop swap first pair)
   each
   dict.from-pairs)
  (pop pop 0 {})
  if)
 'match-pattern defp

 ### defp route-matches
 (routes path -- rows : "Return the rows whose pattern matches the path.")
 ((|row path| path row 1 at match-pattern pop) partial filter)
 'route-matches defp

 ### def route
 (request routes -- response :
  "Dispatch a request over [method pattern handler] rows. Patterns are slash paths whose `:name`
   segments bind one nonempty path segment each into a 'params string dict added to the request. The
   first row whose method and pattern both match has its handler applied inline; a pattern match
   with no method match answers 405 with an allow header; no pattern match answers 404. A malformed
   row is 'type or 'shape before any comparison.")
 (dup type 'list match? "http.server.route expects a list of rows" type-error assert
  dup (checked-route) for
  over 'path at route-matches
  dup len 0 =
  (pop pop not-found)
  (over 'method at over swap (|row method| row 0 at method match?) partial filter
   dup len 0 =
   (pop (0 at) each ", " join "allow" swap wrap pair dict.from-flat
    405 "method not allowed" text swap over 'headers at swap dict.merge 'headers swap put nip)
   (nip first over 'path at over 1 at match-pattern nip
    (|request row params| request 'params params put row 2 at call)
    call)
   if)
  if)
 'route def

 ### defp hex-digit?
 (char -- bool : "Return 1 for an ASCII hexadecimal digit.")
 (dup digit? over dup \a >= swap \f <= and or swap dup \A >= swap \F <= and or)
 'hex-digit? defp

 ### defp decode-escape
 (part -- bytes : "Decode the leading %XX of a split part and append the rest as UTF-8.")
 (dup len 2 >= "http.server.query found a truncated percent escape" domain-error assert
  dup 2 take dup (hex-digit?) all?
  "http.server.query found a malformed percent escape" domain-error assert
  "0x" swap cat int wrap swap 2 drop bytes cat)
 'decode-escape defp

 ### defp percent-decode
 (text -- text :
  "Decode %XX escapes into UTF-8 text; malformed escapes and invalid UTF-8 are 'domain.")
 ("%" split dup first bytes swap rest (decode-escape) each raze cat chars)
 'percent-decode defp

 ### defp query-pair
 (params part -- params :
  "Decode one key=value part into the params dict; later keys replace earlier.")
 ("=" split dup first percent-decode swap rest "=" join percent-decode put)
 'query-pair defp

 ### def query
 (request -- params :
  "Parse the request's 'query string into a dict from string keys to string values: `&` separates
   pairs, the first `=` separates key from value, a key without `=` maps to the empty string, `%XX`
   escapes are decoded and the result must be UTF-8, `+` is left as is, and a later duplicate key
   replaces an earlier one. An empty query is {}. A malformed escape is 'domain.")
 ('query at "http.server.query expects a string 'query" checked-string
  "&" split ("" match? not) filter {} (query-pair) fold)
 'query def
) 'http.server @defm
