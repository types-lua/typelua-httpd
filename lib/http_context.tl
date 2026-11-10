--- Per-request handler context and response helpers.

import url from "./http_url"

class HttpContext implements HttpContextApi {
  req: HttpRequestApi,
  res: HttpResponseApi,
  params: map<string, string> = {},
  state: map<string, any> = {},

  constructor(req: HttpRequestApi, res: HttpResponseApi)
    self.req = req
    self.res = res
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
}

return { HttpContext = HttpContext }
