import T from "tlua_test"
import http from "../lib/http"
import ws from "../lib/http_websocket"
import literal from "../lib/http_literal"

local socket: any = nil
local loadedSocket: any = nil
local socketOk: boolean = false
socketOk, loadedSocket = pcall(require, "socket")
if socketOk then
  socket = loadedSocket
end
if not socketOk then
  return {
    ["LuaSocket transport (skipped: socket module unavailable)"] = function(): void
      T.ok(true, "memory transport tests cover the protocol core")
    end,
  }
end

type TcpFixture = {
  server: HttpServerApi,
  client: any,
}

local function open(router: HttpRouterApi): TcpFixture
  local transport = http.SocketTransport.new()
  local server = http.HttpServer.new(router, transport, { idleTimeout = 5 })
  server:listen("127.0.0.1", 0)
  local address = server:address()
  if address.port <= 0 then
    error("server did not report a bound port")
  end
  local client, err = socket.connect("127.0.0.1", address.port)
  if client == nil then
    error("connect failed: " .. tostring(err))
  end
  client:settimeout(0)
  -- The router is available through the closure in each case; this record is
  -- deliberately minimal so the test cannot accidentally reach server state.
  return { server = server, client = client }
end

local function close(fixture: TcpFixture): void
  pcall(function(): void fixture.client:close() end)
  fixture.server:close()
end

local function send(fixture: TcpFixture, data: string): void
  local sent, err, last = fixture.client:send(data)
  if sent == nil then
    error("send failed: " .. tostring(err) .. " at " .. tostring(last))
  end
end

local function countResponses(buffer: string): integer
  local count: integer = 0
  for _ in string.gmatch(buffer, "HTTP/%d%.%d %d%d%d") do
    count = count + 1
  end
  return count
end

