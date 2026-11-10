--- Smallest useful real HTTP server.
---
--- Build the project, then run from the emitted tree so `lib.http` resolves:
---   tlua build
---   (cd dist && lua5.4 examples/hello.lua)
---   curl -i http://127.0.0.1:8090/

import http from "../lib/http"

local router = http.HttpRouter.new()
router:get("/", function(ctx: HttpContextApi): void
  ctx:text("hello from TypeLua\n")
end)
router:get("/time", function(ctx: HttpContextApi): void
  ctx:send("{\"now\":" .. tostring(os.time()) .. "}", "application/json")
end)

local server = http.HttpServer.new(
  router,
  http.SocketTransport.new(),
  { serverName = "hello", idleTimeout = 15 }
)
server:listen("127.0.0.1", 8090)
local address = server:address()
print("listening on http://" .. address.host .. ":" .. tostring(address.port))
server:serve()
