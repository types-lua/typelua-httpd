import T from "tlua_test"
import http from "../lib/http"

return {
  ["status reasons and body rules"] = function(): void
    T.eq(http.status.reason(200), "OK", "200")
    T.eq(http.status.reason(418), "I'm a teapot", "418")
    T.eq(http.status.reason(416), "Range Not Satisfiable", "416")
    T.eq(http.status.reason(205), "Reset Content", "205")
    T.eq(http.status.reason(299), "Unknown", "unknown")
    T.ok(http.status.isBodyless(204), "204")
    T.ok(http.status.isBodyless(205), "205")
    T.ok(http.status.isBodyless(304), "304")
    T.ok(http.status.isBodyless(101), "101")
    T.ok(not http.status.isBodyless(200), "200 body")
  end,

  ["http date and etag"] = function(): void
    T.eq(http.date.httpDate(0), "Thu, 01 Jan 1970 00:00:00 GMT", "epoch")
    local a: string = http.date.etag("hello")
    local b: string = http.date.etag("hello")
    T.eq(a, b, "stable")
    T.ok(a ~= http.date.etag("HellO"), "different")
    T.eq(#a, 18, "quoted 64-bit tag")
  end,

  ["mime types"] = function(): void
    T.eq(http.mime.typeFor("a.html"), "text/html; charset=utf-8", "html")
    T.eq(http.mime.typeFor("x.Y.JS"), "text/javascript; charset=utf-8", "case")
    T.eq(http.mime.typeFor("noext"), "application/octet-stream", "default")
  end,
}
