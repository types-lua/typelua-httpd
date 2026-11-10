--- Static file handler with traversal protection, ETag/304 and single ranges.
---
--- Path containment is lexical (`safeJoin`); the root must not contain
--- attacker-controlled symlinks. Content is read into memory and capped, so a
--- huge file yields 413 instead of unbounded memory use.

import url from "./http_url"
import mime from "./http_mime"
import date from "./http_date"
import literal from "./http_literal"
import headers from "./http_headers"

local function parseInt(value: string): integer | nil
  if value == "" then return nil end
  for i: integer = 1, #value do
    local c: integer = string.byte(value, i)!
    if c < 48 or c > 57 then return nil end
  end
  local n: number | nil = tonumber(value)
  if n == nil then return nil end
  return math.floor(n!)
end

local function trimOws(value: string): string
  local out: string = value
  while #out > 0 do
    local c: string = string.sub(out, 1, 1)
    if c == " " or c == "\t" then out = string.sub(out, 2) else break end
  end
  while #out > 0 do
    local c: string = string.sub(out, -1)
    if c == " " or c == "\t" then out = string.sub(out, 1, -2) else break end
  end
  return out
end

--- Weak comparison as required by If-None-Match; `*` matches any entity.
local function etagMatches(header: string, tag: string): boolean
  local text: string = trimOws(header)
  if text == "*" then return true end
  for part in string.gmatch(text, "[^,]+") do
    local item: string = trimOws(part)
    if string.sub(item, 1, 2) == "W/" then
      item = string.sub(item, 3)
    end
    if item == tag then
      return true
    end
  end
  return false
end

type FileRead = {
  data: string | nil,
  tooLarge: boolean,
}

--- Reads a file with a hard cap. `seek` distinguishes directories (which
--- `io.open` accepts on Linux) from empty regular files, where `read(n)`
--- would report EOF and be mistaken for an I/O error.
local function readCapped(path: string, maxBytes: integer): FileRead
  local file = io.open(path, "rb")
  if file == nil then
    return { data = nil, tooLarge = false }
  end
  local size: number | nil = file:seek("end")
  if size == nil then
    file:close()
    return { data = nil, tooLarge = false }
  end
  if size > maxBytes then
    file:close()
    return { data = nil, tooLarge = true }
  end
  file:seek("set", 0)
  -- Read at most cap+1 even if the file grows between seek and read.
  -- `read(n)` returns nil both for a directory and for an empty regular file;
  -- the size tells them apart.
  local data: string | nil = file:read(maxBytes + 1)
  file:close()
  if data == nil then
    if size == 0 then
      return { data = "", tooLarge = false }
    end
    return { data = nil, tooLarge = false }
  end
  if #data > maxBytes then
    return { data = nil, tooLarge = true }
  end
  return { data = data!, tooLarge = false }
end

type RangeResult = {
  start: integer,
  finish: integer,
  ok: boolean,
  unsatisfiable: boolean,
}

local function parseRange(header: string, size: integer): RangeResult | nil
  if string.lower(string.sub(header, 1, 6)) ~= "bytes=" then
    return nil
  end
  local spec: string = string.sub(header, 7)
  if literal.contains(spec, ",") then
    return nil -- multiple ranges are deliberately unsupported
  end
  local dash: integer | nil = literal.find(spec, "-", 1)
  if dash == nil then return nil end
  local at: integer = dash!
  local firstText: string = string.sub(spec, 1, at - 1)
  local lastText: string = string.sub(spec, at + 1)
  if firstText == "" then
    local suffix: integer | nil = parseInt(lastText)
    if suffix == nil or suffix! <= 0 then return nil end
    if size == 0 then
      return { start = 0, finish = -1, ok = false, unsatisfiable = true }
    end
    local n: integer = suffix!
    if n > size then n = size end
    return { start = size - n, finish = size - 1, ok = true, unsatisfiable = false }
  end
  local start: integer | nil = parseInt(firstText)
  if start == nil then return nil end
  if start! >= size then
    return { start = start!, finish = start!, ok = false, unsatisfiable = true }
  end
  if lastText == "" then
    return { start = start!, finish = size - 1, ok = true, unsatisfiable = false }
  end
  local finishAt: integer | nil = parseInt(lastText)
  if finishAt == nil or finishAt! < start! then
    return { start = start!, finish = start!, ok = false, unsatisfiable = true }
  end
  local finish: integer = finishAt!
  if finish >= size then finish = size - 1 end
  return { start = start!, finish = finish, ok = true, unsatisfiable = false }
end

class HttpStatic implements StaticApi {
  root: string,
  prefix: string,
  indexFile: string,
  maxBytes: integer,
  dotfiles: boolean,
  cacheControl: string,

