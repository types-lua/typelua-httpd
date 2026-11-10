--- Strict standard Base64 (RFC 4648) without padding shortcuts.
---
--- Used by the WebSocket handshake. Decoding rejects whitespace and
--- non-alphabet characters instead of silently skipping them.

local ALPHABET: string = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function valueOf(c: integer): integer
  if c >= 65 and c <= 90 then return c - 65 end
  if c >= 97 and c <= 122 then return c - 71 end
  if c >= 48 and c <= 57 then return c + 4 end
  if c == 43 then return 62 end
  if c == 47 then return 63 end
  return -1
end

local function encode(data: string): string
  local out: string[] = {}
  local i: integer = 1
  while i <= #data do
    local b1: integer = string.byte(data, i)!
    local b2: integer = 0
    local b3: integer = 0
    local have2: boolean = i + 1 <= #data
    local have3: boolean = i + 2 <= #data
    if have2 then b2 = string.byte(data, i + 1)! end
    if have3 then b3 = string.byte(data, i + 2)! end
    local n: integer = b1 * 65536 + b2 * 256 + b3
    local c1: integer = math.floor((n / 262144) % 64)
    local c2: integer = math.floor((n / 4096) % 64)
    local c3: integer = math.floor((n / 64) % 64)
    local c4: integer = math.floor(n % 64)
    out[#out + 1] = string.sub(ALPHABET, c1 + 1, c1 + 1)
    out[#out + 1] = string.sub(ALPHABET, c2 + 1, c2 + 1)
    if have2 then
      out[#out + 1] = string.sub(ALPHABET, c3 + 1, c3 + 1)
    else
      out[#out + 1] = "="
    end
    if have3 then
      out[#out + 1] = string.sub(ALPHABET, c4 + 1, c4 + 1)
    else
      out[#out + 1] = "="
    end
    i = i + 3
  end
  return table.concat(out)
end

local function decode(value: string): string
  if #value % 4 ~= 0 then
    error("invalid base64 length")
  end
  local out: string[] = {}
  local i: integer = 1
  while i <= #value do
    local chunk: string = string.sub(value, i, i + 3)
    local pad: integer = 0
    if string.sub(chunk, 4, 4) == "=" then
      pad = 1
      if string.sub(chunk, 3, 3) == "=" then pad = 2 end
    end
    if pad == 2 and string.sub(chunk, 3, 3) ~= "=" then
      error("invalid base64 padding")
    end
    local c1: integer = valueOf(string.byte(chunk, 1)!)
    local c2: integer = valueOf(string.byte(chunk, 2)!)
    local c3: integer = 0
    local c4: integer = 0
    if pad < 2 then c3 = valueOf(string.byte(chunk, 3)!) end
    if pad < 1 then c4 = valueOf(string.byte(chunk, 4)!) end
    if c1 < 0 or c2 < 0 or c3 < 0 or c4 < 0 then
      error("invalid base64 character")
    end
    local n: integer = c1 * 262144 + c2 * 4096 + c3 * 64 + c4
    out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    if pad < 2 then
      out[#out + 1] = string.char(math.floor(n / 256) % 256)
    end
    if pad < 1 then
      out[#out + 1] = string.char(n % 256)
    end
    i = i + 4
  end
  return table.concat(out)
end

return {
  encode = encode,
  decode = decode,
}
