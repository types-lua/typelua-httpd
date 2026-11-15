import T from "tlua_test"
import http from "../lib/http"
import ws from "../lib/http_websocket"
import h2 from "../lib/http_h2_connection"
import h2f from "../lib/http_h2_frame"
import hpack from "../lib/http_hpack"
import ffiTransport from "../lib/http_ffi_transport"

local socketOk: boolean = false
local socket: any = nil
socketOk, socket = pcall(require, "socket")
local sslOk: boolean = false
local ssl: any = nil
sslOk, ssl = pcall(require, "ssl")

local ffiOk: boolean = false
local ffi: any = nil
ffiOk, ffi = pcall(ffiTransport.ensureCdefs)

if not ffiOk or ffi == nil then
  return {
    ["FFI transport (skipped: LuaJIT FFI unavailable)"] = function(): void
      T.ok(true, "run with --lua luajit to exercise the FFI transport")
    end,
  }
end

local C: any = ffi.C
local AF_INET: integer = 2
local SOCK_STREAM: integer = 1
local MSG_NOSIGNAL: integer = 0x4000
local MSG_DONTWAIT: integer = 0x40
local POLLIN: integer = 1

class FfiClient {
  fd: integer,
  closed: boolean = false,
  buffer: string = "",

  constructor(host: string, port: integer)
    local fd: any = C.socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 then error("FFI client socket failed") end
    self.fd = fd as integer
    local addr: any = ffi.new("sockaddr_in")
    addr.sin_family = AF_INET
    addr.sin_port = C.htons(port)
    local scratch: any = ffi.new("uint8_t[4]")
    if C.inet_pton(AF_INET, host, scratch) ~= 1 then
      error("FFI client host must be IPv4")
    end
    addr.sin_addr.s_addr = (ffi.cast("in_addr*", scratch)[0]).s_addr
    if C.connect(
      self.fd,
      ffi.cast("sockaddr*", addr),
      ffi.sizeof("sockaddr_in")
    ) ~= 0 then
      C.close(self.fd)
      error("FFI client connect failed")
    end
  end,

