--- Portable 32-bit bit twiddling for Lua 5.1/LuaJIT/Lua 5.4.
---
--- Tiny nibble lookup tables keep SHA-1 and WebSocket masking independent of
--- `bit32` / LuaJIT `bit`. HPACK needs no 32-bit bitwise operations.

local MOD: number = 4294967296

local AND4: map<integer, integer[]> = {}
local OR4: map<integer, integer[]> = {}
local XOR4: map<integer, integer[]> = {}

local function small(a: integer, b: integer, op: string): integer
  local out: integer = 0
  local mul: integer = 1
  for _: integer = 1, 4 do
    local abit: integer = a % 2
    local bbit: integer = b % 2
    local bit: integer = 0
    if op == "and" then
      if abit == 1 and bbit == 1 then bit = 1 end
    elseif op == "or" then
      if abit == 1 or bbit == 1 then bit = 1 end
    else
      if abit ~= bbit then bit = 1 end
    end
    out = out + bit * mul
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    mul = mul * 2
  end
  return out
end

for a: integer = 0, 15 do
  local andRow: integer[] = {}
  local orRow: integer[] = {}
  local xorRow: integer[] = {}
  for b: integer = 0, 15 do
    andRow[b] = small(a, b, "and")
    orRow[b] = small(a, b, "or")
    xorRow[b] = small(a, b, "xor")
  end
  AND4[a] = andRow
  OR4[a] = orRow
  XOR4[a] = xorRow
end

local function bitop(a: integer, b: integer, table16: map<integer, integer[]>): integer
  local out: integer = 0
  local mul: integer = 1
  for _: integer = 1, 8 do
    local av: integer = a % 16
    local bv: integer = b % 16
    out = out + table16[av][bv] * mul
    a = math.floor(a / 16)
    b = math.floor(b / 16)
    mul = mul * 16
  end
  return out
end

local function band(a: integer, b: integer): integer
  return bitop(a, b, AND4)
end

local function bor(a: integer, b: integer): integer
  return bitop(a, b, OR4)
end

local function bxor(a: integer, b: integer): integer
  return bitop(a, b, XOR4)
end

local function bnot(a: integer): integer
  return math.floor(4294967295 - (a % MOD))
end

local function lshift32(a: integer, n: integer): integer
  if n <= 0 then return math.floor(a % MOD) end
  if n >= 32 then return 0 end
  local low: integer = a % 65536
  local high: integer = math.floor(a / 65536)
  local lowPart: number = (low * 2 ^ n) % MOD
  local highPart: number = (high * 2 ^ n) % 65536
  return math.floor((lowPart + highPart * 65536) % MOD)
end

local function rshift32(a: integer, n: integer): integer
  if n <= 0 then return math.floor(a % MOD) end
  if n >= 32 then return 0 end
  return math.floor((a % MOD) / 2 ^ n)
end

local function rol32(a: integer, n: integer): integer
  n = math.floor(n % 32)
  if n == 0 then return math.floor(a % MOD) end
  return math.floor((lshift32(a, n) + rshift32(a, 32 - n)) % MOD)
end

local function add32(a: integer, b: integer): integer
  return math.floor((a + b) % MOD)
end

--- XOR a byte string with a repeating key, returning a byte string.
local function xorRepeat(data: string, key: string): string
  if #key == 0 then return data end
  local out: string[] = {}
  local kpos: integer = 1
  for i: integer = 1, #data do
    local byte: integer = string.byte(data, i)!
    local k: integer = string.byte(key, kpos)!
    local lo: integer = XOR4[byte % 16][k % 16]
    local hi: integer = XOR4[math.floor(byte / 16)][math.floor(k / 16)]
    out[#out + 1] = string.char(hi * 16 + lo)
    kpos = kpos + 1
    if kpos > #key then kpos = 1 end
  end
  return table.concat(out)
end

local function hex32(value: integer): string
  local v: integer = math.floor(value % MOD)
  local bytes: string[] = {}
  for i: integer = 3, 0, -1 do
    local divisor: number = 2 ^ (i * 8)
    local byte: integer = math.floor((v / divisor) % 256)
    bytes[#bytes + 1] = string.format("%02x", byte)
  end
  return table.concat(bytes)
end

return {
  MOD = MOD,
  band = band,
  bor = bor,
  bxor = bxor,
  bnot = bnot,
  lshift32 = lshift32,
  rshift32 = rshift32,
  rol32 = rol32,
  add32 = add32,
  xorRepeat = xorRepeat,
  hex32 = hex32,
}
