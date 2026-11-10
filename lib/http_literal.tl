--- Literal substring search that works identically on PUC Lua and the
--- embedded golua runtime (which mishandles `string.find(..., plain=true)`
--- when init > 1). Patterns are escaped before searching.

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
  if needle == "" then
    if init < 1 or init > #value + 1 then return nil end
    return init
  end
  local pattern: string = escapePattern(needle)
  local at: integer | nil = string.find(value, pattern, init)
  return at
end

local function contains(value: string, needle: string): boolean
  return find(value, needle, 1) ~= nil
end

return {
  find = find,
  contains = contains,
  escapePattern = escapePattern,
}