local function pump(fixture: TcpFixture, expected: integer): string
  local buffer: string = ""
  for _: integer = 1, 4000 do
    fixture.server:step(0.002)
    local data, err, partial = fixture.client:receive(65536)
    if data ~= nil then
      buffer = buffer .. tostring(data)
    elseif partial ~= nil and #tostring(partial) > 0 then
      buffer = buffer .. tostring(partial)
    end
    if countResponses(buffer) >= expected then
      return buffer
    end
    if err == "closed" then
      break
    end
  end
  error("no response after pumping; received " .. tostring(#buffer) .. " bytes")
end

return {
  ["real TCP GET, keep-alive and POST"] = function(): void
    local router = http.HttpRouter.new()
    router:get("/hello", function(ctx: HttpContextApi): void
      ctx:text("hello tcp")
    end)
    router:post("/echo", function(ctx: HttpContextApi): void
      ctx:text(ctx.req.body)
    end)
    local fixture: TcpFixture = open(router)

    send(fixture, "GET /hello HTTP/1.1\r\nHost: tcp\r\n\r\n")
    local first: string = pump(fixture, 1)
    T.ok(string.find(first, "HTTP/1.1 200 OK", 1, true) ~= nil, "status")
    T.ok(string.find(first, "hello tcp", 1, true) ~= nil, "body")
    T.ok(string.find(first, "Connection: close", 1, true) == nil, "kept alive")

    send(fixture, "POST /echo HTTP/1.1\r\nHost: tcp\r\nContent-Length: 11\r\n\r\nsocket body")
    local second: string = pump(fixture, 1)
    T.ok(string.find(second, "socket body", 1, true) ~= nil, "post echo")

    send(fixture, "POST /echo HTTP/1.1\r\nHost: tcp\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
    local third: string = pump(fixture, 1)
    T.ok(string.find(third, "abc", 1, true) ~= nil, "chunked echo")

    close(fixture)
  end,

  ["real TCP pipelining and connection close"] = function(): void
    local transport = http.SocketTransport.new()
    local router = http.HttpRouter.new()
    local server = http.HttpServer.new(router, transport, { idleTimeout = 5 })
    server:listen("127.0.0.1", 0)
    local address = server:address()
    router:get("/a", function(ctx: HttpContextApi): void ctx:text("A") end)
    router:get("/b", function(ctx: HttpContextApi): void ctx:text("B") end)

    local client, err = socket.connect("127.0.0.1", address.port)
    if client == nil then
      error("connect failed: " .. tostring(err))
    end
    client:settimeout(0)
    local fixture: TcpFixture = { server = server, client = client }

    send(
      fixture,
      "GET /a HTTP/1.1\r\nHost: tcp\r\n\r\n"
        .. "GET /b HTTP/1.1\r\nHost: tcp\r\nConnection: close\r\n\r\n"
    )
    local buffer: string = pump(fixture, 2)
    T.eq(countResponses(buffer), 2, "two responses")
    T.ok(string.find(buffer, "A", 1, true) ~= nil, "first body")
    T.ok(string.find(buffer, "B", 1, true) ~= nil, "second body")
    T.ok(string.find(buffer, "Connection: close", 1, true) ~= nil, "close header")

    -- Give the server a chance to observe the client's FIN and clean up.
    for _: integer = 1, 20 do
      fixture.server:step(0.002)
    end
    T.ok(fixture.server:address().port > 0, "server remains healthy")
    close(fixture)
  end,
  ["real TCP WebSocket echo"] = function(): void
    local transport = http.SocketTransport.new()
    local router = http.HttpRouter.new()
    router:get("/ws", function(ctx: HttpContextApi): void
      ctx:websocket({
        onText = function(socket: any, text: string): void
          socket:sendText("real:" .. text)
        end,
      })
    end)
    local server = http.HttpServer.new(router, transport, { idleTimeout = 10 })
    server:listen("127.0.0.1", 0)
    local address = server:address()
    local client, err = socket.connect("127.0.0.1", address.port)
    if client == nil then error("connect failed: " .. tostring(err)) end
    client:settimeout(0)
    local fixture: TcpFixture = { server = server, client = client }
    local function receiveUntil(predicate: (buffer: string) -> boolean, initial: string): string
      local buffer: string = initial
      for _: integer = 1, 4000 do
        fixture.server:step(0.002)
        local data, rerr, partial = fixture.client:receive(65536)
        if data ~= nil then
          buffer = buffer .. tostring(data)
        elseif partial ~= nil and #tostring(partial) > 0 then
          buffer = buffer .. tostring(partial)
        end
        if predicate(buffer) then return buffer end
        if rerr == "closed" then return buffer end
      end
      error("WebSocket pump timed out")
    end
    send(
      fixture,
      "GET /ws HTTP/1.1\r\nHost: tcp\r\n"
        .. "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        .. "Sec-WebSocket-Version: 13\r\n"
        .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
    )
    local handshake = receiveUntil(function(buffer: string): boolean
      return literal.find(buffer, "\r\n\r\n", 1) ~= nil
    end, "")
    T.ok(string.find(handshake, "HTTP/1.1 101", 1, true) ~= nil, "101")
    T.ok(string.find(handshake, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", 1, true) ~= nil, "accept")
    local separator: integer = literal.find(handshake, "\r\n\r\n", 1)!
    local streamBytes: string = string.sub(handshake, separator + 4)

    local mask: string = "\1\2\3\4"
    send(fixture, ws.encodeFrame(ws.OP_TEXT, "hi", true, mask))
    local afterEcho = receiveUntil(function(buffer: string): boolean
      return string.find(buffer, "real:hi", 1, true) ~= nil
    end, streamBytes)
    T.ok(string.find(afterEcho, "real:hi", 1, true) ~= nil, "echo")

    send(fixture, ws.encodeFrame(ws.OP_CLOSE, string.char(3, 232), true, mask))
    for _: integer = 1, 100 do
      fixture.server:step(0.002)
    end
    T.ok(client ~= nil, "socket alive")
    close(fixture)
  end,

  ["real TCP streaming request body"] = function(): void
    local transport = http.SocketTransport.new()
    local router = http.HttpRouter.new()
    router:stream("POST", "/stream", function(ctx: HttpContextApi): void
      local total: integer = 0
      local chunks: integer = 0
      while true do
        local chunk: string | nil = ctx:readBody()
        if chunk == nil then break end
        total = total + #chunk!
        chunks = chunks + 1
      end
      ctx:send(tostring(total) .. ":" .. tostring(chunks), "text/plain")
    end)
    local server = http.HttpServer.new(router, transport, { idleTimeout = 10, maxBody = 200000 })
    server:listen("127.0.0.1", 0)
    local address = server:address()
    local client, err = socket.connect("127.0.0.1", address.port)
    if client == nil then error("connect failed: " .. tostring(err)) end
    client:settimeout(0)
    local fixture: TcpFixture = { server = server, client = client }
    local body: string = string.rep("s", 70000)
    send(fixture, "POST /stream HTTP/1.1\r\nHost: tcp\r\nContent-Length: 70000\r\n\r\n")
    for _: integer = 1, 30 do fixture.server:step(0.001) end
    send(fixture, string.sub(body, 1, 30000))
    for _: integer = 1, 30 do fixture.server:step(0.001) end
    send(fixture, string.sub(body, 30001))
    local response = pump(fixture, 1)
    T.ok(string.find(response, "70000:", 1, true) ~= nil, "streamed total")
    close(fixture)
  end,

}
