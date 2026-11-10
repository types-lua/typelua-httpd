# Design notes

## Goals

1. One router-serving library for HTTP/1.1, HTTP/2, TLS and WebSocket.
2. Strict framing, bounded memory and no dispatch before the protocol state is
   valid.
3. Streaming request bodies without sacrificing Lua 5.1/LuaJIT compatibility.
4. Deterministic tests for protocol logic, plus real TCP/TLS interoperability.
5. TypeLua source that erases to portable Lua 5.4 and Lua 5.1/LuaJIT.

Non-goals: HTTP/3, server push, HTTP/2 priority scheduling, RFC 8441 WebSocket,
mTLS termination, compression and streaming responses.

## Layers

```
                       application
          ┌──────────────────────────────────┐
          │ router · middleware · handlers   │
          │ static · WebSocket · multipart   │
          ├──────────────────────────────────┤
          │ HttpContext / Request / Response │
          ├──────────────────────────────────┤
          │ HttpServer protocol dispatcher   │
          │  sniff → H1 | H2 | WS            │
          ├──────────────┬───────────────────┤
          │ HTTP/1.1     │ HTTP/2            │
          │ parser/state │ frames/HPACK/flow │
          ├──────────────┴───────────────────┤
          │ HttpTransportApi                 │
          │ memory · LuaSocket · LuaSec TLS  │
          └──────────────────────────────────┘
```

`HttpServer` never sees sockets. It sees `HttpConnectionApi` values exposing
non-blocking `readAvailable`, `writeSome`, `close`, ALPN protocol, handshake and
polling hints. The memory transport returns immediately and uses a manual clock,
so timeout tests are deterministic.

## Connection lifecycle

```
accept
  │
  ├─ TLS handshake (non-blocking wantread/wantwrite)
  │      └─ ALPN result: h2 or http/1.1
  │
  ├─ protocol sniff
  │    ├─ h2c preface  → HTTP/2 connection
  │    ├─ h2 ALPN     → HTTP/2 connection
  │    └─ anything else → HTTP/1.1 parser
  │
  ├─ HTTP/1.1 request ──→ headers complete
  │                         ├─ normal route: buffer body → handler
  │                         └─ stream route: coroutine + body chunks
  │
  ├─ HTTP/2 stream ────→ headers decoded
  │                         ├─ normal route: buffer DATA → handler
  │                         └─ stream route: coroutine + DATA chunks
  │
  └─ HTTP/1.1 101 upgrade → WebSocket frame loop
```

A connection has one mode: `SNIFF`, `H1`, `H2` or `WS`. Mode transitions happen
before any application bytes are misparsed. HTTP/2 and WebSocket connections skip
the HTTP/1.1 phase state machine entirely.

### Protocol sniffing

The h2c preface is the 24-byte `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` string. The
server buffers only while the bytes remain a prefix of that preface; the first
mismatch commits to HTTP/1.1. TLS ALPN is authoritative and does not wait for a
preface. A one-byte partial preface is still an active request for timeout
purposes, so slow preface clients cannot hold connections indefinitely.

## HTTP/1.1 parser invariants

States:

```
LINE → HEADERS → BODY ────────────────┐
                    │                 │
                    └→ CHUNK_SIZE ← CHUNK_DATA → CHUNK_CRLF
                           │
                           └→ TRAILERS → END
```

Invariants:

- CRLF is mandatory; a bare LF is `400`.
- Obs-fold is rejected; header names are RFC tokens; values reject C0 controls
  other than HTAB, plus DEL.
- At most one `Host`; HTTP/1.1 requires it.
- `Transfer-Encoding` and `Content-Length` cannot coexist; duplicate lengths only
  when identical decimal strings.
- Only `Transfer-Encoding: chunked` is accepted.
- Limits are enforced while reading, never after unbounded buffering.
- A buffered request returns only after the complete body/trailers.
- `expectContinue` is emitted once, only for HTTP/1.1 with a body.
- `requestActive()` remains true after complete header lines are consumed while
  waiting for the terminating CRLF; `buffered()` alone is insufficient.
- `takeBuffered()` hands remaining bytes to a WebSocket session after upgrade.

### Buffered vs streaming events

`nextEvent()` emits `headers`, `body` chunks, `end` (or `continue`/`error`/
`needMore`). `peekHeaders()` stops at the end of headers. A normal route then
calls `next()` to concatenate the body; a stream route consumes `nextEvent()`
chunks. Both share the same framing code and tests.

Streaming handler dispatch runs the handler in a coroutine. `ctx:readBody()`
yields until the server pushes a chunk. On Lua 5.1/LuaJIT, yielding through
`pcall` is illegal, so the router's streaming path is intentionally unprotected
and the server wraps `coroutine.resume` with `pcall` instead. A handler error
becomes a clean 500; `router.onError` is only invoked for buffered handlers.

## HTTP/2

### Frames

`http_h2_frame.tl` parses the 9-byte header and payload incrementally with a
16 KiB advertised maximum frame size. Frame semantics are checked by the
connection:

- SETTINGS: stream 0, ACK length 0, known values validated, ACK sent.
- PING: stream 0, 8 bytes, ACK echoed.
- WINDOW_UPDATE: 4-byte increments, zero is a protocol error, overflow checked.
- RST_STREAM/PRIORITY/GOAWAY lengths and stream ids validated.
- PUSH_PROMISE from a client is a connection error.
- HEADERS/CONTINUATION ordering enforced; no other frame may interleave.
- DATA padding, END_STREAM and stream existence validated.