  sendAll(data: string): void
    local offset: integer = 1
    while offset <= #data do
      local part: string = string.sub(data, offset)
      local sent: any = C.send(self.fd, part, #part, MSG_NOSIGNAL)
      if sent <= 0 then error("FFI client send failed") end
      offset = offset + (sent as integer)
    end
  end,

  recvSome(): string
    if self.closed then return "" end
    local pfd: any = ffi.new("pollfd[1]")
    pfd[0].fd = self.fd
    pfd[0].events = POLLIN
    pfd[0].revents = 0
    local ready: any = C.poll(pfd, 1, 0)
    if ready <= 0 then return "" end
    local buffer: any = ffi.new("char[65536]")
    local count: any = C.recv(self.fd, buffer, 65536, MSG_DONTWAIT)
    if count > 0 then
      return ffi.string(buffer, count)
    end
    if count == 0 then
      self.closed = true
      return ""
    end
    local errno: integer = ffi.errno() as integer
    if errno ~= 11 and errno ~= 4 then
      self.closed = true
    end
    return ""
  end,

  readUntil(
    server: HttpServerApi,
    predicate: (text: string) -> boolean,
    timeoutSteps: integer
  ): string
    local text: string = self.buffer
    for _: integer = 1, timeoutSteps do
      server:step(0.001)
      local chunk: string = self:recvSome()
      if chunk ~= "" then
        text = text .. chunk
        if predicate(text) then
          self.buffer = text
          return text
        end
      end
      if self.closed then break end
    end
    self.buffer = text
    return text
  end,

  close(): void
    if self.closed then return end
    self.closed = true
    C.close(self.fd)
  end,
}

local function statusCount(text: string): integer
  local count: integer = 0
  for _ in string.gmatch(text, "HTTP/%d%.%d %d%d%d") do count = count + 1 end
  return count
end

local function framesOf(text: string): any[]
  local parser = h2f.H2FrameParser.new(16777215)
  parser:feed(text)
  local frames: any[] = {}
  while true do
    local read: any = parser:next()
    if read.needMore then break end
    if read.err ~= nil and #read.err > 0 then error(read.err) end
    frames[#frames + 1] = read.frame
  end
  return frames
end

local function h2StatusAndBody(frames: any[], streamId: integer): (string, string)
  local block: string[] = {}
  local body: string[] = {}
  local status: string = ""
  local decoded: any = nil
  for i: integer = 1, #frames do
    local frame = frames[i]
    if frame.streamId == streamId then
      if frame.frameType == h2f.FRAME_HEADERS then
        block = { frame.payload }
        if math.floor(frame.flags / h2f.FLAG_END_HEADERS) % 2 == 1 then
          local decoder = hpack.HpackDecoder.new()
          decoded = decoder:decode(table.concat(block))
          if decoded.error ~= "" then error(decoded.error) end
        end
      elseif frame.frameType == h2f.FRAME_CONTINUATION and #block > 0 then
        block[#block + 1] = frame.payload
        if math.floor(frame.flags / h2f.FLAG_END_HEADERS) % 2 == 1 then
          local decoder = hpack.HpackDecoder.new()
          decoded = decoder:decode(table.concat(block))
          if decoded.error ~= "" then error(decoded.error) end
        end
      elseif frame.frameType == h2f.FRAME_DATA then
        body[#body + 1] = frame.payload
      end
    end
  end
  if decoded ~= nil then
    for i: integer = 1, #decoded.headers do
      if decoded.headers[i].name == ":status" then status = decoded.headers[i].value end
    end
  end
  return status, table.concat(body)
end

local function plainFixture(): any
  local router = http.HttpRouter.new()
  router:get("/", function(ctx: HttpContextApi): void
    ctx:text("ffi tcp\n")
  end)
  router:post("/echo", function(ctx: HttpContextApi): void
    ctx:text(ctx.req.body)
  end)
  router:get("/ws", function(ctx: HttpContextApi): void
    ctx:websocket({
      onText = function(socket: any, text: string): void
        socket:sendText("ffi:" .. text)
      end,
    })
  end)
  local transport = http.FfiSocketTransport.new()
  local server = http.HttpServer.new(router, transport, { idleTimeout = 10 })
  server:listen("127.0.0.1", 0)
  return { server = server, router = router, transport = transport }
end

local CERT: string = "data/tls-test/cert.pem"
local KEY: string = "data/tls-test/key.pem"

local function ensureCertificate(): void
  local existing: any = io.open(CERT, "rb")
  if existing ~= nil then
    existing:close()
    local keyFile: any = io.open(KEY, "rb")
    if keyFile ~= nil then
      keyFile:close()
      return
    end
  end
  os.execute("mkdir -p data/tls-test")
  local code: any = os.execute(
    "openssl req -x509 -newkey rsa:2048 -nodes -keyout " .. KEY
      .. " -out " .. CERT .. " -days 1 -subj '/CN=localhost' >/dev/null 2>&1"
  )
  if code ~= true and code ~= 0 then
    error("openssl failed to create the FFI TLS test certificate")
  end
end

type TlsClientFixture = {
  server: HttpServerApi,
  client: any,
  port: integer,
}

local function openTls(router: HttpRouterApi, alpn: string[]): TlsClientFixture
  ensureCertificate()
  local transport = http.FfiTlsTransport.new({
    certificate = CERT,
    key = KEY,
    alpn = alpn,
  })
  local server = http.HttpServer.new(router, transport, { idleTimeout = 10 })
  server:listen("127.0.0.1", 0)
  local address = server:address()
  local raw: any = nil
  local connectErr: any = nil
  raw, connectErr = socket.connect("127.0.0.1", address.port)
  if raw == nil then error("FFI TLS client connect failed: " .. tostring(connectErr)) end
  raw:settimeout(0)
  local client: any = ssl.wrap(raw, {
    mode = "client",
    protocol = "any",
    verify = "none",
    alpn = alpn,
  })
  if client == nil then error("ssl.wrap failed") end
  client:settimeout(0)
  for _: integer = 1, 4000 do
    server:step(0.001)
    local ok: boolean = false
    local hsErr: any = nil
    ok, hsErr = client:dohandshake()
    if ok then
      return { server = server, client = client, port = address.port }
    end
    if hsErr ~= "wantread" and hsErr ~= "wantwrite" and hsErr ~= "timeout" then
      error("FFI TLS handshake failed: " .. tostring(hsErr))
    end
  end
  error("FFI TLS handshake timed out")
end

local function tlsSend(client: any, data: string): void
  local sent: any = nil
  local err: any = nil
  local last: any = nil
  sent, err, last = client:send(data)
  if sent == nil and (last == nil or last == 0) then
    error("FFI TLS client send failed: " .. tostring(err))
  end
end

local function tlsPump(
  fixture: TlsClientFixture,
  predicate: (text: string) -> boolean,
  steps: integer
): string
  local buffer: string = ""
  for _: integer = 1, steps do
    fixture.server:step(0.001)
    local data: any = nil
    local err: any = nil
    local partial: any = nil
    data, err, partial = fixture.client:receive(65536)
    if data ~= nil then
      buffer = buffer .. tostring(data)
    elseif partial ~= nil and #tostring(partial) > 0 then
      buffer = buffer .. tostring(partial)
    end
    if predicate(buffer) then return buffer end
    if err == "closed" then break end
  end
  return buffer
end


return {
  ["FFI TCP keep-alive, POST and WebSocket"] = function(): void
    local f = plainFixture()
    local port: integer = f.server:address().port
    local client = FfiClient.new("127.0.0.1", port)

    client:sendAll("GET / HTTP/1.1\r\nHost: ffi\r\n\r\n")
    local first: string = client:readUntil(f.server, function(text: string): boolean
      return statusCount(text) >= 1
    end, 20000)
    T.ok(string.find(first, "HTTP/1.1 200 OK", 1, true) ~= nil, "GET status")
    T.ok(string.find(first, "ffi tcp", 1, true) ~= nil, "GET body")

    client:sendAll("POST /echo HTTP/1.1\r\nHost: ffi\r\nContent-Length: 5\r\n\r\nhello")
    local second: string = client:readUntil(f.server, function(text: string): boolean
      return statusCount(text) >= 2
    end, 20000)
    T.ok(string.find(second, "hello", 1, true) ~= nil, "POST body")

    client:sendAll(
      "GET /ws HTTP/1.1\r\nHost: ffi\r\n"
        .. "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        .. "Sec-WebSocket-Version: 13\r\n"
        .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
    )
    local handshake: string = client:readUntil(f.server, function(text: string): boolean
      return string.find(text, "\r\n\r\n", 1, true) ~= nil
    end, 20000)
    T.ok(string.find(handshake, "HTTP/1.1 101", 1, true) ~= nil, "WS handshake")
    local separator: integer = string.find(handshake, "\r\n\r\n", 1, true)!
    client:sendAll(ws.encodeFrame(ws.OP_TEXT, "hi", true, "\1\2\3\4"))
    local echoed: string = client:readUntil(f.server, function(text: string): boolean
      return string.find(text, "ffi:hi", 1, true) ~= nil
    end, 20000)
    T.ok(string.find(echoed, "ffi:hi", 1, true) ~= nil, "WS echo")
    client:close()
    f.server:close()
  end,

  ["FFI TLS HTTP/1.1 and ALPN h2"] = function(): void
    if not sslOk or ssl == nil or not socketOk or socket == nil then
      T.ok(true, "TLS client skipped: install lua-socket and lua-sec")
      return
    end
    local router = http.HttpRouter.new()
    router:get("/", function(ctx: HttpContextApi): void ctx:text("ffi tls\n") end)
    router:get("/version", function(ctx: HttpContextApi): void
      ctx:text("version=" .. ctx.req.version)
    end)

    local plainFixture = openTls(router, { "http/1.1" })
    T.eq(plainFixture.client:getalpn(), "http/1.1", "ALPN http/1.1")
    tlsSend(plainFixture.client, "GET / HTTP/1.1\r\nHost: ffi\r\n\r\n")
    local h1: string = tlsPump(plainFixture, function(text: string): boolean
      return string.find(text, "ffi tls", 1, true) ~= nil
    end, 30000)
    T.ok(string.find(h1, "HTTP/1.1 200 OK", 1, true) ~= nil, "TLS H1 status")
    T.ok(string.find(h1, "ffi tls", 1, true) ~= nil, "TLS H1 body")
    pcall(function(): void plainFixture.client:close() end)
    plainFixture.server:close()

    local h2Fixture = openTls(router, { "h2", "http/1.1" })
    T.eq(h2Fixture.client:getalpn(), "h2", "ALPN h2")
    local block: string = hpack.encodeHeaders({
      { name = ":method", value = "GET" },
      { name = ":scheme", value = "https" },
      { name = ":authority", value = "ffi.test" },
      { name = ":path", value = "/version" },
    })
    local wire: string = h2.PREFACE
      .. h2f.encodeFrame(h2f.FRAME_SETTINGS, 0, 0, "")
      .. h2f.encodeFrame(
        h2f.FRAME_HEADERS,
        h2f.FLAG_END_HEADERS + h2f.FLAG_END_STREAM,
        1,
        block
      )
    tlsSend(h2Fixture.client, wire)
    local response: string = tlsPump(h2Fixture, function(text: string): boolean
      return string.find(text, "version=2.0", 1, true) ~= nil
    end, 30000)
    local status, body = h2StatusAndBody(framesOf(response), 1)
    T.eq(status, "200", "TLS h2 status")
    T.eq(body, "version=2.0", "TLS h2 body")
    pcall(function(): void h2Fixture.client:close() end)
    h2Fixture.server:close()
  end,

  ["FFI TCP h2c prior knowledge"] = function(): void
    local f = plainFixture()
    local port: integer = f.server:address().port
    local client = FfiClient.new("127.0.0.1", port)
    local block: string = hpack.encodeHeaders({
      { name = ":method", value = "GET" },
      { name = ":scheme", value = "http" },
      { name = ":authority", value = "ffi.test" },
      { name = ":path", value = "/" },
    })
    local wire: string = h2.PREFACE
      .. h2f.encodeFrame(h2f.FRAME_SETTINGS, 0, 0, "")
      .. h2f.encodeFrame(
        h2f.FRAME_HEADERS,
        h2f.FLAG_END_HEADERS + h2f.FLAG_END_STREAM,
        1,
        block
      )
    client:sendAll(wire)
    local response: string = client:readUntil(f.server, function(text: string): boolean
      return string.find(text, "ffi tcp", 1, true) ~= nil
    end, 30000)
    local status, body = h2StatusAndBody(framesOf(response), 1)
    T.eq(status, "200", "h2 status")
    T.eq(body, "ffi tcp\n", "h2 body")
    client:close()
    f.server:close()
  end,
}
