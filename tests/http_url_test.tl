import T from "tlua_test"
import http from "../lib/http"

return {
  ["percent decoding"] = function(): void
    T.eq(http.url.decodeComponent("a%20b"), "a b", "space")
    T.eq(http.url.decodeComponent("a+b"), "a+b", "plus literal")
    T.eq(http.url.decodeComponent("%zz"), "%zz", "invalid escape literal")
    T.eq(http.url.decodeComponent("%2e%2e"), "..", "dots")
    T.eq(http.url.decodeQueryValue("a+b%20c"), "a b c", "query plus")
  end,

  ["target splitting and query"] = function(): void
    local t = http.url.splitTarget("/a/b?x=1&y=a+b&x=2")
    T.eq(t.path, "/a/b", "path")
    T.eq(t.rawQuery, "x=1&y=a+b&x=2", "query")
    local q = http.url.parseQuery(t.rawQuery)
    T.eq(q["x"], "2", "last wins")
    T.eq(q["y"], "a b", "plus decoded")
    local abs = http.url.splitTarget("http://example.com:8080/x?q=1")
    T.eq(abs.path, "/x", "absolute path")
    T.eq(abs.rawQuery, "q=1", "absolute query")
    local star = http.url.splitTarget("*")
    T.eq(star.path, "*", "asterisk")
    local noPath = http.url.splitTarget("http://example.com?q=1")
    T.eq(noPath.path, "/", "absolute URI without path")
    T.eq(noPath.rawQuery, "q=1", "absolute URI query without path")
  end,

  ["path segments and safe join"] = function(): void
    T.eq(table.concat(http.url.pathSegments("/a/b%20c/"), ","), "a,b c", "segments")
    T.eq(http.url.safeJoin("/srv/root", "/a/b"), "/srv/root/a/b", "join")
    T.eq(http.url.safeJoin("/srv/root", "/a/../b"), "/srv/root/b", "dotdot")
    T.eq(http.url.safeJoin("/srv/root", "/../etc/passwd"), nil, "escape")
    T.eq(http.url.safeJoin("/srv/root", "/%2e%2e/etc"), nil, "encoded escape")
    T.eq(http.url.safeJoin("/srv/root", "/a\\b"), nil, "backslash")
    T.eq(http.url.safeJoin("/srv/root", "/a\0b"), nil, "nul")
  end,

  ["cookies and encoding"] = function(): void
    local c = http.url.parseCookies("a=1; b=\"two\";  c=3")
    T.eq(c["a"], "1", "a")
    T.eq(c["b"], "two", "quoted")
    T.eq(c["c"], "3", "spaces")
    T.eq(http.url.encodeComponent("a b/中"), "a%20b%2F%E4%B8%AD", "encode")
  end,
}
