--- HTTP/2 frame codec (RFC 7540 §4).
---
--- Incremental, length-prefixed and bounded. Semantic validation (stream
--- ids, flags, continuation ordering, flow control) lives in the connection
--- state machine, not here.

type H2Frame = {
  length: integer,
  frameType: integer,
  flags: integer,
  streamId: integer,
  payload: string,
}

type H2FrameRead = {
  frame: H2Frame | nil,
  err: string,
  needMore: boolean,
}

local FRAME_DATA: integer = 0
local FRAME_HEADERS: integer = 1
local FRAME_PRIORITY: integer = 2
local FRAME_RST_STREAM: integer = 3
local FRAME_SETTINGS: integer = 4
local FRAME_PUSH_PROMISE: integer = 5
local FRAME_PING: integer = 6
local FRAME_GOAWAY: integer = 7
local FRAME_WINDOW_UPDATE: integer = 8
local FRAME_CONTINUATION: integer = 9

local FLAG_END_STREAM: integer = 1
local FLAG_ACK: integer = 1
local FLAG_END_HEADERS: integer = 4
local FLAG_PADDED: integer = 8
local FLAG_PRIORITY: integer = 32

local H2_NO_ERROR: integer = 0
local H2_PROTOCOL_ERROR: integer = 1
local H2_INTERNAL_ERROR: integer = 2
local H2_FLOW_CONTROL_ERROR: integer = 3
local H2_STREAM_CLOSED: integer = 5
local H2_FRAME_SIZE_ERROR: integer = 6
local H2_REFUSED_STREAM: integer = 7
local H2_CANCEL: integer = 8
local H2_COMPRESSION_ERROR: integer = 9
local H2_ENHANCE_YOUR_CALM: integer = 11

local VALID_TYPES: map<integer, boolean> = {
  [0] = true, [1] = true, [2] = true, [3] = true, [4] = true,
  [5] = true, [6] = true, [7] = true, [8] = true, [9] = true,
}

local function u24(value: integer): string
  return string.char(
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256
  )
end

local function u32(value: integer): string
  local v: integer = math.floor(value % 4294967296)
  return string.char(
    math.floor(v / 16777216) % 256,
    math.floor(v / 65536) % 256,
    math.floor(v / 256) % 256,
    v % 256
  )
end

local function readU32(data: string, at: integer): integer
  local n: number = 0
  for i: integer = 0, 3 do
    n = n * 256 + string.byte(data, at + i)!
  end
  return math.floor(n)
end

