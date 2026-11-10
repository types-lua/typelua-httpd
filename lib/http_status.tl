--- Status reason phrases and body semantics.

local REASONS: map<string, string> = {
  ["100"] = "Continue",
  ["101"] = "Switching Protocols",
  ["200"] = "OK",
  ["201"] = "Created",
  ["202"] = "Accepted",
  ["204"] = "No Content",
  ["206"] = "Partial Content",
  ["301"] = "Moved Permanently",
  ["302"] = "Found",
  ["303"] = "See Other",
  ["304"] = "Not Modified",
  ["307"] = "Temporary Redirect",
  ["308"] = "Permanent Redirect",
  ["400"] = "Bad Request",
  ["401"] = "Unauthorized",
  ["403"] = "Forbidden",
  ["404"] = "Not Found",
  ["405"] = "Method Not Allowed",
  ["408"] = "Request Timeout",
  ["409"] = "Conflict",
  ["411"] = "Length Required",
  ["413"] = "Content Too Large",
  ["414"] = "URI Too Long",
  ["415"] = "Unsupported Media Type",
  ["417"] = "Expectation Failed",
  ["418"] = "I'm a teapot",
  ["422"] = "Unprocessable Content",
  ["429"] = "Too Many Requests",
  ["431"] = "Request Header Fields Too Large",
  ["500"] = "Internal Server Error",
  ["501"] = "Not Implemented",
  ["502"] = "Bad Gateway",
  ["503"] = "Service Unavailable",
  ["504"] = "Gateway Timeout",
  ["505"] = "HTTP Version Not Supported",
}

local function reason(status: integer): string
  local value: string | nil = REASONS[tostring(status)]
  if value == nil then
    return "Unknown"
  end
  return value!
end

local function isBodyless(status: integer): boolean
  return (status >= 100 and status < 200) or status == 204
    or status == 205 or status == 304
end

local function isRedirect(status: integer): boolean
  return status == 301 or status == 302 or status == 303
    or status == 307 or status == 308
end

return {
  reason = reason,
  isBodyless = isBodyless,
  isRedirect = isRedirect,
}
