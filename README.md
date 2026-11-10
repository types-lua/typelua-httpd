# typelua-httpd

A small, strict HTTP/1.1 server library written in [TypeLua](https://github.com/types-lua/TypeLua).
The protocol core is transport-independent: deterministic in-memory tests drive the same
state machine that serves real TCP through LuaSocket.

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

## Why

- **Library, not a demo.** Router, middleware, static files, limits and a blocking
  `serve()` are usable independently.
- **Framing is treated as security.** Request smuggling defences reject conflicting
  `Content-Length`/`Transfer-Encoding`, bare LF, obsolete folding and malformed chunks
  before an application handler can run.
- **Deterministic tests.** The entire server loop runs over a memory transport; the real
  socket adapter is a thin, separately tested port.
- **No runtime dependency for the protocol.** Types erase to ordinary Lua. LuaSocket is
  only needed when you call `SocketTransport.new()`.

## Requirements

| Component | Requirement |
| --- | --- |
| TypeLua | `tlua` v0.9.9 or newer |
| Lua | 5.4 (default), or LuaJIT / Lua 5.1 with `tlua --target 5.1` |
| Real TCP | [LuaSocket](https://lunarmodules.github.io/luasocket/) (`lua-socket`) |
| Tests | only `tlua`; LuaSocket enables the optional real-socket cases |

Install LuaSocket on Debian/Ubuntu:

```bash
sudo apt-get install lua-socket
```

The embedded golua runtime used by `tlua run` cannot load C modules such as LuaSocket.
Use an external interpreter for the real server:

```bash
tlua run --lua lua5.4 main.tl
```

## Run the demo

```bash
tlua check
tlua run --lua lua5.4 main.tl
# PORT=0 prints the ephemeral port it selected
```

Then:

```bash
curl -i http://127.0.0.1:8080/
curl -i http://127.0.0.1:8080/health
curl -i http://127.0.0.1:8080/api/users/42?verbose=1
curl -i -X POST --data-binary 'hello' http://127.0.0.1:8080/api/echo
curl -i http://127.0.0.1:8080/static/
curl -i -H 'Range: bytes=0-4' http://127.0.0.1:8080/static/hello.txt
```

The smallest complete program is [`examples/hello.tl`](examples/hello.tl). It lives in a
subdirectory, so run it from the emitted tree:

```bash
tlua build
(cd dist && lua5.4 examples/hello.lua)
```

## Library tour

`lib/http.tl` re-exports the public pieces. Import lower-level modules when needed.

| Module | Purpose |
| --- | --- |
| `lib/http_parser.tl` | Incremental request parser: strict framing, chunked bodies, 100-continue, limits |
| `lib/http_server.tl` | Non-blocking connection state machine: keep-alive, pipelining, timeouts, backpressure |
| `lib/http_router.tl` | Ordered routes, `:params`, `*` wildcard, middleware, 404/405/OPTIONS |
| `lib/http_context.tl` | Request/response helpers (`text`, `html`, `send`, `redirect`, cookies) |
| `lib/http_static.tl` | Static files: traversal protection, dotfile policy, ETag/304, ranges |
| `lib/http_headers.tl` | Case-insensitive ordered headers with CR/LF/NUL validation |
| `lib/http_response.tl` | Response serializer; recomputes `Content-Length`, removes `Transfer-Encoding` |
| `lib/http_url.tl` | Percent decoding, query/cookie parsing, safe lexical path joining |
| `lib/http_memory_transport.tl` | Scriptable transport used by the tests |
| `lib/http_socket_transport.tl` | LuaSocket TCP adapter |
| `types/http.d.tl` | Ambient contracts shared by all modules |

### Routing

```tl
local router = http.HttpRouter.new()

router:use(function(ctx: HttpContextApi, next: () -> void): void
  local begin: number = os.clock()
  next()
  print(ctx.req.method, ctx.req.target, ctx.res.status, os.clock() - begin)
end)

router:get("/users/:id", function(ctx: HttpContextApi): void
  ctx:send("user " .. ctx.params["id"] .. "\n", "text/plain")
end)

router:post("/files/*", function(ctx: HttpContextApi): void
  ctx:text(ctx.params["*"] .. "\n")
end)
```

- Routes match in registration order. A wildcard must be the final segment.
- `HEAD` falls back to a matching `GET` route; the serializer suppresses the body.
- Unknown paths produce `404`; known paths with the wrong method produce `405` with
  `Allow`; `OPTIONS` is answered automatically unless an explicit handler exists.
- `OPTIONS *` reports the methods registered on the server.
- Middleware is a conventional `(ctx, next)` chain. A middleware may short-circuit by
  setting a response and not calling `next`.
- Handler and middleware errors produce `500`; `onError` can observe the error and
  replace the response. An error handler that itself throws still yields a clean 500.

### Static files

```tl
local files = http.HttpStatic.new({
  root = "public",
  prefix = "/static",
  cacheControl = "public, max-age=60",
  maxBytes = 4 * 1024 * 1024,
})
router:get("/static/*", files:handler())
```

Supports `ETag`, weak/list/star `If-None-Match`, single `Range` requests (`206`/`416`),
`If-Range`, directory index fallback, MIME types, HEAD and method rejection.

Traversal protection is lexical and decodes exactly once: `..`, encoded `..`, NUL,
backslash, encoded slashes, double-encoded names and dotfiles are handled without
escaping `root`. The root itself must not contain attacker-controlled symlinks.

### Real TCP or memory

```tl
-- Production
local transport = http.SocketTransport.new()

-- Tests: no sockets, manual clock, scripted input
local transport = http.MemoryTransport.new("127.0.0.1", 0)
```

`HttpServer` only depends on `HttpTransportApi` (`listen`, `selector`, `now`), so custom
transports are possible.

## Protocol behaviour

### Accepted

- HTTP/1.0 and HTTP/1.1 request lines, origin-form and absolute-form targets.
- Fixed-length bodies and `Transfer-Encoding: chunked` with extensions/trailers.
- Keep-alive, sequential requests, pipelining and half-closed clients.
- `Expect: 100-continue` for HTTP/1.1, including a body already buffered behind the
  headers.

### Rejected or corrected

- Missing `Host` on HTTP/1.1, multiple `Host`, bare LF, obsolete header folding,
  control characters, malformed request lines/targets.
- Both `Transfer-Encoding` and `Content-Length`, conflicting duplicate lengths,
  non-numeric or negative lengths, unsupported transfer codings.
- Invalid chunk sizes, missing chunk CRLF, chunk/trailer overflow, unsupported `Expect`.
- Response splitting: header names/values are validated and serialization rejects
  invalid HTTP versions and methods.
- Response framing: `Content-Length` is always recomputed, `Transfer-Encoding` is
  removed, `HEAD`/1xx/204/205/304 carry no body, and 205 sends `Content-Length: 0`.

Errors are sent with `Connection: close`; the server never reuses a connection after a
framing error.

### Defaults

| Option | Default | Meaning |
| --- | --- | --- |
| `maxRequestLine` | 8192 | Request-line bytes |
| `maxHeaderBytes` | 32768 | Header block bytes |
| `maxHeaders` | 100 | Header count |
| `maxBody` | 1048576 | Fixed-length and chunked body bytes |
| `maxChunkLine` | 128 | Chunk-size line |
| `maxChunks` | 10000 | Chunks per request |
| `maxConnections` | 1024 | Concurrent accepted connections |
| `maxRequestsPerConnection` | 1000 | Requests before forcing close |
| `idleTimeout` | 75 s | Keep-alive idle time |
| `requestTimeout` | 30 s | Incomplete request time |
| `outBufferLimit` | 16 MiB | Queued response bytes per connection |
| `keepAlive` | true | Allow persistent connections |
| `serverName` | `typelua-httpd` | `Server` response header |

Exceeding a limit produces `413`, `414`, `431` or `503` as appropriate. Excess
connections receive a one-shot `503` and are closed.

## Testing

```bash
tlua check
tlua test                                  # embedded golua (socket cases skip)
tlua test --lua lua5.4                     # real LuaSocket integration cases run
tlua test --lua luajit --target 5.1        # LuaJIT / Lua 5.1 compatibility
```

The suite covers headers, URL/path safety, status/date/MIME, parser framing (including
byte-by-byte and chunked input), response serialization, router semantics, static
files/ranges/ETags, and server integration (keep-alive, pipelining, 100-continue,
timeouts, connection limits, error recovery). Real TCP tests bind `127.0.0.1:0` and
exercise GET, POST, chunked requests and pipelining.

See [`docs/design.md`](docs/design.md) for the state machine and invariants.

## Not included

- TLS, HTTP/2, WebSocket/upgrades, proxies.
- Multipart or form decoding; use the raw body.
- Streaming request/response bodies; bodies are bounded and buffered by design.
- Directory listings.
- True parallelism: the server is a single-threaded CSP-style loop.
- Date-based conditional requests (`If-Modified-Since`); ETags are supported.

## License

MIT. See [`LICENSE`](LICENSE).
