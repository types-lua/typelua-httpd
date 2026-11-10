--- Immutable-by-convention request value parsed from the wire.

class HttpRequest implements HttpRequestApi {
  method: string,
  target: string,
  path: string,
  rawQuery: string,
  query: Query,
  version: string,
  headers: HeadersApi,
  body: string = "",
  remote: string = "",
  keepAlive: boolean = false,

  constructor(
    method: string,
    target: string,
    path: string,
    rawQuery: string,
    query: Query,
    version: string,
    headers: HeadersApi,
    keepAlive: boolean
  )
    self.method = method
    self.target = target
    self.path = path
    self.rawQuery = rawQuery
    self.query = query
    self.version = version
    self.headers = headers
    self.keepAlive = keepAlive
  end,
}

return { HttpRequest = HttpRequest }
