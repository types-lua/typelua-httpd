--- TypeLua HTTP server demo.
---
--- Run with an external Lua because LuaSocket is a C module:
---   lua-socket install: apt install lua-socket
---   tlua run --lua lua5.4 main.tl
---
--- Environment:
---   HOST (default 127.0.0.1)
---   PORT (default 8080, 0 picks a free port)
---   TLS_CERT / TLS_KEY (optional PEM paths; enables TLS + ALPN h2/http1.1)

import http from "./lib/http"

local function env(name: string, fallback: string): string
  local value: string | nil = os.getenv(name)
  if value == nil or value == "" then
    return fallback
  end
  return value!
end

local function portFromEnv(): integer
  local raw: string = env("PORT", "8080")
  local parsed: number | nil = tonumber(raw)
  if parsed == nil or parsed! < 0 or parsed! > 65535 then
    error("PORT must be an integer between 0 and 65535, got: " .. raw)
  end
  return math.floor(parsed!)
end

--- Minimal JSON string encoder for values derived from the request.
local function jsonString(value: string): string
  local out: string[] = { "\"" }
  for i: integer = 1, #value do
    local c: integer = string.byte(value, i)!
    if c == 34 then
      out[#out + 1] = "\\\""
    elseif c == 92 then
      out[#out + 1] = "\\\\"
    elseif c == 10 then
      out[#out + 1] = "\\n"
    elseif c == 13 then
      out[#out + 1] = "\\r"
    elseif c == 9 then
      out[#out + 1] = "\\t"
    elseif c < 32 then
      out[#out + 1] = string.format("\\u%04x", c)
    else
      out[#out + 1] = string.char(c)
    end
  end
  out[#out + 1] = "\""
  return table.concat(out)
end

local router = http.HttpRouter.new()
local startedAt: number = os.time()

router:use(function(ctx: HttpContextApi, next: () -> void): void
  local begin: number = os.clock()
  next()
  local elapsedMs: number = (os.clock() - begin) * 1000
  print(string.format(
    "%s %s -> %d (%.1f ms)",
    ctx.req.method,
    ctx.req.target,
    ctx.res.status,
    elapsedMs
  ))
end)

router:get("/", function(ctx: HttpContextApi): void
  ctx:html([[
<!doctype html>
<html lang="en">
  <head><meta charset="utf-8"><title>typelua-httpd</title></head>
  <body>
    <h1>typelua-httpd</h1>
    <p>A small, strict HTTP/1.1 server written in TypeLua.</p>
    <ul>
      <li><a href="/health">/health</a></li>
      <li><a href="/api/users/42?verbose=1">/api/users/42</a></li>
      <li><a href="/static/">/static/</a></li>
      <li><a href="/redirect">/redirect</a></li>
    </ul>
    <p>WebSocket endpoint: <code>ws://HOST:PORT/ws</code></p>
  </body>
</html>
]])
end)

router:get("/health", function(ctx: HttpContextApi): void
  local uptime: integer = math.floor(os.time() - startedAt)
  ctx:send(
    "{\"status\":\"ok\",\"uptimeSeconds\":" .. tostring(uptime)
      .. ",\"server\":\"typelua-httpd\"}",
    "application/json; charset=utf-8"
  )
end)

router:get("/api/users/:id", function(ctx: HttpContextApi): void
  local id: string = "unknown"
  local value: string | nil = ctx:param("id")
  if value ~= nil then
    id = value!
  end
  local verbose: string = "false"
  if ctx:query("verbose") == "1" then
    verbose = "true"
  end
  ctx:send(
    "{\"id\":" .. jsonString(id) .. ",\"verbose\":" .. verbose .. "}\n",
    "application/json; charset=utf-8"
  )
end)

router:put("/api/users/:id", function(ctx: HttpContextApi): void
  -- The body has already been fully framed and validated by the server.
  ctx.res.headers:set("X-Body-Bytes", tostring(#ctx.req.body))
  ctx.res.status = 204
end)

router:delete("/api/users/:id", function(ctx: HttpContextApi): void
  ctx.res.status = 204
end)

router:post("/api/echo", function(ctx: HttpContextApi): void
  ctx:set("X-Request-Bytes", tostring(#ctx.req.body))
  ctx:send(ctx.req.body, "application/octet-stream")
end)

--- Streaming upload: the body never lands in req.body.
router:stream("POST", "/upload", function(ctx: HttpContextApi): void
  local total: integer = 0
  local chunks: integer = 0
  while true do
    local chunk: string | nil = ctx:readBody()
    if chunk == nil then break end
    total = total + #chunk!
    chunks = chunks + 1
  end
  ctx:set("X-Chunks", tostring(chunks))
  ctx:send("received " .. tostring(total) .. " bytes in " .. tostring(chunks) .. " chunks\n",
    "text/plain; charset=utf-8")
end)

--- Multipart upload. Works for buffered and streaming routes.
router:post("/form", function(ctx: HttpContextApi): void
  local reader = ctx:multipart({ maxPartBytes = 2 * 1024 * 1024 })
  local summary: string[] = {}
  while true do
    local part = reader:nextPart()
    if part == nil then break end
    local meta = part:meta()
    local value: string = part:readAll()
    local label: string = meta.name
    if meta.filename ~= nil then label = label .. "[" .. meta.filename! .. "]" end
    summary[#summary + 1] = label .. "=" .. tostring(#value) .. " bytes"
  end
  ctx:send(table.concat(summary, "\n") .. "\n", "text/plain; charset=utf-8")
end)

router:get("/ws", function(ctx: HttpContextApi): void
  ctx:websocket({
    onOpen = function(socket: any): void
      socket:sendText("welcome to typelua-httpd websocket")
    end,
    onText = function(socket: any, text: string): void
      socket:sendText("echo: " .. text)
    end,
    onBinary = function(socket: any, data: string): void
      socket:sendBinary(data)
    end,
  })
end)

router:get("/redirect", function(ctx: HttpContextApi): void
  ctx:redirect("/", 302)
end)

local files = http.HttpStatic.new({
  root = "public",
  prefix = "/static",
  indexFile = "index.html",
  cacheControl = "public, max-age=60",
  maxBytes = 4 * 1024 * 1024,
})
router:get("/static/*", files:handler())

router:notFound(function(ctx: HttpContextApi): void
  ctx:text("Not Found\n", 404)
end)

router:onError(function(ctx: HttpContextApi, err: any): void
  print("handler error: " .. tostring(err))
  ctx:text("Internal Server Error\n", 500)
end)

local certificate: string = env("TLS_CERT", "")
local key: string = env("TLS_KEY", "")
local transport: HttpTransportApi
local scheme: string = "http"
if certificate ~= "" and key ~= "" then
  transport = http.TlsTransport.new({ certificate = certificate, key = key })
  scheme = "https"
else
  transport = http.SocketTransport.new()
end

local server = http.HttpServer.new(router, transport, {
  serverName = "typelua-httpd-demo",
  maxBody = 2 * 1024 * 1024,
  maxConnections = 256,
  idleTimeout = 75,
  requestTimeout = 30,
})

server:listen(env("HOST", "127.0.0.1"), portFromEnv())
local address = server:address()
print("typelua-httpd listening on " .. scheme .. "://" .. address.host .. ":" .. tostring(address.port))
print("Press Ctrl+C to stop.")
server:serve()
