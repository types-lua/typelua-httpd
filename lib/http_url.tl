--- URL, query, cookie and safe path helpers.
---
--- Decoding is intentionally conservative: malformed `%` escapes stay
--- literal, and static-file paths are lexically normalized and rejected when
--- they escape the configured root.

import literal from "./http_literal"

local function hexValue(c: integer): integer
  if c >= 48 and c <= 57 then return c - 48 end
  if c >= 65 and c <= 70 then return c - 55 end
  if c >= 97 and c <= 102 then return c - 87 end
  return -1
end

local function decode(s: string, plusAsSpace: boolean): string
  local parts: string[] = {}
  local i: integer = 1
  while i <= #s do
    local c: integer = string.byte(s, i)!
    if c == 37 and i + 2 <= #s then
      local hi: integer = hexValue(string.byte(s, i + 1)!)
      local lo: integer = hexValue(string.byte(s, i + 2)!)
      if hi >= 0 and lo >= 0 then
        parts[#parts + 1] = string.char(hi * 16 + lo)
        i = i + 3
      else
        parts[#parts + 1] = "%"
        i = i + 1
      end
    elseif plusAsSpace and c == 43 then
      parts[#parts + 1] = " "
      i = i + 1
    else
      parts[#parts + 1] = string.char(c)
      i = i + 1
    end
  end
  return table.concat(parts)
end

local function decodeComponent(value: string): string
  return decode(value, false)
end

local function decodeQueryValue(value: string): string
  return decode(value, true)
end

local function encodeComponent(value: string): string
  local out: string[] = {}
  for i: integer = 1, #value do
    local c: integer = string.byte(value, i)!
    local unreserved: boolean =
      (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
      or c == 45 or c == 46 or c == 95 or c == 126
    if unreserved then
      out[#out + 1] = string.char(c)
    else
      out[#out + 1] = string.format("%%%02X", c)
    end
  end
  return table.concat(out)
end

type Target = {
  path: string,
  rawQuery: string,
}

local function splitTarget(target: string): Target
  if target == "*" then
    return { path = "*", rawQuery = "" }
  end
  local rest: string = target
  local scheme: integer | nil = literal.find(rest, "://", 1)
  if scheme ~= nil then
    local after: integer = scheme! + 3
    local slash: integer | nil = literal.find(rest, "/", after)
    local queryAt: integer | nil = literal.find(rest, "?", after)
    if slash == nil then
      if queryAt == nil then
        rest = "/"
      else
        rest = "/" .. string.sub(rest, queryAt!)
      end
    elseif queryAt ~= nil and queryAt! < slash! then
      rest = "/" .. string.sub(rest, queryAt!)
    else
      rest = string.sub(rest, slash!)
    end
  end
  local question: integer | nil = literal.find(rest, "?", 1)
  if question == nil then
    local path: string = rest
    if path == "" then
      return { path = "/", rawQuery = "" }
    end
    return { path = path, rawQuery = "" }
  end
  local q: integer = question!
  local path: string = string.sub(rest, 1, q - 1)
  if path == "" then
    return { path = "/", rawQuery = string.sub(rest, q + 1) }
  end
  return { path = path, rawQuery = string.sub(rest, q + 1) }
end

local function parseQuery(raw: string): Query
  local out: map<string, string> = {}
  if raw == "" then
    return out
  end
  for part in string.gmatch(raw, "[^&]+") do
    local eq: integer | nil = literal.find(part, "=", 1)
    local name: string
    local value: string
    if eq == nil then
      name = decodeQueryValue(part)
      value = ""
    else
      local e: integer = eq!
      name = decodeQueryValue(string.sub(part, 1, e - 1))
      value = decodeQueryValue(string.sub(part, e + 1))
    end
    if name ~= "" then
      out[name] = value
    end
  end
  return out
end

--- Decoded path segments; empty segments are collapsed, matching the
--- router's normalized view (`/a//b` behaves like `/a/b`).
local function pathSegments(path: string): string[]
  local out: string[] = {}
  for part in string.gmatch(path, "[^/]+") do
    out[#out + 1] = decodeComponent(part)
  end
  return out
end

--- Lexically joins an already-decoded path onto root. Returns nil when the
--- path escapes root or contains NUL/backslash. Callers that accept wire
--- paths must decode exactly once before calling this.
local function safeJoinDecoded(root: string, decoded: string): string | nil
  if literal.find(decoded, "\0", 1) ~= nil then return nil end
  if literal.find(decoded, "\\", 1) ~= nil then return nil end
  local stack: string[] = {}
  for part in string.gmatch(decoded, "[^/]+") do
    if part == ".." then
      if #stack == 0 then return nil end
      table.remove(stack)
    elseif part == "." or part == "" then
      -- skip
    else
      stack[#stack + 1] = part
    end
  end
  local base: string = root
  while #base > 1 and string.sub(base, -1) == "/" do
    base = string.sub(base, 1, -2)
  end
  if #stack == 0 then
    return base
  end
  return base .. "/" .. table.concat(stack, "/")
end

--- Convenience wrapper for a still-encoded request path.
local function safeJoin(root: string, requestPath: string): string | nil
  return safeJoinDecoded(root, decodeComponent(requestPath))
end

local function parseCookies(header: string | nil): map<string, string>
  local out: map<string, string> = {}
  if header == nil or header == "" then
    return out
  end
  for part in string.gmatch(header!, "[^;]+") do
    local item: string = part
    while #item > 0 and string.sub(item, 1, 1) == " " do
      item = string.sub(item, 2)
    end
    while #item > 0 and string.sub(item, -1) == " " do
      item = string.sub(item, 1, -2)
    end
    local eq: integer | nil = literal.find(item, "=", 1)
    if eq ~= nil then
      local e: integer = eq!
      local name: string = string.sub(item, 1, e - 1)
      local value: string = string.sub(item, e + 1)
      if #value >= 2 and string.sub(value, 1, 1) == "\"" and string.sub(value, -1) == "\"" then
        value = string.sub(value, 2, #value - 1)
      end
      if name ~= "" then
        out[name] = value
      end
    end
  end
  return out
end

return {
  decodeComponent = decodeComponent,
  decodeQueryValue = decodeQueryValue,
  encodeComponent = encodeComponent,
  splitTarget = splitTarget,
  parseQuery = parseQuery,
  pathSegments = pathSegments,
  safeJoin = safeJoin,
  safeJoinDecoded = safeJoinDecoded,
  parseCookies = parseCookies,
}
