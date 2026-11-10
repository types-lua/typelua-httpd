--- Non-blocking HTTP/1.1 server state machine.
---
--- One `step()` accepts pending clients, multiplexes readable/writable
--- connections through the transport selector, parses complete requests,
--- dispatches the router and flushes responses. Keep-alive, pipelining,
--- chunked bodies, 100-continue, limits and idle/request timeouts live here.

import parserMod from "./http_parser"
import responseMod from "./http_response"
import headersMod from "./http_headers"
import h2Mod from "./http_h2_connection"
import wsMod from "./http_websocket"
import statusMod from "./http_status"
import dateMod from "./http_date"

local PHASE_HEAD: integer = 1
local PHASE_BODY: integer = 2
local PHASE_STREAM: integer = 3

local MODE_SNIFF: integer = 1
local MODE_H1: integer = 2
local MODE_H2: integer = 3
local MODE_WS: integer = 4

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
  phase: integer,
  streamReq: HttpRequestApi | nil,
  streamRes: HttpResponseApi | nil,
  streamCo: any,
  streamQueue: string[],
  streamEnded: boolean,
  streamDone: boolean,
  streamBodyComplete: boolean,
  mode: integer,
  sniff: string,
  h2: any,
  ws: any,
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
    o.http2 = optionBool(options.http2, true)
    o.h2c = optionBool(options.h2c, true)
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

    -- LuaSec can buffer decrypted bytes internally, and handshakes can need a
    -- write followed by an immediate completion. Poll such transports before
    -- select and use a short select timeout while they are present.
    local hasPoll: boolean = false
    for _, state in pairs(self.states) do
      if state ~= nil then
        local st: ConnState = state!
        if st.conn:poll() then
          hasPoll = true
          if not st.closing then
            self:handleReadable(st)
          end
        end
      end
    end

    local readers: HttpConnectionApi[] = {}
    local writers: HttpConnectionApi[] = {}
    for _, state in pairs(self.states) do
      if state ~= nil then
        local st: ConnState = state!
        local pending: boolean = st.outPos <= #st.out
        if pending or st.conn:needsWrite() then
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

    local waitSeconds: number = timeoutSeconds
    if hasPoll and waitSeconds > 0.02 then waitSeconds = 0.02 end
    local selected: SelectResult = selector:select(readers, writers, waitSeconds)
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
          phase = PHASE_HEAD,
          streamReq = nil,
          streamRes = nil,
          streamCo = nil,
          streamQueue = {},
          streamEnded = false,
          streamDone = false,
          streamBodyComplete = false,
          mode = MODE_SNIFF,
          sniff = "",
          h2 = nil,
          ws = nil,
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
    -- TLS handshakes that want to write have no application bytes queued yet.
    if st.outPos > #st.out and st.conn:needsWrite() then
      local handshakeWrite: WriteResult = st.conn:writeSome("")
      if handshakeWrite.err ~= nil then
        self:closeState(st)
        return
      end
      st.lastActive = self.transport:now()
    end
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

  startH1(st: ConnState): void
    st.mode = MODE_H1
    local buffered: string = st.sniff
    st.sniff = ""
    if buffered ~= "" then st.parser:feed(buffered) end
  end,

  startH2(st: ConnState): void
    st.mode = MODE_H2
    local buffered: string = st.sniff
    st.sniff = ""
    local h2 = h2Mod.H2Connection.new(
      st.conn,
      self.router,
      self.options,
      self.statsData,
      function(wire: string): void
        if self.states[st.conn:id()] ~= nil then
          self:appendOut(st, wire)
        end
      end
    )
    st.h2 = h2
    if buffered ~= "" then
      local fed: boolean = pcall(function(): void h2:feed(buffered) end)
      if not fed then
        h2:shutdown(h2Mod.H2_INTERNAL_ERROR, "internal error")
        st.closing = true
      end
    end
    if h2:isClosed() then st.closing = true end
  end,

  decideProtocol(st: ConnState): boolean
    local proto: string = st.conn:protocol()
    if proto == "h2" and self.options.http2! then
      self:startH2(st)
      return true
    elseif proto == "http/1.1" or not self.options.http2! then
      self:startH1(st)
      return true
    end
    local buffered: string = st.sniff
    if buffered == "" then
      return false
    end
    if not self.options.h2c! then
      self:startH1(st)
      return true
    end
    local preface: string = h2Mod.PREFACE
    if #buffered < #preface then
      if string.sub(preface, 1, #buffered) == buffered then
        return false
      end
      self:startH1(st)
      return true
    end
    if string.sub(buffered, 1, #preface) == preface then
      self:startH2(st)
    else
      self:startH1(st)
    end
    return true
  end,

  upgradeWebSocket(
    st: ConnState,
    req: HttpRequestApi,
    res: HttpResponseApi,
    handlers: any
  ): void
    res.headers:setIfAbsent("Date", dateMod.httpDate(os.time()))
    local serverName: string = self.options.serverName!
    if serverName ~= "" then
      res.headers:setIfAbsent("Server", serverName)
    end
    res.headers:remove("Content-Length")
    res.headers:remove("Transfer-Encoding")
    local parts: string[] = {
      "HTTP/1.1 101 " .. statusMod.reason(101) .. "\r\n",
    }
    local entries: HeaderEntry[] = res.headers:entries()
    for i: integer = 1, #entries do
      parts[#parts + 1] = entries[i].name .. ": " .. entries[i].value .. "\r\n"
    end
    parts[#parts + 1] = "\r\n"
    st.requests = st.requests + 1
    self.statsData.requests = self.statsData.requests + 1
    self.statsData.responses = self.statsData.responses + 1
    st.continueSent = false
    if not self:appendOut(st, table.concat(parts)) then return end

    local wsOptions: any = {
      emit = function(wire: string): void
        if self.states[st.conn:id()] ~= nil then
          self:appendOut(st, wire)
        end
      end,
      requireMask = true,
    }
    if handlers.onText ~= nil then wsOptions.onText = handlers.onText end
    if handlers.onBinary ~= nil then wsOptions.onBinary = handlers.onBinary end
    if handlers.onClose ~= nil then wsOptions.onClose = handlers.onClose end
    if handlers.maxMessageBytes ~= nil then
      wsOptions.maxMessageBytes = handlers.maxMessageBytes
    end
    if handlers.maxFrameBytes ~= nil then wsOptions.maxFrameBytes = handlers.maxFrameBytes end
    local session = wsMod.WebSocketSession.new(wsOptions)
    st.mode = MODE_WS
    st.ws = session
    st.phase = PHASE_HEAD
    local leftover: string = st.parser:takeBuffered()
    if leftover ~= "" then session:feed(leftover) end
    if handlers.onOpen ~= nil then
      local opened: boolean = pcall(function(): void
        handlers.onOpen!(session)
      end)
      if not opened then
        session:close(1011, "open handler failed")
      end
    end
    if session:isClosed() then st.closing = true end
    if st.inputClosed then st.closing = true end
  end,

  sendError(st: ConnState, code: integer, message: string): boolean
    local opts: SerializeOptions = {
      serverName = self.options.serverName!,
      keepAlive = false,
      requestMethod = "GET",
      version = "1.1",
    }
    if not self:appendOut(st, responseMod.errorResponse(code, message, opts)) then
      return false
    end
    st.closing = true
    return true
  end,

  finalizeResponse(
    st: ConnState,
    req: HttpRequestApi,
    res: HttpResponseApi,
    allowKeep: boolean
  ): boolean
    local keep: boolean = allowKeep and self.options.keepAlive!
      and req.keepAlive and not st.closing
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
      requestMethod = req.method,
      version = req.version,
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
    if not self:appendOut(st, wireText) then
      return false
    end
    return keep
  end,

  clearStream(st: ConnState): void
    st.phase = PHASE_HEAD
    st.streamReq = nil
    st.streamRes = nil
    st.streamCo = nil
    st.streamQueue = {}
    st.streamEnded = false
    st.streamDone = false
    st.streamBodyComplete = false
  end,

  resumeStreaming(st: ConnState): void
    local co: any = st.streamCo
    if co == nil or st.streamDone then return end
    local callOk: boolean = false
    local resumeOk: any = nil
    local resumeValue: any = nil
    callOk, resumeOk, resumeValue = pcall(coroutine.resume, co)
    if not callOk or resumeOk ~= true then
      st.streamDone = true
      local res: HttpResponseApi | nil = st.streamRes
      if res ~= nil then
        res!.status = 500
        res!.headers:set("Content-Type", "text/plain; charset=utf-8")
        res!.body = "Internal Server Error\n"
      end
      return
    end
    if coroutine.status(co) == "dead" then
      st.streamDone = true
    end
  end,

  startStreaming(st: ConnState, req: HttpRequestApi): void
    local res = responseMod.HttpResponse.new(200)
    st.phase = PHASE_STREAM
    st.streamReq = req
    st.streamRes = res
    st.streamQueue = {}
    st.streamEnded = false
    st.streamDone = false
    st.streamBodyComplete = false
    local function bodyReader(): string | nil
      while #st.streamQueue == 0 and not st.streamEnded do
        coroutine.yield("body")
      end
      if #st.streamQueue > 0 then
        local chunk: string = table.remove(st.streamQueue, 1)!
        return chunk
      end
      return nil
    end
    st.streamCo = coroutine.create(function(): void
      self.router:handleStream(req, res, bodyReader)
    end)
    self:resumeStreaming(st)
  end,

  finalizeStreaming(st: ConnState, bodyComplete: boolean): void
    local req: HttpRequestApi | nil = st.streamReq
    local res: HttpResponseApi | nil = st.streamRes
    if req == nil or res == nil then
      self:clearStream(st)
      return
    end
    local keep: boolean = self:finalizeResponse(st, req!, res!, bodyComplete)
    self:clearStream(st)
    if not keep then
      st.closing = true
    end
  end,

  --- Drives a streaming request until it needs more bytes or finishes.
  --- Returns true when the request reached a terminal state.
  driveStreaming(st: ConnState): boolean
    while true do
      local ev: ParseEvent = st.parser:nextEvent()
      if ev.kind == "needMore" then
        return false
      elseif ev.kind == "body" then
        st.streamQueue[#st.streamQueue + 1] = ev.chunk
        self:resumeStreaming(st)
        if st.streamDone then
          self:finalizeStreaming(st, false)
          return true
        end
      elseif ev.kind == "end" then
        st.streamBodyComplete = true
        st.streamEnded = true
        self:resumeStreaming(st)
        self:finalizeStreaming(st, true)
        return true
      elseif ev.kind == "error" then
        local e: HttpError = ev.error!
        self:clearStream(st)
        st.streamCo = nil
        self:sendError(st, e.status, e.message)
        return true
      else
        self:clearStream(st)
        self:sendError(st, 500, "invalid parser event")
        return true
      end
    end
  end,

  handleReadable(st: ConnState): void
    local read: ReadResult = st.conn:readAvailable(65536)
    if read.err ~= nil then
      self:closeState(st)
      return
    end
    local data: string = read.data
    if data ~= "" then
      self.statsData.bytesIn = self.statsData.bytesIn + #data
      st.lastActive = self.transport:now()
    end
    if read.closed then
      st.inputClosed = true
    end

    if st.mode == MODE_SNIFF then
      st.sniff = st.sniff .. data
      data = ""
      if not self:decideProtocol(st) then
        if st.inputClosed then
          self:closeState(st)
        end
        return
      end
    end

    if st.mode == MODE_WS then
      local session: any = st.ws
      if session ~= nil then
        if data ~= "" then
          local fed: boolean = pcall(function(): void session:feed(data) end)
          if not fed then
            pcall(function(): void session:close(1011, "websocket handler error") end)
          end
        end
        if st.inputClosed or session:isClosed() then st.closing = true end
      else
        st.closing = true
      end
      self:flush(st)
      return
    elseif st.mode == MODE_H2 then
      local h2: any = st.h2
      if h2 ~= nil then
        if data ~= "" then
          local fed: boolean = pcall(function(): void h2:feed(data) end)
          if not fed then
            h2:shutdown(h2Mod.H2_INTERNAL_ERROR, "internal error")
            st.closing = true
          end
        end
        if st.inputClosed then
          h2:inputClosed()
          st.closing = true
        end
        if h2:isClosed() then st.closing = true end
      else
        st.closing = true
      end
      self:flush(st)
      return
    elseif st.mode == MODE_H1 then
      if data ~= "" then st.parser:feed(data) end
    end

    local guard: integer = 0
    while true do
      guard = guard + 1
      if guard > 10000 then
        self:closeState(st)
        return
      end

      if st.phase == PHASE_HEAD then
        local outcome: ParseOutcome = st.parser:peekHeaders()
        if outcome.expectContinue and not st.continueSent then
          st.continueSent = true
          if not self:appendOut(st, "HTTP/1.1 100 Continue\r\n\r\n") then return end
          -- Loop again: the body may already be buffered and the request
          -- object is created by the next parser event.
        elseif outcome.needMore then
          break
        elseif outcome.error ~= nil then
          local e: HttpError = outcome.error!
          self:sendError(st, e.status, e.message)
          break
        else
          local req: HttpRequestApi | nil = outcome.request
          if req == nil then
            st.closing = true
            break
          end
          req!.remote = st.conn:remoteAddress()
          if self.router:isStreaming(req!.method, req!.path) then
            self:startStreaming(st, req!)
            if st.streamDone then
              self:finalizeStreaming(st, false)
              if st.closing then break end
            end
          else
            st.phase = PHASE_BODY
          end
        end
      elseif st.phase == PHASE_BODY then
        local outcome: ParseOutcome = st.parser:next()
        if outcome.needMore then
          break
        elseif outcome.error ~= nil then
          local e: HttpError = outcome.error!
          self:sendError(st, e.status, e.message)
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
        local upgrade: any = nil
        local responseAny: any = res
        upgrade = responseAny.websocket
        if res.status == 101 and upgrade ~= nil then
          self:upgradeWebSocket(st, req!, res, upgrade)
          break
        end
        local keep: boolean = self:finalizeResponse(st, req!, res, true)
        st.phase = PHASE_HEAD
        if not keep then
          st.closing = true
          break
        end
      elseif st.phase == PHASE_STREAM then
        local finished: boolean = self:driveStreaming(st)
        if not finished then
          break
        end
        if st.closing then
          break
        end
      else
        st.closing = true
        break
      end
    end

    if st.inputClosed and not st.closing then
      if st.phase == PHASE_STREAM and not st.streamBodyComplete then
        self:clearStream(st)
        self:sendError(st, 400, "Incomplete Request")
      elseif st.phase == PHASE_BODY and st.parser:requestActive() then
        self:sendError(st, 400, "Incomplete Request")
      elseif st.phase == PHASE_HEAD and st.parser:requestActive() then
        self:sendError(st, 400, "Incomplete Request")
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
        local any: boolean = active
        if st.mode == MODE_SNIFF then
          active = st.sniff ~= "" or st.conn:needsHandshake()
          any = active
        elseif st.mode == MODE_WS then
          active = true
          any = true
        elseif st.mode == MODE_H2 and st.h2 ~= nil then
          active = st.h2:requestActive()
          any = st.h2:active()
        end
        if not st.closing and active and idle > self.options.requestTimeout! then
          if st.mode == MODE_H2 and st.h2 ~= nil then
            st.h2:shutdown(h2Mod.H2_NO_ERROR, "request timeout")
            st.closing = true
            self:flush(st)
          else
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
          end
        elseif not st.closing and not any and idle > self.options.idleTimeout! then
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
