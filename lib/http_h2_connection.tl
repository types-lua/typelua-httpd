--- Server-side HTTP/2 connection state machine (RFC 7540).
---
--- Scope: request streams, HPACK header blocks with CONTINUATION, settings,
--- ping, rst/goaway, connection and stream flow control, response DATA
--- scheduling, request body limits, buffered and coroutine-streaming routes.
--- Server push and priority scheduling are intentionally not implemented.

import frameMod from "./http_h2_frame"
import hpack from "./http_hpack"
import headersMod from "./http_headers"
import requestMod from "./http_request"
import responseMod from "./http_response"
import url from "./http_url"
import date from "./http_date"
import statusMod from "./http_status"

local PREFACE: string = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

type H2Stream = {
  id: integer,
  req: HttpRequestApi | nil,
  headersDone: boolean,
  endStream: boolean,
  bodyParts: string[],
  bodySize: integer,
  contentLength: integer,
  streaming: boolean,
  streamCo: any,
  streamQueue: string[],
  streamEnded: boolean,
  streamDone: boolean,
  bodyComplete: boolean,
  res: HttpResponseApi | nil,
  responseStarted: boolean,
  pendingBody: string,
  pendingOffset: integer,
  sendWindow: integer,
  counted: boolean,
}

local function newStream(id: integer, sendWindow: integer): H2Stream
  return {
    id = id,
    req = nil,
    headersDone = false,
    endStream = false,
    bodyParts = {},
    bodySize = 0,
    contentLength = -1,
    streaming = false,
    streamCo = nil,
    streamQueue = {},
    streamEnded = false,
    streamDone = false,
    bodyComplete = false,
    res = nil,
    responseStarted = false,
    pendingBody = "",
    pendingOffset = 1,
    sendWindow = sendWindow,
    counted = false,
  }
end

class H2Connection {
  conn: HttpConnectionApi,
  router: HttpRouterApi,
  options: ServerOptions,
  stats: ServerStats,
  emit: (wire: string) -> void,
  parser: any,
  decoder: any,
  streams: map<integer, H2Stream | nil> = {},
  activeStreams: integer = 0,
  lastStreamId: integer = 0,
  prefaceDone: boolean = false,
  prefaceBuf: string = "",
  closed: boolean = false,
  closing: boolean = false,
  peerMaxFrameSize: integer = 16384,
  peerInitialWindow: integer = 65535,
  sendWindow: integer = 65535,
  headerStream: integer = 0,
  headerBlock: string = "",
  expectingContinuation: boolean = false,
  settingsAcked: boolean = false,

  constructor(
    conn: HttpConnectionApi,
    router: HttpRouterApi,
    options: ServerOptions,
    stats: ServerStats,
    emit: (wire: string) -> void
  )
    self.conn = conn
    self.router = router
    self.options = options
    self.stats = stats
    self.emit = emit
    self.parser = frameMod.H2FrameParser.new(16384)
    self.decoder = hpack.HpackDecoder.new()
    local settings = frameMod.settingsPayload({
      { id = 1, value = 4096 },
      { id = 2, value = 0 },
      { id = 3, value = 100 },
      { id = 4, value = 65535 },
      { id = 5, value = 16384 },
      { id = 6, value = 65536 },
    })
    self:sendFrame(frameMod.FRAME_SETTINGS, 0, 0, settings)
  end,

  isClosed(): boolean
    return self.closed
  end,

  shutdown(code: integer, message: string): void
    self:connectionError(code, message)
  end,

  active(): boolean
    return self.activeStreams > 0 or not self.prefaceDone
  end,

  prefaceComplete(): boolean
    return self.prefaceDone
  end,

  requestActive(): boolean
    if not self.prefaceDone then return true end
    for _, stream in pairs(self.streams) do
      if stream ~= nil and not stream!.bodyComplete then return true end
    end
    return false
  end,

  sendFrame(frameType: integer, flags: integer, streamId: integer, payload: string): void
    if self.closed then return end
    self.emit(frameMod.encodeFrame(frameType, flags, streamId, payload))
  end,

  connectionError(code: integer, message: string): void
    if self.closed then return end
    self:sendFrame(
      frameMod.FRAME_GOAWAY,
      0,
      0,
      frameMod.goawayPayload(self.lastStreamId, code, message)
    )
    self.closing = true
    self.closed = true
  end,

