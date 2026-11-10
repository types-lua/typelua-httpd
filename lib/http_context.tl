--- Per-request handler context and response helpers.

import url from "./http_url"
import multipartMod from "./http_multipart"
import wsMod from "./http_websocket"

class HttpContext implements HttpContextApi {
  req: HttpRequestApi,
  res: HttpResponseApi,
  params: map<string, string> = {},
  state: map<string, any> = {},
  bodyReader: BodyReader | nil = nil,
  bodyConsumed: boolean = false,

  constructor(req: HttpRequestApi, res: HttpResponseApi)
    self.req = req
    self.res = res
  end,

  setBodyReader(reader: BodyReader): void
    self.bodyReader = reader
    self.bodyConsumed = false
  end,

  readBody(): string | nil
    local reader: BodyReader | nil = self.bodyReader
    if reader ~= nil then
      local fn: BodyReader = reader!
      return fn()
    end
    if self.bodyConsumed then return nil end
    self.bodyConsumed = true
    return self.req.body
  end,

  text(body: string, statusCode: integer | nil): void
    if statusCode ~= nil then self.res.status = statusCode! end
    self.res.headers:set("Content-Type", "text/plain; charset=utf-8")
    self.res.body = body
  end,

  html(body: string, statusCode: integer | nil): void
    if statusCode ~= nil then self.res.status = statusCode! end
    self.res.headers:set("Content-Type", "text/html; charset=utf-8")
    self.res.body = body
  end,

  send(body: string, contentType: string, statusCode: integer | nil): void
    if statusCode ~= nil then self.res.status = statusCode! end
    self.res.headers:set("Content-Type", contentType)
    self.res.body = body
  end,

  redirect(location: string, statusCode: integer | nil): void
    self.res.status = 302
    if statusCode ~= nil then self.res.status = statusCode! end
    self.res.headers:set("Location", location)
    self.res.headers:set("Content-Type", "text/plain; charset=utf-8")
    self.res.body = "Redirecting to " .. location .. "\n"
  end,

  set(name: string, value: string): void
    self.res.headers:set(name, value)
  end,

  get(name: string): string | nil
    return self.req.headers:get(name)
  end,

  param(name: string): string | nil
    return self.params[name]
  end,

  query(name: string): string | nil
    return self.req.query[name]
  end,

  cookie(name: string): string | nil
    local values: string[] = self.req.headers:getAll("Cookie")
    if #values == 0 then
      return nil
    end
    return url.parseCookies(table.concat(values, "; "))[name]
  end,

  --- Pull-based multipart reader over readBody(). In a streaming route the
  --- source yields to the server; in a buffered route it yields the body once.
  websocket(handlers: WebSocketHandlers): void
    if self.bodyReader ~= nil then
      error("WebSocket upgrade requires a buffered route, not router:stream")
    end
    local check = wsMod.validateHandshake(self.req)
    if not check.ok then
      self:text(check.error, 400)
      return
    end
    local key: string | nil = self.req.headers:get("Sec-WebSocket-Key")
    if key == nil then
      self:text("missing WebSocket key", 400)
      return
    end
    self.res.status = 101
    self.res.headers:set("Upgrade", "websocket")
    self.res.headers:set("Connection", "Upgrade")
    self.res.headers:set("Sec-WebSocket-Accept", wsMod.acceptKey(key!))
    local protocols: string[] | nil = handlers.protocols
    if protocols ~= nil then
      local offered: string | nil = self.req.headers:get("Sec-WebSocket-Protocol")
      if offered ~= nil then
        local selected: string = ""
        local found: boolean = false
        for i: integer = 1, #protocols! do
          for part in string.gmatch(offered!, "[^,]+") do
            local item: string = part
            while #item > 0 and string.sub(item, 1, 1) == " " do item = string.sub(item, 2) end
            while #item > 0 and string.sub(item, -1) == " " do item = string.sub(item, 1, -2) end
            if item == protocols![i] and not found then
              selected = item
              found = true
            end
          end
        end
        if found then
          self.res.headers:set("Sec-WebSocket-Protocol", selected)
        end
      end
    end
    local writable: any = self.res
    writable.websocket = handlers
  end,

  multipart(options: MultipartRequestOptions): any
    local contentType: string | nil = self.req.headers:get("Content-Type")
    if contentType == nil then
      error("multipart: missing Content-Type")
    end
    local boundary: string | nil = multipartMod.boundaryFrom(contentType!)
    if boundary == nil then
      error("multipart: Content-Type is not multipart/form-data")
    end
    local readerOptions: any = {
      boundary = boundary!,
      source = function(): string | nil
        return self:readBody()
      end,
    }
    local maxHeaderBytes: integer | nil = options.maxHeaderBytes
    if maxHeaderBytes ~= nil then readerOptions.maxHeaderBytes = maxHeaderBytes! end
    local maxHeaders: integer | nil = options.maxHeaders
    if maxHeaders ~= nil then readerOptions.maxHeaders = maxHeaders! end
    local maxParts: integer | nil = options.maxParts
    if maxParts ~= nil then readerOptions.maxParts = maxParts! end
    local maxPartBytes: integer | nil = options.maxPartBytes
    if maxPartBytes ~= nil then readerOptions.maxPartBytes = maxPartBytes! end
    local maxTotalBytes: integer | nil = options.maxTotalBytes
    if maxTotalBytes ~= nil then readerOptions.maxTotalBytes = maxTotalBytes! end
    local requireDisposition: boolean | nil = options.requireDisposition
    if requireDisposition ~= nil then
      readerOptions.requireDisposition = requireDisposition!
    end
    return multipartMod.MultipartReader.new(readerOptions)
  end,
}

return { HttpContext = HttpContext }
