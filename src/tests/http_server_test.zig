//! Public Session coverage for the `http.@serve` server module.
//!
//! Every case runs source text through a Session whose Host grants exact
//! loopback binds on `127.0.0.1` port 0, and observes the other end of the
//! wire through a Zig-side `HttpPeer` thread: it connects to the bound port,
//! writes its request bytes verbatim, and reads until EOF into a 4 KiB buffer,
//! so the oracle is the exact byte sequence the server put on the socket.
//! Peers synchronize by bytes on the socket, never by sleeping; the one timed
//! case (the read deadline) configures a 20 ms deadline and waits for EOF.
//!
//! Programs decide their own shutdown through handlers—`/stop` cancels the
//! serving task and `/close-listener` closes the listener—because
//! `requestCancellation` cannot wake a parked root unit. Sessions run only
//! source strings, so the traceless session heap is the right allocator (see
//! `test_heap.zig`). No wall-clock sleeps, no ambient network, no fixture
//! process.
//!
//! Pending. Patch 5 of gameplans/http-server.json implements each test below;
//! until then every body skips and its `PENDING` comment records the oracle.

// PENDING: Patch 5. Oracle: peer writes `GET /a/b?x=1&y=2 HTTP/1.1\r\nHost: h\r\nX-Multi: one\r\nX-Multi: two\r\nContent-Length: 3\r\n\r\nabc`; the handler answers with `request 'peer del str` as the body; the peer asserts the exact dict text (`'method "GET"`, `'target "/a/b?x=1&y=2"`, `'path "/a/b"`, `'query "x=1&y=2"`, lowercased header keys with list values `("one" "two")`, `'body` as the byte list of `abc`), and the test asserts the peer's own bound address and port were what `'peer` held.
test "http server: a request is materialized with method target path query lowercased list headers body and peer" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: two peers `GET /s` and `GET /b`; handlers answer `"ok"` and `[111 107]`; each peer reads exactly `HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok` then EOF.
test "http server: string and byte-list bodies are written with content-length and connection close" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: the handler answers headers `{"set-cookie" ("a=1" "b=2")}`; the peer reads two `Set-Cookie:` lines, one per value, in order, and no third.
test "http server: repeated response headers are written once per value" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: the peer writes `POST / HTTP/1.1` with `Content-Length: 4` and body bytes `[0 255 10 13]`; the handler echoes `request 'body at str`; the peer reads `[0 255 10 13]` as the response body.
test "http server: a content-length body is delivered as an exact byte list including binary octets" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: peers write `GARBAGE\r\n\r\n`, `GET / HTTP/1.1\r\nNoColon\r\n\r\n`, and `GET /  HTTP/1.1\r\n\r\n`; each reads a `HTTP/1.1 400` status line with `Connection: close` then EOF; the handler is never invoked, and a later well-formed request is answered 200.
test "http server: malformed request lines and headers are answered 400 and closed" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: `Transfer-Encoding: chunked` reads a `411` status line; `GET / HTTP/2.0` reads `505`; `GET / HTTP/1.0` reads `200` with `Connection: close` then EOF.
test "http server: chunked requests are answered 411 and unsupported versions 505 while HTTP/1.0 is answered and closed" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: config `'max-header-bytes 64` and `'max-body-bytes 4`; a peer with 100 bytes of headers reads `431`; a peer with `Content-Length: 5` reads `413`; both read `Connection: close` then EOF.
test "http server: header and body limits are answered 431 and 413" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: config `'read-timeout-ms 20`; the peer writes `GET / HTTP/1.1\r\nHost:` without finishing and reads until EOF; it observes a `HTTP/1.1 408` status line followed by EOF.
test "http server: the read deadline answers 408 and closes" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: config `'max-in-flight N`; a second listener `l2` with `[] (l2 net.accept) @spawn 'gate set`; handler `/slow` runs `gate await`; handler `/probe` answers `gate 0 await-for 'ok dict.has? ("terminal") ("active") if`. Peers: `/slow` (read until EOF), then `/probe` whose thread signals a `ResetEvent` after flushing its request, then the test connects a third peer to `l2` to release the gate. With N=1 `/probe` sees `terminal`; with N=2, `active`.
test "http server: max-in-flight stops accepting until a request completes" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: handlers `/raise` (raises), `/extra` (leaves two results), `/malformed` (answers a non-response value), and `/reserved` (sets `content-length` itself) each read a `500` status line with `Connection: close` then EOF; a following `GET /ok` is answered 200, proving the server stayed live.
test "http server: handler failures extra results malformed responses and reserved headers are answered 500 while the server stays live" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: `/slow` awaits a gate that is never released; `/stop` runs `srv cancel`; after `srv await` the stack shows `'cancelled`, the `/slow` peer observes EOF with no status line, and `l net.local-address 'port at` still equals the bound port.
test "http server: cancellation cancels in-flight requests and leaves the caller's listener open" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: handler `/close-listener` runs `l net.close`; `srv await 'err at` has kind `'io` and `'data 'reason` `'closed`.
test "http server: closing the listener fails the serving unit with io closed" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: a peer connects and closes without writing; it reads EOF with zero bytes, the handler is never invoked, and a following `GET /ok` is answered 200.
test "http server: a peer that connects and closes without sending is closed silently" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: a non-dict config, a negative `'max-in-flight`, an unknown config key, a connection port or process port in place of the listener, and a non-quotation handler each fail `'type` or `'domain` synchronously before any accept; no peer is needed.
test "http server: configuration and listener arguments are validated before serving" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: `.{ .worker_pool = 8 }`; eight peers each request `/n/<i>` concurrently and the handler echoes the path; every peer reads exactly its own path as the body once, then EOF.
test "http server: concurrent requests under the worker pool are each answered exactly once" {
    return error.SkipZigTest;
}

// PENDING: Patch 5. Oracle: `doc` is non-empty for `http.@serve` and the response constructor words; `'http ('@serve) import 1` leaves `1` on the stack after a cold load through the embedded manifest.
test "http server: words cold-load through the embedded manifest and are documented" {
    return error.SkipZigTest;
}
