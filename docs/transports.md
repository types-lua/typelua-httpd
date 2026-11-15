# Transports

`HttpServer` is deliberately transport-independent. It never calls a socket API
directly; it drives an object that implements three small ports. The bundled
adapters are:

| Adapter | Entry point | Dependency |
| --- | --- | --- |
| Memory | `core.MemoryTransport` | none |
| LuaSocket | `adapters/socket.SocketTransport` | `lua-socket` |
| LuaSec | `adapters/tls.TlsTransport` | `lua-socket`, `lua-sec` |
| LuaJIT FFI | `adapters/ffi.FfiSocketTransport` / `adapters/ffi.FfiTlsTransport` | LuaJIT + libc/OpenSSL |

The core (`github.com/types-lua/typelua-httpd/core`) imports none of the
optional adapters and performs no `require("socket")`, `require("ssl")` or
`require("ffi")`.

## Ports

```tl
type ReadResult = {
  data: string,
  err: string | nil,       -- non-nil means a broken transport
  closed: boolean,         -- peer half-closed / EOF
  wouldBlock: boolean,     -- no bytes now, try later
}

type WriteResult = {
  written: integer,        -- bytes accepted by the transport
  err: string | nil,
  wouldBlock: boolean,
}

type ListenResult = {
  listener: HttpListenerApi | nil,
  err: string | nil,
}

type AcceptResult = {
  conn: HttpConnectionApi | nil,
  err: string | nil,
  wouldBlock: boolean,
}

type SelectResult = {
  readable: HttpConnectionApi[],
  writable: HttpConnectionApi[],
  err: string | nil,
}
```

`HttpListenerApi`:

```tl
interface HttpListenerApi {
  accept(): AcceptResult,
  close(): void,
  address(): TransportAddress,
}
```

`HttpConnectionApi`:

```tl
interface HttpConnectionApi {
  id(): string,
  isReadable(): boolean,
  needsWrite(): boolean,
  needsHandshake(): boolean,
  poll(): boolean,
  protocol(): string,
  readAvailable(maxBytes: integer): ReadResult,
  writeSome(data: string): WriteResult,
  close(): void,
  remoteAddress(): string,
}
```

`HttpSelectorApi`:

```tl
interface HttpSelectorApi {
  select(
    readers: HttpConnectionApi[],
    writers: HttpConnectionApi[],
    timeoutSeconds: number
  ): SelectResult,
}
```

`HttpTransportApi`:

```tl
interface HttpTransportApi {
  listen(host: string, port: integer, backlog: integer): ListenResult,
  selector(): HttpSelectorApi,
  now(): number,
}
```

## Invariants

- `readAvailable(maxBytes)` returns at most an implementation-defined burst;
  the server repeatedly calls it when data is available. Return `wouldBlock`
  only when no progress is possible now.
- `writeSome` may accept fewer bytes than supplied. The server advances its
  output queue by `written`; `wouldBlock` means retry the same remaining bytes.
- Never return `err` for ordinary EOF, timeout or `EAGAIN`. Use `closed` for
  EOF and `wouldBlock` for retry.
- `id()` must be stable and unique for the lifetime of the connection.
- `protocol()` is `""` when unknown, or the ALPN result (`"h2"`,
  `"http/1.1"`). The server uses it before parsing any HTTP bytes.
- `needsHandshake()` keeps the connection in the request-timeout category while
  TLS negotiation is still in progress.
- `needsWrite()` registers the connection with the selector even when the
  application output queue is empty (for `wantwrite` handshakes).
- `poll()` should return true only for transports that can hold decrypted or
  otherwise buffered bytes invisible to the raw descriptor's `select()`.
  Such connections are driven once per short server turn, and the selector
  timeout is capped at 20 ms while any exist.
- `selector().select` must not block longer than `timeoutSeconds`. It may
  return a connection in both lists.
- `now()` is a monotonic clock used for idle/request timeouts. Seconds may be
  fractional.

## Skeleton adapter

The following is the shape of an adapter over an application-owned socket and
event loop. It is intentionally incomplete: replace `MySocket` with the real
object.

```tl
class MyConnection implements HttpConnectionApi {
  sock: any,
  name: string,
  remote: string,

  constructor(sock: any)
    self.sock = sock
    self.name = tostring(sock)
    self.remote = ""
  end,

  id(): string return self.name end,
  isReadable(): boolean return true end,
  needsWrite(): boolean return false end,
  needsHandshake(): boolean return false end,
  poll(): boolean return false end,
  protocol(): string return "" end,
  remoteAddress(): string return self.remote end,

  readAvailable(maxBytes: integer): ReadResult
    local data, err = self.sock:readSome(maxBytes)
    if data ~= nil then
      return { data = data, err = nil, closed = false, wouldBlock = false }
    end
    if err == "again" then
      return { data = "", err = nil, closed = false, wouldBlock = true }
    end
    if err == "closed" then
      return { data = "", err = nil, closed = true, wouldBlock = false }
    end
    return { data = "", err = tostring(err), closed = false, wouldBlock = false }
  end,

  writeSome(data: string): WriteResult
    local written, err = self.sock:writeSome(data)
    if written ~= nil then
      return { written = written, err = nil, wouldBlock = false }
    end
    if err == "again" then
      return { written = 0, err = nil, wouldBlock = true }
    end
    return { written = 0, err = tostring(err), wouldBlock = false }
  end,

  close(): void
    pcall(function(): void self.sock:close() end)
  end,
}
```

For TLS, wrap the plain connection and implement `protocol()` from the ALPN
result. If the TLS library buffers decrypted records, return true from
`poll()`; `readAvailable` should drain those records until it would block.

## Using the FFI adapter

```tl
import core from "github.com/types-lua/typelua-httpd/core"
import ffiTransport from "github.com/types-lua/typelua-httpd/adapters/ffi"

local transport = ffiTransport.FfiTlsTransport.new({
  certificate = "cert.pem",
  key = "key.pem",
  alpn = { "h2", "http/1.1" },
})
local server = core.HttpServer.new(router, transport, { http2 = true })
```

The FFI module installs its C declarations on first use. Applications that need
the same primitives for a client can call `ffiTransport.ensureCdefs()` and use
the returned `ffi` namespace.

Current FFI limits:

- Linux/POSIX (`accept4`, `poll`, `MSG_NOSIGNAL`).
- IPv4 addresses (`127.0.0.1`, `0.0.0.0`, or a numeric IPv4 literal as bind
  host); hostnames other than `localhost` are not resolved.
- OpenSSL shared libraries loaded as `ssl`/`crypto`, with `libssl.so.3` /
  `libcrypto.so.3` fallback.
- Unencrypted PEM keys; no client certificates, SNI certificate selection,
  OCSP or session tickets API.
- One server event loop; no threads or true parallelism.

## LuaSocket / LuaSec

Those adapters are unchanged and remain the right choice on Lua 5.4 or when
your deployment already ships LuaSocket/LuaSec:

```tl
import socketTransport from "github.com/types-lua/typelua-httpd/adapters/socket"
import tlsTransport from "github.com/types-lua/typelua-httpd/adapters/tls"

local plain = socketTransport.SocketTransport.new()
local secure = tlsTransport.TlsTransport.new({
  certificate = "cert.pem",
  key = "key.pem",
})
```

They are loaded lazily: importing the full facade does not fail when the C
modules are absent; constructing the corresponding transport gives a clear
error instead.
