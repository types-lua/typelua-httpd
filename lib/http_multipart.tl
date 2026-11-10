--- Incremental multipart/form-data parser and pull reader.
---
--- The parser never buffers a whole part: it emits `partData` chunks as soon
--- as they are safe to release, retaining only enough tail bytes to detect a
--- boundary split across network reads. The reader adapts an arbitrary
--- chunk source (array body or streaming request body) to `nextPart()`.

import literal from "./http_literal"
import url from "./http_url"
import headersMod from "./http_headers"

type MultipartPart = {
  name: string,
  filename: string | nil,
  contentType: string,
  headers: HeadersApi,
}

type MultipartEvent = {
  kind: string,
  part: MultipartPart | nil,
  data: string,
  error: string,
}

local S_INITIAL: integer = 1
local S_BOUNDARY: integer = 2
local S_HEADERS: integer = 3
local S_BODY: integer = 4
local S_DONE: integer = 5

type MultipartLimits = {
  boundary: string,
  maxHeaderBytes: integer,
  maxHeaders: integer,
  maxParts: integer,
  maxPartBytes: integer,
  maxTotalBytes: integer,
  requireDisposition: boolean,
}

type MultipartOptions = {
  boundary: string,
  maxHeaderBytes?: integer,
  maxHeaders?: integer,
  maxParts?: integer,
  maxPartBytes?: integer,
  maxTotalBytes?: integer,
  requireDisposition?: boolean,
}

type ContentType = {
  mediaType: string,
  params: map<string, string>,
}

local function trim(value: string): string
  local out: string = value
  while #out > 0 and (string.sub(out, 1, 1) == " " or string.sub(out, 1, 1) == "\t") do
    out = string.sub(out, 2)
  end
  while #out > 0 and (string.sub(out, -1) == " " or string.sub(out, -1) == "\t") do
    out = string.sub(out, 1, -2)
  end
  return out
end

