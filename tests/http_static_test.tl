import T from "tlua_test"
import http from "../lib/http"
import staticMod from "../lib/http_static"

local ROOT: string = "data/static-fixture"

local function writeFile(relative: string, body: string): void
  local file = io.open(ROOT .. "/" .. relative, "wb")
  if file == nil then
    error("cannot create fixture: " .. relative)
  end
  file:write(body)
  file:close()
end

os.execute("rm -rf " .. ROOT)
os.execute("mkdir -p " .. ROOT .. "/sub " .. ROOT .. "/noindex " .. ROOT .. "/deep/nested")
writeFile("index.html", "<h1>home</h1>")
writeFile("hello.txt", "hello world")
writeFile("empty.txt", "")
writeFile("range.txt", "0123456789")
writeFile("space name.txt", "spaced")
writeFile("sub/index.html", "sub index")
writeFile("sub/app.js", "console.log(1);")
writeFile("sub/style.css", "body{}")
writeFile("noindex/readme.txt", "no index here")
writeFile("deep/nested/file.json", "{\"ok\":true}")
writeFile(".env", "SECRET=1")
writeFile("big.bin", string.rep("x", 40))

local function request(method: string, target: string): HttpRequestApi
  local parts = http.url.splitTarget(target)
  local headers = http.Headers.new()
  headers:set("Host", "test.local")
  return http.HttpRequest.new(
    method,
    target,
    parts.path,
    parts.rawQuery,
    http.url.parseQuery(parts.rawQuery),
    "1.1",
    headers,
    true
  )
end

local function serve(
  handler: StaticApi,
  method: string,
  target: string,
  extra: map<string, string> | nil
): HttpResponseApi
  local req = request(method, target)
  if extra ~= nil then
    for name, value in pairs(extra!) do
      req.headers:set(name, value)
    end
  end
  local res = http.HttpResponse.new(200)
  local ctx = http.HttpContext.new(req, res)
  handler:serve(ctx)
  return res
end

local function wire(res: HttpResponseApi, method: string): string
  return http.serialize(res, {
    serverName = "static-test",
    keepAlive = true,
    requestMethod = method,
    version = "1.1",
  })
end

local static = http.HttpStatic.new({ root = ROOT, cacheControl = "public, max-age=60" })

