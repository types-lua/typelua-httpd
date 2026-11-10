--- HPACK (RFC 7541) decoder and stateless encoder.
---
--- The decoder keeps the per-connection dynamic table, validates table-size
--- updates, enforces header-list limits and supports Huffman strings. The
--- encoder uses static indexed fields and literal-without-indexing fields;
--- that is valid HPACK and avoids encoder-side state, while remaining readable
--- by every HTTP/2 peer.

import tables from "./http_hpack_tables"
import literal from "./http_literal"

type HpackHeader = {
  name: string,
  value: string,
}

type HpackDecodeResult = {
  headers: HpackHeader[] | nil,
  error: string,
}

type HpackInt = {
  value: integer,
  pos: integer,
  err: string,
}

type HpackStr = {
  value: string,
  pos: integer,
  err: string,
}

local STATIC: HpackHeader[] = tables.static
local HUFF_CODES: integer[] = tables.huffmanCodes
local HUFF_LENGTHS: integer[] = tables.huffmanLengths

local EXACT: map<string, integer> = {}
local BY_NAME: map<string, integer> = {}
for i: integer = 1, #STATIC do
  local h: HpackHeader = STATIC[i]
  local byNameKey: string = h.name
  if BY_NAME[byNameKey] == nil then BY_NAME[byNameKey] = i end
  local byValueKey: string = h.name .. "\0" .. h.value
  if EXACT[byValueKey] == nil then EXACT[byValueKey] = i end
end

-- Huffman decoding tree: node 1 is the root; 0 means "no child".
local CHILD0: integer[] = { 0 }
local CHILD1: integer[] = { 0 }
local SYMBOL: integer[] = { 0 }

