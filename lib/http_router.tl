--- Method/path router with middleware, params, wildcard and automatic 405/OPTIONS.

import url from "./http_url"
import contextMod from "./http_context"

type SegmentKind = "static" | "param" | "wildcard"

type Segment = {
  kind: SegmentKind,
  value: string,
}

type Route = {
  method: string,
  pattern: string,
  segments: Segment[],
  handler: Handler,
  streaming: boolean,
}

type Match = {
  route: Route | nil,
  params: map<string, string> | nil,
}

local function compile(pattern: string): Segment[]
  local out: Segment[] = {}
  local seenWildcard: boolean = false
  for part in string.gmatch(pattern, "[^/]+") do
    if seenWildcard then
      error("wildcard must be the last pattern segment: " .. pattern)
    end
    if part == "*" then
      out[#out + 1] = { kind = "wildcard", value = "*" }
      seenWildcard = true
    elseif string.sub(part, 1, 1) == ":" then
      local name: string = string.sub(part, 2)
      if name == "" then
        error("empty parameter name in pattern: " .. pattern)
      end
      out[#out + 1] = { kind = "param", value = name }
    else
      out[#out + 1] = { kind = "static", value = url.decodeComponent(part) }
    end
  end
  return out
end

local function matchSegments(route: Route, parts: string[]): map<string, string> | nil
  local params: map<string, string> = {}
  local i: integer = 1
  local j: integer = 1
  while i <= #route.segments do
    local seg: Segment = route.segments[i]
    if seg.kind == "wildcard" then
      local rest: string[] = {}
      while j <= #parts do
        rest[#rest + 1] = parts[j]
        j = j + 1
      end
      params["*"] = table.concat(rest, "/")
      return params
    end
    if j > #parts then
      return nil
    end
    if seg.kind == "static" then
      if parts[j] ~= seg.value then
        return nil
      end
    else
      params[seg.value] = parts[j]
    end
    i = i + 1
    j = j + 1
  end
  if j <= #parts then
    return nil
  end
  return params
end

class HttpRouter implements HttpRouterApi {
  routes: Route[] = {},
  middleware: Middleware[] = {},
  notFoundHandler: Handler | nil = nil,
  errorHandler: ErrorHandler | nil = nil,

  constructor() end,

  use(mw: Middleware): void
    self.middleware[#self.middleware + 1] = mw
  end,

  add(method: string, pattern: string, handler: Handler): void
    self.routes[#self.routes + 1] = {
      method = string.upper(method),
      pattern = pattern,
      segments = compile(pattern),
      handler = handler,
      streaming = false,
    }
  end,

  --- Registers a handler that is dispatched as soon as headers are complete.
  --- The handler may call ctx:readBody() to pull request chunks.
  stream(method: string, pattern: string, handler: Handler): void
    self.routes[#self.routes + 1] = {
      method = string.upper(method),
      pattern = pattern,
      segments = compile(pattern),
      handler = handler,
      streaming = true,
    }
  end,

  get(pattern: string, handler: Handler): void self:add("GET", pattern, handler) end,
  post(pattern: string, handler: Handler): void self:add("POST", pattern, handler) end,
  put(pattern: string, handler: Handler): void self:add("PUT", pattern, handler) end,
  patch(pattern: string, handler: Handler): void self:add("PATCH", pattern, handler) end,
  delete(pattern: string, handler: Handler): void self:add("DELETE", pattern, handler) end,
  options(pattern: string, handler: Handler): void self:add("OPTIONS", pattern, handler) end,
  head(pattern: string, handler: Handler): void self:add("HEAD", pattern, handler) end,

  notFound(handler: Handler): void
    self.notFoundHandler = handler
  end,

  onError(handler: ErrorHandler): void
    self.errorHandler = handler
  end,

  count(): integer
    return #self.routes
  end,

  find(method: string, path: string): Match
    local parts: string[] = url.pathSegments(path)
    for i: integer = 1, #self.routes do
      local route: Route = self.routes[i]
      if route.method == method then
        local params: map<string, string> | nil = matchSegments(route, parts)
        if params ~= nil then
          return { route = route, params = params! }
        end
      end
    end
    -- HEAD falls back to GET; the serializer suppresses the body.
    if method == "HEAD" then
      for i: integer = 1, #self.routes do
        local route: Route = self.routes[i]
        if route.method == "GET" then
          local params: map<string, string> | nil = matchSegments(route, parts)
          if params ~= nil then
            return { route = route, params = params! }
          end
        end
      end
    end
    return { route = nil, params = nil }
  end,

  allowed(path: string): string[]
    local parts: string[] = url.pathSegments(path)
    local seen: map<string, boolean> = {}
    local out: string[] = {}
    for i: integer = 1, #self.routes do
      local route: Route = self.routes[i]
      if matchSegments(route, parts) ~= nil and seen[route.method] ~= true then
        seen[route.method] = true
        out[#out + 1] = route.method
        if route.method == "GET" and seen["HEAD"] ~= true then
          seen["HEAD"] = true
          out[#out + 1] = "HEAD"
        end
      end
    end
    if #out > 0 and seen["OPTIONS"] ~= true then
      out[#out + 1] = "OPTIONS"
    end
    return out
  end,

  isStreaming(method: string, path: string): boolean
    local match: Match = self:find(string.upper(method), path)
    if match.route == nil then return false end
    return match.route!.streaming
  end,

  allowedAll(): string[]
    local seen: map<string, boolean> = {}
    local out: string[] = {}
    for i: integer = 1, #self.routes do
      local method: string = self.routes[i].method
      if seen[method] ~= true then
        seen[method] = true
        out[#out + 1] = method
        if method == "GET" and seen["HEAD"] ~= true then
          seen["HEAD"] = true
          out[#out + 1] = "HEAD"
        end
      end
    end
    if #out > 0 and seen["OPTIONS"] ~= true then
      out[#out + 1] = "OPTIONS"
    end
    return out
  end,

  handle(req: HttpRequestApi, res: HttpResponseApi): void
    self:runHandle(req, res, nil, true)
  end,

  handleStream(
    req: HttpRequestApi,
    res: HttpResponseApi,
    bodyReader: BodyReader
  ): void
    -- Streaming handlers run inside a server-owned coroutine. On Lua 5.1 a
    -- yield cannot cross pcall, so the server protects coroutine.resume
    -- instead and this path intentionally lets handler errors propagate.
    self:runHandle(req, res, bodyReader, false)
  end,

  runHandle(
    req: HttpRequestApi,
    res: HttpResponseApi,
    bodyReader: BodyReader | nil,
    protectedMode: boolean
  ): void
    local ctx = contextMod.HttpContext.new(req, res)
    if bodyReader ~= nil then ctx:setBodyReader(bodyReader!) end
    local method: string = string.upper(req.method)
    if method == "OPTIONS" and req.path == "*" then
      local all: string[] = self:allowedAll()
      res.status = 204
      if #all > 0 then
        res.headers:set("Allow", table.concat(all, ", "))
      end
      return
    end
    local match: Match = self:find(method, req.path)
    local function dispatch(): void
      if match.route ~= nil then
        ctx.params = match.params!
        match.route!.handler(ctx)
        return
      end
      if method == "OPTIONS" then
        local allow: string[] = self:allowed(req.path)
        if #allow > 0 then
          res.status = 204
          res.headers:set("Allow", table.concat(allow, ", "))
          return
        end
      end
      local allow: string[] = self:allowed(req.path)
      if #allow > 0 then
        res.status = 405
        res.headers:set("Allow", table.concat(allow, ", "))
        ctx:text("Method Not Allowed", 405)
        return
      end
      local handler: Handler | nil = self.notFoundHandler
      if handler ~= nil then
        handler!(ctx)
        return
      end
      ctx:text("Not Found", 404)
    end

    local function continueFrom(stage: integer): void
      local mw: Middleware | nil = self.middleware[stage]
      if mw == nil then
        dispatch()
        return
      end
      local called: boolean = false
      local function nextOnce(): void
        if called then return end
        called = true
        continueFrom(stage + 1)
      end
      mw!(ctx, nextOnce)
    end

    if not protectedMode then
      continueFrom(1)
      return
    end

    local ok, err = pcall(function(): void continueFrom(1) end)
    if not ok then
      local handler: ErrorHandler | nil = self.errorHandler
      res.status = 500
      res.headers:set("Content-Type", "text/plain; charset=utf-8")
      res.body = "Internal Server Error\n"
      if handler ~= nil then
        local okHandler = pcall(function(): void
          handler!(ctx, err)
        end)
        if not okHandler then
          res.status = 500
          res.body = "Internal Server Error\n"
        end
      end
    end
  end,
}

return { HttpRouter = HttpRouter, compile = compile, matchSegments = matchSegments }
