--- Incremental HTTP/1.1 request parser.
---
--- The parser is deliberately strict about framing (CL/TE conflicts, bare LF,
--- obs-fold, invalid lengths) because request smuggling is a framing bug, not
--- an application bug. It never dispatches a request before the complete body
--- has arrived, and enforces line/header/body/chunk limits while reading.

import headersMod from "./http_headers"
import url from "./http_url"
import requestMod from "./http_request"
import literal from "./http_literal"

local STATE_LINE: integer = 1
local STATE_HEADERS: integer = 2
local STATE_BODY: integer = 3
local STATE_CHUNK_SIZE: integer = 4
local STATE_CHUNK_DATA: integer = 5
local STATE_TRAILERS: integer = 6
local STATE_ERROR: integer = 7

type LineRead = {
  line: string | nil,
  err: HttpError | nil,
  needMore: boolean,
}

local function trimOws(value: string): string
  local s: string = value
  while #s > 0 do
    local c: string = string.sub(s, 1, 1)
    if c == " " or c == "\t" then
      s = string.sub(s, 2)
    else
      break
    end
  end
  while #s > 0 do
    local c: string = string.sub(s, -1)
    if c == " " or c == "\t" then
      s = string.sub(s, 1, -2)
    else
      break
    end
  end
  return s
end

local function parseDecimal(value: string): integer | nil
  if value == "" then return nil end
  for i: integer = 1, #value do
    local c: integer = string.byte(value, i)!
    if c < 48 or c > 57 then return nil end
  end
  local n: number | nil = tonumber(value)
  if n == nil then return nil end
  return math.floor(n!)
end

local function parseHex(value: string): integer | nil
  local text: string = trimOws(value)
  if text == "" then return nil end
  for i: integer = 1, #text do
    local c: integer = string.byte(text, i)!
    local ok: boolean = (c >= 48 and c <= 57) or (c >= 65 and c <= 70)
      or (c >= 97 and c <= 102)
    if not ok then return nil end
  end
  local n: number | nil = tonumber(text, 16)
  if n == nil then return nil end
  return math.floor(n!)
end

local function tokenListContains(value: string, token: string): boolean
  local wanted: string = string.lower(trimOws(token))
  for part in string.gmatch(value, "[^,]+") do
    if string.lower(trimOws(part)) == wanted then
      return true
    end
  end
  return false
end

local function defaultOptions(options: ParserOptions): ParserOptions
  local out: ParserOptions = {}
  out.maxRequestLine = 8192
  out.maxHeaderBytes = 32768
  out.maxHeaders = 100
  out.maxBody = 1048576
  out.maxChunkLine = 128
  out.maxChunks = 10000
  local v: integer | nil = options.maxRequestLine
  if v ~= nil then out.maxRequestLine = v! end
  v = options.maxHeaderBytes
  if v ~= nil then out.maxHeaderBytes = v! end
  v = options.maxHeaders
  if v ~= nil then out.maxHeaders = v! end
  v = options.maxBody
  if v ~= nil then out.maxBody = v! end
  v = options.maxChunkLine
  if v ~= nil then out.maxChunkLine = v! end
  v = options.maxChunks
  if v ~= nil then out.maxChunks = v! end
  return out
end

class HttpRequestParser implements HttpRequestParserApi {
  opts: ParserOptions,
  buf: string = "",
  pos: integer = 1,
  state: integer = STATE_LINE,
  lastError: HttpError | nil = nil,

  method: string = "",
  target: string = "",
  path: string = "",
  rawQuery: string = "",
  query: Query = {},
  version: string = "",
  headers: HeadersApi,
  bodyParts: string[] = {},
  bodySize: integer = 0,
  contentLength: integer = 0,
  chunked: boolean = false,
  chunkRemaining: integer = 0,
  chunks: integer = 0,
  headerBytes: integer = 0,
  headerCount: integer = 0,
  expectContinue: boolean = false,
  continueNotified: boolean = false,

  constructor(options: ParserOptions)
    self.opts = defaultOptions(options)
    self.headers = headersMod.Headers.new()
  end,

  feed(data: string): void
    if self.state == STATE_ERROR then
      return
    end
    self.buf = self.buf .. data
  end,

  buffered(): integer
    if self.pos > #self.buf then
      return 0
    end
    return #self.buf - self.pos + 1
  end,

  --- True while a request has been started but not fully delivered. Unlike
  --- `buffered()`, this stays true when the parser has consumed the request
  --- line and every complete header and is waiting for the final CRLF.
  requestActive(): boolean
    if self.state == STATE_LINE then
      return self:buffered() > 0
    end
    if self.state == STATE_ERROR then
      return false
    end
    return true
  end,

