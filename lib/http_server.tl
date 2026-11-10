--- Non-blocking HTTP/1.1 server state machine.
---
--- One `step()` accepts pending clients, multiplexes readable/writable
--- connections through the transport selector, parses complete requests,
--- dispatches the router and flushes responses. Keep-alive, pipelining,
--- chunked bodies, 100-continue, limits and idle/request timeouts live here.

import parserMod from "./http_parser"
import responseMod from "./http_response"
import headersMod from "./http_headers"

type ConnState = {
  conn: HttpConnectionApi,
  parser: HttpRequestParserApi,
  out: string,
  outPos: integer,
  closing: boolean,
  inputClosed: boolean,
  requests: integer,
  lastActive: number,
  continueSent: boolean,
}

local function optionInt(value: integer | nil, fallback: integer): integer
  if value == nil then return fallback end
  return value!
end

local function optionNumber(value: number | nil, fallback: number): number
  if value == nil then return fallback end
  return value!
end

local function optionBool(value: boolean | nil, fallback: boolean): boolean
  if value == nil then return fallback end
  return value!
end

local function hasToken(value: string, token: string): boolean
  local wanted: string = string.lower(token)
  for part in string.gmatch(value, "[^,]+") do
    local item: string = string.lower(part)
    while #item > 0 and (string.sub(item, 1, 1) == " " or string.sub(item, 1, 1) == "\t") do
      item = string.sub(item, 2)
    end
    while #item > 0 and (string.sub(item, -1) == " " or string.sub(item, -1) == "\t") do
      item = string.sub(item, 1, -2)
    end
    if item == wanted then return true end
  end
  return false
end

class HttpServer implements HttpServerApi {
  transport: HttpTransportApi,
  router: HttpRouterApi,
  options: ServerOptions,
  parserOptions: ParserOptions,
  listener: HttpListenerApi | nil = nil,
  selector: HttpSelectorApi | nil = nil,
  states: map<string, ConnState | nil> = {},
  connCount: integer = 0,
  statsData: ServerStats = {
    connections = 0,
    requests = 0,
    responses = 0,
    bytesIn = 0,
    bytesOut = 0,
  },

  constructor(router: HttpRouterApi, transport: HttpTransportApi, options: ServerOptions)
    self.router = router
    self.transport = transport
    local o: ServerOptions = {}
    o.maxRequestLine = optionInt(options.maxRequestLine, 8192)
    o.maxHeaderBytes = optionInt(options.maxHeaderBytes, 32768)
    o.maxHeaders = optionInt(options.maxHeaders, 100)
    o.maxBody = optionInt(options.maxBody, 1048576)
    o.maxChunkLine = optionInt(options.maxChunkLine, 128)
    o.maxChunks = optionInt(options.maxChunks, 10000)
    o.maxConnections = optionInt(options.maxConnections, 1024)
    o.maxRequestsPerConnection = optionInt(options.maxRequestsPerConnection, 1000)
    o.idleTimeout = optionNumber(options.idleTimeout, 75)
    o.requestTimeout = optionNumber(options.requestTimeout, 30)
    o.outBufferLimit = optionInt(options.outBufferLimit, 16 * 1024 * 1024)
    local serverName: string | nil = options.serverName
    if serverName == nil then
      o.serverName = "typelua-httpd"
    else
      o.serverName = serverName!
    end
    o.keepAlive = optionBool(options.keepAlive, true)
    if not headersMod.validValue(o.serverName!) then
      error("serverName contains CR/LF/NUL")
    end
    if o.maxConnections! < 1 then error("maxConnections must be >= 1") end
    if o.maxRequestsPerConnection! < 1 then error("maxRequestsPerConnection must be >= 1") end
    if o.maxBody! < 0 then error("maxBody must be >= 0") end
    if o.outBufferLimit! < 1024 then error("outBufferLimit must be >= 1024") end
    self.options = o
    local p: ParserOptions = {
      maxRequestLine = o.maxRequestLine!,
      maxHeaderBytes = o.maxHeaderBytes!,
      maxHeaders = o.maxHeaders!,
      maxBody = o.maxBody!,
      maxChunkLine = o.maxChunkLine!,
      maxChunks = o.maxChunks!,
    }
    self.parserOptions = p
  end,

  listen(host: string, port: integer): void
    local result: ListenResult = self.transport:listen(host, port, 128)
    if result.listener == nil then
      error("listen failed: " .. tostring(result.err))
    end
    self.listener = result.listener
    self.selector = self.transport:selector()
  end,

  address(): TransportAddress
    local current: HttpListenerApi | nil = self.listener
    if current == nil then
      return { host = "", port = 0 }
    end
    return current:address()
  end,

