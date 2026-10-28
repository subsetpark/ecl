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
