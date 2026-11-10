# Design notes

## Goals

1. A complete HTTP/1.1 request/response core that can be used as a library.
2. Strict framing and bounded resource use; no request is dispatched before its body is
   complete.
3. Deterministic tests for every state transition, plus a real TCP adapter.
4. TypeLua source that erases to portable Lua 5.4 and Lua 5.1/LuaJIT.

Non-goals: TLS, HTTP/2, streaming bodies, multipart, WebSocket upgrades, proxy behaviour
and directory listings.

## Layers

```
                 application
        ┌───────────────────────────┐
        │ router / handlers / static│
        ├───────────────────────────┤
        │ HttpContext / HttpRequest │
        │ HttpResponse / Headers    │
        ├───────────────────────────┤
        │ HttpServer state machine  │
        │ parser · timeouts · queues│
        ├───────────────────────────┤
        │ HttpTransportApi          │
        │  ┌───────────┐ ┌────────┐ │
        │  │ memory    │ │ socket │ │
        │  └───────────┘ └────────┘ │
        └───────────────────────────┘
```

`HttpServer` never sees sockets. It sees `HttpConnectionApi` values that expose
non-blocking `readAvailable`, `writeSome`, `close` and `remoteAddress`. A selector reports
which connections are readable/writable. The memory transport returns immediately and
uses a manual clock, which is why timeout tests are deterministic.

## Request lifecycle

```
accept → parser.feed → parser.next
                         │
          ┌──────────────┼────────────────┐
          │              │                │
       needMore       expectContinue     error
          │              │                │
       wait for       send 100,          400/408/413/
       readable       parse again       414/417/431/505
                         │
                      request
                         │
                 router.handle(req,res)
                         │
                 serialize(res, opts)
                         │
                 append output queue
                         │
                 flush while writable
                         │
                 keep-alive? ──no──→ close
                         │yes
                 parse buffered pipeline
```

A connection owns exactly one parser. After a complete request the parser resets in place
and immediately consumes any buffered pipeline, so one readable event can produce several
responses.

## Parser invariants

The parser is a byte-string state machine with states:

```
LINE → HEADERS → BODY ────────────────┐
                    │                 │
                    └→ CHUNK_SIZE ← CHUNK_DATA
                           │
                           └→ TRAILERS → complete
```

Hard invariants:

- CRLF is mandatory; a bare LF is a `400`.
- Header folding is rejected; header names are RFC tokens; values reject C0 controls
  other than HTAB, plus DEL.
- At most one `Host`; HTTP/1.1 requires it.
- `Transfer-Encoding` and `Content-Length` cannot coexist. Duplicate `Content-Length`
  is accepted only when all values are identical decimal strings.
- Only `Transfer-Encoding: chunked` is supported. Chunk sizes are hex, capped by
  `maxChunkLine`; the accumulated body is capped by `maxBody`; chunk count is capped by
  `maxChunks`.
- A request is returned only after its entire body and trailers have arrived.
- `expectContinue` is emitted at most once, and only for HTTP/1.1 with a body.
- Limits are checked while reading, not after unbounded buffering.
- The parser never decodes or normalizes the request target beyond splitting
  path/query; routers and static serving decode explicitly and exactly once.

`requestActive()` distinguishes "idle keep-alive connection" from "a request was started
but the final CRLF/body has not arrived". This matters because `buffered()` is zero after
the parser has consumed complete header lines while waiting for the blank line.

## Server state

Per connection:

```tl
type ConnState = {
  conn, parser, out, outPos,
  closing, inputClosed,
  requests, lastActive, continueSent,
}
```

- `out` is an append queue; `outPos` tracks bytes already written. `flush` supports
  partial writes and `wouldBlock`.
- A connection with queued output is registered as writable and also readable (unless
  closing), so pipelined input can arrive while a slow client drains responses.
- `outBufferLimit` bounds queued bytes; exceeding it closes the connection rather than
  growing memory without bound.
- `maxConnections` is checked at accept time. Refused connections get one `503` write
  attempt and are closed without entering the state map.
- `maxRequestsPerConnection` forces `Connection: close` on the last allowed response.
- A client may half-close after sending pipelined requests. The server keeps parsing
  buffered complete requests and answers all of them, then closes after the output
  drains.
- `idleTimeout` applies only when no request is active. `requestTimeout` applies while
  `requestActive()` is true and queues a `408`, including after the request line and all
  complete headers have arrived but the terminating CRLF is missing.
- A FIN with an incomplete request queues `400 Incomplete Request` and closes.

## Response invariants

The serializer is the last line of defence:

- Status must be 100–599.
- Version must be `1.0` or `1.1`; request method must be a header token.
- `Content-Length` is always derived from the body. Application values are overwritten.
- `Transfer-Encoding` is always removed; this library never chunks responses.
- `HEAD`, 1xx, 204, 205 and 304 never carry a body.
- 205 explicitly sends `Content-Length: 0`.
- `Date` and `Server` are filled only if the application did not set them.
- `Connection` is `close` when the connection will close; HTTP/1.0 keep-alive is
  explicit; HTTP/1.1 keep-alive is implicit.
