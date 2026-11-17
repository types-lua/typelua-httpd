--- Literal substring helpers shared by the HTTP parsers.
---
--- The standard library's implementation is byte-oriented and avoids the
--- embedded-golua `string.find(..., plain=true)` init-offset bug that this
--- module originally worked around. `escapePattern` remains available for
--- callers that need to build a Lua pattern from literal text.

import strings from "github.com/types-lua/typelua-stdlib/strings"

local MAGIC: map<string, boolean> = {
  ["%"] = true, ["^"] = true, ["$"] = true, ["("] = true, [")"] = true,
  ["."] = true, ["["] = true, ["]"] = true, ["*"] = true, ["+"] = true,
  ["-"] = true, ["?"] = true,
}

local function escapePattern(value: string): string
  local out: string[] = {}
  for i: integer = 1, #value do
    local c: string = string.sub(value, i, i)
    if MAGIC[c] == true then
      out[#out + 1] = "%"
    end
    out[#out + 1] = c
  end
  return table.concat(out)
end

local function find(value: string, needle: string, init: integer): integer | nil
  return strings.find(value, needle, init)
end

local function contains(value: string, needle: string): boolean
  return strings.contains(value, needle)
end

return {
  find = find,
  contains = contains,
  escapePattern = escapePattern,
}
