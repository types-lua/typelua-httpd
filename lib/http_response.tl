--- Response value and wire serializer.
---
--- Content-Length is always recomputed from the body (except bodyless
--- statuses), so an application cannot create a response-smuggling mismatch.
--- HEAD keeps the represented length but writes no body.

import headers from "./http_headers"
import status from "./http_status"
import date from "./http_date"

class HttpResponse implements HttpResponseApi {
  status: integer,
  headers: HeadersApi,
  body: string = "",

  constructor(status: integer)
    if status < 100 or status > 599 then
      error("invalid HTTP status: " .. tostring(status))
    end
    self.status = status
    self.headers = headers.Headers.new()
  end,
}

local function serialize(response: HttpResponse, opts: SerializeOptions): string
  if response.status < 100 or response.status > 599 then
    error("invalid HTTP status: " .. tostring(response.status))
  end
  -- The version and method end up on the status line; validate them here so a
  -- bad application value cannot inject a second response onto the wire.
  if opts.version ~= "1.0" and opts.version ~= "1.1" then
    error("invalid HTTP version: " .. tostring(opts.version))
  end
  if not headers.validName(opts.requestMethod) then
    error("invalid request method: " .. tostring(opts.requestMethod))
  end
  local bodyAllowed: boolean = not status.isBodyless(response.status)
  local head: boolean = string.upper(opts.requestMethod) == "HEAD"
  local body: string = response.body
  if not bodyAllowed or head then
    -- Keep `response.body` for HEAD (Content-Length reflects the GET body),
    -- but never put it on the wire for bodyless statuses.
    if not bodyAllowed then
      body = ""
    end
  end

  response.headers:setIfAbsent("Date", date.httpDate(os.time()))
  if opts.serverName ~= "" then
    response.headers:setIfAbsent("Server", opts.serverName)
  end
  response.headers:remove("Transfer-Encoding")
  if bodyAllowed then
    response.headers:set("Content-Length", tostring(#response.body))
  else
    response.headers:remove("Content-Length")
    if response.status == 205 then
      -- 205 must explicitly signal an empty payload.
      response.headers:set("Content-Length", "0")
    end
  end
  if opts.keepAlive then
    if opts.version == "1.0" then
      response.headers:set("Connection", "keep-alive")
    else
      response.headers:remove("Connection")
    end
  else
    response.headers:set("Connection", "close")
  end

  local parts: string[] = {}
  parts[#parts + 1] = "HTTP/" .. opts.version .. " "
    .. tostring(response.status) .. " " .. status.reason(response.status) .. "\r\n"
  local entries: HeaderEntry[] = response.headers:entries()
  for i: integer = 1, #entries do
    local e: HeaderEntry = entries[i]
    parts[#parts + 1] = e.name .. ": " .. e.value .. "\r\n"
  end
  parts[#parts + 1] = "\r\n"
  if bodyAllowed and not head and #body > 0 then
    parts[#parts + 1] = body
  end
  return table.concat(parts)
end

local function errorResponse(
  statusCode: integer,
  message: string,
  opts: SerializeOptions
): string
  local res = HttpResponse.new(statusCode)
  res.headers:set("Content-Type", "text/plain; charset=utf-8")
  res.body = message .. "\n"
  local copy: SerializeOptions = {
    serverName = opts.serverName,
    keepAlive = false,
    requestMethod = "GET",
    version = opts.version,
  }
  return serialize(res, copy)
end

return {
  HttpResponse = HttpResponse,
  serialize = serialize,
  errorResponse = errorResponse,
}