  constructor(options: StaticOptions)
    local root: string | nil = options.root
    if root == nil or root! == "" then
      error("HttpStatic: root is required")
    end
    self.root = root!
    self.prefix = ""
    local prefix: string | nil = options.prefix
    if prefix ~= nil then
      local value: string = prefix!
      while #value > 1 and string.sub(value, -1) == "/" do
        value = string.sub(value, 1, -2)
      end
      if value == "/" then
        self.prefix = ""
      else
        self.prefix = value
      end
    end
    self.indexFile = "index.html"
    local index: string | nil = options.indexFile
    if index ~= nil then self.indexFile = index! end
    local indexName: string = self.indexFile
    if indexName == "" or indexName == "." or indexName == ".."
      or literal.contains(indexName, "/")
      or literal.contains(indexName, "\\")
      or literal.contains(indexName, "\0") then
      error("HttpStatic: indexFile must be a plain file name")
    end
    self.maxBytes = 8 * 1024 * 1024
    local maxBytes: integer | nil = options.maxBytes
    if maxBytes ~= nil then self.maxBytes = maxBytes! end
    if self.maxBytes < 0 then
      error("HttpStatic: maxBytes must be >= 0")
    end
    self.dotfiles = false
    local dotfiles: boolean | nil = options.dotfiles
    if dotfiles ~= nil then self.dotfiles = dotfiles! end
    self.cacheControl = ""
    local cache: string | nil = options.cacheControl
    if cache ~= nil then self.cacheControl = cache! end
    if not headers.validValue(self.cacheControl) then
      error("HttpStatic: cacheControl contains CR/LF/NUL")
    end
  end,

  handler(): Handler
    local this = self
    return function(ctx: HttpContextApi): void
      this:serve(ctx)
    end
  end,

  relativePath(path: string): string | nil
    if self.prefix ~= "" then
      if path == self.prefix then
        return ""
      end
      if string.sub(path, 1, #self.prefix + 1) ~= self.prefix .. "/" then
        return nil
      end
      return string.sub(path, #self.prefix + 2)
    end
    return path
  end,

  serve(ctx: HttpContextApi): void
    local method: string = string.upper(ctx.req.method)
    if method ~= "GET" and method ~= "HEAD" then
      ctx.res.headers:set("Allow", "GET, HEAD")
      ctx:text("Method Not Allowed", 405)
      return
    end
    local relative: string | nil = self:relativePath(ctx.req.path)
    if relative == nil then
      ctx:text("Not Found", 404)
      return
    end
    if relative! == "" then
      relative = self.indexFile
    end
    -- Encoded slashes are ambiguous: the router treats them as part of one
    -- segment, while a filesystem join would treat them as separators. Reject
    -- the ambiguity instead of letting the two layers disagree.
    local lowerRelative: string = string.lower(relative!)
    if literal.contains(lowerRelative, "%2f") then
      ctx:text("Forbidden", 403)
      return
    end
    -- Decode exactly once: dotfile checks and path joining must agree, or a
    -- double-encoded name could slip past the dotfile policy.
    local decoded: string = url.decodeComponent(relative!)
    if not self.dotfiles then
      for part in string.gmatch(decoded, "[^/]+") do
        if string.sub(part, 1, 1) == "." and part ~= "." and part ~= ".." then
          ctx:text("Not Found", 404)
          return
        end
      end
    end
    local path: string | nil = url.safeJoinDecoded(self.root, decoded)
    if path == nil then
      ctx:text("Forbidden", 403)
      return
    end
    local target: string = path!
    local primary: FileRead = readCapped(target, self.maxBytes)
    if primary.tooLarge then
      ctx:text("Content Too Large", 413)
      return
    end
    local body: string
    if primary.data ~= nil then
      body = primary.data!
    else
      -- `io.open` also succeeds for directories on Linux; their index file
      -- is the actual representation. A missing index is a plain 404.
      local indexTarget: string = target .. "/" .. self.indexFile
      local fallback: FileRead = readCapped(indexTarget, self.maxBytes)
      if fallback.tooLarge then
        ctx:text("Content Too Large", 413)
        return
      end
      if fallback.data == nil then
        ctx:text("Not Found", 404)
        return
      end
      body = fallback.data!
      target = indexTarget
    end

    local tag: string = date.etag(body)
    ctx.res.headers:set("ETag", tag)
    ctx.res.headers:set("Accept-Ranges", "bytes")
    if self.cacheControl ~= "" then
      ctx.res.headers:set("Cache-Control", self.cacheControl)
    end
    local inm: string | nil = ctx.req.headers:get("If-None-Match")
    if inm ~= nil and etagMatches(inm!, tag) then
      ctx.res.status = 304
      return
    end

    local rangeHeader: string | nil = ctx.req.headers:get("Range")
    if rangeHeader ~= nil then
      rangeHeader = trimOws(rangeHeader!)
    end
    local useRange: boolean = rangeHeader ~= nil and rangeHeader! ~= ""
    if useRange then
      local ifRange: string | nil = ctx.req.headers:get("If-Range")
      if ifRange ~= nil and ifRange! ~= tag then
        useRange = false
      end
    end
    if useRange then
      local range: RangeResult | nil = parseRange(rangeHeader!, #body)
      if range == nil then
        -- Malformed/multiple ranges: ignore Range and send the full file.
        useRange = false
      elseif not range!.ok then
        ctx.res.status = 416
        ctx.res.headers:set("Content-Range", "bytes */" .. tostring(#body))
        ctx.res.headers:set("Content-Type", mime.typeFor(target))
        ctx.res.body = ""
        return
      else
        local slice: string = string.sub(body, range!.start + 1, range!.finish + 1)
        ctx.res.status = 206
        ctx.res.headers:set(
          "Content-Range",
          "bytes " .. tostring(range!.start) .. "-" .. tostring(range!.finish)
            .. "/" .. tostring(#body)
        )
        ctx.res.headers:set("Content-Type", mime.typeFor(target))
        ctx.res.body = slice
        return
      end
    end

    ctx.res.status = 200
    ctx.res.headers:set("Content-Type", mime.typeFor(target))
    ctx.res.body = body
  end,
}

return {
  HttpStatic = HttpStatic,
  parseRange = parseRange,
  etagMatches = etagMatches,
  readCapped = readCapped,
}
