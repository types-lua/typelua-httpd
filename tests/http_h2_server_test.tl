import T from "tlua_test"
import http from "../lib/http"
import h2 from "../lib/http_h2_connection"
import h2f from "../lib/http_h2_frame"
import hpack from "../lib/http_hpack"

local function headersBlock(fields: any[]): string
  return hpack.encodeHeaders(fields)
end

local function connectionWire(streams: any[]): string
  local parts: string[] = { h2.PREFACE, h2f.encodeFrame(h2f.FRAME_SETTINGS, 0, 0, "") }
  for i: integer = 1, #streams do
    local s = streams[i]
    local flags: integer = h2f.FLAG_END_HEADERS
    if s.endStream then flags = math.floor(flags + h2f.FLAG_END_STREAM) end
    parts[#parts + 1] = h2f.encodeFrame(h2f.FRAME_HEADERS, flags, s.id, headersBlock(s.headers))
    if s.body ~= nil and #s.body > 0 then
      parts[#parts + 1] = h2f.encodeFrame(
        h2f.FRAME_DATA,
        h2f.FLAG_END_STREAM,
        s.id,
        s.body!
      )
    end
  end
  return table.concat(parts)
end

local function fixture(options: ServerOptions): any
  local router = http.HttpRouter.new()
  router:get("/h2", function(ctx: HttpContextApi): void ctx:text("h2 server") end)
  router:post("/echo", function(ctx: HttpContextApi): void ctx:text(ctx.req.body) end)
  router:get("/a", function(ctx: HttpContextApi): void ctx:text("A") end)
  router:get("/b", function(ctx: HttpContextApi): void ctx:text("B") end)
  local transport = http.MemoryTransport.new("127.0.0.1", 0)
  local server = http.HttpServer.new(router, transport, options)
  server:listen("127.0.0.1", 0)
  return { server = server, router = router, transport = transport }
end

local function exchange(f: any, name: string, wire: string): string
  local conn = http.MemoryConnection.new(name, wire, "203.0.113.60:5555")
  conn:closeInput()
  f.transport.listener:push(conn)
  f.server:step(0)
  return conn:takeOutput()
end

local function framesOf(wire: string): any[]
  local parser = h2f.H2FrameParser.new(16777215)
  parser:feed(wire)
  local frames: any[] = {}
  while true do
    local read: any = parser:next()
    if read.needMore then break end
    if #read.err > 0 then error(read.err) end
    frames[#frames + 1] = read.frame
  end
  return frames
end

local function responseFor(frames: any[], streamId: integer): any
  local block: string[] = {}
  local body: string[] = {}
  local headersDone: boolean = false
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
  local result: any = { headers = {}, body = table.concat(body) }
  if decoded ~= nil then
    for i: integer = 1, #decoded.headers do
      local h = decoded.headers[i]
      result.headers[h.name] = h.value
      if h.name == ":status" then status = h.value end
    end
  end
  result.status = tonumber(status) as integer
  return result
end

return {
  ["memory h2c GET and POST"] = function(): void
    local f = fixture({})
    local wire = connectionWire({
      {
        id = 1,
        endStream = true,
        headers = {
          { name = ":method", value = "GET" },
          { name = ":scheme", value = "http" },
          { name = ":authority", value = "example.test" },
          { name = ":path", value = "/h2" },
        },
      },
      {
        id = 3,
        body = "over h2",
        headers = {
          { name = ":method", value = "POST" },
          { name = ":scheme", value = "http" },
          { name = ":authority", value = "example.test" },
          { name = ":path", value = "/echo" },
          { name = "content-length", value = "7" },
        },
      },
    })
    local output = exchange(f, "h2c", wire)
    local frames = framesOf(output)
    local first = responseFor(frames, 1)
    T.eq(first.status, 200, "get status")
    T.eq(first.headers["content-type"], "text/plain; charset=utf-8", "get type")
    T.eq(first.body, "h2 server", "get body")
    local second = responseFor(frames, 3)
    T.eq(second.status, 200, "post status")
    T.eq(second.body, "over h2", "post body")
    local stats = f.server:stats()
    T.eq(stats.requests, 2, "requests")
    T.eq(stats.responses, 2, "responses")
  end,

  ["h2c can be disabled for HTTP/1.1 parsing"] = function(): void
    local f = fixture({ h2c = false })
    local wire: string = h2.PREFACE .. h2f.encodeFrame(h2f.FRAME_SETTINGS, 0, 0, "")
    local output = exchange(f, "noh2c", wire)
    T.ok(string.find(output, "HTTP/1.1 505 HTTP Version Not Supported", 1, true) ~= nil, "505")
  end,

  ["HTTP/1.1 still works on the same server"] = function(): void
    local f = fixture({})
    local conn = http.MemoryConnection.new(
      "h1",
      "GET /a HTTP/1.1\r\nHost: t\r\n\r\n",
      "203.0.113.61:5555"
    )
    conn:closeInput()
    f.transport.listener:push(conn)
    f.server:step(0)
    local output = conn:takeOutput()
    T.ok(string.find(output, "HTTP/1.1 200 OK", 1, true) ~= nil, "h1 status")
    T.ok(string.find(output, "A", 1, true) ~= nil, "h1 body")
  end,
}
