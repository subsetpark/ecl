## http

Requests yield while awaiting network I/O, including under cooperative scheduling
and with one worker. Each invocation has one total 30-second monotonic deadline,
including preparation, redirects, transfer, and response construction. Expiry is
`` `timeout ``; task cancellation remains `` `cancelled ``. Neither returns a partial
response.

Internal Session configuration defaults to 16 live requests, a 16 KiB target,
16 MiB outbound body, 64 MiB encoded and 64 MiB decoded inbound bodies, and
64 KiB / 256 occurrences of supplied request headers and received response
headers. Header byte counts include field-line framing; received whitespace
counts before normalization and repeated fields count before deduplication.
Redirect responses share cumulative inbound budgets; body limits also apply to
chunked and compressed transfers. The response transport holds at most 64 KiB
and backend scratch at most 16 MiB per request. Admission remains reserved until
response construction and cleanup finish. Exceeding a limit is `` `overflow `` with
the target URL in error data; allocation failure remains `OutOfMemory`.
Configuration is internal: there are no new request fields or CLI options.

### get
`( request -- response )` — Fetch a partial or complete `http.request` value,
using GET and redirect following as defaults. The request must carry a string
`` `target `` URL. An optional `` `method `` overrides GET, optional `` `headers `` are
sent once per value in list order, and an optional byte-list `` `body `` is sent
exactly for POST, PUT, or PATCH. A nonempty body with another method is
`` `domain ``. Return `{status int, headers dict, body string}`. A transport or
protocol failure is `` `io `` carrying the URL in `` `path ``; a non-2xx status is an
ordinary response.

### get-bytes
`( request -- response )` — Perform the same request as `get`, including
redirects and content decoding, but return `` `body `` as the exact ordered octets
in an ordinary integer byte list. Status and headers retain the same types.
This is the binary ingress used for archives; no byte is decoded to or encoded
from a Unicode character before hashing.

### post
`( request -- response )` — Fetch the same request value as `get`, using POST,
an empty body, and no redirect following as defaults. An optional `` `method ``
or `` `body `` overrides those request defaults. Return the same response shape
and errors as `get`.

### send
`( request -- response )` — Send a complete `http.request` value. Unlike `get`
and `post`, this word supplies no method default: both string `` `method `` and
`` `target `` fields are required. Redirects are not followed. Return the same
response shape and errors as `get`.