  reset(): void
    self.buf = ""
    self.pos = 1
    self.state = STATE_LINE
    self.lastError = nil
    self.method = ""
    self.target = ""
    self.path = ""
    self.rawQuery = ""
    self.query = {}
    self.version = ""
    self.headers = headersMod.Headers.new()
    self.bodyParts = {}
    self.bodySize = 0
    self.contentLength = 0
    self.chunked = false
    self.chunkRemaining = 0
    self.chunks = 0
    self.headerBytes = 0
    self.headerCount = 0
    self.expectContinue = false
    self.continueNotified = false
  end,

  fail(status: integer, message: string): ParseOutcome
    local e: HttpError = { status = status, message = message }
    self.lastError = e
    self.state = STATE_ERROR
    return { request = nil, error = e, needMore = false, expectContinue = false }
  end,

  readLine(maxBytes: integer, tooLargeStatus: integer): LineRead
    local crlf: integer | nil = literal.find(self.buf, "\r\n", self.pos)
    if crlf == nil then
      local lf: integer | nil = literal.find(self.buf, "\n", self.pos)
      if lf ~= nil then
        return { line = nil, err = { status = 400, message = "bare LF in request framing" }, needMore = false }
      end
      local count: integer = 0
      if self.pos <= #self.buf then
        count = #self.buf - self.pos + 1
      end
      if count > maxBytes then
        return {
          line = nil,
          err = { status = tooLargeStatus, message = "line exceeds limit" },
          needMore = false,
        }
      end
      return { line = nil, err = nil, needMore = true }
    end
    local at: integer = crlf!
    local line: string = string.sub(self.buf, self.pos, at - 1)
    if #line > maxBytes then
      return {
        line = nil,
        err = { status = tooLargeStatus, message = "line exceeds limit" },
        needMore = false,
      }
    end
    if literal.contains(line, "\r") or literal.contains(line, "\n") then
      return { line = nil, err = { status = 400, message = "control character in line" }, needMore = false }
    end
    self.pos = at + 2
    return { line = line, err = nil, needMore = false }
  end,

  trimBuffer(): void
    if self.pos > 1 then
      self.buf = string.sub(self.buf, self.pos)
      self.pos = 1
    end
  end,

  next(): ParseOutcome
    if self.state == STATE_ERROR then
      local cached: HttpError | nil = self.lastError
      if cached ~= nil then
        return { request = nil, error = cached!, needMore = false, expectContinue = false }
      end
      return {
        request = nil,
        error = { status = 400, message = "parse error" },
        needMore = false,
        expectContinue = false,
      }
    end

