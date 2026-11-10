--- RFC 7231 dates and deterministic ETags.
---
--- `os.date("*t")` fields are used instead of `%a`/`%b` so the output does
--- not depend on the process locale.

local DAYS: string[] = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS: string[] = {
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

local function httpDate(epoch: number): string
  local t: any = os.date("!*t", epoch)
  local day: string = DAYS[(t.wday as integer)]!
  local month: string = MONTHS[(t.month as integer)]!
  return string.format(
    "%s, %02d %s %04d %02d:%02d:%02d GMT",
    day,
    t.day,
    month,
    t.year,
    t.hour,
    t.min,
    t.sec
  )
end

--- Content ETag: two independent 31-bit rolling hashes. A single 31-bit
--- checksum would make accidental 304s plausible on large static trees;
--- 62 bits of tag removes that practical risk without bitwise operators.
local function etag(data: string): string
  local hashA: integer = 5381
  local hashB: integer = 52711
  for i: integer = 1, #data do
    local byte: integer = string.byte(data, i)!
    hashA = math.floor((hashA * 131 + byte) % 2147483647)
    hashB = math.floor((hashB * 137 + byte) % 2147483629)
  end
  return "\"" .. string.format("%08x%08x", hashA, hashB) .. "\""
end

local function now(): number
  return os.time()
end

return {
  httpDate = httpDate,
  etag = etag,
  now = now,
}
