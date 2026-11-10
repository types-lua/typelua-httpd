import T from "tlua_test"
import http from "../lib/http"
import literal from "../lib/http_literal"
import h2 from "../lib/http_h2_connection"
import h2f from "../lib/http_h2_frame"
import hpack from "../lib/http_hpack"
import ws from "../lib/http_websocket"

local socketOk: boolean = false
local sslOk: boolean = false
local socket: any = nil
local ssl: any = nil
local loadedSocket: any = nil
local loadedSsl: any = nil
socketOk, loadedSocket = pcall(require, "socket")
sslOk, loadedSsl = pcall(require, "ssl")
if socketOk then socket = loadedSocket end
if sslOk then ssl = loadedSsl end

if not socketOk or not sslOk then
  return {
    ["TLS transport (skipped: LuaSocket/LuaSec unavailable)"] = function(): void
      T.ok(true, "install lua-socket and lua-sec to run TLS tests")
    end,
  }
end

local CERT: string = "data/tls-test/cert.pem"
local KEY: string = "data/tls-test/key.pem"

local function ensureCertificate(): void
  local existing = io.open(CERT, "rb")
  if existing ~= nil then
    existing:close()
    local key = io.open(KEY, "rb")
    if key ~= nil then
      key:close()
      return
    end
  end
  os.execute("mkdir -p data/tls-test")
  local code = os.execute(
    "openssl req -x509 -newkey rsa:2048 -nodes -keyout " .. KEY
      .. " -out " .. CERT .. " -days 1 -subj '/CN=localhost' >/dev/null 2>&1"
  )
  if code ~= true and code ~= 0 then
    error("openssl failed to create the TLS test certificate")
  end
end

ensureCertificate()

type TlsFixture = {
  server: HttpServerApi,
  client: any,
}

local function openWith(router: HttpRouterApi, alpn: string[]): TlsFixture
  local transport = http.TlsTransport.new({
    certificate = CERT,
    key = KEY,
    alpn = alpn,
  })
  local server = http.HttpServer.new(router, transport, { idleTimeout = 10 })
  server:listen("127.0.0.1", 0)
  local address = server:address()
  local raw, err = socket.connect("127.0.0.1", address.port)
  if raw == nil then
    error("TLS connect failed: " .. tostring(err))
  end
  raw:settimeout(0)
  local client = ssl.wrap(raw, {
    mode = "client",
    protocol = "any",
    verify = "none",
    alpn = alpn,
  })
  if client == nil then
    error("ssl.wrap failed")
  end
  client:settimeout(0)
  for _: integer = 1, 2000 do
    server:step(0.001)
    local ok, hsErr = client:dohandshake()
    if ok then
      return { server = server, client = client }
    end
    if hsErr ~= "wantread" and hsErr ~= "wantwrite" and hsErr ~= "timeout" then
      error("TLS handshake failed: " .. tostring(hsErr))
    end
  end
  error("TLS handshake timed out")
end

local function open(router: HttpRouterApi): TlsFixture
  return openWith(router, { "http/1.1" })
end

local function close(fixture: TlsFixture): void
  pcall(function(): void fixture.client:close() end)
  fixture.server:close()
end

local function send(fixture: TlsFixture, data: string): void
  local sent, err, last = fixture.client:send(data)
  if sent == nil and (last == nil or last == 0) then
    error("TLS send failed: " .. tostring(err))
  end
end

local function countResponses(buffer: string): integer
  local count: integer = 0
  for _ in string.gmatch(buffer, "HTTP/%d%.%d %d%d%d") do
    count = count + 1
  end
  return count
end