### HPACK

The decoder owns a dynamic table per connection:

- Static table indexes 1–61.
- Integer/string decoding with prefix limits and overflow checks.
- Huffman tree generated from the RFC 7541 Appendix B code table; padding must
  be at most 7 bits and all ones; EOS is rejected.
- Dynamic table insertions/evictions, table-size updates only before fields and
  never above the advertised 4096 bytes.
- 64 KiB and 200-header decoded limits.

The encoder is stateless: exact static matches use indexed fields, otherwise
literal-without-indexing with a static name index when possible. The curl/nghttp2
interoperability tests exercise Huffman request blocks and dynamic tables.

### Streams and flow control

- Client stream ids are odd and increasing; 100 concurrent streams advertised.
- Connection and per-stream send windows start at 65535 and shrink on DATA.
- Response headers are fragmented into HEADERS/CONTINUATION at peer
  `MAX_FRAME_SIZE`; DATA waits for WINDOW_UPDATE when windows are exhausted.
- Received DATA immediately replenishes connection and stream windows, while
  `maxBody` caps how much request payload can be retained.
- Buffered routes wait for END_STREAM; streaming routes dispatch at END_HEADERS.
- Early streaming responses send RST_STREAM(CANCEL) for the unfinished request.
- Compressed header blocks are capped at 64 KiB before HPACK decoding.

## TLS

LuaSec wraps accepted sockets with a non-blocking SSL object:

- `dohandshake()` returns `wantread`/`wantwrite`; the connection records write
  interest and the server's selector/flush path drives it.
- ALPN is negotiated from the ordered list (default `h2`, `http/1.1`);
  `getalpn()` selects the HTTP/2 path.
- TLS sockets are polled on short steps because LuaSec may hold decrypted bytes
  that `select()` cannot see on the raw fd. Reads drain decrypted records until
  timeout, capped at 1 MiB per event.
- Writes support short writes/`wantwrite`; the common output queue handles the
  rest.
- Certificate/key files are checked at construction. There is no client cert
  verification, OCSP or SNI certificate switching.

## WebSocket

- Opening handshake validates GET, HTTP/1.1, `Connection: Upgrade`,
  `Upgrade: websocket`, version 13 and a base64 16-byte key.
- `Sec-WebSocket-Accept` is `base64(SHA-1(key + GUID))`.
- The response is serialized manually so `Connection: Upgrade` survives (the
  normal serializer would replace it).
- After 101, parser leftovers are fed to the frame decoder and the connection
  switches to `WS` mode.
- Frames: masked client data required, no RSV bits, control frames ≤125 bytes
  and never fragmented, 7/16/64-bit lengths, 1 MiB frame cap.
- Messages: text/binary, fragmentation, interleaved ping/pong, close handshake,
  UTF-8 validation, 4 MiB message cap, 1002/1007/1009 close codes.
- Idle timeouts are suspended while a WebSocket is open. Heartbeat scheduling is
  application-level.

## Multipart

The parser is incremental:

```
--boundary CRLF
headers CRLF CRLF
body
CRLF--boundary CRLF     (next part)
CRLF--boundary--        (done)
```

- Boundary may be quoted in `Content-Type`.
- The body scanner retains `#("\r\n--" + boundary) - 1` tail bytes so a boundary
  split across network reads cannot be emitted as data.
- `partData` is released as soon as it is unambiguous; parts are never fully
  buffered by the parser.
- Limits: header bytes/count, part count, per-part bytes, total bytes.
- `MultipartReader` adapts a chunk source (string or `ctx:readBody`) into
  `nextPart()`/`part:read()`; `readAll()` is a convenience.

## Resource bounds

Defaults are listed in the README. The important invariants are:

- Every network input has a byte/count limit enforced incrementally.
- Response queues have a per-connection cap (`outBufferLimit`); exceeding it
  closes the connection.
- HTTP/2 compressed and decoded header blocks are independently capped.
- WebSocket frame and message sizes are capped before assembly.
- Multipart limits apply before part data is exposed to handlers.
- TLS plaintext drains are capped per readable event.

## Test strategy

- Crypto vectors (Base64/SHA-1), HPACK RFC vectors, frame round-trips.
- HTTP/2 connection tests with a raw frame client: GET/POST, CONTINUATION,
  PING, SETTINGS ACK, flow control, streaming multipart, early streaming
  response/RST and protocol errors.
- HTTP/1.1 parser and event parser: fixed/chunked, byte-by-byte, every split
  point, pipelining, limits and error stickiness.
- Server integration over memory: keep-alive, pipelining, 100-continue,
  timeouts, backpressure, 503 admission, streaming and early close.
- Static files: traversal variants, dotfiles, MIME, ETags, ranges, caps.
- Multipart: boundary splits at every byte, binary payloads, filename*, limits.
- Real TCP/TLS: LuaSocket/LuaSec clients, ALPN h1/h2, HTTP/2 GET/POST/streaming,
  WebSocket echo and streaming uploads.
- External curl/nghttp2 checks are used during development for h2c, TLS ALPN,
  large headers and 50 KB streaming uploads.