  stats(): ServerStats
    return {
      connections = self.statsData.connections,
      requests = self.statsData.requests,
      responses = self.statsData.responses,
      bytesIn = self.statsData.bytesIn,
      bytesOut = self.statsData.bytesOut,
    }
  end,

  close(): void
    local current: HttpListenerApi | nil = self.listener
    if current ~= nil then
      current:close()
    end
    self.listener = nil
    for _, state in pairs(self.states) do
      if state ~= nil then
        state!.conn:close()
      end
    end
    self.states = {}
    self.connCount = 0
  end,

  serve(): void
    while self.listener ~= nil do
      self:step(0.25)
    end
  end,

  step(timeoutSeconds: number): void
    local selector: HttpSelectorApi | nil = self.selector
    if self.listener == nil or selector == nil then
      return
    end
    self:acceptPending()

    local readers: HttpConnectionApi[] = {}
    local writers: HttpConnectionApi[] = {}
    for _, state in pairs(self.states) do
      if state ~= nil then
        local st: ConnState = state!
        local pending: boolean = st.outPos <= #st.out
        if pending then
          writers[#writers + 1] = st.conn
        end
        if not st.closing then
          readers[#readers + 1] = st.conn
        end
        if not pending and (st.closing or st.inputClosed) then
          self:closeState(st)
        end
      end
    end

    local selected: SelectResult = selector:select(readers, writers, timeoutSeconds)
    if selected.err ~= nil then
      return
    end
    for i: integer = 1, #selected.readable do
      local st: ConnState | nil = self.states[selected.readable[i]:id()]
      if st ~= nil then
        self:handleReadable(st!)
      end
    end
    for i: integer = 1, #selected.writable do
      local st: ConnState | nil = self.states[selected.writable[i]:id()]
      if st ~= nil then
        self:flush(st!)
      end
    end
    self:checkTimeouts()
  end,

  acceptPending(): void
    local listener: HttpListenerApi | nil = self.listener
    if listener == nil then return end
    while true do
      local accepted: AcceptResult = listener:accept()
      if accepted.conn == nil then
        if accepted.err ~= nil and not accepted.wouldBlock then
          return
        end
        return
      end
      local conn: HttpConnectionApi = accepted.conn!
      if self.connCount >= self.options.maxConnections! then
        self:rejectConnection(conn)
      else
        local st: ConnState = {
          conn = conn,
          parser = parserMod.HttpRequestParser.new(self.parserOptions),
          out = "",
          outPos = 1,
          closing = false,
          inputClosed = false,
          requests = 0,
          lastActive = self.transport:now(),
          continueSent = false,
        }
        self.states[conn:id()] = st
        self.connCount = self.connCount + 1
        self.statsData.connections = self.statsData.connections + 1
      end
    end
  end,

  rejectConnection(conn: HttpConnectionApi): void
    local opts: SerializeOptions = {
      serverName = self.options.serverName!,
      keepAlive = false,
      requestMethod = "GET",
      version = "1.1",
    }
    local wire: string = responseMod.errorResponse(503, "Service Unavailable", opts)
    conn:writeSome(wire)
    conn:close()
  end,

  appendOut(st: ConnState, text: string): boolean
    if st.outPos > #st.out then
      st.out = text
      st.outPos = 1
    else
      st.out = st.out .. text
    end
    local pending: integer = #st.out - st.outPos + 1
    if pending > self.options.outBufferLimit! then
      self:closeState(st)
      return false
    end
    return true
  end,

  flush(st: ConnState): void
    if self.states[st.conn:id()] == nil then return end
    while st.outPos <= #st.out do
      local chunk: string = string.sub(st.out, st.outPos)
      local result: WriteResult = st.conn:writeSome(chunk)
      if result.err ~= nil then
        self:closeState(st)
        return
      end
      if result.written > 0 then
        st.outPos = st.outPos + result.written
        self.statsData.bytesOut = self.statsData.bytesOut + result.written
        st.lastActive = self.transport:now()
      end
      if result.wouldBlock or result.written == 0 then
        break
      end
    end
    if st.outPos > #st.out then
      st.out = ""
      st.outPos = 1
      if st.closing or st.inputClosed then
        self:closeState(st)
      end
    end
  end,

  handleReadable(st: ConnState): void
    local read: ReadResult = st.conn:readAvailable(65536)
    if read.err ~= nil then
      self:closeState(st)
      return
    end
    if read.data ~= "" then
      st.parser:feed(read.data)
      self.statsData.bytesIn = self.statsData.bytesIn + #read.data
      st.lastActive = self.transport:now()
    end
    if read.closed then
      st.inputClosed = true
    end

    local guard: integer = 0
    while true do
      guard = guard + 1
      if guard > 10000 then
        self:closeState(st)
        return
      end
      local outcome: ParseOutcome = st.parser:next()
      local sentContinue: boolean = false
      if outcome.expectContinue and not st.continueSent then
        st.continueSent = true
        sentContinue = true
        if not self:appendOut(st, "HTTP/1.1 100 Continue\r\n\r\n") then return end
      end
      if outcome.needMore then
        -- Once 100 Continue is on the wire the body may already be buffered
        -- behind the headers, so give the parser one more chance before
        -- waiting for another readable event that may never come.
        if sentContinue then
          outcome = st.parser:next()
        end
        if outcome.needMore then
          break
        end
      end
      if outcome.error ~= nil then
        local e: HttpError = outcome.error!
        local opts: SerializeOptions = {
          serverName = self.options.serverName!,
          keepAlive = false,
          requestMethod = "GET",
          version = "1.1",
        }
        if not self:appendOut(st, responseMod.errorResponse(e.status, e.message, opts)) then
          return
        end
        st.closing = true
        break
      end
      local req: HttpRequestApi | nil = outcome.request
      if req == nil then
        st.closing = true
        break
      end
      req!.remote = st.conn:remoteAddress()
      local res = responseMod.HttpResponse.new(200)
      local ok = pcall(function(): void
        self.router:handle(req!, res)
      end)
      if not ok then
        res = responseMod.HttpResponse.new(500)
        res.headers:set("Content-Type", "text/plain; charset=utf-8")
        res.body = "Internal Server Error\n"
      end

      local keep: boolean = self.options.keepAlive! and req!.keepAlive and not st.closing
      if st.requests + 1 >= self.options.maxRequestsPerConnection! then
        keep = false
      end
      local connectionHeader: string | nil = res.headers:get("Connection")
      if connectionHeader ~= nil and hasToken(connectionHeader!, "close") then
        keep = false
      end
      if res.status == 101 then
        keep = false
      end
      local opts: SerializeOptions = {
        serverName = self.options.serverName!,
        keepAlive = keep,
        requestMethod = req!.method,
        version = req!.version,
      }
      local serializedOk: boolean = false
      local serializedValue: any = nil
      serializedOk, serializedValue = pcall(function(): string
        return responseMod.serialize(res, opts)
      end)
      local wireText: string
      if not serializedOk then
        local errorOpts: SerializeOptions = {
          serverName = self.options.serverName!,
          keepAlive = false,
          requestMethod = "GET",
          version = "1.1",
        }
        wireText = responseMod.errorResponse(500, "Internal Server Error", errorOpts)
        keep = false
      else
        wireText = tostring(serializedValue)
      end
      st.requests = st.requests + 1
      self.statsData.requests = self.statsData.requests + 1
      self.statsData.responses = self.statsData.responses + 1
      st.continueSent = false
      if not self:appendOut(st, wireText) then return end
      if not keep then
        st.closing = true
        break
      end
      -- A client may half-close after sending pipelined requests; keep parsing
      -- the buffered bytes so every complete request receives a response.
    end

    if st.inputClosed and not st.closing then
      if st.parser:requestActive() then
        local opts: SerializeOptions = {
          serverName = self.options.serverName!,
          keepAlive = false,
          requestMethod = "GET",
          version = "1.1",
        }
        if not self:appendOut(st, responseMod.errorResponse(400, "Incomplete Request", opts)) then
          return
        end
        st.closing = true
      elseif st.outPos > #st.out then
        self:closeState(st)
        return
      end
    end
    self:flush(st)
  end,

  checkTimeouts(): void
    local now: number = self.transport:now()
    for _, state in pairs(self.states) do
      if state ~= nil then
        local st: ConnState = state!
        local idle: number = now - st.lastActive
        local active: boolean = st.parser:requestActive()
        if not st.closing and active and idle > self.options.requestTimeout! then
          local opts: SerializeOptions = {
            serverName = self.options.serverName!,
            keepAlive = false,
            requestMethod = "GET",
            version = "1.1",
          }
          if self:appendOut(st, responseMod.errorResponse(408, "Request Timeout", opts)) then
            st.closing = true
            self:flush(st)
          end
        elseif not st.closing and not active and idle > self.options.idleTimeout! then
          self:closeState(st)
        end
      end
    end
  end,

  closeState(st: ConnState): void
    local id: string = st.conn:id()
    if self.states[id] == nil then return end
    self.states[id] = nil
    if self.connCount > 0 then
      self.connCount = self.connCount - 1
    end
    st.conn:close()
  end,
}

return { HttpServer = HttpServer }
