--- Small extension-to-media-type table used by static serving.

local TYPES: map<string, string> = {
  html = "text/html; charset=utf-8",
  htm = "text/html; charset=utf-8",
  css = "text/css; charset=utf-8",
  js = "text/javascript; charset=utf-8",
  mjs = "text/javascript; charset=utf-8",
  json = "application/json; charset=utf-8",
  map = "application/json; charset=utf-8",
  webmanifest = "application/manifest+json",
  txt = "text/plain; charset=utf-8",
  md = "text/markdown; charset=utf-8",
  csv = "text/csv; charset=utf-8",
  xml = "application/xml; charset=utf-8",
  yaml = "application/yaml; charset=utf-8",
  yml = "application/yaml; charset=utf-8",
  toml = "application/toml; charset=utf-8",
  lua = "text/plain; charset=utf-8",
  svg = "image/svg+xml",
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  avif = "image/avif",
  ico = "image/x-icon",
  pdf = "application/pdf",
  wasm = "application/wasm",
  woff = "font/woff",
  woff2 = "font/woff2",
  ttf = "font/ttf",
  otf = "font/otf",
  mp4 = "video/mp4",
  webm = "video/webm",
  mp3 = "audio/mpeg",
  ogg = "audio/ogg",
  zip = "application/zip",
  gz = "application/gzip",
  tar = "application/x-tar",
}

local function typeFor(path: string): string
  local dot: integer | nil = nil
  local i: integer = #path
  while i >= 1 do
    if string.sub(path, i, i) == "." then
      dot = i
      break
    end
    if string.sub(path, i, i) == "/" then
      break
    end
    i = i - 1
  end
  if dot == nil then
    return "application/octet-stream"
  end
  local ext: string = string.lower(string.sub(path, dot! + 1))
  local found: string | nil = TYPES[ext]
  if found == nil then
    return "application/octet-stream"
  end
  return found!
end

return { typeFor = typeFor, TYPES = TYPES }
