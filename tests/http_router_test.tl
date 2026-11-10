import T from "tlua_test"
import http from "../lib/http"

local function request(method: string, target: string): HttpRequestApi
  local parts = http.url.splitTarget(target)
  local headers = http.Headers.new()
  headers:set("Host", "test.local")
  return http.HttpRequest.new(
    method,
    target,
    parts.path,
    parts.rawQuery,
    http.url.parseQuery(parts.rawQuery),
    "1.1",
    headers,
    true
  )
end

local function dispatch(router: HttpRouterApi, method: string, target: string): HttpResponseApi
  local res = http.HttpResponse.new(200)
  router:handle(request(method, target), res)
  return res
end

return {
  ["params, wildcard and decoded segments"] = function(): void
    local r = http.HttpRouter.new()
    r:get("/", function(ctx: HttpContextApi): void
      ctx:text("root")
    end)
    r:get("/users/:id/posts/:post", function(ctx: HttpContextApi): void
      local id: string = "?"
      local post: string = "?"
      local idValue: string | nil = ctx:param("id")
      local postValue: string | nil = ctx:param("post")
      if idValue ~= nil then id = idValue! end
      if postValue ~= nil then post = postValue! end
      ctx:text(id .. "/" .. post)
    end)
    r:get("/files/*", function(ctx: HttpContextApi): void
      local value: string = ""
      local rest: string | nil = ctx:param("*")
      if rest ~= nil then value = rest! end
      ctx:text(value)
    end)

    T.eq(r:count(), 3, "routes")
    T.eq(dispatch(r, "GET", "/").body, "root", "root")
    T.eq(dispatch(r, "GET", "/users/42/posts/7").body, "42/7", "params")
    T.eq(
      dispatch(r, "GET", "/users/a%20b/posts/c%2Fd").body,
      "a b/c/d",
      "params are decoded"
    )
    T.eq(dispatch(r, "GET", "/files/a/b.txt").body, "a/b.txt", "wildcard")
    T.eq(dispatch(r, "GET", "/files/").body, "", "wildcard may be empty")
    T.eq(dispatch(r, "GET", "/users/42").status, 404, "missing segment")
    T.eq(dispatch(r, "GET", "/users/42/posts/7/extra").status, 404, "extra segment")
  end,

  ["middleware order, state and short circuit"] = function(): void
    local r = http.HttpRouter.new()
    local log: string[] = {}
    r:use(function(ctx: HttpContextApi, next: () -> void): void
      log[#log + 1] = "first"
      ctx.state["user"] = "alice"
      next()
      log[#log + 1] = "first-after"
    end)
    r:use(function(ctx: HttpContextApi, next: () -> void): void
      log[#log + 1] = "second"
      if ctx.req.path == "/blocked" then
        ctx:text("blocked", 403)
        return
      end
      next()
    end)
    r:get("/ok", function(ctx: HttpContextApi): void
      log[#log + 1] = "handler"
      ctx:text(tostring(ctx.state["user"]))
    end)
    r:get("/blocked", function(ctx: HttpContextApi): void
      log[#log + 1] = "should-not-run"
      ctx:text("bad")
    end)

    local ok = dispatch(r, "GET", "/ok")
    T.eq(ok.body, "alice", "state is shared")
    T.eq(table.concat(log, ","), "first,second,handler,first-after", "order")

    log = {}
    local blocked = dispatch(r, "GET", "/blocked")
    T.eq(blocked.status, 403, "short circuit status")
    T.eq(blocked.body, "blocked", "short circuit body")
    T.eq(table.concat(log, ","), "first,second,first-after", "handler skipped")
  end,

  ["404, 405 and automatic OPTIONS"] = function(): void
    local r = http.HttpRouter.new()
    r:get("/thing", function(ctx: HttpContextApi): void ctx:text("get") end)
    r:post("/thing", function(ctx: HttpContextApi): void ctx:text("post") end)
    r:put("/only-put", function(ctx: HttpContextApi): void ctx:text("put") end)

    local missing = dispatch(r, "GET", "/nope")
    T.eq(missing.status, 404, "404")
    T.eq(missing.body, "Not Found", "404 body")

    local notAllowed = dispatch(r, "DELETE", "/thing")
    T.eq(notAllowed.status, 405, "405")
    local allow: string | nil = notAllowed.headers:get("Allow")
    T.ok(allow ~= nil, "allow present")
    T.ok(string.find(allow!, "GET", 1, true) ~= nil, "allow GET")
    T.ok(string.find(allow!, "HEAD", 1, true) ~= nil, "allow HEAD")
    T.ok(string.find(allow!, "POST", 1, true) ~= nil, "allow POST")
    T.ok(string.find(allow!, "OPTIONS", 1, true) ~= nil, "allow OPTIONS")

    local options = dispatch(r, "OPTIONS", "/thing")
    T.eq(options.status, 204, "options 204")
    T.eq(options.body, "", "options empty")
    T.ok(options.headers:get("Allow") ~= nil, "options allow")

    local head = dispatch(r, "HEAD", "/thing")
    T.eq(head.status, 200, "HEAD falls back to GET")
    T.eq(head.body, "get", "router exposes GET body to serializer")

    local putOnly = dispatch(r, "GET", "/only-put")
    T.eq(putOnly.status, 405, "single method 405")
    T.ok(string.find(putOnly.headers:get("Allow")!, "HEAD", 1, true) == nil, "no HEAD without GET")
  end,

  ["calling next twice does not re-dispatch"] = function(): void
    local r = http.HttpRouter.new()
    local calls: integer = 0
    r:use(function(ctx: HttpContextApi, next: () -> void): void
      next()
      next()
    end)
    r:get("/once", function(ctx: HttpContextApi): void
      calls = calls + 1
      ctx:text("once")
    end)
    local res = dispatch(r, "GET", "/once")
    T.eq(calls, 1, "handler once")
    T.eq(res.body, "once", "body")
  end,

  ["server-wide OPTIONS star"] = function(): void
    local r = http.HttpRouter.new()
    r:get("/a", function(ctx: HttpContextApi): void ctx:text("a") end)
    r:post("/b", function(ctx: HttpContextApi): void ctx:text("b") end)
    local res = dispatch(r, "OPTIONS", "*")
    T.eq(res.status, 204, "star status")
    local allow: string = res.headers:get("Allow")!
    T.ok(string.find(allow, "GET", 1, true) ~= nil, "star GET")
    T.ok(string.find(allow, "POST", 1, true) ~= nil, "star POST")
    T.ok(string.find(allow, "OPTIONS", 1, true) ~= nil, "star OPTIONS")
  end,

  ["explicit OPTIONS route wins"] = function(): void
    local r = http.HttpRouter.new()
    r:options("/x", function(ctx: HttpContextApi): void
      ctx.res.status = 200
      ctx.res.headers:set("Allow", "CUSTOM")
      ctx:text("custom")
    end)
    r:get("/x", function(ctx: HttpContextApi): void ctx:text("get") end)
    local res = dispatch(r, "OPTIONS", "/x")
    T.eq(res.status, 200, "custom status")
    T.eq(res.body, "custom", "custom body")
    T.eq(res.headers:get("Allow"), "CUSTOM", "custom allow")
  end,

  ["custom not found handler"] = function(): void
    local r = http.HttpRouter.new()
    r:notFound(function(ctx: HttpContextApi): void
      ctx:html("<h1>gone</h1>", 410)
    end)
    local res = dispatch(r, "GET", "/x")
    T.eq(res.status, 410, "status")
    T.eq(res.body, "<h1>gone</h1>", "body")
    T.eq(res.headers:get("Content-Type"), "text/html; charset=utf-8", "type")
  end,

  ["error handler catches handler and middleware errors"] = function(): void
    local r = http.HttpRouter.new()
    local seen: string[] = {}
    r:onError(function(ctx: HttpContextApi, err: any): void
      seen[#seen + 1] = tostring(err)
      ctx:text("handled: " .. tostring(err), 502)
    end)
    r:get("/boom", function(ctx: HttpContextApi): void
      error("handler exploded")
    end)
    r:use(function(ctx: HttpContextApi, next: () -> void): void
      if ctx.req.path == "/mw" then
        error("middleware exploded")
      end
      next()
    end)
    r:get("/mw", function(ctx: HttpContextApi): void ctx:text("never") end)

    local a = dispatch(r, "GET", "/boom")
    T.eq(a.status, 502, "handler status")
    T.ok(string.find(a.body, "handler exploded", 1, true) ~= nil, "handler message")
    local b = dispatch(r, "GET", "/mw")
    T.eq(b.status, 502, "middleware status")
    T.ok(string.find(b.body, "middleware exploded", 1, true) ~= nil, "middleware message")
    T.eq(#seen, 2, "error handler called twice")
  end,

  ["error handler that throws yields a clean 500"] = function(): void
    local r = http.HttpRouter.new()
    r:onError(function(ctx: HttpContextApi, err: any): void
      error("error handler failed: " .. tostring(err))
    end)
    r:get("/x", function(ctx: HttpContextApi): void error("first") end)
    local res = dispatch(r, "GET", "/x")
    T.eq(res.status, 500, "status")
    T.eq(res.body, "Internal Server Error\n", "body")
  end,

  ["invalid patterns are rejected at registration"] = function(): void
    local r = http.HttpRouter.new()
    T.raises(function(): void
      r:get("/a/*/b", function(ctx: HttpContextApi): void end)
    end)
    T.raises(function(): void
      r:get("/a/:", function(ctx: HttpContextApi): void end)
    end)
  end,

  ["method names and paths are case-normalized where required"] = function(): void
    local r = http.HttpRouter.new()
    r:add("get", "/lower", function(ctx: HttpContextApi): void ctx:text("ok") end)
    T.eq(dispatch(r, "get", "/lower").status, 200, "method upper")
    -- Paths stay case-sensitive.
    T.eq(dispatch(r, "GET", "/Lower").status, 404, "path case")
  end,
}