local function encodeFrame(
  frameType: integer,
  flags: integer,
  streamId: integer,
  payload: string
): string
  return u24(#payload) .. string.char(frameType, flags)
    .. u32(streamId % 2147483648) .. payload
end

class H2FrameParser {
  buf: string = "",
  pos: integer = 1,
  maxFrameSize: integer = 16384,
  failed: boolean = false,

  constructor(maxFrameSize: integer)
    if maxFrameSize ~= nil then
      self.maxFrameSize = maxFrameSize
    end
    if self.maxFrameSize < 16384 or self.maxFrameSize > 16777215 then
      error("invalid HTTP/2 max frame size")
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

  next(): H2FrameRead
    if self.failed then
      return { frame = nil, err = "frame parser failed", needMore = false }
    end
    if self:buffered() < 9 then
      return { frame = nil, err = "", needMore = true }
    end
    local b1: integer = string.byte(self.buf, self.pos)!
    local b2: integer = string.byte(self.buf, self.pos + 1)!
    local b3: integer = string.byte(self.buf, self.pos + 2)!
    local length: integer = (b1 * 256 + b2) * 256 + b3
    local frameType: integer = string.byte(self.buf, self.pos + 3)!
    local flags: integer = string.byte(self.buf, self.pos + 4)!
    local streamId: integer = readU32(self.buf, self.pos + 5) % 2147483648
    if length > self.maxFrameSize then
      self.failed = true
      self.pos = self.pos + 9
      return { frame = nil, err = "HTTP/2 frame exceeds max frame size", needMore = false }
    end
    if self:buffered() < 9 + length then
      return { frame = nil, err = "", needMore = true }
    end
    local payload: string = string.sub(
      self.buf,
      self.pos + 9,
      self.pos + 9 + length - 1
    )
    self.pos = self.pos + 9 + length
    if self.pos > #self.buf then
      self.buf = ""
      self.pos = 1
    elseif self.pos > 65536 then
      self.buf = string.sub(self.buf, self.pos)
      self.pos = 1
    end
    return {
      frame = {
        length = length,
        frameType = frameType,
        flags = flags,
        streamId = streamId,
        payload = payload,
      },
      err = "",
      needMore = false,
    }
  end,
}

type H2Setting = {
  id: integer,
  value: integer,
}

local function settingsPayload(entries: H2Setting[]): string
  local out: string[] = {}
  for i: integer = 1, #entries do
    out[#out + 1] = string.char(math.floor((entries[i].id / 256) % 256), math.floor(entries[i].id % 256))
    out[#out + 1] = u32(entries[i].value)
  end
  return table.concat(out)
end

local function parseSettings(payload: string): H2Setting[]
  local out: H2Setting[] = {}
  if #payload % 6 ~= 0 then
    error("invalid HTTP/2 SETTINGS length")
  end
  local at: integer = 1
  while at <= #payload do
    local id: integer = math.floor(string.byte(payload, at)! * 256 + string.byte(payload, at + 1)!)
    local value: integer = readU32(payload, at + 2)
    out[#out + 1] = { id = id, value = value }
    at = at + 6
  end
  return out
end

local function windowUpdatePayload(increment: integer): string
  return u32(increment)
end

local function rstStreamPayload(code: integer): string
  return u32(code)
end

local function goawayPayload(lastStreamId: integer, code: integer, debug: string): string
  return u32(lastStreamId % 2147483648) .. u32(code) .. debug
end

return {
  FRAME_DATA = FRAME_DATA,
  FRAME_HEADERS = FRAME_HEADERS,
  FRAME_PRIORITY = FRAME_PRIORITY,
  FRAME_RST_STREAM = FRAME_RST_STREAM,
  FRAME_SETTINGS = FRAME_SETTINGS,
  FRAME_PUSH_PROMISE = FRAME_PUSH_PROMISE,
  FRAME_PING = FRAME_PING,
  FRAME_GOAWAY = FRAME_GOAWAY,
  FRAME_WINDOW_UPDATE = FRAME_WINDOW_UPDATE,
  FRAME_CONTINUATION = FRAME_CONTINUATION,

  FLAG_END_STREAM = FLAG_END_STREAM,
  FLAG_ACK = FLAG_ACK,
  FLAG_END_HEADERS = FLAG_END_HEADERS,
  FLAG_PADDED = FLAG_PADDED,
  FLAG_PRIORITY = FLAG_PRIORITY,

  H2_NO_ERROR = H2_NO_ERROR,
  H2_PROTOCOL_ERROR = H2_PROTOCOL_ERROR,
  H2_INTERNAL_ERROR = H2_INTERNAL_ERROR,
  H2_FLOW_CONTROL_ERROR = H2_FLOW_CONTROL_ERROR,
  H2_STREAM_CLOSED = H2_STREAM_CLOSED,
  H2_FRAME_SIZE_ERROR = H2_FRAME_SIZE_ERROR,
  H2_REFUSED_STREAM = H2_REFUSED_STREAM,
  H2_CANCEL = H2_CANCEL,
  H2_COMPRESSION_ERROR = H2_COMPRESSION_ERROR,
  H2_ENHANCE_YOUR_CALM = H2_ENHANCE_YOUR_CALM,

  VALID_TYPES = VALID_TYPES,
  u24 = u24,
  u32 = u32,
  readU32 = readU32,
  encodeFrame = encodeFrame,
  settingsPayload = settingsPayload,
  parseSettings = parseSettings,
  windowUpdatePayload = windowUpdatePayload,
  rstStreamPayload = rstStreamPayload,
  goawayPayload = goawayPayload,
  H2FrameParser = H2FrameParser,
}
