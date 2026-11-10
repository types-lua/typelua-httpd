--- RFC 6455 WebSocket handshake, frame codec and message assembly.
---
--- The server sends unmasked frames and requires masked client frames. The
--- codec is incremental and keeps at most `maxFrameBytes` of buffered input;
--- fragmentation, interleaved control frames, UTF-8 validation, close codes
--- and message limits are enforced above the frame layer.

import base64 from "./http_base64"
import sha1 from "./http_sha1"
import bits from "./http_bits"

local GUID: string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local OP_CONT: integer = 0
local OP_TEXT: integer = 1
local OP_BINARY: integer = 2
local OP_CLOSE: integer = 8
local OP_PING: integer = 9
local OP_PONG: integer = 10

type WsFrame = {
  fin: boolean,
  opcode: integer,
  payload: string,
}

type WsFrameRead = {
  frame: WsFrame | nil,
  err: string | nil,
  needMore: boolean,
}

type WsFrameParserOptions = {
  requireMask?: boolean,
  maxFrameBytes?: integer,
}

type WsSessionOptions = {
  emit: (wire: string) -> void,
  onText?: (ws: any, text: string) -> void,
  onBinary?: (ws: any, data: string) -> void,
  onClose?: (ws: any, code: integer, reason: string) -> void,
  requireMask?: boolean,
  maxFrameBytes?: integer,
  maxMessageBytes?: integer,
}

local function acceptKey(key: string): string
  return base64.encode(sha1.digest(key .. GUID))
end

local function headerHasToken(value: string | nil, token: string): boolean
  if value == nil then return false end
  local wanted: string = string.lower(token)
  for part in string.gmatch(value!, "[^,]+") do
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

type WsHandshakeCheck = {
  ok: boolean,
  error: string,
}

--- Validates the client half of an RFC 6455 opening handshake.
local function validateHandshake(req: HttpRequestApi): WsHandshakeCheck
  if string.upper(req.method) ~= "GET" then
    return { ok = false, error = "WebSocket upgrade requires GET" }
  end
  if req.version ~= "1.1" then
    return { ok = false, error = "WebSocket upgrade requires HTTP/1.1" }
  end
  if not headerHasToken(req.headers:get("Connection"), "upgrade") then
    return { ok = false, error = "Connection: Upgrade is required" }
  end
  local upgrade: string | nil = req.headers:get("Upgrade")
  if upgrade == nil or string.lower(upgrade!) ~= "websocket" then
    return { ok = false, error = "Upgrade: websocket is required" }
  end
  if req.headers:get("Sec-WebSocket-Version") ~= "13" then
    return { ok = false, error = "Sec-WebSocket-Version must be 13" }
  end
  local key: string | nil = req.headers:get("Sec-WebSocket-Key")
  if key == nil then
    return { ok = false, error = "Sec-WebSocket-Key is required" }
  end
  local keyOk: boolean = false
  local decoded: any = nil
  keyOk, decoded = pcall(base64.decode, key!)
  local keyBytes: string = ""
  if keyOk then keyBytes = tostring(decoded) end
  if not keyOk or #keyBytes ~= 16 then
    return { ok = false, error = "Sec-WebSocket-Key must be 16 bytes of base64" }
  end
  return { ok = true, error = "" }
end

--- Validate UTF-8 without accepting overlongs, surrogates or > U+10FFFF.
local function validUtf8(data: string): boolean
  local i: integer = 1
  while i <= #data do
    local c: integer = string.byte(data, i)!
    if c < 128 then
      i = i + 1
    elseif c >= 194 and c <= 223 then
      if i + 1 > #data then return false end
      local c2: integer = string.byte(data, i + 1)!
      if c2 < 128 or c2 > 191 then return false end
      i = i + 2
    elseif c == 224 then
      if i + 2 > #data then return false end
      local c2: integer = string.byte(data, i + 1)!
      local c3: integer = string.byte(data, i + 2)!
      if c2 < 160 or c2 > 191 or c3 < 128 or c3 > 191 then return false end
      i = i + 3
    elseif c >= 225 and c <= 237 then
      if i + 2 > #data then return false end
      local c2: integer = string.byte(data, i + 1)!
      local c3: integer = string.byte(data, i + 2)!
      if c2 < 128 or c2 > 191 or c3 < 128 or c3 > 191 then return false end
      i = i + 3
    elseif c == 237 then
      if i + 2 > #data then return false end
      local c2: integer = string.byte(data, i + 1)!
      local c3: integer = string.byte(data, i + 2)!
      if c2 < 128 or c2 > 159 or c3 < 128 or c3 > 191 then return false end
      i = i + 3
    elseif c >= 238 and c <= 239 then
      if i + 2 > #data then return false end
      local c2: integer = string.byte(data, i + 1)!
      local c3: integer = string.byte(data, i + 2)!
      if c2 < 128 or c2 > 191 or c3 < 128 or c3 > 191 then return false end
      i = i + 3
    elseif c == 240 then
      if i + 3 > #data then return false end
      local c2: integer = string.byte(data, i + 1)!
      local c3: integer = string.byte(data, i + 2)!
      local c4: integer = string.byte(data, i + 3)!
      if c2 < 144 or c2 > 191 or c3 < 128 or c3 > 191 or c4 < 128 or c4 > 191 then
        return false
      end
      i = i + 4
    elseif c >= 241 and c <= 243 then
      if i + 3 > #data then return false end
      local c2: integer = string.byte(data, i + 1)!
      local c3: integer = string.byte(data, i + 2)!
      local c4: integer = string.byte(data, i + 3)!
      if c2 < 128 or c2 > 191 or c3 < 128 or c3 > 191 or c4 < 128 or c4 > 191 then
        return false
      end
      i = i + 4
    elseif c == 244 then
      if i + 3 > #data then return false end
      local c2: integer = string.byte(data, i + 1)!
      local c3: integer = string.byte(data, i + 2)!
      local c4: integer = string.byte(data, i + 3)!
      if c2 < 128 or c2 > 143 or c3 < 128 or c3 > 191 or c4 < 128 or c4 > 191 then
        return false
      end
      i = i + 4
    else
      return false
    end
  end
  return true
