import T from "tlua_test"
import h2 from "../lib/http_h2_frame"

return {
  ["frame round-trip and byte feed"] = function(): void
    local wire: string = h2.encodeFrame(
      h2.FRAME_HEADERS,
      h2.FLAG_END_HEADERS + h2.FLAG_END_STREAM,
      1,
      "abc"
    ) .. h2.encodeFrame(h2.FRAME_DATA, 0, 1, "xy")
    local parser = h2.H2FrameParser.new(16384)
    local frames: any[] = {}
    for i: integer = 1, #wire do
      parser:feed(string.sub(wire, i, i))
      while true do
        local read: any = parser:next()
        if read.needMore then break end
        T.eq(read.err, "", "no error")
        frames[#frames + 1] = read.frame
      end
    end
    T.eq(#frames, 2, "two frames")
    T.eq(frames[1].frameType, h2.FRAME_HEADERS, "type")
    T.eq(frames[1].streamId, 1, "stream")
    T.eq(frames[1].payload, "abc", "payload")
    T.eq(frames[1].flags, 5, "flags")
    T.eq(frames[2].frameType, h2.FRAME_DATA, "data type")
    T.eq(frames[2].payload, "xy", "data payload")
  end,

  ["settings and helper payloads"] = function(): void
    local payload = h2.settingsPayload({
      { id = 3, value = 100 },
      { id = 4, value = 65535 },
    })
    local settings = h2.parseSettings(payload)
    T.eq(#settings, 2, "count")
    T.eq(settings[1].id, 3, "id 1")
    T.eq(settings[1].value, 100, "value 1")
    T.eq(settings[2].id, 4, "id 2")
    T.eq(settings[2].value, 65535, "value 2")
    T.eq(h2.windowUpdatePayload(123), h2.u32(123), "window")
    T.eq(#h2.rstStreamPayload(8), 4, "rst")
    T.eq(#h2.goawayPayload(1, 0, "x"), 9, "goaway")
  end,

  ["frame size and malformed settings"] = function(): void
    local parser = h2.H2FrameParser.new(16384)
    local payload: string = string.rep("x", 16385)
    parser:feed(h2.encodeFrame(h2.FRAME_DATA, 0, 1, payload))
    local read: any = parser:next()
    T.ok(#read.err > 0, "oversized frame rejected")
    T.raises(function(): void h2.parseSettings("abc") end)
    T.raises(function(): void h2.H2FrameParser.new(1) end)
  end,
}