    while true do
      if self.state == STATE_LINE then
        local read: LineRead = self:readLine(self.opts.maxRequestLine!, 414)
        if read.needMore then
          self:trimBuffer()
          return { request = nil, error = nil, needMore = true, expectContinue = false }
        end
        if read.err ~= nil then
          return self:fail(read.err!.status, read.err!.message)
        end
        local line: string = read.line!
        if line == "" then
          return self:fail(400, "empty request line")
        end
        local method, target, versionText = string.match(line, "^(%S+) (%S+) (HTTP/%d%.%d)$")
        if method == nil or target == nil or versionText == nil then
          return self:fail(400, "malformed request line")
        end
        local methodText: string = method!
        local targetText: string = target!
        local versionRaw: string = versionText!
        if not headersMod.validName(methodText) then
          return self:fail(400, "invalid method token")
        end
        local version: string = string.sub(versionRaw, 6)
        if version ~= "1.0" and version ~= "1.1" then
          return self:fail(505, "unsupported HTTP version")
        end
        if literal.contains(targetText, "#") then
          return self:fail(400, "fragment in request target")
        end
        for i: integer = 1, #targetText do
          local c: integer = string.byte(targetText, i)!
          if c < 32 or c == 127 then
            return self:fail(400, "control character in request target")
          end
        end
        if targetText == "*" and methodText ~= "OPTIONS" then
          return self:fail(400, "asterisk target is only valid for OPTIONS")
        end
        local parts = url.splitTarget(targetText)
        self.method = methodText
        self.target = targetText
        self.path = parts.path
        self.rawQuery = parts.rawQuery
        self.query = url.parseQuery(parts.rawQuery)
        self.version = version
        self.headers = headersMod.Headers.new()
        self.headerBytes = 0
        self.headerCount = 0
        self.bodyParts = {}
        self.bodySize = 0
        self.contentLength = 0
        self.chunked = false
        self.continueNotified = false
        self.expectContinue = false
        self.state = STATE_HEADERS
      elseif self.state == STATE_HEADERS then
        local read: LineRead = self:readLine(self.opts.maxHeaderBytes!, 431)
        if read.needMore then
          self:trimBuffer()
          return { request = nil, error = nil, needMore = true, expectContinue = false }
        end
        if read.err ~= nil then
          return self:fail(read.err!.status, read.err!.message)
        end
        local line: string = read.line!
        if line == "" then
          local outcome: ParseOutcome | nil = self:finishHeaders()
          if outcome ~= nil then
            return outcome!
          end
        else
          self.headerBytes = self.headerBytes + #line + 2
          if self.headerBytes > self.opts.maxHeaderBytes! then
            return self:fail(431, "request headers too large")
          end
          if string.sub(line, 1, 1) == " " or string.sub(line, 1, 1) == "\t" then
            return self:fail(400, "obsolete header folding is not allowed")
          end
          local colon: integer | nil = literal.find(line, ":", 1)
          if colon == nil then
            return self:fail(400, "malformed header line")
          end
          local at: integer = colon!
          local name: string = string.sub(line, 1, at - 1)
          local value: string = trimOws(string.sub(line, at + 1))
          if not headersMod.validName(name) then
            return self:fail(400, "invalid header name")
          end
          if not headersMod.validValue(value) then
            return self:fail(400, "invalid header value")
          end
          self.headerCount = self.headerCount + 1
          if self.headerCount > self.opts.maxHeaders! then
            return self:fail(431, "too many headers")
          end
          self.headers:add(name, value)
        end
      elseif self.state == STATE_BODY then
        if self:buffered() < self.contentLength then
          self:trimBuffer()
          return { request = nil, error = nil, needMore = true, expectContinue = false }
        end
        local body: string = string.sub(self.buf, self.pos, self.pos + self.contentLength - 1)
        self.pos = self.pos + self.contentLength
        self.bodyParts = { body }
        self.bodySize = self.contentLength
        return self:finishRequest()
      elseif self.state == STATE_CHUNK_SIZE then
        local read: LineRead = self:readLine(self.opts.maxChunkLine!, 400)
        if read.needMore then
          self:trimBuffer()
          return { request = nil, error = nil, needMore = true, expectContinue = false }
        end
        if read.err ~= nil then
          return self:fail(read.err!.status, read.err!.message)
        end
        local line: string = read.line!
        local semi: integer | nil = literal.find(line, ";", 1)
        local sizeText: string = line
        if semi ~= nil then
          sizeText = string.sub(line, 1, semi! - 1)
        end
        local size: integer | nil = parseHex(sizeText)
        if size == nil then
          return self:fail(400, "invalid chunk size")
        end
        self.chunks = self.chunks + 1
        if self.chunks > self.opts.maxChunks! then
          return self:fail(400, "too many chunks")
        end
        if self.bodySize + size! > self.opts.maxBody! then
          return self:fail(413, "request body too large")
        end
        if size! == 0 then
          self.state = STATE_TRAILERS
          self.headerBytes = 0
          self.headerCount = 0
        else
          self.chunkRemaining = size!
          self.state = STATE_CHUNK_DATA
        end
      elseif self.state == STATE_CHUNK_DATA then
        local need: integer = self.chunkRemaining + 2
        if self:buffered() < need then
          self:trimBuffer()
          return { request = nil, error = nil, needMore = true, expectContinue = false }
        end
        local data: string = string.sub(self.buf, self.pos, self.pos + self.chunkRemaining - 1)
        self.pos = self.pos + self.chunkRemaining
        if string.sub(self.buf, self.pos, self.pos + 1) ~= "\r\n" then
          return self:fail(400, "missing CRLF after chunk data")
        end
        self.pos = self.pos + 2
        self.bodyParts[#self.bodyParts + 1] = data
        self.bodySize = self.bodySize + #data
        self.state = STATE_CHUNK_SIZE
      elseif self.state == STATE_TRAILERS then
        local read: LineRead = self:readLine(self.opts.maxHeaderBytes!, 431)
        if read.needMore then
          self:trimBuffer()
          return { request = nil, error = nil, needMore = true, expectContinue = false }
        end
        if read.err ~= nil then
          return self:fail(read.err!.status, read.err!.message)
        end
        local line: string = read.line!
        if line == "" then
          return self:finishRequest()
        end
        self.headerBytes = self.headerBytes + #line + 2
        if self.headerBytes > self.opts.maxHeaderBytes! then
          return self:fail(431, "trailers too large")
        end
        if string.sub(line, 1, 1) == " " or string.sub(line, 1, 1) == "\t" then
          return self:fail(400, "obsolete trailer folding is not allowed")
        end
        local colon: integer | nil = literal.find(line, ":", 1)
        if colon == nil then
          return self:fail(400, "malformed trailer")
        end
        local name: string = string.sub(line, 1, colon! - 1)
        local value: string = trimOws(string.sub(line, colon! + 1))
        if not headersMod.validName(name) or not headersMod.validValue(value) then
          return self:fail(400, "invalid trailer")
        end
      else
        return self:fail(500, "parser in unknown state")
      end
    end
  end,

  finishHeaders(): ParseOutcome | nil
    local hostValues: string[] = self.headers:getAll("Host")
    if #hostValues > 1 then
      return self:fail(400, "multiple Host headers")
    end
    if self.version == "1.1" and #hostValues == 0 then
      return self:fail(400, "HTTP/1.1 requires Host")
    end

    local teValues: string[] = self.headers:getAll("Transfer-Encoding")
    local clValues: string[] = self.headers:getAll("Content-Length")
    if #teValues > 0 and #clValues > 0 then
      return self:fail(400, "both Transfer-Encoding and Content-Length")
    end

    local expectsBody: boolean = false
    if #teValues > 0 then
      local combined: string = table.concat(teValues, ",")
      local tokens: string[] = {}
      for part in string.gmatch(combined, "[^,]+") do
        tokens[#tokens + 1] = string.lower(trimOws(part))
      end
      if #tokens ~= 1 or tokens[1] ~= "chunked" then
        return self:fail(400, "unsupported Transfer-Encoding")
      end
      self.chunked = true
      self.state = STATE_CHUNK_SIZE
      self.bodyParts = {}
      self.bodySize = 0
      self.chunks = 0
      expectsBody = true
    elseif #clValues > 0 then
      local first: string = trimOws(clValues[1])
      for i: integer = 1, #clValues do
        if trimOws(clValues[i]) ~= first then
          return self:fail(400, "conflicting Content-Length values")
        end
      end
      local length: integer | nil = parseDecimal(first)
      if length == nil or length! < 0 then
        return self:fail(400, "invalid Content-Length")
      end
      if length! > self.opts.maxBody! then
        return self:fail(413, "request body too large")
      end
      self.contentLength = length!
      self.state = STATE_BODY
      expectsBody = length! > 0
    else
      self.state = STATE_BODY
      self.contentLength = 0
    end

    local expect: string | nil = self.headers:get("Expect")
    if expect ~= nil and trimOws(expect!) ~= "" then
      if string.lower(trimOws(expect!)) ~= "100-continue" then
        return self:fail(417, "unsupported Expect header")
      end
      -- 100-continue is an HTTP/1.1 mechanism. For a 1.0 client the header
      -- is ignored and the server simply waits for the body.
      if expectsBody and self.version == "1.1" and not self.continueNotified then
        self.expectContinue = true
        self.continueNotified = true
        return { request = nil, error = nil, needMore = true, expectContinue = true }
      end
    end
    return nil
  end,

  keepAlive(): boolean
    local connection: string | nil = self.headers:get("Connection")
    local close: boolean = false
    local keep: boolean = false
    if connection ~= nil then
      close = tokenListContains(connection!, "close")
      keep = tokenListContains(connection!, "keep-alive")
    end
    if self.version == "1.0" then
      return keep and not close
    end
    return not close
  end,

  finishRequest(): ParseOutcome
    local body: string = table.concat(self.bodyParts)
    local req = requestMod.HttpRequest.new(
      self.method,
      self.target,
      self.path,
      self.rawQuery,
      self.query,
      self.version,
      self.headers,
      self:keepAlive()
    )
    req.body = body
    self:trimBuffer()
    self.state = STATE_LINE
    self.headers = headersMod.Headers.new()
    self.bodyParts = {}
    self.bodySize = 0
    self.contentLength = 0
    self.chunked = false
    self.chunkRemaining = 0
    self.chunks = 0
    self.headerBytes = 0
    self.headerCount = 0
    self.expectContinue = false
    self.continueNotified = false
    return { request = req, error = nil, needMore = false, expectContinue = false }
  end,
}

return { HttpRequestParser = HttpRequestParser, defaultOptions = defaultOptions }
