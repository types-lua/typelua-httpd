--- SHA-1 compatibility wrapper over `typelua-stdlib/hash`.
---
--- SHA-1 is only used for the RFC 6455 WebSocket accept key here. The
--- implementation and vectors live in the standard library.

import hash from "github.com/types-lua/typelua-stdlib/hash"
import encoding from "github.com/types-lua/typelua-stdlib/encoding"

local function digest(data: string): string
  return hash.sha1(data)
end

local function hex(data: string): string
  return encoding.hexEncode(data)
end

return {
  digest = digest,
  hex = hex,
}