  streamError(stream: H2Stream, code: integer): void
    if stream.id == 0 then return end
    self:sendFrame(frameMod.FRAME_RST_STREAM, 0, stream.id, frameMod.rstStreamPayload(code))
    self:dropStream(stream)
  end,

  dropStream(stream: H2Stream): void
    if self.streams[stream.id] == nil then return end
    self.streams[stream.id] = nil
    if self.activeStreams > 0 then self.activeStreams = self.activeStreams - 1 end
    stream.streamCo = nil
    stream.streamDone = true
  end,

  feed(data: string): void
    if self.closed then return end
    if not self.prefaceDone then
      self.prefaceBuf = self.prefaceBuf .. data
      if #self.prefaceBuf < #PREFACE then
        if string.sub(PREFACE, 1, #self.prefaceBuf) ~= self.prefaceBuf then
          self:connectionError(frameMod.H2_PROTOCOL_ERROR, "invalid connection preface")
        end
        return
      end
      if string.sub(self.prefaceBuf, 1, #PREFACE) ~= PREFACE then
        self:connectionError(frameMod.H2_PROTOCOL_ERROR, "invalid connection preface")
        return
      end
      local rest: string = string.sub(self.prefaceBuf, #PREFACE + 1)
      self.prefaceBuf = ""
      self.prefaceDone = true
      self.parser:feed(rest)
    else
      self.parser:feed(data)
    end
    self:processFrames()
  end,

  inputClosed(): void
    if self.closed then return end
    self.closing = true
  end,

  processFrames(): void
    if self.closed then return end
    while true do
      local read: any = self.parser:next()
      if read.err ~= nil and #read.err > 0 then
        self:connectionError(frameMod.H2_FRAME_SIZE_ERROR, read.err)
        return
      end
      if read.needMore then return end
      local frame: any = read.frame
      if self.expectingContinuation and frame.frameType ~= frameMod.FRAME_CONTINUATION then
        self:connectionError(frameMod.H2_PROTOCOL_ERROR, "expected CONTINUATION")
        return
      end
      self:handleFrame(frame)
      if self.closed then return end
    end
  end,

  handleFrame(frame: any): void
    local t: integer = frame.frameType
    if t == frameMod.FRAME_SETTINGS then
      self:handleSettings(frame)
    elseif t == frameMod.FRAME_PING then
      self:handlePing(frame)
    elseif t == frameMod.FRAME_GOAWAY then
      if frame.streamId ~= 0 or frame.length < 8 then
        self:connectionError(frameMod.H2_PROTOCOL_ERROR, "invalid GOAWAY")
        return
      end
      self.closing = true
      self.closed = true
    elseif t == frameMod.FRAME_WINDOW_UPDATE then
      self:handleWindowUpdate(frame)
    elseif t == frameMod.FRAME_RST_STREAM then
      if frame.streamId == 0 or frame.length ~= 4 then
        self:connectionError(frameMod.H2_PROTOCOL_ERROR, "invalid RST_STREAM")
        return
      end
      local stream: H2Stream | nil = self.streams[frame.streamId]
      if stream ~= nil then self:dropStream(stream!) end
    elseif t == frameMod.FRAME_PRIORITY then
      if frame.streamId == 0 or frame.length ~= 5 then
        self:connectionError(frameMod.H2_PROTOCOL_ERROR, "invalid PRIORITY")
      end
    elseif t == frameMod.FRAME_PUSH_PROMISE then
      self:connectionError(frameMod.H2_PROTOCOL_ERROR, "client sent PUSH_PROMISE")
    elseif t == frameMod.FRAME_HEADERS then
      self:handleHeaders(frame)
    elseif t == frameMod.FRAME_CONTINUATION then
      self:handleContinuation(frame)
    elseif t == frameMod.FRAME_DATA then
      self:handleData(frame)
    end
  end,

  handleSettings(frame: any): void
    if frame.streamId ~= 0 then
      self:connectionError(frameMod.H2_PROTOCOL_ERROR, "SETTINGS on a stream")
      return
    end
    if frame.flags % 2 == 1 then
      if frame.length ~= 0 then
        self:connectionError(frameMod.H2_FRAME_SIZE_ERROR, "SETTINGS ACK with payload")
        return
      end
      self.settingsAcked = true
      return
    end
    local settings: any = nil
    local ok: boolean = false
    ok, settings = pcall(frameMod.parseSettings, frame.payload)
    if not ok then
      self:connectionError(frameMod.H2_FRAME_SIZE_ERROR, "malformed SETTINGS")
      return
    end
    for i: integer = 1, #settings do
      local setting = settings[i]
      if setting.id == 4 then
        if setting.value > 2147483647 then
          self:connectionError(frameMod.H2_FLOW_CONTROL_ERROR, "invalid initial window")
          return
        end
        local delta: integer = math.floor(setting.value - self.peerInitialWindow)
        self.peerInitialWindow = setting.value
        for _, stream in pairs(self.streams) do
          if stream ~= nil then
            local nextWindow: integer = math.floor(stream!.sendWindow + delta)
            if nextWindow > 2147483647 then
              self:connectionError(frameMod.H2_FLOW_CONTROL_ERROR, "stream window overflow")
              return
            end
            stream!.sendWindow = nextWindow
          end
        end
      elseif setting.id == 2 then
        if setting.value > 1 then
          self:connectionError(frameMod.H2_PROTOCOL_ERROR, "invalid ENABLE_PUSH")
          return
        end
      elseif setting.id == 5 then
        if setting.value < 16384 or setting.value > 16777215 then
          self:connectionError(frameMod.H2_PROTOCOL_ERROR, "invalid max frame size")
          return
        end
        self.peerMaxFrameSize = setting.value
      end
    end
    self:sendFrame(frameMod.FRAME_SETTINGS, frameMod.FLAG_ACK, 0, "")
    self:pumpAll()
  end,

  handlePing(frame: any): void
    if frame.streamId ~= 0 or frame.length ~= 8 then
      self:connectionError(frameMod.H2_PROTOCOL_ERROR, "invalid PING")
      return
    end
    if frame.flags % 2 == 0 then
      self:sendFrame(frameMod.FRAME_PING, frameMod.FLAG_ACK, 0, frame.payload)
    end
  end,

  handleWindowUpdate(frame: any): void
    if frame.length ~= 4 then
      self:connectionError(frameMod.H2_FRAME_SIZE_ERROR, "invalid WINDOW_UPDATE")
      return
    end
    local increment: integer = math.floor(frameMod.readU32(frame.payload, 1) % 2147483648)
    if increment == 0 then
      self:connectionError(frameMod.H2_PROTOCOL_ERROR, "zero window increment")
      return
    end
    if frame.streamId == 0 then
      self.sendWindow = self.sendWindow + increment
      if self.sendWindow > 2147483647 then
        self:connectionError(frameMod.H2_FLOW_CONTROL_ERROR, "connection window overflow")
        return
      end
    else
      local stream: H2Stream | nil = self.streams[frame.streamId]
      if stream ~= nil then
        stream!.sendWindow = stream!.sendWindow + increment
        if stream!.sendWindow > 2147483647 then
          self:streamError(stream!, frameMod.H2_FLOW_CONTROL_ERROR)
          return
        end
        self:pumpStream(stream!)
      end
    end
    if frame.streamId == 0 then self:pumpAll() end
  end,

  headerFragment(frame: any): (string, string)
    local payload: string = frame.payload
    local at: integer = 1
    local endAt: integer = #payload
    if frame.flags % 16 >= 8 then
      if payload == "" then return "", "padded HEADERS without pad length" end
      local pad: integer = string.byte(payload, 1)!
      at = 2
      endAt = #payload - pad
      if endAt < at - 1 then return "", "invalid HEADERS padding" end
    end
    if math.floor(frame.flags / 32) % 2 == 1 then
      if endAt - at + 1 < 5 then return "", "truncated HEADERS priority" end
      at = at + 5
    end
    return string.sub(payload, at, endAt), ""
  end,

  handleHeaders(frame: any): void
    if frame.streamId == 0 then
      self:connectionError(frameMod.H2_PROTOCOL_ERROR, "HEADERS on stream 0")
      return
    end
    if frame.streamId % 2 == 0 then
      self:connectionError(frameMod.H2_PROTOCOL_ERROR, "client stream id must be odd")
      return
    end
    local existing: H2Stream | nil = self.streams[frame.streamId]
    local stream: H2Stream
    if existing == nil then
      if frame.streamId <= self.lastStreamId then
        self:connectionError(frameMod.H2_PROTOCOL_ERROR, "stream id did not increase")
        return
      end
      if self.activeStreams >= 100 then
        self:sendFrame(
          frameMod.FRAME_RST_STREAM,
          0,
          frame.streamId,
          frameMod.rstStreamPayload(frameMod.H2_REFUSED_STREAM)
        )
        return
      end
      self.lastStreamId = frame.streamId
      local created: H2Stream = newStream(frame.streamId, self.peerInitialWindow)
      self.streams[frame.streamId] = created
      self.activeStreams = self.activeStreams + 1
      stream = created
    else
      if existing!.headersDone then
        self:streamError(existing!, frameMod.H2_PROTOCOL_ERROR)
        return
      end
      stream = existing!
    end
    local fragment, perr = self:headerFragment(frame)
    if perr ~= "" then
      self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
      return
    end
    if #fragment > 65536 then
      self:connectionError(frameMod.H2_ENHANCE_YOUR_CALM, "header block too large")
      return
    end
    self.headerStream = frame.streamId
    self.headerBlock = fragment
    self.expectingContinuation = math.floor(frame.flags / 4) % 2 == 0
    if frame.flags % 2 == 1 then
      stream.endStream = true
    end
    if not self.expectingContinuation then
      self:finishHeaders(stream)
    end
  end,

  handleContinuation(frame: any): void
    if not self.expectingContinuation or frame.streamId ~= self.headerStream then
      self:connectionError(frameMod.H2_PROTOCOL_ERROR, "unexpected CONTINUATION")
      return
    end
    if #self.headerBlock + #frame.payload > 65536 then
      self:connectionError(frameMod.H2_ENHANCE_YOUR_CALM, "header block too large")
      return
    end
    self.headerBlock = self.headerBlock .. frame.payload
    self.expectingContinuation = math.floor(frame.flags / 4) % 2 == 0
    if not self.expectingContinuation then
      local stream: H2Stream | nil = self.streams[self.headerStream]
      if stream == nil then
        self:connectionError(frameMod.H2_PROTOCOL_ERROR, "CONTINUATION lost its stream")
        return
      end
      self:finishHeaders(stream!)
    end
  end,

  findHeader(headers: any[], name: string): string | nil
    for i: integer = 1, #headers do
      if headers[i].name == name then return headers[i].value end
    end
    return nil
  end,

  finishHeaders(stream: H2Stream): void
    local decoded: any = self.decoder:decode(self.headerBlock)
    self.headerBlock = ""
    self.headerStream = 0
    if decoded.error ~= "" then
      self:connectionError(frameMod.H2_COMPRESSION_ERROR, decoded.error)
      return
    end
    local list: any[] = decoded.headers
    local method: string = ""
    local path: string = ""
    local scheme: string = ""
    local authority: string = ""
    local haveMethod: boolean = false
    local havePath: boolean = false
    local haveScheme: boolean = false
    local haveAuthority: boolean = false
    local regular: boolean = false
    local outHeaders = headersMod.Headers.new()
    local contentLength: integer = -1
    for i: integer = 1, #list do
      local name: string = list[i].name
      local value: string = list[i].value
      if string.lower(name) ~= name then
        self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
        return
      end
      if string.sub(name, 1, 1) == ":" then
        if regular then
          self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
          return
        end
        if name == ":method" then
          if haveMethod then self:streamError(stream, frameMod.H2_PROTOCOL_ERROR); return end
          method = value
          haveMethod = true
        elseif name == ":path" then
          if havePath then self:streamError(stream, frameMod.H2_PROTOCOL_ERROR); return end
          path = value
          havePath = true
        elseif name == ":scheme" then
          if haveScheme then self:streamError(stream, frameMod.H2_PROTOCOL_ERROR); return end
          scheme = value
          haveScheme = true
        elseif name == ":authority" then
          if haveAuthority then self:streamError(stream, frameMod.H2_PROTOCOL_ERROR); return end
          authority = value
          haveAuthority = true
        else
          self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
          return
        end
      else
        regular = true
        if name == "connection" or name == "keep-alive" or name == "proxy-connection"
          or name == "transfer-encoding" or name == "upgrade" then
          self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
          return
        end
        if name == "te" and string.lower(value) ~= "trailers" then
          self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
          return
        end
        if not headersMod.validName(name) or not headersMod.validValue(value) then
          self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
          return
        end
        outHeaders:add(name, value)
        if name == "content-length" then
          local n: number | nil = tonumber(value)
          if n == nil or n! < 0 then
            self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
            return
          end
          local parsedLength: integer = math.floor(n!)
          if contentLength >= 0 and contentLength ~= parsedLength then
            self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
            return
          end
          contentLength = parsedLength
        end
      end
    end
    if not haveMethod or not havePath or not haveScheme or path == "" then
      self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
      return
    end
    if not headersMod.validName(method) then
      self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
      return
    end
    if string.find(path, "#", 1, true) ~= nil then
      self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
      return
    end
    if path ~= "*" and string.sub(path, 1, 1) ~= "/" then
      self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
      return
    end
    for i: integer = 1, #path do
      local c: integer = string.byte(path, i)!
      if c < 32 or c == 127 then
        self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
        return
      end
    end
    if haveAuthority and not headersMod.validValue(authority) then
      self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
      return
    end
    if haveAuthority and not outHeaders:has("Host") then
      outHeaders:set("Host", authority)
    end
    if not outHeaders:has("Host") then
      self:streamError(stream, frameMod.H2_PROTOCOL_ERROR)
      return
    end
    if contentLength > self.options.maxBody! then
      self:respondManual(stream, 413, "Content Too Large")
      return
    end
    stream.contentLength = contentLength
    local parts = url.splitTarget(path)
    local req = requestMod.HttpRequest.new(
      method,
      path,
      parts.path,
      parts.rawQuery,
      url.parseQuery(parts.rawQuery),
      "2.0",
      outHeaders,
      true
    )
    req.remote = self.conn:remoteAddress()
    stream.req = req
    stream.headersDone = true
    stream.streaming = self.router:isStreaming(req.method, req.path)
    if stream.streaming then
      self:startStreaming(stream)
      if stream.streamDone and not stream.endStream then
        self:finalizeStreaming(stream)
        return
      end
    end
    if stream.endStream then
      self:finishBody(stream)
    end
  end,

  handleData(frame: any): void
    if frame.streamId == 0 then
      self:connectionError(frameMod.H2_PROTOCOL_ERROR, "DATA on stream 0")
      return
    end
    local stream: H2Stream | nil = self.streams[frame.streamId]
    if stream == nil then
      self:sendFrame(
        frameMod.FRAME_RST_STREAM,
        0,
        frame.streamId,
        frameMod.rstStreamPayload(frameMod.H2_STREAM_CLOSED)
      )
      return
    end
    local current: H2Stream = stream!
    if not current.headersDone or current.endStream then
      self:streamError(current, frameMod.H2_STREAM_CLOSED)
      return
    end
    local data: string = frame.payload
    if math.floor(frame.flags / 8) % 2 == 1 then
      if data == "" then
        self:streamError(current, frameMod.H2_PROTOCOL_ERROR)
        return
      end
      local pad: integer = string.byte(data, 1)!
      if pad > #data - 1 then
        self:streamError(current, frameMod.H2_PROTOCOL_ERROR)
        return
      end
      data = string.sub(data, 2, #data - pad)
    end
    if #data > 0 then
      current.bodySize = current.bodySize + #data
      if current.bodySize > self.options.maxBody! then
        self:respondManual(current, 413, "Content Too Large")
        return
      end
      if current.streaming then
        current.streamQueue[#current.streamQueue + 1] = data
        self:resumeStreaming(current)
      else
        current.bodyParts[#current.bodyParts + 1] = data
      end
      self:sendFrame(
        frameMod.FRAME_WINDOW_UPDATE,
        0,
        0,
        frameMod.windowUpdatePayload(frame.length)
      )
      if not current.endStream then
        self:sendFrame(
          frameMod.FRAME_WINDOW_UPDATE,
          0,
          current.id,
          frameMod.windowUpdatePayload(frame.length)
        )
      end
    end
    if frame.flags % 2 == 1 then
      current.endStream = true
      self:finishBody(current)
    end
  end,

  finishBody(stream: H2Stream): void
    if not stream.headersDone or stream.req == nil then return end
    if stream.contentLength >= 0 and stream.bodySize ~= stream.contentLength then
      stream.streamDone = true
      stream.streamCo = nil
      self:respondManual(stream, 400, "Content-Length mismatch")
      return
    end
    if stream.streaming then
      stream.streamEnded = true
      stream.bodyComplete = true
      self:resumeStreaming(stream)
      if stream.streamDone then
        self:finalizeStreaming(stream)
      end
      return
    end
    stream.req!.body = table.concat(stream.bodyParts)
    stream.bodyParts = {}
    stream.bodyComplete = true
    local res = responseMod.HttpResponse.new(200)
    local ok = pcall(function(): void
      self.router:handle(stream.req!, res)
    end)
    if not ok then
      res = responseMod.HttpResponse.new(500)
      res.headers:set("Content-Type", "text/plain; charset=utf-8")
      res.body = "Internal Server Error\n"
    end
    self:sendResponse(stream, res)
  end,

  startStreaming(stream: H2Stream): void
    local res = responseMod.HttpResponse.new(200)
    stream.res = res
    stream.streamQueue = {}
    stream.streamEnded = false
    stream.streamDone = false
    local function bodyReader(): string | nil
      while #stream.streamQueue == 0 and not stream.streamEnded do
        coroutine.yield("body")
      end
      if #stream.streamQueue > 0 then
        local chunk: string = table.remove(stream.streamQueue, 1)!
        return chunk
      end
      return nil
    end
    stream.streamCo = coroutine.create(function(): void
      self.router:handleStream(stream.req!, res, bodyReader)
    end)
    self:resumeStreaming(stream)
  end,

  resumeStreaming(stream: H2Stream): void
    local co: any = stream.streamCo
    if co == nil or stream.streamDone then return end
    local callOk: boolean = false
    local resumeOk: any = nil
    local resumeValue: any = nil
    callOk, resumeOk, resumeValue = pcall(coroutine.resume, co)
    if not callOk or resumeOk ~= true then
      stream.streamDone = true
      local res: HttpResponseApi | nil = stream.res
      if res ~= nil then
        res!.status = 500
        res!.headers:set("Content-Type", "text/plain; charset=utf-8")
        res!.body = "Internal Server Error\n"
      end
      return
    end
    if coroutine.status(co) == "dead" then stream.streamDone = true end
  end,

  finalizeStreaming(stream: H2Stream): void
    local res: HttpResponseApi | nil = stream.res
    if res == nil then
      self:dropStream(stream)
      return
    end
    if stream.req == nil then
      self:dropStream(stream)
      return
    end
    self.stats.requests = self.stats.requests + 1
    stream.counted = true
    self:sendResponse(stream, res!)
  end,

  respondManual(stream: H2Stream, code: integer, message: string): void
    local res = responseMod.HttpResponse.new(code)
    res.headers:set("Content-Type", "text/plain; charset=utf-8")
    res.body = message .. "\n"
    self:sendResponse(stream, res)
  end,

  buildResponseHeaders(stream: H2Stream, res: HttpResponseApi): (any[], string, boolean)
    local bodyAllowed: boolean = not statusMod.isBodyless(res.status)
    local head: boolean = false
    if stream.req ~= nil and string.upper(stream.req!.method) == "HEAD" then head = true end
    local body: string = res.body
    if not bodyAllowed then body = "" end
    local headers: any[] = { { name = ":status", value = tostring(res.status) } }
    local hasDate: boolean = false
    local hasServer: boolean = false
    local entries: HeaderEntry[] = res.headers:entries()
    for i: integer = 1, #entries do
      local name: string = string.lower(entries[i].name)
      local value: string = entries[i].value
      if name == "connection" or name == "keep-alive" or name == "proxy-connection"
        or name == "transfer-encoding" or name == "upgrade" then
        -- stripped by HTTP/2 rules
      elseif name == "content-length" then
        -- recomputed below
      else
        if name == "date" then hasDate = true end
        if name == "server" then hasServer = true end
        headers[#headers + 1] = { name = name, value = value }
      end
    end
    if not hasDate then
      headers[#headers + 1] = { name = "date", value = date.httpDate(os.time()) }
    end
    local serverName: string = ""
    if self.options.serverName ~= nil then serverName = self.options.serverName! end
    if not hasServer and serverName ~= "" then
      headers[#headers + 1] = { name = "server", value = serverName }
    end
    if res.status == 205 then
      headers[#headers + 1] = { name = "content-length", value = "0" }
    elseif bodyAllowed then
      headers[#headers + 1] = { name = "content-length", value = tostring(#res.body) }
    end
    return headers, body, head
  end,

  sendResponse(stream: H2Stream, res: HttpResponseApi): void
    if stream.responseStarted then return end
    if res.status < 200 or res.status > 599 then
      res.status = 500
      res.headers:set("Content-Type", "text/plain; charset=utf-8")
      res.body = "Internal Server Error\n"
    end
    stream.responseStarted = true
    self.stats.responses = self.stats.responses + 1
    if not stream.counted then
      self.stats.requests = self.stats.requests + 1
      stream.counted = true
    end
    local headers, body, head = self:buildResponseHeaders(stream, res)
    local block: string = hpack.encodeHeaders(headers)
    local endStream: boolean = body == "" or head
    local max: integer = self.peerMaxFrameSize
    local first: string = string.sub(block, 1, max)
    local rest: string = string.sub(block, max + 1)
    local flags: integer = 0
    if #rest == 0 then flags = frameMod.FLAG_END_HEADERS end
    if endStream then flags = math.floor(flags + frameMod.FLAG_END_STREAM) end
    self:sendFrame(frameMod.FRAME_HEADERS, flags, stream.id, first)
    while #rest > 0 do
      local part: string = string.sub(rest, 1, max)
      rest = string.sub(rest, max + 1)
      local cflags: integer = 0
      if #rest == 0 then cflags = frameMod.FLAG_END_HEADERS end
      self:sendFrame(frameMod.FRAME_CONTINUATION, cflags, stream.id, part)
    end
    if endStream then
      self:completeResponse(stream)
      return
    end
    stream.pendingBody = body
    stream.pendingOffset = 1
    self:pumpStream(stream)
  end,

  pumpAll(): void
    for _, stream in pairs(self.streams) do
      if stream ~= nil then self:pumpStream(stream!) end
    end
  end,

  pumpStream(stream: H2Stream): void
    while #stream.pendingBody > 0 and stream.pendingOffset <= #stream.pendingBody do
      local remaining: integer = #stream.pendingBody - stream.pendingOffset + 1
      local allowed: integer = self.sendWindow
      if stream.sendWindow < allowed then allowed = stream.sendWindow end
      if self.peerMaxFrameSize < allowed then allowed = self.peerMaxFrameSize end
      if remaining < allowed then allowed = remaining end
      if allowed <= 0 then return end
      local chunk: string = string.sub(
        stream.pendingBody,
        stream.pendingOffset,
        stream.pendingOffset + allowed - 1
      )
      local last: boolean = stream.pendingOffset + allowed > #stream.pendingBody
      local flags: integer = 0
      if last then flags = frameMod.FLAG_END_STREAM end
      self:sendFrame(frameMod.FRAME_DATA, flags, stream.id, chunk)
      self.sendWindow = self.sendWindow - allowed
      stream.sendWindow = stream.sendWindow - allowed
      stream.pendingOffset = stream.pendingOffset + allowed
    end
    if stream.pendingOffset > #stream.pendingBody then
      stream.pendingBody = ""
      self:completeResponse(stream)
    end
  end,

  completeResponse(stream: H2Stream): void
    if not stream.endStream then
      -- We answered before the client finished uploading. Stop the request
      -- direction instead of leaving an unterminated stream around.
      self:sendFrame(
        frameMod.FRAME_RST_STREAM,
        0,
        stream.id,
        frameMod.rstStreamPayload(frameMod.H2_CANCEL)
      )
    end
    self:dropStream(stream)
  end,
}

return {
  H2Connection = H2Connection,
  PREFACE = PREFACE,
}
