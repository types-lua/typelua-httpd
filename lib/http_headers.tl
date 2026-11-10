--- Case-insensitive, ordered HTTP header collection.
---
--- Header names are validated as RFC 7230 tokens and values reject CR/LF/NUL,
--- which closes the response-splitting hole before anything reaches the wire.
--- Insertion order is preserved for deterministic output.

local function isTokenChar(c: integer): boolean
  if c >= 48 and c <= 57 then return true end
  if c >= 65 and c <= 90 then return true end
  if c >= 97 and c <= 122 then return true end
  return c == 33 or c == 35 or c == 36 or c == 37 or c == 38 or c == 39
    or c == 42 or c == 43 or c == 45 or c == 46 or c == 94 or c == 95
    or c == 96 or c == 124 or c == 126
end

local function validName(name: string): boolean
  if name == "" then return false end
  for i: integer = 1, #name do
    local c: integer = string.byte(name, i)!
    if not isTokenChar(c) then return false end
  end
  return true
end

local function validValue(value: string): boolean
  for i: integer = 1, #value do
    local c: integer = string.byte(value, i)!
    -- field-vchar / SP / HTAB only: rejecting the remaining C0 controls
    -- prevents header-injection variants that survive CR/LF filtering.
    if (c < 32 and c ~= 9) or c == 127 then
      return false
    end
  end
  return true
end

local function lower(value: string): string
  return string.lower(value)
end

class Headers implements HeadersApi {
  items: HeaderEntry[] = {},
  indexes: map<string, integer[]> = {},

  constructor() end,

  set(name: string, value: string): void
    self:validate(name, value)
    self:remove(name)
    self:addEntry({ name = name, value = value })
  end,

  add(name: string, value: string): void
    self:validate(name, value)
    self:addEntry({ name = name, value = value })
  end,

  setIfAbsent(name: string, value: string): void
    if not self:has(name) then
      self:set(name, value)
    end
  end,

  get(name: string): string | nil
    local key: string = lower(name)
    local list: integer[] | nil = self.indexes[key]
    if list == nil then
      return nil
    end
    local owner: integer[] = list!
    if #owner == 0 then
      return nil
    end
    return self.items[owner[1]!].value
  end,

  getAll(name: string): string[]
    local key: string = lower(name)
    local out: string[] = {}
    local list: integer[] | nil = self.indexes[key]
    if list == nil then
      return out
    end
    local owner: integer[] = list!
    for i: integer = 1, #owner do
      out[#out + 1] = self.items[owner[i]!].value
    end
    return out
  end,

  has(name: string): boolean
    local list: integer[] | nil = self.indexes[lower(name)]
    if list == nil then
      return false
    end
    return #list! > 0
  end,

  remove(name: string): void
    local key: string = lower(name)
    local list: integer[] | nil = self.indexes[key]
    if list == nil then
      return
    end
    local drop: map<integer, boolean> = {}
    for i: integer = 1, #list do
      drop[list[i]!] = true
    end
    local kept: HeaderEntry[] = {}
    for i: integer = 1, #self.items do
      if drop[i] ~= true then
        kept[#kept + 1] = self.items[i]
      end
    end
    self.items = kept
    self:rebuild()
  end,

  count(): integer
    return #self.items
  end,

  entries(): HeaderEntry[]
    local out: HeaderEntry[] = {}
    for i: integer = 1, #self.items do
      local e: HeaderEntry = self.items[i]
      out[i] = { name = e.name, value = e.value }
    end
    return out
  end,

  clone(): Headers
    local copy = Headers.new()
    for i: integer = 1, #self.items do
      local e: HeaderEntry = self.items[i]
      copy:add(e.name, e.value)
    end
    return copy
  end,

  validate(name: string, value: string): void
    if not validName(name) then
      error("invalid HTTP header name: " .. name)
    end
    if not validValue(value) then
      error("invalid HTTP header value for " .. name .. " (CR/LF/NUL)")
    end
  end,

  addEntry(entry: HeaderEntry): void
    self.items[#self.items + 1] = entry
    local key: string = lower(entry.name)
    local created: integer[] = {}
    local existing: integer[] | nil = self.indexes[key]
    if existing ~= nil then
      created = existing!
    end
    created[#created + 1] = #self.items
    self.indexes[key] = created
  end,

  rebuild(): void
    self.indexes = {}
    for i: integer = 1, #self.items do
      local key: string = lower(self.items[i].name)
      local created: integer[] = {}
      local existing: integer[] | nil = self.indexes[key]
      if existing ~= nil then
        created = existing!
      end
      created[#created + 1] = i
      self.indexes[key] = created
    end
  end,
}

return {
  Headers = Headers,
  validName = validName,
  validValue = validValue,
}
