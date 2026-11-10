import T from "tlua_test"
import http from "../lib/http"

return {
  ["case-insensitive lookup and order"] = function(): void
    local h = http.Headers.new()
    h:set("Content-Type", "text/plain")
    h:add("X-Test", "a")
    h:add("x-test", "b")
    T.eq(h:get("content-type"), "text/plain", "get")
    T.eq(h:get("X-TEST"), "a", "case")
    T.eq(#h:getAll("X-Test"), 2, "duplicates")
    T.eq(h:getAll("x-test")[2], "b", "second")
    T.eq(h:count(), 3, "count")
    T.ok(h:has("CONTENT-TYPE"), "has")
    local entries: HeaderEntry[] = h:entries()
    T.eq(entries[1].name, "Content-Type", "insertion order")
    T.eq(entries[3].value, "b", "insertion order value")
  end,

  ["set replaces, remove drops all and setIfAbsent preserves"] = function(): void
    local h = http.Headers.new()
    h:set("X", "1")
    h:add("X", "2")
    h:set("x", "3")
    T.eq(h:getAll("X")[1], "3", "set replaces")
    T.eq(#h:getAll("X"), 1, "one after set")
    h:add("Y", "a")
    h:remove("y")
    T.ok(not h:has("Y"), "removed")
    T.eq(h:count(), 1, "count")
    h:setIfAbsent("X", "4")
    T.eq(h:get("X"), "3", "setIfAbsent")
    h:setIfAbsent("Z", "5")
    T.eq(h:get("Z"), "5", "setIfAbsent adds")
  end,

  ["clone is independent"] = function(): void
    local h = http.Headers.new()
    h:set("A", "1")
    local c = h:clone()
    c:set("A", "2")
    T.eq(h:get("A"), "1", "original")
    T.eq(c:get("A"), "2", "clone")
  end,

  ["invalid names and values are rejected"] = function(): void
    local h = http.Headers.new()
    T.raises(function(): void h:set("Bad Name", "x") end)
    T.raises(function(): void h:set("X\nY", "x") end)
    T.raises(function(): void h:set("X", "a\r\nInjected: yes") end)
    T.raises(function(): void h:add("X", "nul\0") end)
    T.raises(function(): void h:add("X", "ctl\1") end)
    T.ok(h:has("X") == false, "nothing was added")
  end,

  ["header values may contain tabs and high bytes"] = function(): void
    local h = http.Headers.new()
    h:set("X", "a\tb\255")
    T.eq(h:get("x"), "a\tb\255", "value")
  end,
}