local function unquote(value: string): string
  local text: string = trim(value)
  if #text >= 2 and string.sub(text, 1, 1) == "\"" and string.sub(text, -1) == "\"" then
    local inner: string = string.sub(text, 2, #text - 1)
    local out: string[] = {}
    local i: integer = 1
    while i <= #inner do
      local c: string = string.sub(inner, i, i)
      if c == "\\" and i < #inner then
        out[#out + 1] = string.sub(inner, i + 1, i + 1)
        i = i + 2
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
    return table.concat(out)
  end
  return text
end

--- Parses `type; key=value; key="quoted"` media type headers.
local function parseContentType(value: string): ContentType
  local out: ContentType = { mediaType = "", params = {} }
  local parts: string[] = {}
  local current: string[] = {}
  local quoted: boolean = false
  local escaped: boolean = false
  for i: integer = 1, #value do
    local c: string = string.sub(value, i, i)
    if escaped then
      current[#current + 1] = c
      escaped = false
    elseif c == "\\" and quoted then
      current[#current + 1] = c
      escaped = true
    elseif c == "\"" then
      quoted = not quoted
      current[#current + 1] = c
    elseif c == ";" and not quoted then
      parts[#parts + 1] = table.concat(current)
      current = {}
    else
      current[#current + 1] = c
    end
  end
  parts[#parts + 1] = table.concat(current)
  if #parts == 0 then return out end
  out.mediaType = string.lower(trim(parts[1]))
  for i: integer = 2, #parts do
    local item: string = trim(parts[i])
    if item ~= "" then
      local eq: integer | nil = literal.find(item, "=", 1)
      if eq ~= nil then
        local name: string = string.lower(trim(string.sub(item, 1, eq! - 1)))
        local raw: string = string.sub(item, eq! + 1)
        if name ~= "" then
          out.params[name] = unquote(raw)
        end
      end
    end
  end
  return out
end

local function decode5987(value: string): string | nil
  local first: integer | nil = literal.find(value, "'", 1)
  if first == nil then return nil end
  local second: integer | nil = literal.find(value, "'", first! + 1)
  if second == nil then return nil end
  local charset: string = string.lower(string.sub(value, 1, first! - 1))
  if charset ~= "utf-8" and charset ~= "utf8" then return nil end
  return url.decodeComponent(string.sub(value, second! + 1))
end

local function parseDisposition(value: string): map<string, string>
  local out: map<string, string> = {}
  local parsed: ContentType = parseContentType(value)
  out["__type"] = parsed.mediaType
  for name, v in pairs(parsed.params) do
    out[name] = v
  end
  local extended: string | nil = out["filename*"]
  if extended ~= nil then
    local decoded: string | nil = decode5987(extended!)
    if decoded ~= nil then
      out["filename"] = decoded!
    end
  end
  return out
end

class MultipartParser {
  boundary: string,
  marker: string,
  buf: string = "",
  pos: integer = 1,
  state: integer = S_INITIAL,
  opts: MultipartLimits,
  current: MultipartPart | nil = nil,
  partBytes: integer = 0,
  totalBytes: integer = 0,
  parts: integer = 0,
  ended: boolean = false,
  failed: boolean = false,
  errorText: string = "",

  constructor(options: MultipartOptions)
    local boundary: string = options.boundary
    if boundary == "" or #boundary > 70 then
      error("multipart boundary must be 1..70 bytes")
    end
    if literal.contains(boundary, "\r") or literal.contains(boundary, "\n") then
      error("multipart boundary must not contain CR/LF")
    end
    self.boundary = boundary
    self.marker = "\r\n--" .. boundary
    local maxHeaderBytes: integer = 8192
    local maxHeaders: integer = 32
    local maxParts: integer = 100
    local maxPartBytes: integer = 8 * 1024 * 1024
    local maxTotalBytes: integer = 32 * 1024 * 1024
    local requireDisposition: boolean = false
    if options.maxHeaderBytes ~= nil then maxHeaderBytes = options.maxHeaderBytes! end
    if options.maxHeaders ~= nil then maxHeaders = options.maxHeaders! end
    if options.maxParts ~= nil then maxParts = options.maxParts! end
    if options.maxPartBytes ~= nil then maxPartBytes = options.maxPartBytes! end
    if options.maxTotalBytes ~= nil then maxTotalBytes = options.maxTotalBytes! end
    if options.requireDisposition ~= nil then requireDisposition = options.requireDisposition! end
    self.opts = {
      boundary = boundary,
      maxHeaderBytes = maxHeaderBytes,
      maxHeaders = maxHeaders,
      maxParts = maxParts,
      maxPartBytes = maxPartBytes,
      maxTotalBytes = maxTotalBytes,
      requireDisposition = requireDisposition,
    }
  end,

  feed(data: string): void
    if self.ended or self.failed then return end
    self.buf = self.buf .. data
  end,

  buffered(): integer
    if self.pos > #self.buf then return 0 end
    return #self.buf - self.pos + 1
  end,

  event(kind: string, part: MultipartPart | nil, data: string): MultipartEvent
    return { kind = kind, part = part, data = data, error = "" }
  end,

  needMore(): MultipartEvent
    return { kind = "needMore", part = nil, data = "", error = "" }
  end,

  fail(message: string): MultipartEvent
    self.failed = true
    self.errorText = message
    return { kind = "error", part = nil, data = "", error = message }
  end,

  trimBuffer(): void
    if self.pos > 1 then
      self.buf = string.sub(self.buf, self.pos)
      self.pos = 1
    end
  end,

  clearCurrent(): void
    self.current = nil
  end,

  next(): MultipartEvent
    if self.failed then
      return { kind = "error", part = nil, data = "", error = self.errorText }
    end
    if self.ended then
      return { kind = "end", part = nil, data = "", error = "" }
    end

    while true do
      if self.state == S_INITIAL then
        local at: integer | nil = literal.find(self.buf, "--" .. self.boundary, self.pos)
        if at == nil then
          -- Keep a tail that could contain a split opening boundary.
          if self:buffered() > #self.boundary + 8 then
            local drop: integer = self.pos + self:buffered() - (#self.boundary + 8)
            self.pos = drop
          end
          self:trimBuffer()
          return self:needMore()
        end
        self.pos = at! + #self.boundary + 2
        self.state = S_BOUNDARY
      elseif self.state == S_BOUNDARY then
        -- After `--boundary`: `--` closes, otherwise optional transport
        -- padding then CRLF opens the next part.
        if self:buffered() < 2 then
          self:trimBuffer()
          return self:needMore()
        end
        if string.sub(self.buf, self.pos, self.pos + 1) == "--" then
          self.pos = self.pos + 2
          self.state = S_DONE
          self.ended = true
          if self.current ~= nil then
            local part: MultipartPart = self.current!
            self:clearCurrent()
            return self:event("partEnd", part, "")
          end
          return self:event("end", nil, "")
        end
        local lineEnd: integer | nil = literal.find(self.buf, "\r\n", self.pos)
        if lineEnd == nil then
          local pending: integer = self:buffered()
          if pending > 80 then
            return self:fail("multipart boundary line is too long")
          end
          self:trimBuffer()
          return self:needMore()
        end
        local padding: string = string.sub(self.buf, self.pos, lineEnd! - 1)
        for i: integer = 1, #padding do
          local c: string = string.sub(padding, i, i)
          if c ~= " " and c ~= "\t" then
            return self:fail("invalid multipart boundary padding")
          end
        end
        self.pos = lineEnd! + 2
        self.state = S_HEADERS
        if self.current ~= nil then
          local part: MultipartPart = self.current!
          self:clearCurrent()
          return self:event("partEnd", part, "")
        end
      elseif self.state == S_HEADERS then
        local separator: integer | nil = literal.find(self.buf, "\r\n\r\n", self.pos)
        if separator == nil then
          if self:buffered() > self.opts.maxHeaderBytes! then
            return self:fail("multipart part headers too large")
          end
          self:trimBuffer()
          return self:needMore()
        end
        local block: string = string.sub(self.buf, self.pos, separator! - 1)
        if #block > self.opts.maxHeaderBytes! then
          return self:fail("multipart part headers too large")
        end
        self.pos = separator! + 4
        self.parts = self.parts + 1
        if self.parts > self.opts.maxParts! then
          return self:fail("too many multipart parts")
        end
        local partHeaders = headersMod.Headers.new()
        local count: integer = 0
        if block ~= "" then
          for line in string.gmatch(block, "[^\r\n]+") do
            count = count + 1
            if count > self.opts.maxHeaders! then
              return self:fail("too many multipart part headers")
            end
            if string.sub(line, 1, 1) == " " or string.sub(line, 1, 1) == "\t" then
              return self:fail("folded multipart header")
            end
            local colon: integer | nil = literal.find(line, ":", 1)
            if colon == nil then
              return self:fail("malformed multipart header")
            end
            local name: string = string.sub(line, 1, colon! - 1)
            local value: string = trim(string.sub(line, colon! + 1))
            if not headersMod.validName(name) or not headersMod.validValue(value) then
              return self:fail("invalid multipart header")
            end
            partHeaders:add(name, value)
          end
        end
        local disposition: string | nil = partHeaders:get("Content-Disposition")
        local fields: map<string, string> = {}
        if disposition ~= nil then
          fields = parseDisposition(disposition!)
        else
          if self.opts.requireDisposition! then
            return self:fail("missing Content-Disposition")
          end
        end
        local name: string = ""
        local named: string | nil = fields["name"]
        if named ~= nil then name = named! end
        local filename: string | nil = fields["filename"]
        local contentType: string = "application/octet-stream"
        local ct: string | nil = partHeaders:get("Content-Type")
        if ct ~= nil then contentType = ct! end
        local part: MultipartPart = {
          name = name,
          filename = filename,
          contentType = contentType,
          headers = partHeaders,
        }
        self.current = part
        self.partBytes = 0
        self.state = S_BODY
        return self:event("partStart", part, "")
      elseif self.state == S_BODY then
        local at: integer | nil = literal.find(self.buf, self.marker, self.pos)
        if at ~= nil then
          if at! > self.pos then
            local data: string = string.sub(self.buf, self.pos, at! - 1)
            self.pos = at!
            self.partBytes = self.partBytes + #data
            self.totalBytes = self.totalBytes + #data
            if self.partBytes > self.opts.maxPartBytes! then
              return self:fail("multipart part exceeds maxPartBytes")
            end
            if self.totalBytes > self.opts.maxTotalBytes! then
              return self:fail("multipart body exceeds maxTotalBytes")
            end
            return self:event("partData", self.current, data)
          end
          self.pos = at! + #self.marker
          self.state = S_BOUNDARY
        else
          local keep: integer = #self.marker - 1
          local safeEnd: integer = #self.buf - keep
          if safeEnd >= self.pos then
            local data: string = string.sub(self.buf, self.pos, safeEnd)
            self.pos = safeEnd + 1
            self.partBytes = self.partBytes + #data
            self.totalBytes = self.totalBytes + #data
            if self.partBytes > self.opts.maxPartBytes! then
              return self:fail("multipart part exceeds maxPartBytes")
            end
            if self.totalBytes > self.opts.maxTotalBytes! then
              return self:fail("multipart body exceeds maxTotalBytes")
            end
            self:trimBuffer()
            return self:event("partData", self.current, data)
          end
          if self:buffered() > self.opts.maxPartBytes! + #self.marker then
            return self:fail("multipart part exceeds maxPartBytes")
          end
          self:trimBuffer()
          return self:needMore()
        end
      elseif self.state == S_DONE then
        self.ended = true
        return self:event("end", nil, "")
      else
        return self:fail("multipart parser in unknown state")
      end
    end
  end,
}

type MultipartSource = () -> string | nil

type MultipartReaderOptions = {
  boundary: string,
  source: MultipartSource,
  maxHeaderBytes?: integer,
  maxHeaders?: integer,
  maxParts?: integer,
  maxPartBytes?: integer,
  maxTotalBytes?: integer,
  requireDisposition?: boolean,
}

class MultipartPartReader {
  owner: MultipartReader,
  info: MultipartPart,
  done: boolean = false,

  constructor(owner: MultipartReader, info: MultipartPart)
    self.owner = owner
    self.info = info
  end,

  meta(): MultipartPart
    return self.info
  end,

  read(): string | nil
    if self.done then return nil end
    while true do
      local ev: MultipartEvent = self.owner:nextEvent()
      if ev.kind == "partData" then
        return ev.data
      elseif ev.kind == "partEnd" then
        self.done = true
        return nil
      elseif ev.kind == "end" then
        self.done = true
        return nil
      elseif ev.kind == "error" then
        error("multipart: " .. ev.error)
      end
    end
  end,

  readAll(): string
    local parts: string[] = {}
    while true do
      local chunk: string | nil = self:read()
      if chunk == nil then break end
      parts[#parts + 1] = chunk!
    end
    return table.concat(parts)
  end,
}

class MultipartReader {
  parser: MultipartParser,
  source: MultipartSource,
  current: MultipartPartReader | nil = nil,
  finished: boolean = false,
  sourceDone: boolean = false,

  constructor(options: MultipartReaderOptions)
    local parserOptions: MultipartOptions = { boundary = options.boundary }
    if options.maxHeaderBytes ~= nil then parserOptions.maxHeaderBytes = options.maxHeaderBytes! end
    if options.maxHeaders ~= nil then parserOptions.maxHeaders = options.maxHeaders! end
    if options.maxParts ~= nil then parserOptions.maxParts = options.maxParts! end
    if options.maxPartBytes ~= nil then parserOptions.maxPartBytes = options.maxPartBytes! end
    if options.maxTotalBytes ~= nil then parserOptions.maxTotalBytes = options.maxTotalBytes! end
    if options.requireDisposition ~= nil then
      parserOptions.requireDisposition = options.requireDisposition!
    end
    self.parser = MultipartParser.new(parserOptions)
    self.source = options.source
  end,

  pull(): boolean
    if self.sourceDone then return false end
    local chunk: string | nil = self.source()
    if chunk == nil then
      self.sourceDone = true
      return false
    end
    self.parser:feed(chunk!)
    return true
  end,

  nextEvent(): MultipartEvent
    while true do
      local ev: MultipartEvent = self.parser:next()
      if ev.kind == "needMore" then
        if self:pull() then
          -- keep parsing
        else
          local again: MultipartEvent = self.parser:next()
          if again.kind == "end" then
            return again
          end
          return self.parser:fail("truncated multipart body")
        end
      else
        return ev
      end
    end
  end,

  nextPart(): MultipartPartReader | nil
    if self.finished then return nil end
    if self.current ~= nil then
      local previous: MultipartPartReader = self.current!
      while previous:read() ~= nil do
        -- drain an unread previous part
      end
    end
    while true do
      local ev: MultipartEvent = self:nextEvent()
      if ev.kind == "partStart" then
        local reader = MultipartPartReader.new(self, ev.part!)
        self.current = reader
        return reader
      elseif ev.kind == "end" then
        self.finished = true
        return nil
      elseif ev.kind == "error" then
        error("multipart: " .. ev.error)
      elseif ev.kind == "partEnd" then
        -- partEnd for an already-consumed part; keep looking.
      end
    end
  end,
}

--- Extracts and validates the boundary from a Content-Type header.
local function boundaryFrom(contentType: string): string | nil
  local parsed: ContentType = parseContentType(contentType)
  if parsed.mediaType ~= "multipart/form-data" then
    return nil
  end
  return parsed.params["boundary"]
end

return {
  MultipartParser = MultipartParser,
  MultipartReader = MultipartReader,
  MultipartPartReader = MultipartPartReader,
  parseContentType = parseContentType,
  boundaryFrom = boundaryFrom,
}
