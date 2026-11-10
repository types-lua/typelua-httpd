import T from "tlua_test"
import http from "../lib/http"

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
}