local function newNode(): integer
  CHILD0[#CHILD0 + 1] = 0
  CHILD1[#CHILD1 + 1] = 0
  SYMBOL[#SYMBOL + 1] = 0
  return #CHILD0
end

for symbol: integer = 1, 257 do
  local code: integer = 0
  local length: integer = 0
  if symbol <= 256 then
    code = HUFF_CODES[symbol]
    length = HUFF_LENGTHS[symbol]
  else
    code = 1073741823 -- EOS: 30 bits of ones
    length = 30
  end
  local node: integer = 1
  for bit: integer = length - 1, 0, -1 do
    local b: integer = math.floor((code / (2 ^ bit)) % 2)
    if b == 0 then
      local nextNode: integer = CHILD0[node]
      if nextNode == 0 then
        nextNode = newNode()
        CHILD0[node] = nextNode
      end
      node = nextNode
    else
      local nextNode: integer = CHILD1[node]
      if nextNode == 0 then
        nextNode = newNode()
        CHILD1[node] = nextNode
      end
      node = nextNode
    end
  end
  SYMBOL[node] = symbol
end

local function huffmanDecode(data: string): (string, string)
  local out: string[] = {}
  local node: integer = 1
  local tailBits: integer = 0
  local tailOnes: boolean = true
  for i: integer = 1, #data do
    local byte: integer = string.byte(data, i)!
    for shift: integer = 7, 0, -1 do
      local bit: integer = math.floor((byte / (2 ^ shift)) % 2)
      local nextNode: integer = 0
      if bit == 0 then
        nextNode = CHILD0[node]
      else
        nextNode = CHILD1[node]
      end
      if nextNode == 0 then
        return "", "invalid Huffman code"
      end
      node = nextNode
      tailBits = tailBits + 1
      if bit == 0 then tailOnes = false end
      local symbol: integer = SYMBOL[node]
      if symbol ~= 0 then
        if symbol == 257 then
          return "", "EOS symbol is not allowed in a Huffman string"
        end
        out[#out + 1] = string.char(symbol - 1)
        node = 1
        tailBits = 0
        tailOnes = true
      end
    end
  end
  if tailBits > 7 or not tailOnes then
    return "", "invalid Huffman padding"
  end
  return table.concat(out), ""
end

local function encodeInt(value: integer, prefix: integer, flag: integer): string
  local max: integer = math.floor(2 ^ prefix - 1)
  if value < max then
    return string.char(math.floor(flag + value))
  end
  local out: string[] = { string.char(flag + max) }
  local rest: integer = value - max
  while rest >= 128 do
    out[#out + 1] = string.char(math.floor(rest % 128 + 128))
    rest = math.floor(rest / 128)
  end
  out[#out + 1] = string.char(rest)
  return table.concat(out)
end

local function encodeString(value: string): string
  return encodeInt(#value, 7, 0) .. value
end

local function readInt(
  data: string,
  start: integer,
  prefix: integer,
  firstByte: integer
): HpackInt
  local max: integer = math.floor(2 ^ prefix - 1)
  local value: integer = math.floor(firstByte % (max + 1))
  local pos: integer = start + 1
  if value < max then
    return { value = value, pos = pos, err = "" }
  end
  local shift: integer = 0
  while true do
    if pos > #data then
      return { value = 0, pos = pos, err = "truncated HPACK integer" }
    end
    local b: integer = string.byte(data, pos)!
    pos = pos + 1
    value = math.floor(value + (b % 128) * (2 ^ shift))
    if value > 2147483647 then
      return { value = 0, pos = pos, err = "HPACK integer overflow" }
    end
    if b < 128 then break end
    shift = shift + 7
    if shift > 28 then
      return { value = 0, pos = pos, err = "HPACK integer is too large" }
    end
  end
  return { value = value, pos = pos, err = "" }
end

local function readString(data: string, start: integer): HpackStr
  if start > #data then
    return { value = "", pos = start, err = "truncated HPACK string" }
  end
  local b: integer = string.byte(data, start)!
  local huffman: boolean = b >= 128
  local length: HpackInt = readInt(data, start, 7, b)
  if length.err ~= "" then
    return { value = "", pos = length.pos, err = length.err }
  end
  if length.pos + length.value - 1 > #data then
    return { value = "", pos = length.pos, err = "truncated HPACK string bytes" }
  end
  local raw: string = string.sub(data, length.pos, length.pos + length.value - 1)
  if huffman then
    local decoded, err = huffmanDecode(raw)
    return { value = decoded, pos = length.pos + length.value, err = err }
  end
  return { value = raw, pos = length.pos + length.value, err = "" }
end

local function encodeHeaders(headers: HpackHeader[]): string
  local parts: string[] = {}
  for i: integer = 1, #headers do
    local h: HpackHeader = headers[i]
    local exact: integer | nil = EXACT[h.name .. "\0" .. h.value]
    if exact ~= nil then
      parts[#parts + 1] = encodeInt(exact!, 7, 128)
    else
      local nameIndex: integer = 0
      local found: integer | nil = BY_NAME[h.name]
      if found ~= nil then nameIndex = found! end
      parts[#parts + 1] = encodeInt(nameIndex, 4, 0)
      if nameIndex == 0 then
        parts[#parts + 1] = encodeString(h.name)
      end
      parts[#parts + 1] = encodeString(h.value)
    end
  end
  return table.concat(parts)
end

class HpackDecoder {
  dynamic: HpackHeader[] = {},
  dynamicSize: integer = 0,
  maxSize: integer = 4096,
  allowedMax: integer = 4096,
  maxHeaderList: integer = 65536,
  maxHeaders: integer = 200,

  constructor() end,

  headerAt(index: integer): HpackHeader | nil
    if index >= 1 and index <= #STATIC then
      return STATIC[index]
    end
    local d: integer = index - #STATIC
    if d >= 1 and d <= #self.dynamic then
      return self.dynamic[d]
    end
    return nil
  end,

  addDynamic(name: string, value: string): void
    local entrySize: integer = #name + #value + 32
    if entrySize > self.maxSize then
      self.dynamic = {}
      self.dynamicSize = 0
      return
    end
    table.insert(self.dynamic, 1, { name = name, value = value })
    self.dynamicSize = self.dynamicSize + entrySize
    while self.dynamicSize > self.maxSize and #self.dynamic > 0 do
      local last: HpackHeader = self.dynamic[#self.dynamic]!
      self.dynamicSize = self.dynamicSize - (#last.name + #last.value + 32)
      table.remove(self.dynamic)
    end
  end,

  decode(data: string): HpackDecodeResult
    local headers: HpackHeader[] = {}
    local pos: integer = 1
    local listSize: integer = 0
    local sawField: boolean = false
    while pos <= #data do
      local beforeCount: integer = #headers
      local b: integer = string.byte(data, pos)!
      if b >= 128 then
        local r: HpackInt = readInt(data, pos, 7, b)
        if r.err ~= "" then return { headers = nil, error = r.err } end
        pos = r.pos
        local h: HpackHeader | nil = self:headerAt(r.value)
        if h == nil then return { headers = nil, error = "invalid HPACK index" } end
        headers[#headers + 1] = { name = h!.name, value = h!.value }
        sawField = true
      elseif b >= 64 then
        local r: HpackInt = readInt(data, pos, 6, b)
        if r.err ~= "" then return { headers = nil, error = r.err } end
        pos = r.pos
        local name: string = ""
        if r.value == 0 then
          local s: HpackStr = readString(data, pos)
          if s.err ~= "" then return { headers = nil, error = s.err } end
          name = s.value
          pos = s.pos
        else
          local h: HpackHeader | nil = self:headerAt(r.value)
          if h == nil then return { headers = nil, error = "invalid HPACK name index" } end
          name = h!.name
        end
        local v: HpackStr = readString(data, pos)
        if v.err ~= "" then return { headers = nil, error = v.err } end
        pos = v.pos
        headers[#headers + 1] = { name = name, value = v.value }
        self:addDynamic(name, v.value)
        sawField = true
      elseif b >= 32 then
        if sawField then
          return { headers = nil, error = "HPACK table size update after a field" }
        end
        local r: HpackInt = readInt(data, pos, 5, b)
        if r.err ~= "" then return { headers = nil, error = r.err } end
        pos = r.pos
        if r.value > self.allowedMax then
          return { headers = nil, error = "HPACK table size update exceeds limit" }
        end
        self.maxSize = r.value
        while self.dynamicSize > self.maxSize and #self.dynamic > 0 do
          local last: HpackHeader = self.dynamic[#self.dynamic]!
          self.dynamicSize = self.dynamicSize - (#last.name + #last.value + 32)
          table.remove(self.dynamic)
        end
      else
        local prefix: integer = 4
        local r: HpackInt = readInt(data, pos, prefix, b)
        if r.err ~= "" then return { headers = nil, error = r.err } end
        pos = r.pos
        local name: string = ""
        if r.value == 0 then
          local s: HpackStr = readString(data, pos)
          if s.err ~= "" then return { headers = nil, error = s.err } end
          name = s.value
          pos = s.pos
        else
          local h: HpackHeader | nil = self:headerAt(r.value)
          if h == nil then return { headers = nil, error = "invalid HPACK name index" } end
          name = h!.name
        end
        local v: HpackStr = readString(data, pos)
        if v.err ~= "" then return { headers = nil, error = v.err } end
        pos = v.pos
        headers[#headers + 1] = { name = name, value = v.value }
        sawField = true
      end
      if #headers > self.maxHeaders then
        return { headers = nil, error = "too many HPACK headers" }
      end
      if #headers > beforeCount then
        local last: HpackHeader = headers[#headers]
        listSize = listSize + #last.name + #last.value + 32
        if listSize > self.maxHeaderList then
          return { headers = nil, error = "HPACK header list too large" }
        end
      end
    end
    if pos ~= #data + 1 then
      return { headers = nil, error = "truncated HPACK header block" }
    end
    return { headers = headers, error = "" }
  end,
}

return {
  STATIC = STATIC,
  HpackDecoder = HpackDecoder,
  encodeHeaders = encodeHeaders,
  huffmanDecode = huffmanDecode,
  encodeInt = encodeInt,
  encodeString = encodeString,
}
