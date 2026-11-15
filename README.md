# typelua-httpd

A strict, transport-independent HTTP server library written in
[TypeLua](https://github.com/types-lua/TypeLua):

- HTTP/1.1 with keep-alive, pipelining, chunked bodies and 100-continue.
- HTTP/2 over TLS ALPN (`h2`) and cleartext h2c prior knowledge.
- TLS through LuaSec or the optional LuaJIT/OpenSSL FFI adapter, including
  non-blocking handshakes and ALPN.
- RFC 6455 WebSocket upgrade, framing, ping/pong, fragmentation and limits.
- Incremental `multipart/form-data` parsing with a pull reader.
- Streaming request bodies with a coroutine-friendly `ctx:readBody()`.
- Router, middleware, static files, ETags/ranges and bounded resource use.

```tl
import http from "./lib/http"

local router = http.HttpRouter.new()
router:get("/", function(ctx: HttpContextApi): void
  ctx:text("hello\n")
end)

local server = http.HttpServer.new(router, http.SocketTransport.new(), {})
server:listen("127.0.0.1", 8080)
server:serve()
```

The same router serves HTTP/1.1, HTTP/2 and WebSocket requests. Protocol
negotiation happens before request parsing, so handlers stay protocol-neutral.

## Why

- **Library, not a demo.** Router, middleware, static files, streaming,
  WebSocket sessions and TLS are independent public pieces.
- **Framing is treated as security.** Request smuggling defences reject
  conflicting `Content-Length`/`Transfer-Encoding`, bare LF, obsolete folding,
  malformed chunks and invalid HTTP/2 sequences before handlers run.
- **Deterministic tests.** The entire server loop runs over a memory transport;
  real socket, TLS and ALPN paths are integration-tested separately.
- **No mandatory C modules for the core.** Types erase to ordinary Lua. The
  core never loads LuaSocket or LuaSec; those adapters are optional, as is the
  LuaJIT FFI adapter for environments that want neither.

## Requirements

| Component | Requirement |
| --- | --- |
| TypeLua | `tlua` v0.9.9 or newer |
| Lua | 5.4 (default), or LuaJIT / Lua 5.1 with `tlua --target 5.1` |
| Real TCP (default adapter) | [LuaSocket](https://lunarmodules.github.io/luasocket/) (`lua-socket`) |
| TLS / HTTP/2 over TLS (default adapter) | [LuaSec](https://github.com/lunarmodules/luasec) (`lua-sec`) |
| Real TCP/TLS without those modules | LuaJIT + the optional FFI adapter, or a custom transport |
| Tests | `tlua`; LuaSocket/LuaSec enable the real-network cases; LuaJIT also covers the FFI adapters |

```bash
sudo apt-get install lua-socket lua-sec
```

The embedded golua runtime used by `tlua run` cannot load C modules such as
LuaSocket/LuaSec. Use an external interpreter for the real server:

```bash
tlua run --lua lua5.4 main.tl
```

## Run the demo

```bash
tlua check
tlua run --lua lua5.4 main.tl

# TLS + HTTP/2 (ALPN h2/http1.1)
mkdir -p data/tls
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout data/tls/key.pem -out data/tls/cert.pem -days 1 -subj '/CN=localhost'
TLS_CERT=data/tls/cert.pem TLS_KEY=data/tls/key.pem \
  tlua run --lua lua5.4 main.tl
```

Then:

```bash
curl -i http://127.0.0.1:8080/
curl --http2-prior-knowledge -i http://127.0.0.1:8080/health
curl -k --http2 -i https://127.0.0.1:8080/health
curl -i -X POST --data-binary 'hello' http://127.0.0.1:8080/api/echo
curl -i -X POST --data-binary @big.bin http://127.0.0.1:8080/upload
curl -i -F 'title=hello' -F 'file=@photo.png' http://127.0.0.1:8080/form
curl -i -H 'Range: bytes=0-4' http://127.0.0.1:8080/static/hello.txt
```

Open `/static/` in a browser for the built-in WebSocket demo.

The smallest complete program is [`examples/hello.tl`](examples/hello.tl).
Run it from the emitted tree:

```bash
tlua build
(cd dist && lua5.4 examples/hello.lua)
```

## Use as a dependency

The repository is also a TypeLua package. The package path is the Git path:

```toml
# tlua.toml
[package]
name = "my-service"
version = "v0.1.0"

[dependencies]
"github.com/types-lua/typelua-httpd" = "^v0.1.0"
```

```bash
tlua mod get
tlua mod vendor        # optional, but recommended for reproducible/offline builds
```

Add the package's ambient contracts to your project so handler annotations such
as `HttpContextApi` resolve:

```json
{
  "compilerOptions": {
    "typeRoots": [
      "types",
      "tlua_modules/github.com/types-lua/typelua-httpd/types"
    ]
  }
}
```

Then import the package root:

```tl
import http from "github.com/types-lua/typelua-httpd"

local router = http.HttpRouter.new()
router:get("/", function(ctx: HttpContextApi): void
  ctx:text("hello from my service\n")
end)

local server = http.HttpServer.new(router, http.SocketTransport.new(), {})
server:listen("127.0.0.1", 8080)
server:serve()
```

```bash
tlua check
tlua build
lua5.4 dist/main.lua
```

If you do not use the package manager, copy `lib/`, `types/`, `init.tl`,
`core.tl` and `adapters/{socket,tls,ffi}.tl` under
`tlua_modules/github.com/types-lua/typelua-httpd/` (or use a Git submodule) and
keep the same import path. Avoid absolute filesystem imports: they do not
survive `tlua build`.

`main.tl`, `examples/` and `docs/` are repository material, not part of the
required runtime package surface.

## Without LuaSocket / LuaSec

The protocol core itself has no C-module dependency:

```tl
import http from "github.com/types-lua/typelua-httpd/core"
```

`core` loads no `socket`, `ssl` or `ffi` module. It gives you the parser,
router, server state machine, static files, WebSocket, multipart and the
memory transport. Real network I/O is injected through `HttpTransportApi`:

| Option | Lua 5.4 | LuaJIT | Notes |
| --- | --- | --- | --- |
| `core` + your transport | yes | yes | No LuaSocket/LuaSec/FFI; I/O owned by your runtime |
| `core` + `MemoryTransport` | yes | yes | Tests, embedded dispatch, protocol fuzzing |
| `ffi` adapter | no | yes | POSIX/Linux, IPv4, system OpenSSL for TLS |
| `socket` / `tls` adapters | yes | yes | Existing LuaSocket/LuaSec path, unchanged |

### LuaJIT FFI transport

On LuaJIT the optional `ffi` entrypoint provides real TCP/TLS without loading
LuaSocket or LuaSec:

```tl
import http from "github.com/types-lua/typelua-httpd/core"
import ffiTransport from "github.com/types-lua/typelua-httpd/adapters/ffi"

local server = http.HttpServer.new(
  router,
  ffiTransport.FfiSocketTransport.new(),
  {}
)
```

TLS (OpenSSL libssl/libcrypto) uses the same transport contract:

```tl
local transport = ffiTransport.FfiTlsTransport.new({
  certificate = "cert.pem",
  key = "key.pem",
  alpn = { "h2", "http/1.1" },
})
```

Run the emitted program with `luajit` (not `lua5.4`). No LuaSocket/LuaSec C
modules are required; the process links the system OpenSSL libraries.

Constraints: Linux/POSIX syscalls (`accept4`, `poll`), IPv4 only, unencrypted
PEM private keys, and no client-certificate verification. TLS policy still
comes from OpenSSL. If you need Lua 5.4 or a platform without FFI, use
LuaSocket/LuaSec, a custom transport, or terminate TLS in a reverse proxy.

### Custom transport

`HttpServer` only needs this small port. Implement it over your own event loop
or socket library and the entire router/serving stack works unchanged:

```tl
interface HttpTransportApi {
  listen(host: string, port: integer, backlog: integer): ListenResult,
  selector(): HttpSelectorApi,
  now(): number,
}

interface HttpConnectionApi {
  id(): string,
  readAvailable(maxBytes: integer): ReadResult,
  writeSome(data: string): WriteResult,
  close(): void,
  remoteAddress(): string,
  isReadable(): boolean,
  needsWrite(): boolean,
  needsHandshake(): boolean,
  poll(): boolean,
  protocol(): string,          -- "" | "h2" | "http/1.1"
}
```

See [`docs/transports.md`](docs/transports.md) for the result records and a
skeleton adapter. `protocol()` is where an external TLS layer reports ALPN;
`poll()` returns true only when the transport can buffer decrypted bytes that
`select()` cannot see (for example a TLS library).

The original adapters remain first-class:

```tl
import http from "github.com/types-lua/typelua-httpd"       -- full facade
import socketTransport from "github.com/types-lua/typelua-httpd/adapters/socket"
import tlsTransport from "github.com/types-lua/typelua-httpd/adapters/tls"
```

## Library tour

| Module | Purpose |
| --- | --- |
| `lib/http_core.tl` | Dependency-free facade: no socket/ssl/ffi imports |
| `lib/http.tl` | Full facade with the bundled Socket/TLS/FFI adapters |
| `lib/http_parser.tl` | Incremental HTTP/1.1 parser plus event/streaming API |
| `lib/http_server.tl` | Protocol sniffing, HTTP/1.1 state machine, timeouts, backpressure |
| `lib/http_router.tl` | Ordered routes, params, wildcard, middleware, `stream` routes |
| `lib/http_context.tl` | Response helpers, `readBody`, `multipart`, WebSocket upgrade |
| `lib/http_static.tl` | Static files: traversal protection, ETag/304, ranges |
| `lib/http_tls_transport.tl` | LuaSec server transport, non-blocking handshake, ALPN |
| `lib/http_h2_frame.tl` | HTTP/2 frame codec and SETTINGS helpers |
| `lib/http_hpack.tl` | HPACK decoder/encoder with dynamic table and Huffman |
| `lib/http_h2_connection.tl` | HTTP/2 streams, flow control, CONTINUATION, GOAWAY |
| `lib/http_websocket.tl` | RFC 6455 handshake, framing, UTF-8 and message assembly |
| `lib/http_multipart.tl` | Incremental multipart parser and pull reader |
| `lib/http_memory_transport.tl` | Scriptable transport used by tests |
| `lib/http_socket_transport.tl` | LuaSocket TCP adapter |
| `lib/http_ffi_transport.tl` | LuaJIT FFI TCP/TLS adapter (optional, Linux/POSIX) |
| `init.tl`, `core.tl`, `adapters/{socket,tls,ffi}.tl` | Package entrypoints for external projects |
| `types/http.d.tl` | Ambient contracts shared by all modules |

### Routing

```tl
local router = http.HttpRouter.new()

router:use(function(ctx: HttpContextApi, next: () -> void): void
  next()
  print(ctx.req.method, ctx.req.path, ctx.res.status)
end)

router:get("/users/:id", function(ctx: HttpContextApi): void
  ctx:send("user " .. ctx.params["id"] .. "\n", "text/plain")
end)

router:post("/files/*", function(ctx: HttpContextApi): void
  ctx:text(ctx.params["*"] .. "\n")
end)
```

- Registration order decides precedence; `*` must be the final segment.
- `HEAD` falls back to `GET`; unknown methods produce `405` + `Allow`.
- `OPTIONS` is automatic unless explicitly registered; `OPTIONS *` reports the
  union of methods.
- Middleware is `(ctx, next)`; calling `next` twice is ignored.
- Normal handlers receive a fully buffered `req.body`. Use `router:stream` for
  streaming request bodies.

### Streaming request bodies

```tl
router:stream("POST", "/upload", function(ctx: HttpContextApi): void
  local total: integer = 0
  while true do
    local chunk: string | nil = ctx:readBody()
    if chunk == nil then break end
    total = total + #chunk!
  end
  ctx:text("received " .. tostring(total) .. "\n")
end)
```

- Streaming handlers are dispatched as soon as headers are complete.
- `ctx:readBody()` yields to the server and returns the next chunk, or `nil` at
  EOF. It works on HTTP/1.1 and HTTP/2 and under Lua 5.1/LuaJIT (the server
  protects `coroutine.resume`, not the handler call).
- `req.body` stays empty for streaming routes. Read to EOF before returning if
  you want keep-alive; answering early intentionally closes the connection
  (HTTP/2 sends `RST_STREAM` instead).
- Normal routes can still call `ctx:readBody()` once to get the buffered body.

### Multipart

```tl
router:post("/form", function(ctx: HttpContextApi): void
  local form = ctx:multipart({ maxPartBytes = 2 * 1024 * 1024 })
  while true do
    local part = form:nextPart()
    if part == nil then break end
    local meta = part:meta()
    local value: string = part:readAll()
    print(meta.name, meta.filename, meta.contentType, #value)
  end
  ctx:text("ok\n")
end)
```

- Works for buffered routes and `router:stream` routes; in the latter the reader
  pulls from `ctx:readBody()` and consumes parts incrementally.
- Boundary parsing, quoted parameters, `filename*`, empty parts, CRLF and
  binary payloads are supported.
- Limits cover part headers, part count, per-part bytes, total bytes and header
  count. Oversized input raises and becomes a `500` unless the handler catches it.
- `MultipartParser` / `MultipartReader` are also exported for standalone use.

### WebSocket

```tl
router:get("/ws", function(ctx: HttpContextApi): void
  ctx:websocket({
    onOpen = function(socket: any): void
      socket:sendText("welcome")
    end,
    onText = function(socket: any, text: string): void
      socket:sendText("echo: " .. text)
    end,
    onClose = function(socket: any, code: integer, reason: string): void
      print("closed", code, reason)
    end,
  })
end)
```

- Validates RFC 6455 handshake, version, key and subprotocol selection.
- Requires masked client frames; server frames are unmasked.
- Handles text/binary messages, fragmentation, interleaved ping/pong, close
  codes, UTF-8 validation and per-frame/per-message limits.
- `ctx:websocket` is an HTTP/1.1 upgrade. HTTP/2 WebSocket (RFC 8441) is not
  implemented.
- Async ping/heartbeat scheduling is left to the application; idle timeouts do
  not fire while a WebSocket session is open.

### TLS + HTTP/2

```tl
local transport = http.TlsTransport.new({
  certificate = "cert.pem",
  key = "key.pem",
  alpn = { "h2", "http/1.1" },
})
local server = http.HttpServer.new(router, transport, { http2 = true })
```

- TLS handshakes are non-blocking; `wantread`/`wantwrite` are driven by the
  server selector.
- ALPN chooses `h2` or `http/1.1`; the same router serves both.
- Plain connections support HTTP/2 prior knowledge (`h2c`) by default. Disable
  with `{ h2c = false }`; disable HTTP/2 entirely with `{ http2 = false }`.
- HTTP/2 implementation: SETTINGS (+ACK), HEADERS/CONTINUATION, HPACK with
  Huffman/dynamic table, DATA, WINDOW_UPDATE, RST_STREAM, PING, GOAWAY,
  PRIORITY validation, per-stream and connection flow control, request body
  limits, buffered and streaming routes.
- Server push, priority scheduling and extended CONNECT are not implemented.
- Certificate verification of clients (mTLS) and multiple SNI certificates are
  not included; terminate mTLS in a proxy if needed.

## Protocol behaviour

### HTTP/1.1

Accepted: 1.0/1.1 request lines, origin/absolute-form targets, fixed and chunked
bodies, trailers, keep-alive, pipelining, half-close, 100-continue.

Rejected or corrected: missing/multiple Host, bare LF, obs-fold, control
characters, CL+TE, conflicting lengths, unsupported transfer codings, invalid
chunks, unsupported Expect. Response `Content-Length` is always recomputed,
`Transfer-Encoding` is removed, and HEAD/1xx/204/205/304 carry no body.

### HTTP/2

- Requires the client connection preface; invalid prefaces get GOAWAY.
- Rejects connection-specific headers (`connection`, `keep-alive`,
  `proxy-connection`, `transfer-encoding`, `upgrade`) and `TE` other than
  `trailers`.
- Encoded header blocks are capped at 64 KiB compressed and 64 KiB decoded.
- Stream ids must be odd and increasing; excessive concurrent streams get
  `REFUSED_STREAM`.
- Responses are split across HEADERS/CONTINUATION and DATA according to peer
  `MAX_FRAME_SIZE`, connection windows and stream windows.
- Request trailers are not surfaced to handlers; DATA after END_STREAM resets
  the stream.

### Defaults

| Option | Default | Meaning |
| --- | --- | --- |
| `maxRequestLine` | 8192 | HTTP/1.1 request-line bytes |
| `maxHeaderBytes` | 32768 | HTTP/1.1 header block bytes |
| `maxHeaders` | 100 | HTTP/1.1 header count |
| `maxBody` | 1048576 | Request body bytes (both protocols) |
| `maxChunkLine` | 128 | HTTP/1.1 chunk-size line |
| `maxChunks` | 10000 | HTTP/1.1 chunks per request |
| `maxConnections` | 1024 | Concurrent accepted connections |
| `maxRequestsPerConnection` | 1000 | HTTP/1.1 requests before close |
| `idleTimeout` | 75 s | Keep-alive idle time |
| `requestTimeout` | 30 s | Incomplete request / preface / TLS handshake time |
| `outBufferLimit` | 16 MiB | Queued response bytes per connection |
| `keepAlive` | true | HTTP/1.1 persistent connections |
| `http2` | true | Enable HTTP/2 (ALPN/h2c) |
| `h2c` | true | Allow cleartext prior-knowledge HTTP/2 |
| `serverName` | `typelua-httpd` | `Server` response header |

Additional fixed HTTP/2 defaults: 100 concurrent streams, 64 KiB header list,
16 KiB frame size, 64 KiB windows. WebSocket defaults: 1 MiB per frame, 4 MiB
per message. Multipart defaults: 8 KiB part headers, 32 headers, 100 parts,
8 MiB per part, 32 MiB total. Static files default to 8 MiB per file.

## Testing

```bash
tlua check
tlua test                                  # embedded golua (C modules skip)
tlua test --lua lua5.4                     # TCP, TLS, ALPN, WebSocket, HTTP/2
tlua test --lua luajit --target 5.1        # LuaJIT / Lua 5.1 compatibility
```

The suite covers headers, URL/path safety, crypto vectors, HPACK RFC vectors,
HTTP/2 frames and streams, parser framing and every split point, response
serialization, router semantics, static files/ranges/ETags, multipart boundaries,
server integration (keep-alive, pipelining, 100-continue, timeouts, limits,
backpressure, streaming, h2c), TLS handshakes/ALPN, HTTP/2 over TLS, real TCP
WebSocket echo and real TCP streaming uploads.

See [`docs/design.md`](docs/design.md) for the state machines and invariants.

## Not included

- HTTP/3 / QUIC, server push, HTTP/2 priority scheduling, RFC 8441 WebSocket.
- TLS client certificates, SNI certificate selection, OCSP.
- Streaming responses (responses are buffered; request bodies can stream).
- Multipart directory listings; MIME sniffing.
- Proxy behaviour, compression (gzip/br), form-urlencoded parsing.
- Threads or true parallelism: one single-threaded event loop per server.

## License

MIT. See [`LICENSE`](LICENSE).
