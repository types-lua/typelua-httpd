--- Strict Base64 wrapper over `typelua-stdlib/encoding`.
---
--- The wrapper preserves the HTTP library's historical API: `decode` raises
--- on malformed input and requires padded, four-byte-group input. The actual
--- alphabet/validation implementation lives in the standard library.

import encoding from "github.com/types-lua/typelua-stdlib/encoding"

local function encode(data: string): string
  return encoding.base64Encode(data)
end

local function decode(value: string): string
  if #value % 4 ~= 0 then
    error("invalid base64 length")
  end
  local result = encoding.base64Decode(value)
  if not result.ok then
    error(result.error)
  end
  return result.data
end

return {
  encode = encode,
  decode = decode,
}
