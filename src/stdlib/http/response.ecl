### module http.response
# A response is the dict {'status 'headers 'body}: what http.get, http.post,
# and http.send return and what an http.server handler leaves. These words
# build one, read its headers by name regardless of letter case, and return
# updated copies.
# Wire rules (no 1xx, reserved names, no CR or LF) belong to
# http.server.render-response; this module accepts every well-shaped value.
[]
(
 ### defp type-error
 (message -- error : "Build a 'type error with the message.")
 ('type error.new swap error.with-message)
 'type-error defp

 ### defp status?
 (value -- bool : "Return 1 for an int in 100...599.")
 (dup type 'int match? (dup 100 >= swap 599 <= and) (pop 0) if)
 'status? defp

 ### defp header-values?
 (value -- bool : "Return 1 for a string or a list of strings.")
 (dup str.str? (pop 1) (dup type 'list match? ((str.str?) all?) (pop 0) if) if)
 'header-values? defp

 ### defp header-pair?
 (pair -- bool : "Return 1 for a [name values] entry with a string name.")
 (dup first str.str? (1 at header-values?) (pop 0) if)
 'header-pair? defp

 ### defp headers?
 (value -- bool : "Return 1 for a dict from string names to header values.")
 (dup type 'dict match? (dict.pairs (header-pair?) all?) (pop 0) if)
 'headers? defp

 ### defp byte?
 (value -- bool : "Return 1 for an int in 0...255.")
 (dup type 'int match? (dup 0 >= swap 255 <= and) (pop 0) if)
 'byte? defp

 ### defp body?
 (value -- bool : "Return 1 for a string or a byte list.")
 (dup str.str? (pop 1) (dup type 'list match? ((byte?) all?) (pop 0) if) if)
 'body? defp

 ### def valid?
 (value -- bool :
  "Return 1 when a value is a response dict: exactly 'status, 'headers, and 'body, with an int
   status in 100...599, a headers dict from string names to a string or a list of strings, and a
   string or byte-list body. Never raises.")
 (dup type 'dict match?
  (dup ['status 'headers 'body] dict.keys-exactly?
   (dup 'status at status? over 'headers at headers? and over 'body at body? and nip)
   (pop 0)
   if)
  (pop 0)
  if)
 'valid? def

 ### defp checked
 (response -- response : "Return a response dict or raise 'type.")
 (dup valid? "expected a response dict {'status 'headers 'body}" type-error assert)
 'checked defp

 ### defp checked-status
 (status -- status : "Return a status int in 100...599 or raise 'type.")
 (dup status? "http.response expects an int status in 100...599" type-error assert)
 'checked-status defp

 ### defp checked-name
 (name -- name : "Return a string header name or raise 'type.")
 (dup str.str? "http.response expects a string header name" type-error assert)
 'checked-name defp

 ### def new
 (status -- response :
  "Return {'status status 'headers {} 'body \"\"}. A status outside 100...599 is 'type.")
 (checked-status 'status swap 'headers {} 'body "" 6 pack dict.from-flat)
 'new def

 ### def text
 (status string -- response :
  "Return {'status status 'headers {\"content-type\" (\"text/plain; charset=utf-8\")} 'body string}.
   A bad status or a non-string body is 'type.")
 (dup str.str? "http.response.text expects a string body" type-error assert
  swap checked-status swap
  (|status body|
   'status status 'headers {"content-type" ("text/plain; charset=utf-8")} 'body body 6 pack
   dict.from-flat)
  call)
 'text def

 ### def json
 (status value -- response :
  "Return {'status status 'headers {\"content-type\" (\"application/json\")} 'body text} where text
   renders the value with json.emit. A bad status is 'type; a value json.emit rejects fails as
   json.emit does.")
 (swap checked-status swap
  (|status value|
   'status status 'headers {"content-type" ("application/json")} 'body value json.emit 6 pack
   dict.from-flat)
  call)
 'json def

 ### def redirect
 (location -- response :
  "Return {'status 302 'headers {\"location\" (location)} 'body \"\"}. A non-string location is
   'type.")
 (dup str.str? "http.response.redirect expects a string location" type-error assert
  (|location| 'status 302 'headers "location" location wrap pair dict.from-flat 'body "" 6 pack
   dict.from-flat)
  call)
 'redirect def

 ### def not-found
 (-- response : "Return 404 \"not found\" text.")
 (404 "not found" text)
 'not-found def

 ### defp values-of
 (pair name -- values :
  "Return the entry's values as a list when its name matches ignoring case, else ().")
 (over first str.lower swap str.lower match?
  (1 at dup str.str? (wrap) () if)
  (pop ())
  if)
 'values-of defp

 ### def header
 (response name -- values :
  "Return every value of a header as a list, matching the name regardless of letter case and in dict
   order; a string value counts as one. () when the header is absent. A non-response or non-string
   name is 'type.")
 (checked-name swap checked 'headers at dict.pairs swap (values-of) partial each raze)
 'header def

 ### def header?
 (response name -- bool : "Return 1 when the response carries the header under any letter case.")
 (header len 0 >)
 'header? def

 ### def class
 (response -- class : "Return the status class: 2 for 200...299, 4 for 400...499, and so on.")
 (checked 'status at 100 div)
 'class def

 ### def ok?
 (response -- bool : "Return 1 for a status in 200...299.")
 (class 2 =)
 'ok? def

 ### def with-status
 (response status -- response : "Return the response with a new status. A bad status is 'type.")
 (checked-status swap checked 'status rolldown put)
 'with-status def

 ### def with-body
 (response body -- response :
  "Return the response with a new string or byte-list body; another kind is 'type.")
 (dup body? "http.response.with-body expects a string or byte list" type-error assert
  swap checked 'body rolldown put)
 'with-body def

 ### def with-header
 (response name value -- response :
  "Return the response with a value added under the header name exactly as given: a string or a list
   of strings, appended to any values already under that name, an existing string value counting as
   one. A non-string name or a bad value is 'type.")
 (dup header-values? "http.response.with-header expects a string or a list of strings" type-error
  assert
  dup str.str? (wrap) () if
  swap checked-name
  (|response value name|
   response checked 'headers at name over over dict.has? (at dup str.str? (wrap) when) (pop pop ())
   if value cat
   response 'headers at name rolldown put
   response 'headers rolldown put)
  call)
 'with-header def

 ### def with-headers
 (response headers -- response :
  "Return the response with a headers dict merged over its own; a right-hand name replaces a
   left-hand one exactly. A headers value that is not a dict of string names to header values is
   'type.")
 (dup headers? "http.response.with-headers expects a dict of headers" type-error assert
  swap checked dup 'headers at rolldown dict.merge 'headers swap put)
 'with-headers def
) 'http.response @defm
