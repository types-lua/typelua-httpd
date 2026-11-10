import T from "tlua_test"
import http from "../lib/http"

local function parser(): HttpRequestParserApi
  return http.HttpRequestParser.new({})
end

return {
  ["event parser emits headers, chunks and end"] = function(): void
    local p = parser()
    p:feed("POST /upload?q=1 HTTP/1.1\r\nHost: h\r\nContent-Length: 11\r\n\r\nhello world")
    local events: any[] = {}
    while true do
      local ev: any = p:nextEvent()
      events[#events + 1] = ev
      if ev.kind == "needMore" or ev.kind == "end" or ev.kind == "error" then break end
    end
    T.eq(events[1].kind, "headers", "headers first")
    T.eq(events[1].request.path, "/upload", "path")
    T.eq(events[1].request.body, "", "headers event has no body")
    local body: string = ""
    for i: integer = 2, #events do
      if events[i].kind == "body" then body = body .. events[i].chunk end
    end
    T.eq(body, "hello world", "streamed body")
    T.eq(events[#events].kind, "end", "end last")
    T.eq(events[#events].request.body, "", "end request is not buffered")
    T.ok(not p:requestActive(), "idle after end")
  end,

  ["event parser partial fixed and chunked bodies"] = function(): void
    local p = parser()
    p:feed("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 6\r\n\r\nabc")
    local first: any = p:nextEvent()
    T.eq(first.kind, "headers", "headers")
    local second: any = p:nextEvent()
    T.eq(second.kind, "body", "partial body")
    T.eq(second.chunk, "abc", "partial bytes")
    T.eq(second.last, false, "not last")
    local third: any = p:nextEvent()
    T.eq(third.kind, "needMore", "waits")
    p:feed("def")
    local body: string = ""
    local done: boolean = false
    while true do
      local ev: any = p:nextEvent()
      if ev.kind == "body" then body = body .. ev.chunk
      elseif ev.kind == "end" then done = true; break
      elseif ev.kind == "needMore" then error("unexpected needMore")
      elseif ev.kind == "error" then error(ev.error.message) end
    end
    T.eq(body, "def", "remaining body")
    T.ok(done, "end")

    local chunked = parser()
    chunked:feed(
      "POST /c HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"
    )
    local pieces: string[] = {}
    local sawEnd: boolean = false
    while true do
      local ev: any = chunked:nextEvent()
      if ev.kind == "body" then pieces[#pieces + 1] = ev.chunk
      elseif ev.kind == "end" then sawEnd = true; break
      elseif ev.kind == "needMore" then error("chunked needMore")
      elseif ev.kind == "error" then error(ev.error.message) end
    end
    T.eq(table.concat(pieces), "Wikipedia", "chunked stream")
    T.ok(sawEnd, "chunked end")
  end,

  ["event parser byte feed and continue"] = function(): void
    local wire: string = "POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\nabc"
    local p = parser()
    local sawContinue: boolean = false
    local body: string = ""
    local ended: boolean = false
    for i: integer = 1, #wire do
      p:feed(string.sub(wire, i, i))
      while true do
        local ev: any = p:nextEvent()
        if ev.kind == "needMore" then
          break
        elseif ev.kind == "continue" then
          sawContinue = true
        elseif ev.kind == "body" then
          body = body .. ev.chunk
        elseif ev.kind == "end" then
          ended = true
          break
        elseif ev.kind == "error" then
          error(ev.error.message)
        end
      end
      if ended then break end
    end
    T.ok(sawContinue, "continue")
    T.eq(body, "abc", "body")
    T.ok(ended, "ended")
  end,

  ["event parser pipelining and errors"] = function(): void
    local p = parser()
    p:feed(
      "GET /a HTTP/1.1\r\nHost: h\r\n\r\n"
        .. "GET /b HTTP/1.1\r\nHost: h\r\n\r\n"
    )
    local paths: string[] = {}
    while true do
      local ev: any = p:nextEvent()
      if ev.kind == "headers" then paths[#paths + 1] = ev.request.path
      elseif ev.kind == "end" then
        -- keep going for the second request
      elseif ev.kind == "needMore" then
        break
      elseif ev.kind == "error" then
        error(ev.error.message)
      end
    end
    T.eq(table.concat(paths, ","), "/a,/b", "pipelined events")

    local bad = parser()
    bad:feed("GET / HTTP/1.1\r\n\r\n")
    local errorEvent: any = bad:nextEvent()
    T.eq(errorEvent.kind, "error", "missing host error")
    T.eq(errorEvent.error.status, 400, "status")
    T.eq(bad:nextEvent().kind, "error", "sticky error")
  end,
}
