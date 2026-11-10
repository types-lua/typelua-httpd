import T from "tlua_test"
import http from "../lib/http"

local function opts(method: string, version: string, keep: boolean): SerializeOptions
  return {
    serverName = "test-server",
    keepAlive = keep,
    requestMethod = method,
    version = version,
  }
end

local function hasLine(wire: string, line: string): boolean
  return string.find(wire, line .. "\r\n", 1, true) ~= nil
end

return {
  ["basic response framing"] = function(): void
    local res = http.HttpResponse.new(200)
    res.headers:set("Content-Type", "text/plain")
    res.body = "hello"
    local wire: string = http.serialize(res, opts("GET", "1.1", true))
    T.ok(string.sub(wire, 1, 17) == "HTTP/1.1 200 OK\r\n", "status line")
    T.ok(hasLine(wire, "Content-Type: text/plain"), "content type")
    T.ok(hasLine(wire, "Content-Length: 5"), "length")
    T.ok(hasLine(wire, "Server: test-server"), "server")
    T.ok(string.find(wire, "Date: ", 1, true) ~= nil, "date")
    T.ok(string.sub(wire, -5) == "hello", "body")
    T.ok(string.find(wire, "Connection:", 1, true) == nil, "1.1 keep-alive has no connection header")
  end,

  ["HEAD keeps length but omits body"] = function(): void
    local res = http.HttpResponse.new(200)
    res.body = "hello"
    local wire: string = http.serialize(res, opts("HEAD", "1.1", true))
    T.ok(hasLine(wire, "Content-Length: 5"), "length")
    T.ok(string.find(wire, "hello", 1, true) == nil, "no body")
  end,

  ["204 and 304 are bodyless"] = function(): void
    local a = http.HttpResponse.new(204)
    a.body = "should vanish"
    local wireA: string = http.serialize(a, opts("GET", "1.1", false))
    T.ok(string.find(wireA, "Content-Length:", 1, true) == nil, "204 no length")
    T.ok(string.find(wireA, "should vanish", 1, true) == nil, "204 no body")
    T.ok(hasLine(wireA, "Connection: close"), "204 close")
    local b = http.HttpResponse.new(304)
    b.body = "also vanish"
    local wireB: string = http.serialize(b, opts("GET", "1.1", true))
    T.ok(string.find(wireB, "Content-Length:", 1, true) == nil, "304 no length")
    T.ok(string.find(wireB, "also vanish", 1, true) == nil, "304 no body")
  end,

  ["duplicate headers survive serialization"] = function(): void
    local res = http.HttpResponse.new(200)
    res.headers:add("Set-Cookie", "a=1")
    res.headers:add("Set-Cookie", "b=2")
    res.body = "ok"
    local out: string = http.serialize(res, opts("GET", "1.1", true))
    local first: integer | nil = string.find(out, "Set-Cookie: a=1\r\n", 1, true)
    local second: integer | nil = string.find(out, "Set-Cookie: b=2\r\n", 1, true)
    T.ok(first ~= nil, "first cookie")
    T.ok(second ~= nil, "second cookie")
  end,

  ["205 resets content explicitly"] = function(): void
    local res = http.HttpResponse.new(205)
    res.body = "must vanish"
    local wire: string = http.serialize(res, opts("GET", "1.1", true))
    T.ok(hasLine(wire, "Content-Length: 0"), "zero length")
    T.ok(string.find(wire, "must vanish", 1, true) == nil, "no body")
  end,

  ["content-length is recomputed"] = function(): void
    local res = http.HttpResponse.new(200)
    res.headers:set("Content-Length", "999")
    res.headers:set("Transfer-Encoding", "chunked")
    res.body = "abc"
    local wire: string = http.serialize(res, opts("GET", "1.1", false))
    T.ok(hasLine(wire, "Content-Length: 3"), "length")
    T.ok(string.find(wire, "Transfer-Encoding", 1, true) == nil, "TE removed")
    T.ok(string.find(wire, "999", 1, true) == nil, "old length gone")
  end,

  ["connection headers for HTTP/1.0"] = function(): void
    local res = http.HttpResponse.new(200)
    local keepWire: string = http.serialize(res, opts("GET", "1.0", true))
    T.ok(hasLine(keepWire, "Connection: keep-alive"), "1.0 keep")
    local closeWire: string = http.serialize(res, opts("GET", "1.0", false))
    T.ok(hasLine(closeWire, "Connection: close"), "1.0 close")
  end,

  ["invalid status and injected headers fail"] = function(): void
    T.raises(function(): void http.HttpResponse.new(42) end)
    local res = http.HttpResponse.new(200)
    T.raises(function(): void res.headers:set("X", "a\r\nb") end)
    res.body = "ok"
    T.raises(function(): void http.serialize(res, opts("GET", "9.9", true)) end)
  end,

  ["error response is text and closes"] = function(): void
    local wire: string = http.errorResponse(400, "bad", opts("GET", "1.1", true))
    T.ok(string.sub(wire, 1, 26) == "HTTP/1.1 400 Bad Request\r\n", "status")
    T.ok(hasLine(wire, "Connection: close"), "close")
    T.ok(string.find(wire, "bad", 1, true) ~= nil, "message")
  end,
}
