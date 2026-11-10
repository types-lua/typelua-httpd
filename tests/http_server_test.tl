import T from "tlua_test"
import http from "../lib/http"
import literal from "../lib/http_literal"

type WireResponse = {
  version: string,
  status: integer,
  headers: map<string, string>,
  body: string,
}

type Fixture = {
  server: HttpServerApi,
  router: HttpRouterApi,
  transport: any,
}

local function requestText(
  method: string,
  target: string,
  extraHeaders: string[],
  body: string
): string
  local lines: string[] = { method .. " " .. target .. " HTTP/1.1", "Host: test.local" }
  for i: integer = 1, #extraHeaders do
    lines[#lines + 1] = extraHeaders[i]
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. body
end

local function parseResponses(wire: string, methods: string[]): WireResponse[]
  local out: WireResponse[] = {}
  local pos: integer = 1
  local index: integer = 0
  while pos <= #wire do
    local separator: integer | nil = literal.find(wire, "\r\n\r\n", pos)
    if separator == nil then
      error("truncated response at byte " .. tostring(pos))
    end
    local block: string = string.sub(wire, pos, separator! - 1)
    local lines: string[] = {}
    for line in string.gmatch(block, "[^\r\n]+") do
      lines[#lines + 1] = line
    end
    if #lines == 0 then
      error("empty response head")
    end
    local version, statusText = string.match(lines[1], "^(HTTP/%d%.%d) (%d%d%d) ")
    if version == nil or statusText == nil then
      error("bad status line: " .. lines[1])
    end
    -- Re-extract from the line instead of relying on narrowing after error(),
    -- which the checker intentionally does not treat as terminating.
    local versionText: string = string.sub(lines[1], 1, 8)
    local statusDigits: string = string.sub(lines[1], 10, 12)
    local headers: map<string, string> = {}
    for i: integer = 2, #lines do
      local colon: integer | nil = literal.find(lines[i], ":", 1)
      if colon ~= nil then
        local name: string = string.lower(string.sub(lines[i], 1, colon! - 1))
        local value: string = string.sub(lines[i], colon! + 1)
        while #value > 0 and string.sub(value, 1, 1) == " " do
          value = string.sub(value, 2)
        end
        headers[name] = value
      end
    end
    local statusNumber: number | nil = tonumber(statusDigits)
    if statusNumber == nil then
      error("bad status digits: " .. statusDigits)
    end
    local status: integer = math.floor(statusNumber!)
    index = index + 1
    local method: string = "GET"
    if methods[index] ~= nil then
      method = methods[index]
    end
    local length: integer = 0
    local rawLength: string | nil = headers["content-length"]
    if rawLength ~= nil then
      local parsed: number | nil = tonumber(rawLength!)
      if parsed ~= nil then length = math.floor(parsed!) end
    end
    local bodyless: boolean = status < 200 or status == 204 or status == 304
      or string.upper(method) == "HEAD"
    local bodyLength: integer = length
    if bodyless then bodyLength = 0 end
    local bodyStart: integer = separator! + 4
    local body: string = ""
    if bodyLength > 0 then
      body = string.sub(wire, bodyStart, bodyStart + bodyLength - 1)
    end
    out[#out + 1] = {
      version = versionText,
      status = status,
      headers = headers,
      body = body,
    }
    pos = bodyStart + bodyLength
  end
  return out
end

local function makeFixture(options: ServerOptions): Fixture
  local router = http.HttpRouter.new()
  local transport = http.MemoryTransport.new("127.0.0.1", 0)
  local server = http.HttpServer.new(router, transport, options)
  server:listen("127.0.0.1", 0)
  return { server = server, router = router, transport = transport }
end

local function connect(
  fixture: Fixture,
  name: string,
  data: string,
  closeInput: boolean
): any
  local conn = http.MemoryConnection.new(name, data, "203.0.113.9:54321")
  if closeInput then
    conn:closeInput()
  end
  local transport: any = fixture.transport
  transport.listener:push(conn)
  return conn
end

local function step(fixture: Fixture): void
  fixture.server:step(0)
end

local function orEmpty(value: string | nil): string
  if value == nil then return "" end
  return value!
end

return {
  ["request context, POST body and response headers"] = function(): void
    local f = makeFixture({})
    f.router:post("/echo", function(ctx: HttpContextApi): void
      ctx:set("X-Method", ctx.req.method)
      ctx:set("X-Query", orEmpty(ctx:query("q")))
      ctx:set("X-Cookie", orEmpty(ctx:cookie("a")))
      ctx:set("X-Remote", ctx.req.remote)
      ctx:set("X-Host", orEmpty(ctx:get("Host")))
      ctx:send(ctx.req.body, "text/plain")
    end)
    local conn = connect(
      f,
      "c1",
      requestText(
        "POST",
        "/echo?q=a+b",
        { "Cookie: a=cookie-value", "X-Test: 1", "Content-Length: 5" },
        "hello"
      ),
      false
    )
    step(f)
    local responses = parseResponses(conn:takeOutput(), { "POST" })
    T.eq(#responses, 1, "one response")
    local res = responses[1]
    T.eq(res.status, 200, "status")
    T.eq(res.body, "hello", "echoed body")
    T.eq(res.headers["content-type"], "text/plain", "content type")
    T.eq(res.headers["content-length"], "5", "length")
    T.eq(res.headers["x-method"], "POST", "method")
    T.eq(res.headers["x-query"], "a b", "decoded query")
    T.eq(res.headers["x-cookie"], "cookie-value", "cookie")
    T.eq(res.headers["x-remote"], "203.0.113.9:54321", "remote")
    T.eq(res.headers["x-host"], "test.local", "host")
    T.eq(res.headers["server"], "typelua-httpd", "server")
    T.ok(res.headers["date"] ~= nil, "date")
    T.eq(res.headers["connection"], nil, "HTTP/1.1 keep-alive has no close header")
    local stats = f.server:stats()
    T.eq(stats.connections, 1, "connection count")
    T.eq(stats.requests, 1, "request count")
    T.eq(stats.responses, 1, "response count")
    T.ok(stats.bytesIn > 0, "bytes in")
    T.ok(stats.bytesOut > 0, "bytes out")
    conn:closeInput()
    step(f)
  end,

  ["sequential keep-alive then FIN"] = function(): void
    local f = makeFixture({})
    f.router:get("/ping", function(ctx: HttpContextApi): void ctx:text("pong") end)
    local conn = connect(f, "ka", requestText("GET", "/ping", {}, ""), false)
    step(f)
    local first = parseResponses(conn:takeOutput(), { "GET" })
    T.eq(#first, 1, "first response")
    T.eq(first[1].body, "pong", "first body")
    T.eq(first[1].headers["connection"], nil, "kept alive")

    conn:feed(requestText("GET", "/ping", { "Connection: keep-alive" }, ""))
    step(f)
    local second = parseResponses(conn:takeOutput(), { "GET" })
    T.eq(#second, 1, "second response")
    T.eq(second[1].body, "pong", "second body")

    local stats = f.server:stats()
    T.eq(stats.requests, 2, "two requests")
    conn:closeInput()
    step(f)
    T.eq(conn:takeOutput(), "", "clean close")
  end,

  ["pipelined requests on a half-closed socket"] = function(): void
    local f = makeFixture({})
    local n: integer = 0
    f.router:get("/n", function(ctx: HttpContextApi): void
      n = n + 1
      ctx:text(tostring(n))
    end)
    local wire: string = requestText("GET", "/n", {}, "")
      .. requestText("GET", "/n", {}, "")
      .. requestText("GET", "/n", {}, "")
    local conn = connect(f, "pipe", wire, true)
    step(f)
    local responses = parseResponses(conn:takeOutput(), { "GET", "GET", "GET" })
    T.eq(#responses, 3, "three responses")
    T.eq(responses[1].body, "1", "first")
    T.eq(responses[2].body, "2", "second")
    T.eq(responses[3].body, "3", "third")
    T.eq(f.server:stats().requests, 3, "stats")
  end,

  ["large body spans multiple read events"] = function(): void
    local f = makeFixture({})
    f.router:post("/big", function(ctx: HttpContextApi): void
      ctx:text(tostring(#ctx.req.body))
    end)
    local body: string = string.rep("a", 70000)
    local wire: string = "POST /big HTTP/1.1\r\nHost: t\r\nContent-Length: 70000\r\n\r\n"
      .. body
    local conn = connect(f, "big", wire, true)
    step(f)
    T.eq(conn:takeOutput(), "", "first read is partial")
    T.eq(f.server:stats().requests, 0, "not dispatched early")
    local buffer: string = ""
    for _: integer = 1, 5 do
      step(f)
      buffer = buffer .. conn:takeOutput()
      if literal.find(buffer, "HTTP/1.1 200 OK", 1) ~= nil then break end
    end
    local res = parseResponses(buffer, { "POST" })[1]
    T.eq(res.status, 200, "status")
    T.eq(res.body, "70000", "body length")
  end,

  ["incomplete pipelined request gets 400 after earlier responses"] = function(): void
    local f = makeFixture({})
    f.router:get("/x", function(ctx: HttpContextApi): void ctx:text("ok") end)
    local wire: string = requestText("GET", "/x", {}, "")
      .. "GET /x HTTP/1.1\r\nHost: t\r\n"
    local conn = connect(f, "tail", wire, true)
    step(f)
    step(f)
    local responses = parseResponses(conn:takeOutput(), { "GET", "GET" })
    T.eq(#responses, 2, "complete plus error")
    T.eq(responses[1].status, 200, "first served")
    T.eq(responses[1].body, "ok", "first body")
    T.eq(responses[2].status, 400, "trailing partial")
    T.eq(responses[2].headers["connection"], "close", "trailing closes")
  end,

  ["HTTP/1.0 closes by default and honours keep-alive"] = function(): void
    local f = makeFixture({})
    f.router:get("/x", function(ctx: HttpContextApi): void ctx:text("x") end)
    local closeWire: string = "GET /x HTTP/1.0\r\n\r\n"
    local conn = connect(f, "v10", closeWire, true)
    step(f)
    local closeResponses = parseResponses(conn:takeOutput(), { "GET" })
    T.eq(#closeResponses, 1, "1.0 response")
    T.eq(closeResponses[1].version, "HTTP/1.0", "1.0 status line")
    T.eq(closeResponses[1].headers["connection"], "close", "1.0 close")

    local keepConn = connect(
      f,
      "v10keep",
      "GET /x HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
      false
    )
    step(f)
    local keepResponses = parseResponses(keepConn:takeOutput(), { "GET" })
    T.eq(keepResponses[1].headers["connection"], "keep-alive", "1.0 keep-alive")
    keepConn:closeInput()
    step(f)
  end,

  ["chunked request with extension and trailer"] = function(): void
    local f = makeFixture({})
    f.router:post("/echo", function(ctx: HttpContextApi): void ctx:text(ctx.req.body) end)
    local wire: string = "POST /echo HTTP/1.1\r\nHost: t\r\n"
      .. "Transfer-Encoding: chunked\r\n\r\n"
      .. "4;foo=bar\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trailer: yes\r\n\r\n"
    local conn = connect(f, "chunk", wire, true)
    step(f)
    local res = parseResponses(conn:takeOutput(), { "POST" })[1]
    T.eq(res.status, 200, "status")
    T.eq(res.body, "Wikipedia", "chunked body")
    T.eq(res.headers["transfer-encoding"], nil, "no chunked response")
  end,

  ["100-continue waits, then accepts the body"] = function(): void
    local f = makeFixture({})
    f.router:post("/upload", function(ctx: HttpContextApi): void ctx:text(ctx.req.body) end)
    local headers: string = "POST /upload HTTP/1.1\r\nHost: t\r\n"
      .. "Content-Length: 5\r\nExpect: 100-continue\r\n\r\n"
    local conn = connect(f, "expect", headers, false)
    step(f)
    local interim = parseResponses(conn:takeOutput(), { "POST" })
    T.eq(#interim, 1, "interim response")
    T.eq(interim[1].status, 100, "100 status")
    T.eq(interim[1].body, "", "100 body")

    conn:feed("hello")
    step(f)
    local final = parseResponses(conn:takeOutput(), { "POST" })
    T.eq(#final, 1, "final response")
    T.eq(final[1].status, 200, "final status")
    T.eq(final[1].body, "hello", "final body")
    conn:closeInput()
    step(f)
  end,

  ["100-continue with the body already buffered"] = function(): void
    local f = makeFixture({})
    f.router:post("/upload", function(ctx: HttpContextApi): void ctx:text(ctx.req.body) end)
    local wire: string = "POST /upload HTTP/1.1\r\nHost: t\r\n"
      .. "Content-Length: 5\r\nExpect: 100-continue\r\n\r\nhello"
    local conn = connect(f, "expect2", wire, true)
    step(f)
    local all = parseResponses(conn:takeOutput(), { "POST", "POST" })
    T.eq(#all, 2, "interim and final")
    T.eq(all[1].status, 100, "interim")
    T.eq(all[2].status, 200, "final")
    T.eq(all[2].body, "hello", "body")
  end,

  ["HTTP/1.0 Expect does not get 100 Continue"] = function(): void
    local f = makeFixture({})
    f.router:post("/x", function(ctx: HttpContextApi): void ctx:text(ctx.req.body) end)
    local wire: string = "POST /x HTTP/1.0\r\nContent-Length: 3\r\n"
      .. "Expect: 100-continue\r\n\r\nabc"
    local conn = connect(f, "expect10", wire, true)
    step(f)
    local all = parseResponses(conn:takeOutput(), { "POST" })
    T.eq(#all, 1, "no interim")
    T.eq(all[1].status, 200, "final")
    T.eq(all[1].body, "abc", "body")
  end,

  ["malformed framing, versions and limits"] = function(): void
    local f = makeFixture({ maxBody = 4 })
    f.router:get("/", function(ctx: HttpContextApi): void ctx:text("ok") end)
    local cases: string[] = {
      "GET / HTTP/1.1\nHost: t\n\n",
      "GET / HTTP/1.1\r\n\r\n",
      "GET / HTTP/2.0\r\nHost: t\r\n\r\n",
      "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 9\r\n\r\n",
      "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
      "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
    }
    local expected: integer[] = { 400, 400, 505, 413, 400, 400 }
    for i: integer = 1, #cases do
      local conn = connect(f, "bad" .. tostring(i), cases[i], true)
      step(f)
      local responses = parseResponses(conn:takeOutput(), { "GET" })
      T.eq(#responses, 1, "one error response " .. tostring(i))
      T.eq(responses[1].status, expected[i], "status " .. tostring(i))
      T.eq(responses[1].headers["connection"], "close", "close " .. tostring(i))
      T.ok(#responses[1].body > 0, "error body " .. tostring(i))
    end
  end,

  ["backpressure queues output and the buffer cap closes"] = function(): void
    local f = makeFixture({ outBufferLimit = 1024 })
    f.router:get("/big", function(ctx: HttpContextApi): void
      ctx:text(string.rep("a", 600))
    end)
    local blocked = connect(
      f,
      "blocked",
      requestText("GET", "/big", {}, "") .. requestText("GET", "/big", {}, ""),
      true
    )
    blocked.blockWrites = true
    step(f)
    T.eq(blocked:takeOutput(), "", "nothing writable")
    T.eq(f.server:stats().requests, 2, "both requests parsed")
    T.ok(blocked.outputClosed, "buffer cap closed the connection")

    local g = makeFixture({ outBufferLimit = 1024 * 1024 })
    g.router:get("/x", function(ctx: HttpContextApi): void ctx:text("x") end)
    local conn = connect(g, "flush", requestText("GET", "/x", {}, ""), false)
    conn.blockWrites = true
    step(g)
    T.eq(conn:takeOutput(), "", "blocked before flush")
    conn.blockWrites = false
    step(g)
    local res = parseResponses(conn:takeOutput(), { "GET" })[1]
    T.eq(res.status, 200, "flushed after unblock")
    T.eq(res.body, "x", "flushed body")
    conn:closeInput()
    step(g)
  end,

  ["invalid server options fail fast"] = function(): void
    T.raises(function(): void
      makeFixture({ serverName = "bad\r\nX-Injected: 1" })
    end)
    T.raises(function(): void
      makeFixture({ maxConnections = 0 })
    end)
    T.raises(function(): void
      makeFixture({ outBufferLimit = 1 })
    end)
  end,

  ["max connections rejects with 503 and recovers"] = function(): void
    local f = makeFixture({ maxConnections = 1 })
    f.router:get("/x", function(ctx: HttpContextApi): void ctx:text("ok") end)
    local first = connect(f, "one", "", false)
    local second = connect(f, "two", requestText("GET", "/x", {}, ""), true)
    step(f)
    local rejected = parseResponses(second:takeOutput(), { "GET" })
    T.eq(#rejected, 1, "rejected response")
    T.eq(rejected[1].status, 503, "503")
    T.eq(rejected[1].headers["connection"], "close", "503 close")
    T.eq(first:takeOutput(), "", "first untouched")
    T.eq(f.server:stats().connections, 1, "rejected not counted")

    first:closeInput()
    step(f)
    local third = connect(f, "three", requestText("GET", "/x", {}, ""), true)
    step(f)
    local served = parseResponses(third:takeOutput(), { "GET" })
    T.eq(served[1].status, 200, "slot recovered")
    T.eq(f.server:stats().connections, 2, "two accepted")
  end,

  ["idle timeout closes keep-alive connections"] = function(): void
    local f = makeFixture({ idleTimeout = 2, requestTimeout = 10 })
    f.router:get("/x", function(ctx: HttpContextApi): void ctx:text("ok") end)
    local conn = connect(f, "idle", "", false)
    local transport: any = f.transport
    step(f)
    transport:advance(1)
    step(f)
    conn:feed(requestText("GET", "/x", {}, ""))
    step(f)
    local res = parseResponses(conn:takeOutput(), { "GET" })
    T.eq(res[1].status, 200, "alive before timeout")
    transport:advance(3)
    step(f)
    T.ok(conn.outputClosed, "socket closed")
    conn:feed(requestText("GET", "/x", {}, ""))
    step(f)
    T.eq(conn:takeOutput(), "", "no response after idle close")
  end,

  ["request timeout covers header-complete partials"] = function(): void
    local f = makeFixture({ idleTimeout = 10, requestTimeout = 2 })
    f.router:get("/x", function(ctx: HttpContextApi): void ctx:text("ok") end)
    local conn = connect(f, "slow", "GET /x HTTP/1.1\r\nHost: t\r\n", false)
    local transport: any = f.transport
    step(f)
    T.eq(conn:takeOutput(), "", "waiting for blank line")
    T.eq(f.server:stats().requests, 0, "not dispatched")
    transport:advance(3)
    step(f)
    local res = parseResponses(conn:takeOutput(), { "GET" })
    T.eq(#res, 1, "timeout response")
    T.eq(res[1].status, 408, "408")
    T.eq(res[1].headers["connection"], "close", "close")
  end,

  ["HEAD, OPTIONS and 405 through the server"] = function(): void
    local f = makeFixture({})
    f.router:get("/head", function(ctx: HttpContextApi): void ctx:text("hello") end)
    f.router:post("/post-only", function(ctx: HttpContextApi): void ctx:text("post") end)

    local headConn = connect(f, "head", requestText("HEAD", "/head", {}, ""), true)
    step(f)
    local head = parseResponses(headConn:takeOutput(), { "HEAD" })[1]
    T.eq(head.status, 200, "HEAD status")
    T.eq(head.headers["content-length"], "5", "HEAD length")
    T.eq(head.body, "", "HEAD body suppressed")

    local optionsConn = connect(f, "opt", requestText("OPTIONS", "/head", {}, ""), true)
    step(f)
    local options = parseResponses(optionsConn:takeOutput(), { "OPTIONS" })[1]
    T.eq(options.status, 204, "OPTIONS status")
    T.ok(options.headers["allow"] ~= nil, "OPTIONS allow")
    T.ok(string.find(options.headers["allow"]!, "GET", 1, true) ~= nil, "allow GET")

    local starConn = connect(f, "star", requestText("OPTIONS", "*", {}, ""), true)
    step(f)
    local star = parseResponses(starConn:takeOutput(), { "OPTIONS" })[1]
    T.eq(star.status, 204, "OPTIONS * status")
    T.ok(star.headers["allow"] ~= nil, "OPTIONS * allow")

    local deniedConn = connect(f, "deny", requestText("DELETE", "/post-only", {}, ""), true)
    step(f)
    local denied = parseResponses(deniedConn:takeOutput(), { "DELETE" })[1]
    T.eq(denied.status, 405, "405 status")
    T.ok(string.find(denied.headers["allow"]!, "POST", 1, true) ~= nil, "allow POST")
  end,

  ["max requests per connection is enforced"] = function(): void
    local f = makeFixture({ maxRequestsPerConnection = 2 })
    local n: integer = 0
    f.router:get("/n", function(ctx: HttpContextApi): void
      n = n + 1
      ctx:text(tostring(n))
    end)
    local wire: string = requestText("GET", "/n", {}, "")
      .. requestText("GET", "/n", {}, "")
      .. requestText("GET", "/n", {}, "")
    local conn = connect(f, "limit", wire, true)
    step(f)
    local responses = parseResponses(conn:takeOutput(), { "GET", "GET" })
    T.eq(#responses, 2, "only two responses")
    T.eq(responses[1].body, "1", "first")
    T.eq(responses[2].body, "2", "second")
    T.eq(responses[2].headers["connection"], "close", "last closes")
    T.eq(f.server:stats().requests, 2, "third ignored")
  end,

  ["handler failures become 500 without killing the connection"] = function(): void
    local f = makeFixture({})
    f.router:get("/bad", function(ctx: HttpContextApi): void
      error("application failure")
    end)
    f.router:get("/good", function(ctx: HttpContextApi): void ctx:text("good") end)
    local conn = connect(
      f,
      "err",
      requestText("GET", "/bad", {}, "") .. requestText("GET", "/good", {}, ""),
      true
    )
    step(f)
    local responses = parseResponses(conn:takeOutput(), { "GET", "GET" })
    T.eq(#responses, 2, "two responses")
    T.eq(responses[1].status, 500, "error status")
    T.eq(responses[1].body, "Internal Server Error\n", "error body")
    T.eq(responses[2].status, 200, "next request")
    T.eq(responses[2].body, "good", "next body")
  end,

  ["content length tampering is corrected"] = function(): void
    local f = makeFixture({})
    f.router:get("/tamper", function(ctx: HttpContextApi): void
      ctx.res.headers:set("Content-Length", "999")
      ctx.res.headers:set("Transfer-Encoding", "chunked")
      ctx:text("safe")
    end)
    local conn = connect(f, "tamper", requestText("GET", "/tamper", {}, ""), true)
    step(f)
    local raw: string = conn:takeOutput()
    local res = parseResponses(raw, { "GET" })[1]
    T.eq(res.status, 200, "status")
    T.eq(res.body, "safe", "body")
    T.eq(res.headers["content-length"], "4", "length recomputed")
    T.eq(res.headers["transfer-encoding"], nil, "TE removed")
    T.eq(literal.find(raw, "999", 1), nil, "old value gone")
  end,
}