local function pump(fixture: TlsFixture, expected: integer): string
  local buffer: string = ""
  for _: integer = 1, 4000 do
    fixture.server:step(0.002)
    local data, err, partial = fixture.client:receive(65536)
    if data ~= nil then
      buffer = buffer .. tostring(data)
    elseif partial ~= nil and #tostring(partial) > 0 then
      buffer = buffer .. tostring(partial)
    end
    if countResponses(buffer) >= expected then return buffer end
    if err == "closed" then break end
  end
  error("TLS response timed out; got " .. tostring(#buffer) .. " bytes")
end

return {
  ["TLS handshake, ALPN and HTTP/1.1 requests"] = function(): void
    local router = http.HttpRouter.new()
    router:get("/hello", function(ctx: HttpContextApi): void ctx:text("tls hello") end)
    router:post("/echo", function(ctx: HttpContextApi): void ctx:text(ctx.req.body) end)
    local fixture = open(router)
    T.eq(fixture.client:getalpn(), "http/1.1", "ALPN selected")

    send(fixture, "GET /hello HTTP/1.1\r\nHost: tls\r\n\r\n")
    local first = pump(fixture, 1)
    T.ok(string.find(first, "HTTP/1.1 200 OK", 1, true) ~= nil, "status")
    T.ok(string.find(first, "tls hello", 1, true) ~= nil, "body")
    T.ok(string.find(first, "Connection: close", 1, true) == nil, "keep-alive")

    send(fixture, "POST /echo HTTP/1.1\r\nHost: tls\r\nContent-Length: 8\r\n\r\nover tls")
    local second = pump(fixture, 1)
    T.ok(string.find(second, "over tls", 1, true) ~= nil, "post body")

    send(
      fixture,
      "POST /echo HTTP/1.1\r\nHost: tls\r\nTransfer-Encoding: chunked\r\n\r\n"
        .. "3\r\nabc\r\n0\r\n\r\n"
    )
    local third = pump(fixture, 1)
    T.ok(string.find(third, "abc", 1, true) ~= nil, "chunked body")
    close(fixture)
  end,

  ["TLS pipelining and close"] = function(): void
    local router = http.HttpRouter.new()
    router:get("/a", function(ctx: HttpContextApi): void ctx:text("A") end)
    router:get("/b", function(ctx: HttpContextApi): void ctx:text("B") end)
    local fixture = open(router)
    send(
      fixture,
      "GET /a HTTP/1.1\r\nHost: tls\r\n\r\n"
        .. "GET /b HTTP/1.1\r\nHost: tls\r\nConnection: close\r\n\r\n"
    )
    local buffer = pump(fixture, 2)
    T.eq(countResponses(buffer), 2, "two responses")
    T.ok(string.find(buffer, "A", 1, true) ~= nil, "first")
    T.ok(string.find(buffer, "B", 1, true) ~= nil, "second")
    T.ok(string.find(buffer, "Connection: close", 1, true) ~= nil, "close header")
    close(fixture)
  end,

  ["TLS ALPN negotiates HTTP/2 and carries frames"] = function(): void
    local router = http.HttpRouter.new()
    router:get("/h2", function(ctx: HttpContextApi): void ctx:text("tls h2") end)
    local fixture = openWith(router, { "h2", "http/1.1" })
    T.eq(fixture.client:getalpn(), "h2", "ALPN h2")
    local fields = hpack.encodeHeaders({
      { name = ":method", value = "GET" },
      { name = ":scheme", value = "https" },
      { name = ":authority", value = "localhost" },
      { name = ":path", value = "/h2" },
    })
    local wire: string = h2.PREFACE
      .. h2f.encodeFrame(h2f.FRAME_SETTINGS, 0, 0, "")
      .. h2f.encodeFrame(
        h2f.FRAME_HEADERS,
        h2f.FLAG_END_HEADERS + h2f.FLAG_END_STREAM,
        1,
        fields
      )
    send(fixture, wire)
    local buffer: string = ""
    for _: integer = 1, 4000 do
      fixture.server:step(0.002)
      local data, err, partial = fixture.client:receive(65536)
      if data ~= nil then
        buffer = buffer .. tostring(data)
      elseif partial ~= nil and #tostring(partial) > 0 then
        buffer = buffer .. tostring(partial)
      end
      if string.find(buffer, "tls h2", 1, true) ~= nil then break end
    end
    local parser = h2f.H2FrameParser.new(16777215)
    parser:feed(buffer)
    local status: string = ""
    local body: string[] = {}
    local block: string[] = {}
    while true do
      local read: any = parser:next()
      if read.needMore then break end
      local frame = read.frame
      if frame.streamId == 1 and frame.frameType == h2f.FRAME_HEADERS then
        local decoder = hpack.HpackDecoder.new()
        local decoded = decoder:decode(frame.payload)
        if decoded.error ~= "" then error(decoded.error) end
        for i: integer = 1, #decoded.headers! do
          if decoded.headers![i].name == ":status" then status = decoded.headers![i].value end
        end
      elseif frame.streamId == 1 and frame.frameType == h2f.FRAME_DATA then
        body[#body + 1] = frame.payload
      end
    end
    T.eq(status, "200", "h2 status")
    T.eq(table.concat(body), "tls h2", "h2 body")
    close(fixture)
  end,

  ["TLS WebSocket echo"] = function(): void
    local router = http.HttpRouter.new()
    router:get("/ws", function(ctx: HttpContextApi): void
      ctx:websocket({
        onText = function(socket: any, text: string): void
          socket:sendText("real:" .. text)
        end,
      })
    end)
    local fixture = openWith(router, { "http/1.1" })
    send(
      fixture,
      "GET /ws HTTP/1.1\r\nHost: tls\r\n"
        .. "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        .. "Sec-WebSocket-Version: 13\r\n"
        .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
    )
    local buffer: string = ""
    for _: integer = 1, 2000 do
      fixture.server:step(0.002)
      local data, err, partial = fixture.client:receive(65536)
      if data ~= nil then buffer = buffer .. tostring(data)
      elseif partial ~= nil and #tostring(partial) > 0 then buffer = buffer .. tostring(partial) end
      if literal.find(buffer, "\r\n\r\n", 1) ~= nil then break end
    end
    T.ok(string.find(buffer, "HTTP/1.1 101", 1, true) ~= nil, "101")
    local separator: integer = literal.find(buffer, "\r\n\r\n", 1)!
    send(fixture, ws.encodeFrame(ws.OP_TEXT, "hi", true, "\1\2\3\4"))
    local wsBuffer: string = string.sub(buffer, separator + 4)
    for _: integer = 1, 2000 do
      fixture.server:step(0.002)
      local data, err, partial = fixture.client:receive(65536)
      if data ~= nil then wsBuffer = wsBuffer .. tostring(data)
      elseif partial ~= nil and #tostring(partial) > 0 then wsBuffer = wsBuffer .. tostring(partial) end
      if string.find(wsBuffer, "real:hi", 1, true) ~= nil then break end
    end
    local parser = ws.WsFrameParser.new({ requireMask = false })
    parser:feed(wsBuffer)
    local read: any = parser:next()
    T.ok(read.frame ~= nil, "server frame")
    T.eq(read.frame.payload, "real:hi", "echo")
    close(fixture)
  end,

  ["TLS transport validates configuration"] = function(): void
    T.raises(function(): void
      http.TlsTransport.new({ certificate = "", key = KEY })
    end)
    T.raises(function(): void
      http.TlsTransport.new({ certificate = "missing.pem", key = "missing.pem" })
    end)
  end,
}
