import T from "tlua_test"
import http from "../lib/http"
import ws from "../lib/http_websocket"

local MASK: string = "\1\2\3\4"

local function request(extra: map<string, string>): HttpRequestApi
  local headers = http.Headers.new()
  headers:set("Host", "test.local")
  for name, value in pairs(extra) do
    headers:set(name, value)
  end
  return http.HttpRequest.new("GET", "/ws", "/ws", "", {}, "1.1", headers, true)
end

local function parseServerFrame(wire: string): any
  local parser = ws.WsFrameParser.new({ requireMask = false, maxFrameBytes = 1024 * 1024 })
  parser:feed(wire)
  local read: any = parser:next()
  T.ok(read.err == nil, "server frame parses")
  T.ok(read.frame ~= nil, "frame present")
  return read.frame
end

return {
  ["handshake key and validation"] = function(): void
    T.eq(ws.acceptKey("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "accept vector")
    local good = request({
      ["Connection"] = "Upgrade",
      ["Upgrade"] = "websocket",
      ["Sec-WebSocket-Version"] = "13",
      ["Sec-WebSocket-Key"] = "dGhlIHNhbXBsZSBub25jZQ==",
    })
    local goodCheck = ws.validateHandshake(good)
    T.ok(goodCheck.ok, "valid handshake: " .. goodCheck.error)
    local noKey = request({
      ["Connection"] = "Upgrade",
      ["Upgrade"] = "websocket",
      ["Sec-WebSocket-Version"] = "13",
    })
    local noKeyCheck = ws.validateHandshake(noKey)
    T.ok(not noKeyCheck.ok, "missing key rejected")
    T.ok(#noKeyCheck.error > 0, "reason")
    local wrongVersion = request({
      ["Connection"] = "Upgrade",
      ["Upgrade"] = "websocket",
      ["Sec-WebSocket-Version"] = "8",
      ["Sec-WebSocket-Key"] = "dGhlIHNhbXBsZSBub25jZQ==",
    })
    T.ok(not ws.validateHandshake(wrongVersion).ok, "version rejected")
    local shortKey = request({
      ["Connection"] = "Upgrade",
      ["Upgrade"] = "websocket",
      ["Sec-WebSocket-Version"] = "13",
      ["Sec-WebSocket-Key"] = "c2hvcnQ=",
    })
    T.ok(not ws.validateHandshake(shortKey).ok, "short key rejected")
  end,

  ["masked frame parsing, lengths and byte-by-byte feed"] = function(): void
    local payloads: string[] = {
      "",
      "hello",
      string.rep("a", 125),
      string.rep("b", 126),
      string.rep("c", 65535),
      string.rep("d", 65536),
    }
    for i: integer = 1, #payloads do
      local wire: string = ws.encodeFrame(ws.OP_TEXT, payloads[i], true, MASK)
      local parser = ws.WsFrameParser.new({ requireMask = true, maxFrameBytes = 100000 })
      if #wire <= 512 then
        for p: integer = 1, #wire do
          parser:feed(string.sub(wire, p, p))
          local read: any = parser:next()
          if p < #wire then
            T.ok(read.needMore, "partial frame at " .. tostring(i))
          else
            T.ok(read.frame ~= nil, "complete frame at " .. tostring(i))
            T.eqBytes(read.frame.payload, payloads[i], "payload at " .. tostring(i))
          end
        end
      else
        parser:feed(string.sub(wire, 1, #wire - 1))
        T.ok(parser:next().needMore, "large frame partial at " .. tostring(i))
        parser:feed(string.sub(wire, #wire, #wire))
        local read: any = parser:next()
        T.ok(read.frame ~= nil, "large frame complete at " .. tostring(i))
        T.eqBytes(read.frame.payload, payloads[i], "large payload at " .. tostring(i))
      end
    end
    local unmasked: string = ws.encodeFrame(ws.OP_TEXT, "x", true, nil)
    local parser = ws.WsFrameParser.new({ requireMask = true })
    parser:feed(unmasked)
    local bad: any = parser:next()
    T.ok(bad.err ~= nil, "unmasked rejected")
    local relaxed = ws.WsFrameParser.new({ requireMask = false })
    relaxed:feed(unmasked)
    local ok: any = relaxed:next()
    T.eq(ok.frame.payload, "x", "unmasked allowed when configured")
  end,

  ["fragmentation, ping/pong and text callback"] = function(): void
    local output: string[] = {}
    local texts: string[] = {}
    local session = ws.WebSocketSession.new({
      emit = function(wire: string): void output[#output + 1] = wire end,
      onText = function(_ws: any, text: string): void texts[#texts + 1] = text end,
      requireMask = true,
    })
    session:feed(ws.encodeFrame(ws.OP_TEXT, "hel", false, MASK))
    session:feed(ws.encodeFrame(ws.OP_PING, "p", true, MASK))
    session:feed(ws.encodeFrame(ws.OP_CONT, "lo", true, MASK))
    T.eq(#texts, 1, "one message")
    T.eq(texts[1], "hello", "assembled")
    T.eq(#output, 1, "one control response")
    local pong = parseServerFrame(output[1])
    T.eq(pong.opcode, ws.OP_PONG, "pong opcode")
    T.eq(pong.payload, "p", "pong payload")

    session:sendText("server")
    T.eq(#output, 2, "server frame")
    local text = parseServerFrame(output[2])
    T.eq(text.opcode, ws.OP_TEXT, "text opcode")
    T.eq(text.payload, "server", "text payload")
  end,

  ["protocol errors close and invalid UTF-8 uses 1007"] = function(): void
    local output: string[] = {}
    local closes: integer[] = {}
    local session = ws.WebSocketSession.new({
      emit = function(wire: string): void output[#output + 1] = wire end,
      onClose = function(_ws: any, code: integer, _reason: string): void
        closes[#closes + 1] = code
      end,
      requireMask = true,
    })
    session:feed(ws.encodeFrame(ws.OP_TEXT, "\255", true, MASK))
    T.ok(session:isFailed(), "utf8 failure")
    T.eq(closes[1], 1007, "close code")
    local closeFrame = parseServerFrame(output[1])
    T.eq(closeFrame.opcode, ws.OP_CLOSE, "close opcode")
    T.eqBytes(string.sub(closeFrame.payload, 1, 2), string.char(3, 239), "1007 encoded")

    local secondOutput: string[] = {}
    local second = ws.WebSocketSession.new({
      emit = function(wire: string): void secondOutput[#secondOutput + 1] = wire end,
      requireMask = true,
      maxMessageBytes = 4,
    })
    second:feed(ws.encodeFrame(ws.OP_BINARY, "12345", true, MASK))
    T.ok(second:isFailed(), "message cap")
    local close = parseServerFrame(secondOutput[1])
    T.eqBytes(string.sub(close.payload, 1, 2), string.char(3, 241), "1009 encoded")
  end,

  ["close handshake echoes code and reason"] = function(): void
    local output: string[] = {}
    local closes: integer[] = {}
    local reasons: string[] = {}
    local session = ws.WebSocketSession.new({
      emit = function(wire: string): void output[#output + 1] = wire end,
      onClose = function(_ws: any, code: integer, reason: string): void
        closes[#closes + 1] = code
        reasons[#reasons + 1] = reason
      end,
      requireMask = true,
    })
    local payload: string = string.char(3, 233) .. "bye"
    session:feed(ws.encodeFrame(ws.OP_CLOSE, payload, true, MASK))
    T.ok(session:isClosed(), "closed")
    T.eq(closes[1], 1001, "close code")
    T.eq(reasons[1], "bye", "close reason")
    local echo = parseServerFrame(output[1])
    T.eq(echo.opcode, ws.OP_CLOSE, "echo opcode")
    T.eqBytes(echo.payload, payload, "echo payload")
  end,

  ["frame parser rejects reserved bits, control fragmentation and huge lengths"] = function(): void
    local parser = ws.WsFrameParser.new({ requireMask = false })
    parser:feed(string.char(0x91, 0))
    local rsv: any = parser:next()
    T.ok(rsv.err ~= nil, "RSV rejected")

    local control = ws.WsFrameParser.new({ requireMask = false })
    control:feed(string.char(0x09, 0))
    local fragmented: any = control:next()
    T.ok(fragmented.err ~= nil, "fragmented ping rejected")

    local huge = ws.WsFrameParser.new({ requireMask = false, maxFrameBytes = 10 })
    huge:feed(string.char(0x82, 11) .. string.rep("x", 11))
    local tooBig: any = huge:next()
    T.ok(tooBig.err ~= nil, "frame cap")
  end,
}