return {
  ["serves index, files and nested indexes"] = function(): void
    local root = serve(static, "GET", "/", nil)
    T.eq(root.status, 200, "root status")
    T.eq(root.body, "<h1>home</h1>", "root body")
    T.eq(root.headers:get("Content-Type"), "text/html; charset=utf-8", "root type")
    T.eq(root.headers:get("Cache-Control"), "public, max-age=60", "cache control")

    local hello = serve(static, "GET", "/hello.txt", nil)
    T.eq(hello.body, "hello world", "file")
    T.eq(hello.headers:get("Content-Type"), "text/plain; charset=utf-8", "file type")

    local sub = serve(static, "GET", "/sub", nil)
    T.eq(sub.status, 200, "directory status")
    T.eq(sub.body, "sub index", "directory index")
    local subSlash = serve(static, "GET", "/sub/", nil)
    T.eq(subSlash.body, "sub index", "trailing slash")

    T.eq(serve(static, "GET", "/sub/app.js", nil).headers:get("Content-Type"), "text/javascript; charset=utf-8", "js")
    T.eq(serve(static, "GET", "/sub/style.css", nil).headers:get("Content-Type"), "text/css; charset=utf-8", "css")
    T.eq(serve(static, "GET", "/deep/nested/file.json", nil).body, "{\"ok\":true}", "nested")
    T.eq(serve(static, "GET", "/space%20name.txt", nil).body, "spaced", "encoded space")
    T.eq(serve(static, "GET", "/empty.txt", nil).body, "", "empty file")
    T.eq(serve(static, "GET", "/noindex", nil).status, 404, "directory without index")
    T.eq(serve(static, "GET", "/missing.txt", nil).status, 404, "missing")
  end,

  ["dotfile policy is applied after one decode"] = function(): void
    T.eq(serve(static, "GET", "/.env", nil).status, 404, "plain dotfile")
    T.eq(serve(static, "GET", "/%2eenv", nil).status, 404, "encoded dotfile")
    T.eq(serve(static, "GET", "/%252eenv", nil).status, 404, "double encoded stays literal")
    local open = http.HttpStatic.new({ root = ROOT, dotfiles = true })
    T.eq(serve(open, "GET", "/.env", nil).status, 200, "dotfiles enabled")
    T.eq(serve(open, "GET", "/.env", nil).body, "SECRET=1", "dotfile body")
  end,

  ["traversal, NUL and backslash are rejected"] = function(): void
    T.eq(serve(static, "GET", "/../etc/passwd", nil).status, 403, "dotdot")
    T.eq(serve(static, "GET", "/%2e%2e/etc/passwd", nil).status, 403, "encoded dotdot")
    T.eq(serve(static, "GET", "/sub/../../etc/passwd", nil).status, 403, "nested escape")
    T.eq(serve(static, "GET", "/%252e%252e%252fetc", nil).status, 404, "double encoded is a literal")
    T.eq(serve(static, "GET", "/a%5cb", nil).status, 403, "backslash")
    T.eq(serve(static, "GET", "/a%00b", nil).status, 403, "NUL")
    T.eq(serve(static, "GET", "/sub%2Fapp.js", nil).status, 403, "encoded slash")
    T.eq(serve(static, "GET", "/%252Fetc", nil).status, 404, "double encoded slash is literal")
    T.eq(serve(static, "GET", "/sub/%2e%2e/hello.txt", nil).status, 200, "internal dotdot normalizes")
  end,

  ["ETag and conditional requests"] = function(): void
    local first = serve(static, "GET", "/hello.txt", nil)
    local tag: string | nil = first.headers:get("ETag")
    T.ok(tag ~= nil, "etag present")
    T.eq(first.headers:get("Accept-Ranges"), "bytes", "accept ranges")

    local cached = serve(static, "GET", "/hello.txt", { ["If-None-Match"] = tag! })
    T.eq(cached.status, 304, "exact match")
    T.eq(cached.body, "", "304 body")
    T.ok(string.find(wire(cached, "GET"), "Content-Length:", 1, true) == nil, "304 no length")

    local weak = serve(static, "GET", "/hello.txt", {
      ["If-None-Match"] = "W/" .. tag! .. ", \"other\"",
    })
    T.eq(weak.status, 304, "weak match in list")

    local star = serve(static, "GET", "/hello.txt", { ["If-None-Match"] = "*" })
    T.eq(star.status, 304, "star")

    local stale = serve(static, "GET", "/hello.txt", { ["If-None-Match"] = "\"nope\"" })
    T.eq(stale.status, 200, "mismatch")
    T.eq(stale.body, "hello world", "mismatch body")
  end,

  ["single byte ranges"] = function(): void
    local a = serve(static, "GET", "/range.txt", { Range = "bytes=0-4" })
    T.eq(a.status, 206, "closed range")
    T.eq(a.body, "01234", "closed body")
    T.eq(a.headers:get("Content-Range"), "bytes 0-4/10", "closed content-range")

    local b = serve(static, "GET", "/range.txt", { Range = "bytes=5-" })
    T.eq(b.body, "56789", "open range")
    T.eq(b.headers:get("Content-Range"), "bytes 5-9/10", "open content-range")

    local c = serve(static, "GET", "/range.txt", { Range = "bytes=-3" })
    T.eq(c.body, "789", "suffix range")
    T.eq(c.headers:get("Content-Range"), "bytes 7-9/10", "suffix content-range")

    local d = serve(static, "GET", "/range.txt", { Range = "bytes=7-100" })
    T.eq(d.body, "789", "clamped end")

    local e = serve(static, "GET", "/range.txt", { Range = "bytes=10-" })
    T.eq(e.status, 416, "out of range")
    T.eq(e.headers:get("Content-Range"), "bytes */10", "416 content-range")
    T.eq(e.body, "", "416 body")

    local f = serve(static, "GET", "/range.txt", { Range = "bytes=4-2" })
    T.eq(f.status, 416, "inverted range")

    local g = serve(static, "GET", "/range.txt", { Range = "items=0-1" })
    T.eq(g.status, 200, "unknown unit ignored")
    T.eq(g.body, "0123456789", "ignored full body")

    local h = serve(static, "GET", "/range.txt", { Range = "bytes=0-1,3-4" })
    T.eq(h.status, 200, "multiple ranges ignored")
    T.eq(h.body, "0123456789", "multiple full body")

    local i = serve(static, "GET", "/empty.txt", { Range = "bytes=0-" })
    T.eq(i.status, 416, "empty byte range")

    local j = serve(static, "GET", "/range.txt", { Range = "BYTES=0-1" })
    T.eq(j.status, 206, "range unit is case-insensitive")
    T.eq(j.body, "01", "range unit body")
  end,

  ["If-Range requires a matching strong tag"] = function(): void
    local first = serve(static, "GET", "/range.txt", nil)
    local tag: string = first.headers:get("ETag")!
    local partial = serve(static, "GET", "/range.txt", {
      Range = "bytes=0-2",
      ["If-Range"] = tag,
    })
    T.eq(partial.status, 206, "matching if-range")
    T.eq(partial.body, "012", "partial body")

    local full = serve(static, "GET", "/range.txt", {
      Range = "bytes=0-2",
      ["If-Range"] = "\"stale\"",
    })
    T.eq(full.status, 200, "stale if-range")
    T.eq(full.body, "0123456789", "full body")
    T.eq(full.headers:get("Content-Range"), nil, "no content-range")
  end,

  ["HEAD and method handling"] = function(): void
    local head = serve(static, "HEAD", "/range.txt", nil)
    T.eq(head.status, 200, "head status")
    T.eq(head.body, "0123456789", "static exposes representation")
    local text: string = wire(head, "HEAD")
    T.ok(string.find(text, "Content-Length: 10", 1, true) ~= nil, "head length")
    T.ok(string.find(text, "0123456789", 1, true) == nil, "head has no body")

    local post = serve(static, "POST", "/hello.txt", nil)
    T.eq(post.status, 405, "post rejected")
    T.eq(post.headers:get("Allow"), "GET, HEAD", "post allow")

    local headRange = serve(static, "HEAD", "/range.txt", { Range = "bytes=0-3" })
    T.eq(headRange.status, 206, "HEAD range status")
    T.eq(headRange.body, "0123", "HEAD range representation")
    T.eq(headRange.headers:get("Content-Range"), "bytes 0-3/10", "HEAD range header")
    local rangeWire: string = wire(headRange, "HEAD")
    T.ok(string.find(rangeWire, "Content-Length: 4", 1, true) ~= nil, "HEAD range length")
    T.ok(string.find(rangeWire, "0123", 1, true) == nil, "HEAD range no body")
  end,

  ["size cap and prefix mounting"] = function(): void
    local capped = http.HttpStatic.new({ root = ROOT, maxBytes = 20 })
    T.eq(serve(capped, "GET", "/hello.txt", nil).status, 200, "under cap")
    T.eq(serve(capped, "GET", "/big.bin", nil).status, 413, "over cap")

    local mounted = http.HttpStatic.new({ root = ROOT, prefix = "/public/" })
    T.eq(serve(mounted, "GET", "/public", nil).body, "<h1>home</h1>", "mount root")
    T.eq(serve(mounted, "GET", "/public/hello.txt", nil).body, "hello world", "mount file")
    T.eq(serve(mounted, "GET", "/hello.txt", nil).status, 404, "outside mount")
    T.eq(serve(mounted, "GET", "/publicity/x", nil).status, 404, "prefix boundary")
  end,

  ["handler integration with router wildcard"] = function(): void
    local mounted = http.HttpStatic.new({ root = ROOT, prefix = "/assets" })
    local r = http.HttpRouter.new()
    r:get("/assets/*", mounted:handler())
    local req = request("GET", "/assets/sub/index.html")
    local res = http.HttpResponse.new(200)
    r:handle(req, res)
    T.eq(res.status, 200, "router status")
    T.eq(res.body, "sub index", "router body")

    local missing = http.HttpResponse.new(200)
    r:handle(request("GET", "/assets/nope"), missing)
    T.eq(missing.status, 404, "router 404")
  end,

  ["invalid static configuration fails fast"] = function(): void
    T.raises(function(): void
      http.HttpStatic.new({ root = ROOT, indexFile = "../secret" })
    end)
    T.raises(function(): void
      http.HttpStatic.new({ root = ROOT, indexFile = "a/b" })
    end)
    T.raises(function(): void
      http.HttpStatic.new({ root = ROOT, maxBytes = -1 })
    end)
    T.raises(function(): void
      http.HttpStatic.new({ root = ROOT, cacheControl = "a\r\nX: y" })
    end)
  end,

  ["readCapped distinguishes directories from empty files"] = function(): void
    local dir: any = staticMod.readCapped(ROOT, 1024)
    T.eq(dir.data, nil, "directory is not a file")
    local empty: any = staticMod.readCapped(ROOT .. "/empty.txt", 1024)
    T.eq(empty.data, "", "empty file is empty content")
    local file: any = staticMod.readCapped(ROOT .. "/hello.txt", 1024)
    T.eq(file.data, "hello world", "regular content")
    local capped: any = staticMod.readCapped(ROOT .. "/hello.txt", 4)
    T.ok(capped.tooLarge, "cap")
  end,

  ["range parser edge cases"] = function(): void
    local a: any = staticMod.parseRange("bytes=0-0", 1)
    T.eq(a.start, 0, "single byte start")
    T.eq(a.finish, 0, "single byte finish")
    local b: any = staticMod.parseRange("bytes=-1", 1)
    T.eq(b.start, 0, "suffix one")
    local c: any = staticMod.parseRange("bytes=-2", 1)
    T.eq(c.start, 0, "suffix clamped")
    local d: any = staticMod.parseRange("bytes=0-", 0)
    T.ok(not d.ok and d.unsatisfiable, "empty file")
    local e: any = staticMod.parseRange("bytes=abc", 10)
    T.eq(e, nil, "invalid")
  end,
}
