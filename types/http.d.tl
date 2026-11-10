--- Ambient contracts for the HTTP/1.1 server library.
---
--- Checked but never emitted. Keeping the ports here lets the protocol core
--- run on the in-memory transport in tests and on LuaSocket in production
--- without leaking concrete classes into the server state machine.

-- ---------------------------------------------------------------------------
-- Headers
-- ---------------------------------------------------------------------------

declare type HeaderEntry = { name: string, value: string }

declare interface HeadersApi {
  set(name: string, value: string): void,
  setIfAbsent(name: string, value: string): void,
  add(name: string, value: string): void,
  get(name: string): string | nil,
  getAll(name: string): string[],
  has(name: string): boolean,
  remove(name: string): void,
  count(): integer,
  entries(): HeaderEntry[],
}

-- ---------------------------------------------------------------------------
-- Requests, responses, handlers
-- ---------------------------------------------------------------------------

declare type Query = map<string, string>

declare interface HttpRequestApi {
  method: string,
  target: string,
  path: string,
  rawQuery: string,
  query: Query,
  version: string,
  headers: HeadersApi,
  body: string,
  remote: string,
  keepAlive: boolean,
}

declare interface HttpResponseApi {
  status: integer,
  headers: HeadersApi,
  body: string,
}

declare type Handler = (ctx: HttpContextApi) -> void
declare type Middleware = (ctx: HttpContextApi, next: () -> void) -> void
declare type ErrorHandler = (ctx: HttpContextApi, err: any) -> void

declare interface HttpContextApi {
  req: HttpRequestApi,
  res: HttpResponseApi,
  params: map<string, string>,
  state: map<string, any>,
  text(body: string, status?: integer): void,
  html(body: string, status?: integer): void,
  send(body: string, contentType: string, status?: integer): void,
  redirect(location: string, status?: integer): void,
  set(name: string, value: string): void,
  get(name: string): string | nil,
  param(name: string): string | nil,
  query(name: string): string | nil,
  cookie(name: string): string | nil,
}

declare interface HttpRouterApi {
  use(mw: Middleware): void,
  add(method: string, pattern: string, handler: Handler): void,
  get(pattern: string, handler: Handler): void,
  post(pattern: string, handler: Handler): void,
  put(pattern: string, handler: Handler): void,
  patch(pattern: string, handler: Handler): void,
  delete(pattern: string, handler: Handler): void,
  options(pattern: string, handler: Handler): void,
  head(pattern: string, handler: Handler): void,
  notFound(handler: Handler): void,
  onError(handler: ErrorHandler): void,
  handle(req: HttpRequestApi, res: HttpResponseApi): void,
  count(): integer,
}

declare type StaticOptions = {
  root?: string,
  prefix?: string,
  indexFile?: string,
  maxBytes?: integer,
  dotfiles?: boolean,
  cacheControl?: string,
}

declare interface StaticApi {
  serve(ctx: HttpContextApi): void,
  handler(): Handler,
}

-- ---------------------------------------------------------------------------
-- Parsing
-- ---------------------------------------------------------------------------

declare type HttpError = {
  status: integer,
  message: string,
}

--- One incremental parser step. Exactly one of request/error is set when
--- needMore is false. `expectContinue` asks the server to emit 100 Continue
--- before the body arrives.
declare type ParseOutcome = {
  request: HttpRequestApi | nil,
  error: HttpError | nil,
  needMore: boolean,
  expectContinue: boolean,
}

declare interface HttpRequestParserApi {
  feed(data: string): void,
  next(): ParseOutcome,
  reset(): void,
  buffered(): integer,
  requestActive(): boolean,
}

declare type ParserOptions = {
  maxRequestLine?: integer,
  maxHeaderBytes?: integer,
  maxHeaders?: integer,
  maxBody?: integer,
  maxChunkLine?: integer,
  maxChunks?: integer,
}

-- ---------------------------------------------------------------------------
-- Transport ports (memory for tests, LuaSocket for real TCP)
-- ---------------------------------------------------------------------------

declare type ReadResult = {
  data: string,
  err: string | nil,
  closed: boolean,
  wouldBlock: boolean,
}

declare type WriteResult = {
  written: integer,
  err: string | nil,
  wouldBlock: boolean,
}

declare type ListenResult = {
  listener: HttpListenerApi | nil,
  err: string | nil,
}

declare type AcceptResult = {
  conn: HttpConnectionApi | nil,
  err: string | nil,
  wouldBlock: boolean,
}

declare type SelectResult = {
  readable: HttpConnectionApi[],
  writable: HttpConnectionApi[],
  err: string | nil,
}

declare type TransportAddress = {
  host: string,
  port: integer,
}

declare interface HttpConnectionApi {
  id(): string,
  isReadable(): boolean,
  readAvailable(maxBytes: integer): ReadResult,
  writeSome(data: string): WriteResult,
  close(): void,
  remoteAddress(): string,
}

declare interface HttpListenerApi {
  accept(): AcceptResult,
  close(): void,
  address(): TransportAddress,
}

declare interface HttpSelectorApi {
  select(
    readers: HttpConnectionApi[],
    writers: HttpConnectionApi[],
    timeoutSeconds: number
  ): SelectResult,
}

declare interface HttpTransportApi {
  listen(host: string, port: integer, backlog: integer): ListenResult,
  selector(): HttpSelectorApi,
  now(): number,
}

-- ---------------------------------------------------------------------------
-- Server
-- ---------------------------------------------------------------------------

declare type ServerOptions = {
  maxRequestLine?: integer,
  maxHeaderBytes?: integer,
  maxHeaders?: integer,
  maxBody?: integer,
  maxChunkLine?: integer,
  maxChunks?: integer,
  maxConnections?: integer,
  maxRequestsPerConnection?: integer,
  idleTimeout?: number,
  requestTimeout?: number,
  outBufferLimit?: integer,
  serverName?: string,
  keepAlive?: boolean,
}

declare type ServerStats = {
  connections: integer,
  requests: integer,
  responses: integer,
  bytesIn: integer,
  bytesOut: integer,
}

declare interface HttpServerApi {
  listen(host: string, port: integer): void,
  step(timeoutSeconds: number): void,
  serve(): void,
  close(): void,
  address(): TransportAddress,
  stats(): ServerStats,
}

declare type SerializeOptions = {
  serverName: string,
  keepAlive: boolean,
  requestMethod: string,
  version: string,
}
