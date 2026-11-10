import T from "tlua_test"
import http from "../lib/http"
import h2 from "../lib/http_h2_connection"
import h2f from "../lib/http_h2_frame"
import hpack from "../lib/http_hpack"
import multipart from "../lib/http_multipart"

type Sink = {
  text: string,
}

local function requestHeaders(fields: any[]): string
  return hpack.encodeHeaders(fields)
end

local function fixture(streaming: boolean): any
  local router = http.HttpRouter.new()
  router:get("/get", function(ctx: HttpContextApi): void
    ctx:text("h2 get")
  end)
  router:post("/echo", function(ctx: HttpContextApi): void
    ctx:text(ctx.req.body)
  end)
  router:get("/big", function(ctx: HttpContextApi): void
    ctx:text(string.rep("x", 70000))
  end)
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
  local conn = http.MemoryConnection.new("h2test", "", "203.0.113.50:4444")
  local sink: Sink = { text = "" }
  local stats: ServerStats = {
    connections = 1, requests = 0, responses = 0, bytesIn = 0, bytesOut = 0,
  }
  local server = h2.H2Connection.new(
    conn,
    router,
    {
      maxBody = 200000,
      maxConnections = 10,
      maxRequestsPerConnection = 100,
      idleTimeout = 30,
      requestTimeout = 10,
      outBufferLimit = 1000000,
      serverName = "h2-test",
    },
    stats,
    function(wire: string): void sink.text = sink.text .. wire end
  )
  return { connection = server, sink = sink, stats = stats, router = router }
end

local function feed(f: any, wire: string): void
  f.connection:feed(wire)
end

local function clientSettings(): string
  return h2f.encodeFrame(h2f.FRAME_SETTINGS, 0, 0, "")
end

local function headersFrame(fields: any[], endStream: boolean): string
  local block = requestHeaders(fields)
  local flags: integer = h2f.FLAG_END_HEADERS
  if endStream then flags = math.floor(flags + h2f.FLAG_END_STREAM) end
  return h2f.encodeFrame(h2f.FRAME_HEADERS, flags, 1, block)
end

