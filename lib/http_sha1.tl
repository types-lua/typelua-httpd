--- SHA-1 for the WebSocket handshake.
---
--- SHA-1 is not used for signatures or password storage here; RFC 6455
--- mandates it for `Sec-WebSocket-Accept`.

import bits from "./http_bits"

local K: integer[] = {
  1518500249, 1518500249, 1518500249, 1518500249, 1518500249,
  1518500249, 1518500249, 1518500249, 1518500249, 1518500249,
  1518500249, 1518500249, 1518500249, 1518500249, 1518500249,
  1518500249, 1518500249, 1518500249, 1518500249, 1518500249,
  1859775393, 1859775393, 1859775393, 1859775393, 1859775393,
  1859775393, 1859775393, 1859775393, 1859775393, 1859775393,
  1859775393, 1859775393, 1859775393, 1859775393, 1859775393,
  1859775393, 1859775393, 1859775393, 1859775393, 1859775393,
  2400959708, 2400959708, 2400959708, 2400959708, 2400959708,
  2400959708, 2400959708, 2400959708, 2400959708, 2400959708,
  2400959708, 2400959708, 2400959708, 2400959708, 2400959708,
  2400959708, 2400959708, 2400959708, 2400959708, 2400959708,
  3395469782, 3395469782, 3395469782, 3395469782, 3395469782,
  3395469782, 3395469782, 3395469782, 3395469782, 3395469782,
  3395469782, 3395469782, 3395469782, 3395469782, 3395469782,
  3395469782, 3395469782, 3395469782, 3395469782, 3395469782,
}

local function word(data: string, at: integer): integer
  local b1: integer = string.byte(data, at)!
  local b2: integer = string.byte(data, at + 1)!
  local b3: integer = string.byte(data, at + 2)!
  local b4: integer = string.byte(data, at + 3)!
  return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
end

local function digest(data: string): string
  local message: string = data .. "\128"
  local pad: integer = (56 - (#message % 64)) % 64
  message = message .. string.rep("\0", pad)
  local bitLength: number = #data * 8
  local high: number = math.floor(bitLength / 4294967296) % 4294967296
  local low: number = bitLength % 4294967296
  local lengths: string[] = {}
  local values: number[] = { high, low }
  for v: integer = 1, 2 do
    local n: number = values[v]
    for shift: integer = 3, 0, -1 do
      lengths[#lengths + 1] = string.char(math.floor(n / (256 ^ shift)) % 256)
    end
  end
  message = message .. table.concat(lengths)

  local h0: integer = 1732584193
  local h1: integer = 4023233417
  local h2: integer = 2562383102
  local h3: integer = 271733878
  local h4: integer = 3285377520

  local w: integer[] = {}
  local offset: integer = 1
  while offset <= #message do
    for i: integer = 1, 16 do
      w[i] = word(message, offset + (i - 1) * 4)
    end
    for i: integer = 17, 80 do
      w[i] = bits.rol32(
        bits.bxor(bits.bxor(w[i - 3], w[i - 8]), bits.bxor(w[i - 14], w[i - 16])),
        1
      )
    end

    local a: integer = h0
    local b: integer = h1
    local c: integer = h2
    local d: integer = h3
    local e: integer = h4
    for i: integer = 1, 80 do
      local f: integer = 0
      if i <= 20 then
        f = bits.bor(bits.band(b, c), bits.band(bits.bnot(b), d))
      elseif i <= 40 then
        f = bits.bxor(bits.bxor(b, c), d)
      elseif i <= 60 then
        f = bits.bor(bits.bor(bits.band(b, c), bits.band(b, d)), bits.band(c, d))
      else
        f = bits.bxor(bits.bxor(b, c), d)
      end
      local temp: integer = bits.add32(
        bits.add32(bits.add32(bits.rol32(a, 5), f), bits.add32(e, K[i])),
        w[i]
      )
      e = d
      d = c
      c = bits.rol32(b, 30)
      b = a
      a = temp
    end
    h0 = bits.add32(h0, a)
    h1 = bits.add32(h1, b)
    h2 = bits.add32(h2, c)
    h3 = bits.add32(h3, d)
    h4 = bits.add32(h4, e)
    offset = offset + 64
  end

  local out: string[] = {}
  local state: integer[] = { h0, h1, h2, h3, h4 }
  for i: integer = 1, 5 do
    local value: integer = state[i]
    for shift: integer = 3, 0, -1 do
      out[#out + 1] = string.char(math.floor(value / (256 ^ shift)) % 256)
    end
  end
  return table.concat(out)
end

local function hex(data: string): string
  local out: string[] = {}
  for i: integer = 1, #data do
    out[#out + 1] = string.format("%02x", string.byte(data, i)!)
  end
  return table.concat(out)
end

return {
  digest = digest,
  hex = hex,
}
