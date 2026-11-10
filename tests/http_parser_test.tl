import T from "tlua_test"
import http from "../lib/http"

local function parser(opts: ParserOptions): HttpRequestParserApi
  return http.HttpRequestParser.new(opts)
end

local function one(wire: string, opts: ParserOptions): HttpRequestApi
  local p = parser(opts)
  p:feed(wire)
  local outcome: ParseOutcome = p:next()
  if outcome.request == nil then
    local message: string = "no request"
    if outcome.error ~= nil then
      message = outcome.error!.message
    end
    error(message)
  end
  return outcome.request!
end

local function oneError(wire: string, opts: ParserOptions): HttpError
  local p = parser(opts)
  p:feed(wire)
  local outcome: ParseOutcome = p:next()
  if outcome.error == nil then
    error("expected parse error")
  end
  return outcome.error!
end

local GET: string = "GET /hello?x=1&y=two HTTP/1.1\r\nHost: example.com\r\n\r\n"

return {
  ["simple GET"] = function(): void
    local req: HttpRequestApi = one(GET, {})
    T.eq(req.method, "GET", "method")
    T.eq(req.target, "/hello?x=1&y=two", "target")
    T.eq(req.path, "/hello", "path")
    T.eq(req.rawQuery, "x=1&y=two", "raw query")
    T.eq(req.query["x"], "1", "query x")
    T.eq(req.query["y"], "two", "query y")
    T.eq(req.version, "1.1", "version")
    T.eq(req.headers:get("host"), "example.com", "host")
    T.eq(req.body, "", "body")
    T.ok(req.keepAlive, "1.1 keep-alive");
  end,

  ["byte-by-byte incremental parse"] = function(): void
    local p = parser({})
    local got: HttpRequestApi | nil = nil
    for i: integer = 1, #GET do
      p:feed(string.sub(GET, i, i))
      local outcome: ParseOutcome = p:next()
      if outcome.request ~= nil then
        got = outcome.request!
        break
      end
    end
    T.ok(got ~= nil, "parsed")
    T.eq(got!.path, "/hello", "path")
    T.eq(p:buffered(), 0, "buffer drained")
  end,

  ["content-length body is binary safe"] = function(): void
    local body: string = "a\0b\r\nc"
    local wire: string = "POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: "
      .. tostring(#body) .. "\r\n\r\n" .. body
    local req: HttpRequestApi = one(wire, {})
    T.eqBytes(req.body, body, "body")
    T.eq(req.method, "POST", "method")
  end,

  ["partial body returns needMore then completes"] = function(): void
    local p = parser({})
    p:feed("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\nab")
    local first: ParseOutcome = p:next()
    T.ok(first.needMore, "need more")
    p:feed("cd")
    local second: ParseOutcome = p:next()
    T.ok(second.request ~= nil, "complete")
    T.eq(second.request!.body, "abcd", "body")
  end,

  ["chunked body with extension and trailer"] = function(): void
    local wire: string = "POST /x HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"
      .. "4;foo=bar\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trailer: yes\r\n\r\n"
    local req: HttpRequestApi = one(wire, {})
    T.eq(req.body, "Wikipedia", "body")
  end,

  ["chunked byte-by-byte"] = function(): void
    local wire: string = "POST /x HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"
      .. "1\r\na\r\n1\r\nb\r\n0\r\n\r\n"
    local p = parser({})
    local got: HttpRequestApi | nil = nil
    for i: integer = 1, #wire do
      p:feed(string.sub(wire, i, i))
      local outcome: ParseOutcome = p:next()
      if outcome.request ~= nil then
        got = outcome.request!
        break
      end
    end
    T.ok(got ~= nil, "parsed")
    T.eq(got!.body, "ab", "body")
  end,

  ["pipelined requests parse in order"] = function(): void
    local p = parser({})
    p:feed(GET .. GET)
    local a: ParseOutcome = p:next()
    local b: ParseOutcome = p:next()
    T.ok(a.request ~= nil, "first")
    T.ok(b.request ~= nil, "second")
    T.eq(a.request!.path, "/hello", "first path")
    T.eq(b.request!.path, "/hello", "second path")
    T.eq(p:buffered(), 0, "drained")
  end,

  ["http 1.0 keep-alive semantics"] = function(): void
    local closeReq: HttpRequestApi = one(
      "GET / HTTP/1.0\r\n\r\n",
      {}
    )
    T.ok(not closeReq.keepAlive, "1.0 closes by default")
    local keepReq: HttpRequestApi = one(
      "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
      {}
    )
    T.ok(keepReq.keepAlive, "1.0 keep-alive")
    local close11: HttpRequestApi = one(
      "GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n",
      {}
    )
    T.ok(not close11.keepAlive, "1.1 close")
  end,

  ["absolute-form target and query"] = function(): void
    local req: HttpRequestApi = one(
      "GET http://example.com/a/b?q=1 HTTP/1.1\r\nHost: example.com\r\n\r\n",
      {}
    )
    T.eq(req.path, "/a/b", "path")
    T.eq(req.query["q"], "1", "query")
  end,

  ["expect 100-continue is signalled once"] = function(): void
    local p = parser({})
    p:feed("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
    local first: ParseOutcome = p:next()
    T.ok(first.expectContinue, "continue")
    p:feed("abc")
    local second: ParseOutcome = p:next()
    T.ok(second.request ~= nil, "request")
    T.eq(second.request!.body, "abc", "body")
  end,

  ["framing errors"] = function(): void
    T.eq(oneError("GET / HTTP/1.1\r\n\r\n", {}).status, 400, "missing host")
    T.eq(oneError("GET / HTTP/1.1\r\nHost: h\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n", {}).status, 400, "CL+TE")
    T.eq(oneError("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n", {}).status, 400, "duplicate CL")
    T.eq(oneError("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: +1\r\n\r\n", {}).status, 400, "signed CL")
    T.eq(oneError("GET / HTTP/1.1\r\nHost: h\r\n X: folded\r\n\r\n", {}).status, 400, "obs-fold")
    T.eq(oneError("GET / HTTP/1.1\nHost: h\n\n", {}).status, 400, "bare LF")
    T.eq(oneError("GET / HTTP/2.0\r\nHost: h\r\n\r\n", {}).status, 505, "version")
    T.eq(oneError("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip\r\n\r\n", {}).status, 400, "TE")
    T.eq(oneError("GET / HTTP/1.1\r\nHost: h\r\nExpect: nope\r\n\r\n", {}).status, 417, "expect")
    T.eq(oneError("GET * HTTP/1.1\r\nHost: h\r\n\r\n", {}).status, 400, "asterisk")
    T.eq(oneError("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\n", { maxBody = 4 }).status, 413, "body limit")
    T.eq(oneError("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", {}).status, 400, "chunk size")
    T.eq(oneError("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nabcde\r\n0\r\n\r\n", { maxBody = 4 }).status, 413, "chunk body limit")
  end,

  ["header and line limits"] = function(): void
    local many: string[] = {}
    for i: integer = 1, 5 do
      many[#many + 1] = "X-" .. tostring(i) .. ": v\r\n"
    end
    local wire: string = "GET / HTTP/1.1\r\nHost: h\r\n" .. table.concat(many) .. "\r\n"
    T.eq(oneError(wire, { maxHeaders = 3 }).status, 431, "header count")
    local longLine: string = "GET /" .. string.rep("a", 100) .. " HTTP/1.1\r\nHost: h\r\n\r\n"
    T.eq(oneError(longLine, { maxRequestLine = 32 }).status, 414, "request line")
    T.eq(oneError(wire, { maxHeaderBytes = 20 }).status, 431, "header bytes")
  end,

  ["requestActive follows the parser state"] = function(): void
    local p = parser({})
    T.ok(not p:requestActive(), "idle")
    p:feed("GET / HTTP/1.1\r\nHost: h\r\n")
    local outcome: ParseOutcome = p:next()
    T.ok(outcome.needMore, "waiting for blank line")
    T.ok(p:requestActive(), "header-complete partial is active")
    p:feed("\r\n")
    local done: ParseOutcome = p:next()
    T.ok(done.request ~= nil, "complete")
    T.ok(not p:requestActive(), "reset after complete")
  end,

  ["every split point of a pipelined chunked stream"] = function(): void
    local chunked: string = "POST /x HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"
      .. "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"
    local wire: string = GET .. chunked .. GET
    for cut: integer = 0, #wire do
      local p = parser({})
      if cut > 0 then p:feed(string.sub(wire, 1, cut)) end
      if cut < #wire then p:feed(string.sub(wire, cut + 1)) end
      local seen: HttpRequestApi[] = {}
      while true do
        local outcome: ParseOutcome = p:next()
        if outcome.request ~= nil then
          seen[#seen + 1] = outcome.request!
        elseif outcome.error ~= nil then
          error("split " .. tostring(cut) .. ": " .. outcome.error!.message)
        else
          break
        end
      end
      T.eq(#seen, 3, "requests at split " .. tostring(cut))
      T.eq(seen[1].path, "/hello", "first at split " .. tostring(cut))
      T.eq(seen[2].body, "abcde", "chunked at split " .. tostring(cut))
      T.eq(seen[3].path, "/hello", "third at split " .. tostring(cut))
    end
  end,

  ["multiple identical content-length is accepted"] = function(): void
    local req: HttpRequestApi = one(
      "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nok",
      {}
    )
    T.eq(req.body, "ok", "body")
  end,

  ["chunked zero body"] = function(): void
    local req: HttpRequestApi = one(
      "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
      {}
    )
    T.eq(req.body, "", "empty")
  end,
}
