### module http.server
# HTTP/1.1 framing, routing, and serving over `net` connections; request and
# response values are built and read with http.request and http.response.
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
  "Parse a request line such as \"GET /users?id=42 HTTP/1.1\" into {'method \"GET\" 'target
   \"/users?id=42\" 'path \"/users\" 'query \"id=42\" 'version \"HTTP/1.1\"}: 'path and 'query are
   the target split at its first ?, undecoded, with 'query \"\" when absent. A line without exactly
   three space-separated tokens is 'domain with 'data {'status 400}; a version other than HTTP/1.1
   or HTTP/1.0 is 'domain with 'data {'status 505}; a non-string is 'type.")
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
 (dup len 0 = (400 "malformed header line" framing-error) when
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
  "Fold a list of header lines such as (\"Host: a\" \"X-Multi: one\" \"x-multi: two\") into a dict
   from ASCII-lowercased name to the list of its values, trimmed of surrounding ASCII whitespace, in
   arrival order: {\"host\" (\"a\") \"x-multi\" (\"one\" \"two\")}. A non-list, or a list with an
   element that is not a string, is 'type. A line that has no :, has an empty name or a name
   containing whitespace, or begins with a space or tab (obsolete line folding) is 'domain with
   'data {'status 400}. () is {}.")
 (dup type 'list match? "http.server.parse-headers expects a list of header lines" type-error assert
  dup (str.str?) all? "http.server.parse-headers expects every header line to be a string"
  type-error assert
  {} (header-line) fold)
 'parse-headers def

 ### defp digit?
 (char -- bool : "Return 1 for an ASCII decimal digit.")
 (dup \0 >= swap \9 <= and)
 'digit? defp

 ### defp decimal?
 (text -- bool : "Return 1 for a nonempty string of ASCII digits.")
 (dup len 0 > swap (digit?) all? and)
 'decimal? defp

 ### defp strip-zeros
 (digits -- digits : "Remove leading zeros from a digit string, keeping at least one digit.")
 (dup (\0 = not) each where dup len 0 = (pop dup len 1 - drop) (first drop) if)
 'strip-zeros defp

 ### defp representable?
 (digits -- bool : "Return 1 when a zero-stripped digit string fits a signed 64-bit int.")
 (dup len 19 < (pop 1) (dup len 19 = ("9223372036854775807" lex-cmp 1 <) (pop 0) if) if)
 'representable? defp

 ### def content-length
 (headers -- length :
  "Return the request body length named by a headers dict as parse-headers builds it: 0 when
   content-length is absent, otherwise the int that every occurrence spells ({\"content-length\"
   (\"5\")} is 5). A value that is not a nonempty string of decimal digits, or repeated values that
   differ, is 'domain with 'data {'status 400}; a value too large for a 64-bit int exceeds every
   body limit and is 'domain with 'data {'status 413}; a non-dict is 'type.")
 (dup type 'dict match? "http.server.content-length expects a header dict" type-error assert
  "content-length" [] at-or
  dup len 0 =
  (pop 0)
  (dup first dup decimal? () (400 "malformed Content-Length" framing-error) if
   swap over (match?) partial all? () (400 "conflicting Content-Length values" framing-error) if
   strip-zeros dup representable? ()
   (413 "Content-Length exceeds the representable range" framing-error) if
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

 ### defp token-char?
 (char -- bool :
  "Return 1 for an HTTP token character: a letter, digit, or one of !#$%&'*+-.^_`|~.")
 (dup digit?
  over dup \a >= swap \z <= and or
  over dup \A >= swap \Z <= and or
  swap "!#$%&'*+-.^_`|~" in? or)
 'token-char? defp

 ### defp token?
 (name -- bool : "Return 1 for a nonempty string of HTTP token characters.")
 (dup str.str? (dup len 0 > swap (token-char?) all? and) (pop 0) if)
 'token? defp

 ### defp field-char?
 (char -- bool :
  "Return 1 for a character allowed in a header value: tab, or anything from space up that is not
   DEL.")
 (dup \tab = swap dup \space >= swap 127 char = not and or)
 'field-char? defp

 ### defp field-value?
 (value -- bool : "Return 1 for a string whose every character may appear in a header value.")
 (dup str.str? ((field-char?) all?) (pop 0) if)
 'field-value? defp

 ### defp header-values?
 (value -- bool : "Return 1 for a header value or a list of them.")
 (dup str.str? (field-value?) (dup type 'list match? ((field-value?) all?) (pop 0) if) if)
 'header-values? defp

 ### defp checked-header
 (pair -- :
  "Validate one [name values] header entry: a token name that is not reserved and clean values.")
 (dup first token? "http.server response header names must be nonempty HTTP tokens" domain-error
  assert
  dup first reserved-header? not
  "http.server response may not set content-length, connection, or transfer-encoding" domain-error
  assert
  1 at header-values?
  "http.server response header values must be strings without CR, LF, NUL, or control characters, or lists of them"
  domain-error assert)
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
  dup 'status at dup type 'int match? (dup 200 >= swap 599 <= and) (pop 0) if
  "http.server response status must be an int in 200...599; interim 1xx responses are not served"
  domain-error assert
  dup 'headers at dup type 'dict match? "http.server response headers must be a dict" domain-error
  assert
  dict.pairs (checked-header) for
  dup 'body at body? "http.server response body must be a string or a byte list" domain-error assert
  dup 'status at [204 205 304] in? not over 'body at len 0 = or
  "http.server response with status 204, 205, or 304 must have an empty body" domain-error assert)
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
  "Validate a response in full and serialize it to the exact bytes the server writes. The response
   is the dict {'status 'headers 'body} with exactly those keys: 'status an int in 200...599, since
   interim 1xx responses are not served, with an empty body when it is 204, 205, or 304; 'headers a
   dict from header names, nonempty strings of HTTP token characters, to a string or a list of
   strings containing no CR, LF, NUL, or control character other than tab, written once per value in
   the given order with the name as given ({\"set-cookie\" (\"a=1\" \"b=2\")} writes two lines);
   'body a string, written as UTF-8, or a byte list of ints in 0...255. The bytes are the status
   line HTTP/1.1 status reason (an empty reason for codes outside the built-in table), the header
   lines, Content-Length (omitted for 204 and 304, whose length is not the empty body's),
   Connection: close, an empty line, and the body. A non-dict is 'type; any other key set, a status
   outside the range, a body with status 204, 205, or 304, a header name that is not a token or is
   content-length, connection, or transfer-encoding in any letter case, a header value that is not a
   clean string or list of them, or a body of another kind is 'domain. Every byte the server writes
   has passed this word.")
 (checked-response
  (|response|
   response 'body at body-bytes
   response 'status at dup reason pair "HTTP/1.1 {} {}" str.format
   response 'headers at header-lines cons
   response 'status at [204 304] in? not (over len wrap "Content-Length: {}" str.format append) when
   "Connection: close" append "" append "" append
   crlf join bytes swap cat)
  call)
 'render-response def

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
  "Dispatch a request over a list of [method pattern handler] rows: method is a string compared
   exactly against the request's 'method (\"GET\"), pattern is a slash path whose segments must
   equal the request's 'path segments except that a segment beginning with : matches any nonempty
   segment and binds it by name (\"/users/:id\"), and handler is a ( request -- response )
   quotation. The first row whose method and pattern both match has its handler applied inline to
   the request with a 'params dict of the bound segments added ({\"id\" \"42\"}). When some pattern
   matches but no method does, the result is 405 with an allow header listing those rows' methods;
   when no pattern matches, http.response.not-found. Middleware is composition: wrap the handler
   quotation. A non-list routes or a row that is not a three-element list of string, string, and
   quotation is 'type or 'shape before any comparison.")
 (dup type 'list match? "http.server.route expects a list of rows" type-error assert
  dup (checked-route) for
  over 'path at route-matches
  dup len 0 =
  (pop pop http.response.not-found)
  (over 'method at over swap (|row method| row 0 at method match?) partial filter
   dup len 0 =
   (pop (0 at) each ", " join "allow" swap wrap pair dict.from-flat
    405 "method not allowed" http.response.text swap over 'headers at swap dict.merge 'headers swap
    put nip)
   (nip first over 'path at over 1 at match-pattern nip
    (|request row params| request 'params params put row 2 at call)
    call)
   if)
  if)
 'route def

 ### defp default-config
 (-- config : "Return the serving configuration with every limit at its default.")
 ({'max-header-bytes 32768
   'max-body-bytes 1048576
   'max-in-flight 128
   'read-timeout-ms 10000
   'on-failure (str io.eprint)})
 'default-config defp

 ### defp config-keys
 (-- keys : "Return the recognized configuration keys.")
 (['max-header-bytes 'max-body-bytes 'max-in-flight 'read-timeout-ms 'on-failure])
 'config-keys defp

 ### defp config-entry-problem
 (pair -- problem :
  "Classify one configuration entry as 'ok, 'unknown-key, 'wrong-type, or 'out-of-range.")
 (dup first config-keys in? not
  (pop 'unknown-key)
  (dup first 'on-failure match?
   (1 at type 'list match? ('ok) ('wrong-type) if)
   (1 at dup type 'int match? (0 > ('ok) ('out-of-range) if) (pop 'wrong-type) if)
   if)
  if)
 'config-entry-problem defp

 ### defp checked-config
 (config -- config : "Validate a serving configuration and fill in the defaults.")
 (dup type 'dict match? "http.server.@serve expects a configuration dict" type-error assert
  dup dict.pairs (config-entry-problem) each
  dup ('unknown-key match?) any? not
  "http.server.@serve configuration accepts only 'max-header-bytes, 'max-body-bytes, 'max-in-flight, 'read-timeout-ms, and 'on-failure"
  domain-error assert
  dup ('wrong-type match?) any? not
  "http.server.@serve limits must be ints and 'on-failure a quotation" type-error assert
  ('out-of-range match?) any? not
  "http.server.@serve limits must be greater than zero" domain-error assert
  default-config swap dict.merge)
 'checked-config defp

 ### defp peer-text
 (address -- text : "Format {'address 'port} as address:port, bracketing an IPv6 address.")
 (dup 'address at dup ":" str.contains? ("[" swap cat "]" cat) () if
  swap 'port at pair "{}:{}" str.format)
 'peer-text defp

 ### defp peer-gone
 (-- : "Raise the 'io error that marks a peer which sent nothing before closing.")
 ('io error.new "peer closed before sending a request" error.with-message raise)
 'peer-gone defp

 ### defp head-end
 (bytes -- index : "Return the index of the first CR LF CR LF in a byte list, or -1.")
 (4 windows ([13 10 13 10] match?) each where dup len 0 = (pop -1) (first) if)
 'head-end defp

 ### defp hex-digit?
 (char -- bool : "Return 1 for an ASCII hexadecimal digit.")
 (dup digit? over dup \a >= swap \f <= and or swap dup \A >= swap \F <= and or)
 'hex-digit? defp

 ### defp host-char?
 (char -- bool :
  "Return 1 for a character allowed in a registered host name: unreserved, sub-delims, or %.")
 (dup digit?
  over dup \a >= swap \z <= and or
  over dup \A >= swap \Z <= and or
  swap "-._~!$&'()*+,;=%" in? or)
 'host-char? defp

 ### defp ip-literal-char?
 (char -- bool : "Return 1 for a character allowed inside an IP-literal's brackets.")
 (dup hex-digit? swap ":." in? or)
 'ip-literal-char? defp

 ### defp port?
 (text -- bool : "Return 1 for a possibly empty string of digits.")
 ((digit?) all?)
 'port? defp

 ### defp bracketed-host?
 (value -- bool : "Return 1 for [IP-literal] with an optional :port.")
 ("]" split dup len 2 =
  (dup first 1 drop dup len 0 > swap (ip-literal-char?) all? and
   swap 1 at dup "" match? swap dup ":" str.starts? (1 drop port?) (pop 0) if or
   and)
  (pop 0)
  if)
 'bracketed-host? defp

 ### defp host-value?
 (value -- bool :
  "Return 1 for a Host value of the form uri-host with an optional :port, as RFC 9112 admits.")
 (dup "[" str.starts?
  (bracketed-host?)
  (dup ":" str.contains?
   (":" split dup len 2 = (dup first (host-char?) all? swap 1 at port? and) (pop 0) if)
   ((host-char?) all?)
   if)
  if)
 'host-value? defp

 ### defp read-head-step
 (connection limit buffer -- connection limit buffer :
  "Read more head bytes: 431 past the limit, 400 on EOF after some bytes, 'io on EOF before any.")
 (|connection limit buffer|
  buffer len limit > (431 "request header fields too large" framing-error) when
  connection limit 4 + buffer len - 1 max net.read
  dup len 0 = buffer len 0 = and (peer-gone) when
  dup len 0 = (400 "incomplete request head" framing-error) when
  buffer swap cat connection limit rolldown)
 'read-head-step defp

 ### defp read-head
 (connection limit -- connection buffer index :
  "Read until the head terminator appears and return its index.")
 ([] (dup head-end -1 =) (read-head-step) while nip dup head-end)
 'read-head defp

 ### defp decode-head
 (bytes -- text : "Decode the head as UTF-8 text; undecodable bytes are a 400.")
 (wrap (chars) @attempt dup 'ok dict.has? ('ok at first)
  (pop 400 "malformed request head" framing-error) if)
 'decode-head defp

 ### defp read-body-step
 (connection length buffer -- connection length buffer :
  "Read more body bytes; EOF before the length is a 400.")
 (|connection length buffer|
  connection length buffer len - net.read
  dup len 0 = (400 "incomplete request body" framing-error) when
  buffer swap cat connection length rolldown)
 'read-body-step defp

 ### defp read-body
 (connection leftover length -- body :
  "Complete a Content-Length body from the leftover head bytes and the connection.")
 (swap (over over len >) (read-body-step) while swap take nip)
 'read-body defp

 ### defp build-request
 (connection request-line headers body -- request :
  "Assemble the request dict handed to the handler.")
 (|connection request-line headers body|
  'method request-line 'method at
  'target request-line 'target at
  'path request-line 'path at
  'query request-line 'query at
  'headers headers
  'body body
  'peer connection net.peer-address peer-text
  14 pack dict.from-flat)
 'build-request defp

 ### defp read-request
 (connection config -- request :
  "Frame one request from the connection: head, request line, headers, and Content-Length body.")
 (|connection config|
  connection config 'max-header-bytes at read-head
  (|connection buffer index| connection buffer index 4 + drop buffer index take decode-head crlf
   split)
  call
  dup first parse-request-line swap rest parse-headers
  over 'version at "HTTP/1.1" match?
  (dup "host" () at-or dup len 1 = swap (host-value?) all? and not
   (400 "an HTTP/1.1 request needs exactly one well-formed Host header" framing-error)
   when)
  when
  dup "transfer-encoding" dict.has? (411 "length required" framing-error) when
  dup content-length
  dup config 'max-body-bytes at > (413 "content too large" framing-error) when
  (|connection leftover request-line headers length|
   connection request-line headers connection leftover length read-body build-request)
  call)
 'read-request defp

 ### defp answer
 (connection config status -- :
  "Write the minimal text response for a status the server generates itself.")
 (dup reason http.response.text 0 swap write-response)
 'answer defp

 ### defp report
 (config error -- :
  "Hand a request failure to the configured 'on-failure quotation; its own failure is discarded.")
 (wrap swap 'on-failure at @attempt pop)
 'report defp

 ### defp fail-request
 (connection config error -- : "Report a request failure to 'on-failure and answer 500.")
 (|connection config error| config error report connection config 500 answer)
 'fail-request defp

 ### defp write-response
 # The module's only write to a connection: every byte a server puts on the
 # wire has passed render-response, so an invalid response dict is data the
 # handler gets a 500 for and never a malformed wire message. The source audit
 # holds the write word to this one call site.
 (connection config head? response -- :
  "Validate and encode a response in full, then write it, without its body when the request was
   HEAD; a rejected response is reported and answered 500.")
 (wrap (render-response) @attempt
  dup 'ok dict.has?
  ('ok at first swap (head-only) when nip net.write)
  ('err at nip fail-request)
  if)
 'write-response defp

 ### defp head-only
 (bytes -- bytes : "Keep a rendered response's status line and headers, dropping the body.")
 (dup head-end 4 + take)
 'head-only defp

 ### defp handler-success
 (connection config head? values -- :
  "Write the single response a handler left, or report and answer 500.")
 (dup len 1 =
  (first write-response)
  (nip len wrap "handler left {} values instead of one response" str.format
   'contract error.new swap error.with-message fail-request)
  if)
 'handler-success defp

 ### defp run-handler
 (connection config handler request -- :
  "Run the handler in a fresh unit and write its response; a HEAD request gets no body.")
 (dup 'method at "HEAD" match? swap wrap rolldown @attempt
  dup 'ok dict.has?
  ('ok at handler-success)
  ('err at nip fail-request)
  if)
 'run-handler defp

 ### defp read-failure
 (connection config error -- :
  "Answer a framing failure by status, close silently on a vanished peer, or report.")
 (dup 'kind at
  ['timeout (pop 408 answer)
   'io (pop pop pop)
   (dup 'data {} at-or 'status 0 at-or dup 0 =
    (pop fail-request)
    (nip answer)
    if)]
  case)
 'read-failure defp

 ### defp dispatch-read
 (connection config handler reader result -- :
  "Continue from the reader child's result or its failure.")
 (dup 'ok dict.has?
  (nip 'ok at first run-handler)
  ('err at swap dup cancel await pop nip read-failure)
  if)
 'dispatch-read defp

 ### defp handle-connection
 (connection config handler -- :
  "Serve one connection: frame the request under the read deadline, run the handler, write the
   response.")
 (|connection config handler|
  connection config handler
  connection config 2 pack (read-request) @spawn
  dup config 'read-timeout-ms at await-for
  dispatch-read)
 'handle-connection defp

 ### defp serve-connection
 (connection config handler -- :
  "Serve one connection this unit owns: frame and answer one request, close the connection, and
   report any non-io failure through 'on-failure.")
 (|connection config handler|
  connection config handler 3 pack (handle-connection) @attempt
  connection net.close
  config swap
  dup 'err dict.has?
  ('err at dup 'kind at 'io match? (pop pop) (report) if)
  (pop pop)
  if)
 'serve-connection defp

 ### defp accept-one
 (listener config handler tasks -- listener config handler tasks :
  "Accept one connection and give it to a child unit that owns it for its whole life.")
 (|listener config handler tasks|
  listener config handler
  tasks
  listener net.accept wrap config handler 2 pack (serve-connection) @give
  append)
 'accept-one defp

 ### defp reap-one
 (tasks -- tasks :
  "Park until some child unit finishes, then drop it from the live set. Its result is discarded:
   serve-connection reports its own failures.")
 (dup await-any pop del)
 'reap-one defp

 ### defp serve-step
 (listener config handler tasks -- listener config handler tasks :
  "Wait for a free slot when the in-flight cap is reached, then accept one more connection.")
 (|listener config handler tasks|
  listener config handler
  tasks dup len config 'max-in-flight at >= (reap-one) when
  accept-one)
 'serve-step defp

 ### defp accept-loop
 (listener config handler -- :
  "Accept and serve connections forever, with at most 'max-in-flight connections in flight.")
 ([] (1) (serve-step) while)
 'accept-loop defp

 ### def @serve
 (listener config handler -- :
  "Serve HTTP/1.1 requests from a net listener until cancelled: accept in a loop and give each
   connection to a child unit that owns it. The child frames one request under the read deadline,
   applies the handler as [request] handler @attempt in a fresh unit, writes its single response
   with Content-Length and Connection: close, and closes the connection.

   The handler is a quotation ( request -- response ). The request is the dict {'method 'target
   'path 'query 'headers 'body 'peer}: 'method and 'target are the request-line tokens; 'path and
   'query are the target split at the first ?, undecoded, with 'query \"\" when absent; 'headers
   maps each ASCII-lowercased header name to the list of its trimmed values in arrival order; 'body
   is the exact Content-Length byte list, [] when there is none; 'peer is the peer's address:port,
   an IPv6 address in brackets. The response is the dict {'status 'headers 'body} that
   render-response accepts; every byte written to a connection has passed render-response.

   The config is a dict whose keys are all optional; {} is valid:
   - 'max-header-bytes (32768): most head bytes accepted before the CRLFCRLF terminator; more is
     431.
   - 'max-body-bytes (1048576): largest Content-Length accepted; more is 413 before any body byte is
     read.
   - 'max-in-flight (128): most connections served at once; accepting waits for a free slot.
   - 'read-timeout-ms (10000): deadline for reading one whole request; expiry is 408.
   - 'on-failure ((str io.eprint)): a ( error -- ) quotation applied to the error of every request
     answered 500; a failure of the quotation itself is discarded.
   Each limit is an int greater than zero.

   A HEAD request is answered with the handler's status and headers and no body. Requests the server
   cannot serve are answered with a minimal text/plain response and closed: 400 for a malformed
   request line or header, an HTTP/1.1 request without exactly one well-formed Host header,
   non-UTF-8 head bytes, a bad Content-Length, or end of stream after some bytes; 411 for any
   Transfer-Encoding; 505 for a version other than HTTP/1.1 or HTTP/1.0; 431 and 413 for the size
   limits; 408 for the deadline; 500 when the handler fails, leaves other than one value, or leaves
   a response render-response rejects, in which case 'on-failure receives the error. A peer that
   sends nothing before closing, or resets during the exchange, is closed silently.

   A non-port listener, non-dict config, non-quotation handler, non-int limit, or non-quotation
   'on-failure is 'type; an unknown config key or a limit not greater than zero is 'domain. The word
   fails 'cancelled when the serving unit is cancelled and re-raises an 'io failure of net.accept,
   such as 'io 'closed when the listener is closed elsewhere; either way every child is quiesced by
   scope rules and every connection a child owns is closed with it. It never closes the listener,
   which stays the caller's to close.")
 (|listener config handler|
  listener type 'port match? "http.server.@serve expects a net listener" type-error assert
  handler type 'list match? "http.server.@serve expects a handler quotation" type-error assert
  listener config checked-config handler accept-loop)
 '@serve def
) 'http.server @defm
