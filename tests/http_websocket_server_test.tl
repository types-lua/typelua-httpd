import T from "tlua_test"
import http from "../lib/http"
import ws from "../lib/http_websocket"
import literal from "../lib/http_literal"

local MASK: string = "\9\8\7\6"
local KEY: string = "dGhlIHNhbXBsZSBub25jZQ=="

local function fixture(): any
  local router = http.HttpRouter.new()
  local state: any = { messages = {}, closes = {} }
  router:get("/ws", function(ctx: HttpContextApi): void
    ctx:websocket({
      protocols = { "superchat" },
      onOpen = function(socket: any): void
        socket:sendText("welcome")
      end,
      onText = function(socket: any, text: string): void
        state.messages[#state.messages + 1] = text
        socket:sendText("echo:" .. text)
      end,
      onClose = function(_socket: any, code: integer, reason: string): void
        state.closes[#state.closes + 1] = tostring(code) .. ":" .. reason
      end,
    })
  end)
  local transport = http.MemoryTransport.new("127.0.0.1", 0)
  local server = http.HttpServer.new(router, transport, { idleTimeout = 30 })
  server:listen("127.0.0.1", 0)
  return { server = server, router = router, transport = transport, state = state }
end

local function handshake(): string
  return "GET /ws HTTP/1.1\r\nHost: t\r\n"
    .. "Upgrade: websocket\r\nConnection: Upgrade\r\n"
    .. "Sec-WebSocket-Version: 13\r\n"
    .. "Sec-WebSocket-Key: " .. KEY .. "\r\n"
    .. "Sec-WebSocket-Protocol: chat, superchat\r\n\r\n"
end

local function connect(f: any, name: string, data: string): any
  local conn = http.MemoryConnection.new(name, data, "198.51.100.20:9999")
  f.transport.listener:push(conn)
  return conn
end

local function splitHandshake(output: string): any
  local sep: integer | nil = literal.find(output, "\r\n\r\n", 1)
  if sep == nil then error("no handshake separator") end
  return {
    head = string.sub(output, 1, sep! - 1),
    rest = string.sub(output, sep! + 4),
  }
end

local function parseFrames(wire: string): any[]
  local parser = ws.WsFrameParser.new({ requireMask = false, maxFrameBytes = 1024 * 1024 })
  parser:feed(wire)
  local frames: any[] = {}
  while true do
    local read: any = parser:next()
    if read.needMore then break end
    if read.err ~= nil then error(read.err) end
    frames[#frames + 1] = read.frame
  end
  return frames
end

return {
  ["WebSocket handshake, leftover frame, echo and close"] = function(): void
    local f = fixture()
    local first: string = ws.encodeFrame(ws.OP_TEXT, "hi", true, MASK)
    local conn = connect(f, "ws1", handshake() .. first)
    f.server:step(0)
    local output: string = conn:takeOutput()
    local split = splitHandshake(output)
    T.ok(literal.contains(split.head, "HTTP/1.1 101 Switching Protocols"), "101")
    T.ok(literal.contains(split.head, "Upgrade: websocket"), "upgrade")
    T.ok(literal.contains(split.head, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), "accept")
    T.ok(literal.contains(split.head, "Sec-WebSocket-Protocol: superchat"), "subprotocol")
    local frames = parseFrames(split.rest)
    T.eq(#frames, 2, "echo and welcome")
    T.eq(frames[1].opcode, ws.OP_TEXT, "echo opcode")
    T.eq(frames[1].payload, "echo:hi", "echo payload")
    T.eq(frames[2].payload, "welcome", "welcome")
    T.eq(f.state.messages[1], "hi", "callback")

    conn:feed(ws.encodeFrame(ws.OP_PING, "p", true, MASK))
    f.server:step(0)
    local pongFrames = parseFrames(conn:takeOutput())
    T.eq(#pongFrames, 1, "pong")
    T.eq(pongFrames[1].opcode, ws.OP_PONG, "pong opcode")
    T.eq(pongFrames[1].payload, "p", "pong payload")

    conn:feed(ws.encodeFrame(ws.OP_CLOSE, string.char(3, 232), true, MASK))
    f.server:step(0)
    local closeFrames = parseFrames(conn:takeOutput())
    T.eq(#closeFrames, 1, "close echo")
    T.eq(closeFrames[1].opcode, ws.OP_CLOSE, "close opcode")
    T.eq(f.state.closes[1], "1000:", "close callback")
    T.ok(conn.outputClosed, "socket closed")
  end,

  ["WebSocket unmasked client frame fails 1002"] = function(): void
    local f = fixture()
    local conn = connect(f, "ws2", handshake())
    f.server:step(0)
    local initial = conn:takeOutput()
    local split = splitHandshake(initial)
    T.ok(literal.contains(split.head, "101"), "upgraded")
    -- Discard the welcome frame in split.rest.
    conn:feed(ws.encodeFrame(ws.OP_TEXT, "bad", true, nil))
    f.server:step(0)
    local frames = parseFrames(conn:takeOutput())
    T.ok(#frames >= 1, "close frame")
    T.eq(frames[1].opcode, ws.OP_CLOSE, "close opcode")
    T.eqBytes(string.sub(frames[1].payload, 1, 2), string.char(3, 234), "1002")
    T.ok(conn.outputClosed, "closed")
  end,

  ["WebSocket invalid handshake stays HTTP"] = function(): void
    local f = fixture()
    local conn = http.MemoryConnection.new(
      "wsbad",
      "GET /ws HTTP/1.1\r\nHost: t\r\n\r\n",
      "198.51.100.21:9999"
    )
    conn:closeInput()
    f.transport.listener:push(conn)
    f.server:step(0)
    local output = conn:takeOutput()
    T.ok(literal.contains(output, "HTTP/1.1 400 Bad Request"), "400")
    T.ok(not literal.contains(output, "Switching Protocols"), "no upgrade")
  end,
}