local function responseFrames(f: any): any[]
  local parser = h2f.H2FrameParser.new(16777215)
  parser:feed(f.sink.text)
  local frames: any[] = {}
  while true do
    local read: any = parser:next()
    if read.needMore then break end
    if #read.err > 0 then error(read.err) end
    frames[#frames + 1] = read.frame
  end
  return frames
end

local function responseHeaders(f: any): any[]
  local frames = responseFrames(f)
  local blocks: string[] = {}
  local inHeaders = false
  for i: integer = 1, #frames do
    local frame = frames[i]
    if frame.frameType == h2f.FRAME_HEADERS then
      blocks = { frame.payload }
      inHeaders = math.floor(frame.flags / h2f.FLAG_END_HEADERS) % 2 == 0
    elseif frame.frameType == h2f.FRAME_CONTINUATION and inHeaders then
      blocks[#blocks + 1] = frame.payload
      if math.floor(frame.flags / h2f.FLAG_END_HEADERS) % 2 == 1 then
        inHeaders = false
      end
    elseif inHeaders then
      error("unexpected frame during response headers")
    end
    if #blocks > 0 and not inHeaders then
      local decoder = hpack.HpackDecoder.new()
      local decoded = decoder:decode(table.concat(blocks))
      if decoded.error ~= "" then error(decoded.error) end
      return decoded.headers!
    end
  end
  return {}
end

local function responseBody(f: any): string
  local frames = responseFrames(f)
  local parts: string[] = {}
  for i: integer = 1, #frames do
    if frames[i].frameType == h2f.FRAME_DATA then
      parts[#parts + 1] = frames[i].payload
    end
  end
  return table.concat(parts)
end

local function start(f: any): void
  feed(f, h2.PREFACE .. clientSettings())
end

return {
  ["GET response over HTTP/2 frames"] = function(): void
    local f = fixture(false)
    start(f)
    feed(f, headersFrame({
      { name = ":method", value = "GET" },
      { name = ":scheme", value = "http" },
      { name = ":authority", value = "example.test" },
      { name = ":path", value = "/get?x=1" },
    }, true))
    local headers = responseHeaders(f)
    T.eq(headers[1].name, ":status", "status name")
    T.eq(headers[1].value, "200", "status 200")
    T.eq(responseBody(f), "h2 get", "body")
    T.eq(f.stats.requests, 1, "request count")
    T.eq(f.stats.responses, 1, "response count")
  end,

  ["POST body and streaming route"] = function(): void
    local f = fixture(false)
    start(f)
    local postHeaders = requestHeaders({
      { name = ":method", value = "POST" },
      { name = ":scheme", value = "http" },
      { name = ":authority", value = "example.test" },
      { name = ":path", value = "/echo" },
      { name = "content-type", value = "text/plain" },
      { name = "content-length", value = "5" },
    })
    feed(f, h2f.encodeFrame(h2f.FRAME_HEADERS, h2f.FLAG_END_HEADERS, 1, postHeaders))
    feed(f, h2f.encodeFrame(h2f.FRAME_DATA, 0, 1, "hello"))
    T.eq(responseBody(f), "", "not complete yet")
    feed(f, h2f.encodeFrame(h2f.FRAME_DATA, h2f.FLAG_END_STREAM, 1, ""))
    T.eq(responseHeaders(f)[1].value, "200", "post status")
    T.eq(responseBody(f), "hello", "post body")

    local g = fixture(true)
    start(g)
    local sh = requestHeaders({
      { name = ":method", value = "POST" },
      { name = ":scheme", value = "http" },
      { name = ":authority", value = "example.test" },
      { name = ":path", value = "/stream" },
    })
    feed(g, h2f.encodeFrame(h2f.FRAME_HEADERS, h2f.FLAG_END_HEADERS, 1, sh))
    feed(g, h2f.encodeFrame(h2f.FRAME_DATA, 0, 1, "abc"))
    feed(g, h2f.encodeFrame(h2f.FRAME_DATA, h2f.FLAG_END_STREAM, 1, "de"))
    T.eq(responseHeaders(g)[1].value, "200", "stream status")
    T.eq(responseBody(g), "5:2", "stream body result")
  end,

  ["streaming handler may answer before END_STREAM"] = function(): void
    local f = fixture(true)
    f.router:stream("POST", "/early", function(ctx: HttpContextApi): void
      ctx:text("early h2")
    end)
    start(f)
    local sh = requestHeaders({
      { name = ":method", value = "POST" },
      { name = ":scheme", value = "http" },
      { name = ":authority", value = "example.test" },
      { name = ":path", value = "/early" },
    })
    feed(f, h2f.encodeFrame(h2f.FRAME_HEADERS, h2f.FLAG_END_HEADERS, 1, sh))
    T.eq(responseHeaders(f)[1].value, "200", "status")
    T.eq(responseBody(f), "early h2", "early body")
    local frames = responseFrames(f)
    local reset: boolean = false
    for i: integer = 1, #frames do
      if frames[i].frameType == h2f.FRAME_RST_STREAM then reset = true end
    end
    T.ok(reset, "unfinished upload is reset")
  end,

  ["HTTP/2 streaming multipart upload"] = function(): void
    local f = fixture(true)
    local boundary: string = "----h2multipart"
    f.router:stream("POST", "/form", function(ctx: HttpContextApi): void
      local reader = ctx:multipart({ maxPartBytes = 10000 })
      local name: string = ""
      local value: string = ""
      while true do
        local part = reader:nextPart()
        if part == nil then break end
        local meta = part:meta()
        name = meta.name
        value = part:readAll()
      end
      ctx:send(name .. "=" .. value, "text/plain")
    end)
    start(f)
    local body: string = "--" .. boundary .. "\r\n"
      .. "Content-Disposition: form-data; name=\"field\"\r\n"
      .. "\r\n"
      .. "h2 value\r\n"
      .. "--" .. boundary .. "--\r\n"
    local headers = requestHeaders({
      { name = ":method", value = "POST" },
      { name = ":scheme", value = "http" },
      { name = ":authority", value = "example.test" },
      { name = ":path", value = "/form" },
      { name = "content-type", value = "multipart/form-data; boundary=" .. boundary },
      { name = "content-length", value = tostring(#body) },
    })
    feed(f, h2f.encodeFrame(h2f.FRAME_HEADERS, h2f.FLAG_END_HEADERS, 1, headers))
    local cut: integer = math.floor(#body / 2)
    feed(f, h2f.encodeFrame(h2f.FRAME_DATA, 0, 1, string.sub(body, 1, cut)))
    feed(f, h2f.encodeFrame(h2f.FRAME_DATA, h2f.FLAG_END_STREAM, 1, string.sub(body, cut + 1)))
    T.eq(responseHeaders(f)[1].value, "200", "status")
    T.eq(responseBody(f), "field=h2 value", "multipart result")
  end,

  ["content-length mismatch and invalid stream ids"] = function(): void
    local f = fixture(false)
    start(f)
    local ph = requestHeaders({
      { name = ":method", value = "POST" },
      { name = ":scheme", value = "http" },
      { name = ":authority", value = "example.test" },
      { name = ":path", value = "/echo" },
      { name = "content-length", value = "5" },
    })
    feed(f, h2f.encodeFrame(h2f.FRAME_HEADERS, h2f.FLAG_END_HEADERS, 1, ph))
    feed(f, h2f.encodeFrame(h2f.FRAME_DATA, h2f.FLAG_END_STREAM, 1, "abc"))
    T.eq(responseHeaders(f)[1].value, "400", "length mismatch status")

    local g = fixture(false)
    start(g)
    local block = requestHeaders({
      { name = ":method", value = "GET" },
      { name = ":scheme", value = "http" },
      { name = ":authority", value = "example.test" },
      { name = ":path", value = "/get" },
    })
    feed(g, h2f.encodeFrame(
      h2f.FRAME_HEADERS,
      h2f.FLAG_END_HEADERS + h2f.FLAG_END_STREAM,
      2,
      block
    ))
    local frames = responseFrames(g)
    local goaway: boolean = false
    for i: integer = 1, #frames do
      if frames[i].frameType == h2f.FRAME_GOAWAY then goaway = true end
    end
    T.ok(goaway, "even stream id gets GOAWAY")
  end,

  ["CONTINUATION, PING and SETTINGS ACK"] = function(): void
    local f = fixture(false)
    start(f)
    local block = requestHeaders({
      { name = ":method", value = "GET" },
      { name = ":scheme", value = "http" },
      { name = ":authority", value = "example.test" },
      { name = ":path", value = "/get" },
    })
    local cut: integer = math.floor(#block / 2)
    feed(f, h2f.encodeFrame(
      h2f.FRAME_HEADERS,
      h2f.FLAG_END_STREAM,
      1,
      string.sub(block, 1, cut)
    ))
    feed(f, h2f.encodeFrame(
      h2f.FRAME_CONTINUATION,
      h2f.FLAG_END_HEADERS,
      1,
      string.sub(block, cut + 1)
    ))
    T.eq(responseBody(f), "h2 get", "continuation body")
    feed(f, h2f.encodeFrame(h2f.FRAME_PING, 0, 0, "12345678"))
    local sawPingAck: boolean = false
    local frames = responseFrames(f)
    for i: integer = 1, #frames do
      if frames[i].frameType == h2f.FRAME_PING and frames[i].flags % 2 == 1 then
        sawPingAck = true
        T.eq(frames[i].payload, "12345678", "ping payload")
      end
    end
    T.ok(sawPingAck, "ping ack")
    local sawSettingsAck: boolean = false
    for i: integer = 1, #frames do
      if frames[i].frameType == h2f.FRAME_SETTINGS and frames[i].flags % 2 == 1 then
        sawSettingsAck = true
      end
    end
    T.ok(sawSettingsAck, "settings ack")
  end,

  ["large response headers use CONTINUATION"] = function(): void
    local f = fixture(false)
    f.router:get("/headers", function(ctx: HttpContextApi): void
      ctx:set("X-Big", string.rep("a", 20000))
      ctx:text("ok")
    end)
    start(f)
    feed(f, headersFrame({
      { name = ":method", value = "GET" },
      { name = ":scheme", value = "http" },
      { name = ":authority", value = "example.test" },
      { name = ":path", value = "/headers" },
    }, true))
    local headers = responseHeaders(f)
    local found: boolean = false
    for i: integer = 1, #headers do
      if headers[i].name == "x-big" then
        found = true
        T.eq(#headers[i].value, 20000, "big header length")
      end
    end
    T.ok(found, "big header present")
    T.eq(responseBody(f), "ok", "body")
  end,

  ["response flow control resumes on WINDOW_UPDATE"] = function(): void
    local f = fixture(false)
    start(f)
    feed(f, headersFrame({
      { name = ":method", value = "GET" },
      { name = ":scheme", value = "http" },
      { name = ":authority", value = "example.test" },
      { name = ":path", value = "/big" },
    }, true))
    local frames = responseFrames(f)
    local sent: integer = 0
    for i: integer = 1, #frames do
      if frames[i].frameType == h2f.FRAME_DATA then sent = sent + #frames[i].payload end
    end
    T.ok(sent <= 65535, "initial window respects flow control")
    feed(f, h2f.encodeFrame(
      h2f.FRAME_WINDOW_UPDATE,
      0,
      0,
      h2f.windowUpdatePayload(65535)
    ))
    feed(f, h2f.encodeFrame(
      h2f.FRAME_WINDOW_UPDATE,
      0,
      1,
      h2f.windowUpdatePayload(65535)
    ))
    T.eq(#responseBody(f), 70000, "all data after window update")
  end,

  ["protocol errors and reset"] = function(): void
    local f = fixture(false)
    f.connection:feed("NOT HTTP/2")
    local frames = responseFrames(f)
    local sawGoaway: boolean = false
    for i: integer = 1, #frames do
      if frames[i].frameType == h2f.FRAME_GOAWAY then sawGoaway = true end
    end
    T.ok(sawGoaway, "bad preface gets GOAWAY")
    T.ok(f.connection:isClosed(), "connection closed")

    local g = fixture(false)
    start(g)
    local bad = requestHeaders({
      { name = ":method", value = "GET" },
      { name = ":scheme", value = "http" },
      { name = ":authority", value = "example.test" },
      { name = ":path", value = "/get" },
      { name = "connection", value = "close" },
    })
    feed(g, h2f.encodeFrame(h2f.FRAME_HEADERS, h2f.FLAG_END_HEADERS + h2f.FLAG_END_STREAM, 1, bad))
    local frames2 = responseFrames(g)
    local sawRst: boolean = false
    for i: integer = 1, #frames2 do
      if frames2[i].frameType == h2f.FRAME_RST_STREAM then sawRst = true end
    end
    T.ok(sawRst, "connection-specific header resets stream")
  end,
}
