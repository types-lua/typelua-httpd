import T from "tlua_test"
import http from "../lib/http"

local BOUNDARY: string = "----multipartServerBoundary"

local function body(): string
  return "--" .. BOUNDARY .. "\r\n"
    .. "Content-Disposition: form-data; name=\"title\"\r\n"
    .. "\r\n"
    .. "hello multipart\r\n"
    .. "--" .. BOUNDARY .. "\r\n"
    .. "Content-Disposition: form-data; name=\"file\"; filename=\"data.bin\"\r\n"
    .. "Content-Type: application/octet-stream\r\n"
    .. "\r\n"
    .. string.rep("x", 30000) .. "\r\n"
    .. "--" .. BOUNDARY .. "--\r\n"
end

local function fixture(streaming: boolean): any
  local router = http.HttpRouter.new()
  local transport = http.MemoryTransport.new("127.0.0.1", 0)
  local server = http.HttpServer.new(router, transport, { maxBody = 200000 })
  server:listen("127.0.0.1", 0)
  local handler = function(ctx: HttpContextApi): void
    local reader = ctx:multipart({ maxPartBytes = 100000 })
    local title: string = ""
    local filename: string = ""
    local file: string = ""
    while true do
      local part = reader:nextPart()
      if part == nil then break end
      local meta = part:meta()
      local value: string = part:readAll()
      if meta.name == "title" then
        title = value
      elseif meta.name == "file" then
        filename = meta.filename!
        file = value
      end
    end
    ctx:send(title .. "|" .. filename .. "|" .. tostring(#file), "text/plain")
  end
  if streaming then
    router:stream("POST", "/form", handler)
  else
    router:post("/form", handler)
  end
  return { server = server, router = router, transport = transport }
end

local function connect(f: any, name: string, data: string, closed: boolean): any
  local conn = http.MemoryConnection.new(name, data, "198.51.100.7:9999")
  if closed then conn:closeInput() end
  f.transport.listener:push(conn)
  return conn
end

local function request(data: string): string
  return "POST /form HTTP/1.1\r\nHost: t\r\n"
    .. "Content-Type: multipart/form-data; boundary=" .. BOUNDARY .. "\r\n"
    .. "Content-Length: " .. tostring(#data) .. "\r\n\r\n" .. data
end

return {
  ["buffered multipart route"] = function(): void
    local f = fixture(false)
    local conn = connect(f, "buffered", request(body()), true)
    f.server:step(0)
    local wire: string = conn:takeOutput()
    T.ok(string.find(wire, "HTTP/1.1 200 OK", 1, true) ~= nil, "status")
    T.ok(string.find(wire, "hello multipart|data.bin|30000", 1, true) ~= nil, "fields")
  end,

  ["streaming multipart route across reads"] = function(): void
    local f = fixture(true)
    local data: string = body()
    local cut: integer = #data - 5000
    local conn = connect(f, "stream", request(data), false)
    -- Replace the connection's scripted input with a partial first read.
    conn.input = "POST /form HTTP/1.1\r\nHost: t\r\n"
      .. "Content-Type: multipart/form-data; boundary=" .. BOUNDARY .. "\r\n"
      .. "Content-Length: " .. tostring(#data) .. "\r\n\r\n"
      .. string.sub(data, 1, cut)
    conn.ipos = 1
    f.server:step(0)
    T.eq(conn:takeOutput(), "", "waiting for rest")
    conn:feed(string.sub(data, cut + 1))
    f.server:step(0)
    local wire: string = conn:takeOutput()
    T.ok(string.find(wire, "HTTP/1.1 200 OK", 1, true) ~= nil, "status")
    T.ok(string.find(wire, "hello multipart|data.bin|30000", 1, true) ~= nil, "streamed fields")
  end,

  ["multipart errors become 500"] = function(): void
    local f = fixture(true)
    local badRequest = "POST /form HTTP/1.1\r\nHost: t\r\n"
      .. "Content-Type: text/plain\r\nContent-Length: 4\r\n\r\nnope"
    local conn = connect(f, "bad", badRequest, true)
    f.server:step(0)
    local wire: string = conn:takeOutput()
    T.ok(string.find(wire, "HTTP/1.1 500 Internal Server Error", 1, true) ~= nil, "500")
  end,
}