end

local function validCloseCode(code: integer): boolean
  if code >= 3000 and code <= 4999 then return true end
  return code == 1000 or code == 1001 or code == 1002 or code == 1003
    or (code >= 1007 and code <= 1011)
end

local function encodeLength(length: integer, maskBit: boolean): string
  local first: integer = 0
  if maskBit then first = 128 end
  if length <= 125 then
    return string.char(first + length)
  elseif length <= 65535 then
    return string.char(first + 126, math.floor(length / 256) % 256, length % 256)
  end
  local high: number = math.floor(length / 4294967296)
  local low: number = length % 4294967296
  local out: string[] = { string.char(first + 127) }
  local values: number[] = { high, low }
  for v: integer = 1, 2 do
    local n: number = values[v]
    for shift: integer = 3, 0, -1 do
      out[#out + 1] = string.char(math.floor(n / (256 ^ shift)) % 256)
    end
  end
  return table.concat(out)
end

--- Encodes one frame. A mask key of nil means "server frame" (unmasked).
local function encodeFrame(
  opcode: integer,
  payload: string,
  fin: boolean,
  maskKey: string | nil
): string
  local final: boolean = fin
  local masked: boolean = maskKey ~= nil
  local first: integer = opcode
  if final then first = first + 128 end
  local out: string[] = { string.char(first), encodeLength(#payload, masked) }
  if masked then
    out[#out + 1] = maskKey!
    out[#out + 1] = bits.xorRepeat(payload, maskKey!)
  else
    out[#out + 1] = payload
  end
  return table.concat(out)
end

class WsFrameParser {
  buf: string = "",
  pos: integer = 1,
  requireMask: boolean = true,
  maxFrameBytes: integer = 1048576,
  failed: boolean = false,

  constructor(options: WsFrameParserOptions)
    local requireMask: boolean | nil = options.requireMask
    if requireMask ~= nil then self.requireMask = requireMask! end
    local maxFrameBytes: integer | nil = options.maxFrameBytes
    if maxFrameBytes ~= nil then self.maxFrameBytes = maxFrameBytes! end
    if self.maxFrameBytes < 0 then
      error("maxFrameBytes must be >= 0")
    end
  end,

  feed(data: string): void
    if self.failed then return end
    self.buf = self.buf .. data
  end,

  buffered(): integer
    if self.pos > #self.buf then return 0 end
    return #self.buf - self.pos + 1
  end,

  needMore(): WsFrameRead
    return { frame = nil, err = nil, needMore = true }
  end,

  fail(message: string): WsFrameRead
    self.failed = true
    return { frame = nil, err = message, needMore = false }
  end,

  next(): WsFrameRead
    if self.failed then
      return { frame = nil, err = "frame parser failed", needMore = false }
    end
    if self:buffered() < 2 then return self:needMore() end
    local b1: integer = string.byte(self.buf, self.pos)!
    local b2: integer = string.byte(self.buf, self.pos + 1)!
    local fin: boolean = b1 >= 128
    local rsv: integer = math.floor((b1 % 128) / 16)
    local opcode: integer = b1 % 16
    local masked: boolean = b2 >= 128
    local length7: integer = math.floor(b2 % 128)
    local headerSize: integer = 2

    if rsv ~= 0 then return self:fail("reserved frame bits are not supported") end
    if opcode ~= OP_CONT and opcode ~= OP_TEXT and opcode ~= OP_BINARY
      and opcode ~= OP_CLOSE and opcode ~= OP_PING and opcode ~= OP_PONG then
      return self:fail("unknown frame opcode")
    end
    local control: boolean = opcode >= 8
    if control and not fin then return self:fail("control frames must not fragment") end
    if self.requireMask and not masked then return self:fail("client frames must be masked") end

    local length: number = length7
    if length7 == 126 then
      headerSize = headerSize + 2
      if self:buffered() < headerSize then return self:needMore() end
      length = string.byte(self.buf, self.pos + 2)! * 256
        + string.byte(self.buf, self.pos + 3)!
    elseif length7 == 127 then
      headerSize = headerSize + 8
      if self:buffered() < headerSize then return self:needMore() end
      local high: number = 0
      for i: integer = 0, 3 do
        high = high * 256 + string.byte(self.buf, self.pos + 2 + i)!
      end
      local low: number = 0
      for i: integer = 4, 7 do
        low = low * 256 + string.byte(self.buf, self.pos + 2 + i)!
      end
      if high >= 2097152 then
        return self:fail("frame length exceeds safe integer range")
      end
      length = high * 4294967296 + low
    end
    if length > self.maxFrameBytes then return self:fail("frame exceeds maxFrameBytes") end
    if control and length > 125 then return self:fail("control frame payload too large") end

    local maskKey: string = ""
    if masked then
      headerSize = headerSize + 4
      if self:buffered() < headerSize then return self:needMore() end
      maskKey = string.sub(self.buf, self.pos + headerSize - 4, self.pos + headerSize - 1)
    end
    if self:buffered() < headerSize + length then return self:needMore() end
    local payload: string = ""
    if length > 0 then
      payload = string.sub(
        self.buf,
        self.pos + headerSize,
        self.pos + headerSize + length - 1
      )
      if masked then payload = bits.xorRepeat(payload, maskKey) end
    end
    self.pos = math.floor(self.pos + headerSize + length)
    if self.pos > #self.buf then
      self.buf = ""
      self.pos = 1
    elseif self.pos > 65536 then
      self.buf = string.sub(self.buf, self.pos)
      self.pos = 1
    end
    return {
      frame = { fin = fin, opcode = opcode, payload = payload },
      err = nil,
      needMore = false,
    }
  end,
}

class WebSocketSession {
  parser: WsFrameParser,
  emit: (wire: string) -> void,
  onText: ((ws: any, text: string) -> void) | nil,
  onBinary: ((ws: any, data: string) -> void) | nil,
  onClose: ((ws: any, code: integer, reason: string) -> void) | nil,
  maxMessageBytes: integer = 4 * 1024 * 1024,
  fragmentOpcode: integer = 0,
  fragments: string[] = {},
  fragmentBytes: integer = 0,
  closeSent: boolean = false,
  closed: boolean = false,
  failed: boolean = false,

  constructor(options: WsSessionOptions)
    local frameOptions: WsFrameParserOptions = {
      requireMask = true,
      maxFrameBytes = 1048576,
    }
    if options.requireMask ~= nil then frameOptions.requireMask = options.requireMask! end
    if options.maxFrameBytes ~= nil then frameOptions.maxFrameBytes = options.maxFrameBytes! end
    self.parser = WsFrameParser.new(frameOptions)
    self.emit = options.emit
    self.onText = options.onText
    self.onBinary = options.onBinary
    self.onClose = options.onClose
    local maxMessageBytes: integer | nil = options.maxMessageBytes
    if maxMessageBytes ~= nil then self.maxMessageBytes = maxMessageBytes! end
    if self.maxMessageBytes < 0 then
      error("maxMessageBytes must be >= 0")
    end
  end,

  feed(data: string): void
    if self.closed or self.failed then return end
    self.parser:feed(data)
    while true do
      local read: WsFrameRead = self.parser:next()
      if read.err ~= nil then
        self:failProtocol(1002, read.err!)
        return
      end
      if read.needMore then return end
      if not self:handleFrame(read.frame!) then return end
    end
  end,

  isClosed(): boolean
    return self.closed or self.failed
  end,

  isFailed(): boolean
    return self.failed
  end,

  sendFrame(opcode: integer, payload: string): void
    if self.closed or self.failed then return end
    self.emit(encodeFrame(opcode, payload, true, nil))
  end,

  sendText(text: string): void
    if not validUtf8(text) then
      error("WebSocket text messages must be valid UTF-8")
    end
    self:sendFrame(OP_TEXT, text)
  end,

  sendBinary(data: string): void
    self:sendFrame(OP_BINARY, data)
  end,

  ping(payload: string): void
    local data: string = payload
    if #data > 125 then error("ping payload must be <= 125 bytes") end
    self:sendFrame(OP_PING, data)
  end,

  pong(payload: string): void
    local data: string = payload
    if #data > 125 then error("pong payload must be <= 125 bytes") end
    self:sendFrame(OP_PONG, data)
  end,

  closeNormal(): void
    self:close(1000, "")
  end,

  close(code: integer, reason: string): void
    if self.closed or self.failed then return end
    local status: integer = code
    local text: string = reason
    if not validCloseCode(status) then
      error("invalid WebSocket close code: " .. tostring(status))
    end
    if #text > 123 then error("close reason must be <= 123 bytes") end
    if not validUtf8(text) then error("close reason must be valid UTF-8") end
    local payload: string = string.char(math.floor((status / 256) % 256), math.floor(status % 256)) .. text
    if not self.closeSent then
      self.emit(encodeFrame(OP_CLOSE, payload, true, nil))
      self.closeSent = true
    end
    self.closed = true
  end,

  failProtocol(code: integer, message: string): void
    if self.failed or self.closed then return end
    self.failed = true
    local payload: string = string.char(math.floor(code / 256), math.floor(code % 256))
      .. string.sub(message, 1, 123)
    self.emit(encodeFrame(OP_CLOSE, payload, true, nil))
    if self.onClose ~= nil then
      self.onClose!(self, code, message)
    end
  end,

  completeMessage(opcode: integer, payload: string): void
    if opcode == OP_TEXT then
      if not validUtf8(payload) then
        self:failProtocol(1007, "text message is not valid UTF-8")
        return
      end
      if self.onText ~= nil then self.onText!(self, payload) end
    else
      if self.onBinary ~= nil then self.onBinary!(self, payload) end
    end
  end,

  handleFrame(frame: WsFrame): boolean
    if frame.opcode == OP_CLOSE then
      if #frame.payload == 1 then
        self:failProtocol(1002, "close frame has a one-byte payload")
        return false
      end
      local code: integer = 1005
      local reason: string = ""
      if #frame.payload >= 2 then
        code = math.floor(string.byte(frame.payload, 1)! * 256 + string.byte(frame.payload, 2)!)
        reason = string.sub(frame.payload, 3)
        if not validCloseCode(code) then
          self:failProtocol(1002, "invalid close code")
          return false
        end
        if not validUtf8(reason) then
          self:failProtocol(1007, "close reason is not valid UTF-8")
          return false
        end
      end
      if not self.closeSent then
        self.emit(encodeFrame(OP_CLOSE, frame.payload, true, nil))
        self.closeSent = true
      end
      self.closed = true
      if self.onClose ~= nil then self.onClose!(self, code, reason) end
      return false
    end
    if self.closed then return false end

    if frame.opcode == OP_PING then
      self:sendFrame(OP_PONG, frame.payload)
      return true
    end
    if frame.opcode == OP_PONG then
      return true
    end

    if frame.opcode == OP_CONT then
      if self.fragmentOpcode == 0 then
        self:failProtocol(1002, "continuation frame without a message")
        return false
      end
      self.fragmentBytes = self.fragmentBytes + #frame.payload
      if self.fragmentBytes > self.maxMessageBytes then
        self:failProtocol(1009, "message exceeds maxMessageBytes")
        return false
      end
      self.fragments[#self.fragments + 1] = frame.payload
      if frame.fin then
        local opcode: integer = self.fragmentOpcode
        local payload: string = table.concat(self.fragments)
        self.fragmentOpcode = 0
        self.fragments = {}
        self.fragmentBytes = 0
        self:completeMessage(opcode, payload)
      end
      return true
    end

    if self.fragmentOpcode ~= 0 then
      self:failProtocol(1002, "new data frame during a fragmented message")
      return false
    end
    if frame.fin then
      if #frame.payload > self.maxMessageBytes then
        self:failProtocol(1009, "message exceeds maxMessageBytes")
        return false
      end
      self:completeMessage(frame.opcode, frame.payload)
      return true
    end
    self.fragmentOpcode = frame.opcode
    self.fragments = { frame.payload }
    self.fragmentBytes = #frame.payload
    if self.fragmentBytes > self.maxMessageBytes then
      self:failProtocol(1009, "message exceeds maxMessageBytes")
      return false
    end
    return true
  end,
}

return {
  OP_CONT = OP_CONT,
  OP_TEXT = OP_TEXT,
  OP_BINARY = OP_BINARY,
  OP_CLOSE = OP_CLOSE,
  OP_PING = OP_PING,
  OP_PONG = OP_PONG,
  GUID = GUID,
  acceptKey = acceptKey,
  validateHandshake = validateHandshake,
  validUtf8 = validUtf8,
  validCloseCode = validCloseCode,
  encodeFrame = encodeFrame,
  WsFrameParser = WsFrameParser,
  WebSocketSession = WebSocketSession,
}