- Header names/values are validated at insertion time, so CRLF injection fails before
  serialization.

## Router semantics

- Routes are matched in registration order, first match wins.
- Patterns are `/`-separated; `:name` captures one decoded segment, `*` captures all
  remaining segments (including none) under key `"*"`.
- Empty and duplicate slashes collapse because segments are extracted with `[^/]+`.
- Static pattern segments are percent-decoded; request segments are decoded once.
- `HEAD` first looks for an explicit HEAD route, then falls back to GET.
- If no route matches but another method does, the result is `405` with `Allow`.
- `OPTIONS` without an explicit route returns `204` and `Allow`; `OPTIONS *` returns the
  union of registered methods.
- Handler and middleware exceptions are caught. The default is a plain `500`; an
  `onError` callback can inspect the error and rewrite the response. If that callback
  throws, the clean default is restored.
- Middleware is `(ctx, next) -> void`. Calling `next` more than once is not meaningful;
  a middleware that wants to stop simply returns without calling it.

## Static file security model

`HttpStatic` is intentionally lexical:

1. Strip the mount prefix and reject paths outside it.
2. Reject encoded slashes (`%2F`), which would otherwise mean one thing to the router
   and another to the filesystem.
3. Percent-decode exactly once.
4. Reject any segment starting with `.` unless `dotfiles = true`.
5. Normalize `.`/`..` lexically with a stack; `..` that would pop above the root is
   rejected. NUL and backslash are rejected.
6. Join the resulting relative path onto the configured root and open it.

Because decoding happens once, `%252e%252e` remains the literal name `%2e%2e` and cannot
become `..` later. The root itself is trusted configuration; symlinks inside it are not
followed with an additional containment check, so do not expose an attacker-writable
tree.

Files are probed with `read(0)` before trusting `seek("end")`; directory sizes are
filesystem-specific (some report zero, some report more than the cap), while `io.open`
accepts directories on Linux. A zero-byte regular file is still served as empty. The size
probe enforces `maxBytes` before reading, and the read is capped at `maxBytes + 1` to
catch files that grow between the probe and the read. Content is buffered whole. ETags
are two independent 31-bit rolling hashes (62 bits of tag). Conditional requests use weak
comparison; `If-Range` requires the exact strong tag.

Only a single byte range is implemented. Multiple or malformed ranges are ignored and
the full representation is sent, which RFC 7233 permits. An unsatisfiable range sends
`416` with `Content-Range: bytes */<size>`.

## Transport contract

`readAvailable(maxBytes)` returns:

```tl
{ data, err, closed, wouldBlock }
```

- `data` may contain bytes even when `closed` or `wouldBlock` is true.
- `closed` is a FIN; parse whatever was returned first.
- `wouldBlock` means no more bytes are available *now*.

`writeSome(data)` returns `written`, `err`, `wouldBlock`. A short positive write is
normal; the server advances `outPos` and retries on the next writable event. `0` written
without an error is treated as backpressure to avoid a busy loop.

`select(readers, writers, timeout)` may return a subset. The memory selector reports all
readable/writable candidates immediately; the LuaSocket selector delegates to
`socket.select`.

## Compatibility

- No `table.pack`, `table.unpack`, `//`, bitwise operators, `<const>` or `<close>` in the
  runtime path, so emitted code runs on Lua 5.4 and LuaJIT/5.1.
- `string.find(..., plain=true)` with `init > 1` is avoided entirely; literal searching
  goes through `lib/http_literal.tl`, which escapes magic characters and uses pattern
  search. This works around a bug in the embedded golua runtime.
- LuaSocket is loaded lazily with `pcall(require, "socket")`. Constructing
  `SocketTransport` without it raises a clear error; the memory transport still works.

## Test strategy

- Unit tests for headers, URL/path helpers, status/date/MIME, parser and serializer.
- Router tests for params, wildcards, ordering, middleware, 404/405/OPTIONS, HEAD,
  explicit/intercepted errors.
- Static tests build a real temporary tree and cover traversal variants, dotfiles,
  empty files, indexes, MIME, caps, ETags, weak/list/star matches, ranges, `If-Range`,
  HEAD and mounting.
- Server tests use the memory transport and manual clock to cover keep-alive,
  pipelining, half-close, chunked requests, 100-continue (both waiting and
  body-already-buffered), malformed framing, body limits, 503 admission control,
  idle/request timeouts and response tampering.
- Real-socket tests bind `127.0.0.1:0`, drive `server:step` from the test loop, and use a
  non-blocking LuaSocket client for GET, POST, chunked bodies and pipelining. They skip
  automatically when LuaSocket is unavailable (for example in embedded golua).
