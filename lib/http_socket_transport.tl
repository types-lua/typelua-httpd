--- LuaSocket-backed transport for real TCP.
---
--- LuaSocket is loaded lazily so the protocol core and memory-transport tests
--- work on a bare Lua install; `new()` reports a clear error when it is
--- missing. All sockets are non-blocking; multiplexing is done by `select`.

local socketModule: any = nil
local loadOk, loaded = pcall(require, "socket")
if loadOk then
  socketModule = loaded
end

class SocketConnection implements HttpConnectionApi {
  sock: any,
  name: string,
  remote: string,

  constructor(sock: any)
    self.sock = sock
    self.name = tostring(sock)
    self.sock:settimeout(0)
    pcall(function(): void
      self.sock:setoption("tcp-nodelay", true)
    end)
    self.remote = ""
    local peerOk, ip, port = pcall(function(): (string | nil, integer | nil)
      return self.sock:getpeername()
    end)
    if peerOk and ip ~= nil then
      self.remote = tostring(ip) .. ":" .. tostring(port)
    end
  end,

  id(): string
    return self.name
  end,

  isReadable(): boolean
    return true
  end,

  needsWrite(): boolean
    return false
  end,

  needsHandshake(): boolean
    return false
  end,

  poll(): boolean
    return false
  end,

  protocol(): string
    return ""
  end,

  readAvailable(maxBytes: integer): ReadResult
    local data, err, partial = self.sock:receive(maxBytes)
    if data ~= nil then
      return { data = data, err = nil, closed = false, wouldBlock = false }
    end
    local tail: string = ""
    if partial ~= nil then tail = partial end
    if err == "closed" then
      return { data = tail, err = nil, closed = true, wouldBlock = false }
    end
    if err == "timeout" then
      return { data = tail, err = nil, closed = false, wouldBlock = true }
    end
    return { data = tail, err = tostring(err), closed = false, wouldBlock = false }
  end,

  writeSome(data: string): WriteResult
    local sent, err, last = self.sock:send(data)
    if sent ~= nil then
      return { written = sent, err = nil, wouldBlock = false }
    end
    local written: integer = 0
    if last ~= nil then written = math.floor(last) end
    if err == "timeout" then
      return { written = written, err = nil, wouldBlock = true }
    end
    return { written = written, err = tostring(err), wouldBlock = false }
  end,

  close(): void
    pcall(function(): void self.sock:close() end)
  end,

  remoteAddress(): string
    return self.remote
  end,

  raw(): any
    return self.sock
  end,
}

class SocketListener implements HttpListenerApi {
  server: any,
  host: string,
  port: integer,

  constructor(server: any, host: string, port: integer)
    self.server = server
    self.host = host
    self.port = port
    self.server:settimeout(0)
  end,

  accept(): AcceptResult
    local client, err = self.server:accept()
    if client ~= nil then
      return { conn = SocketConnection.new(client), err = nil, wouldBlock = false }
    end
    if err == "timeout" then
      return { conn = nil, err = nil, wouldBlock = true }
    end
    return { conn = nil, err = tostring(err), wouldBlock = false }
  end,

  close(): void
    pcall(function(): void self.server:close() end)
  end,

  address(): TransportAddress
    local ok, host, port = pcall(function(): (string | nil, integer | nil)
      return self.server:getsockname()
    end)
    if ok and host ~= nil then
      return { host = tostring(host), port = math.floor(port or 0) }
    end
    return { host = self.host, port = self.port }
  end,
}

class SocketSelector implements HttpSelectorApi {
  constructor() end,

  select(
    readers: HttpConnectionApi[],
    writers: HttpConnectionApi[],
    timeoutSeconds: number
  ): SelectResult
    local byId: map<string, HttpConnectionApi> = {}
    local rs: any[] = {}
    local ws: any[] = {}
    for i: integer = 1, #readers do
      local c = readers[i] as any
      byId[readers[i]:id()] = readers[i]
      rs[#rs + 1] = c:raw()
    end
    for i: integer = 1, #writers do
      local c = writers[i] as any
      byId[writers[i]:id()] = writers[i]
      ws[#ws + 1] = c:raw()
    end
    if socketModule == nil then
      return { readable = {}, writable = {}, err = "LuaSocket is not installed" }
    end
    local selectOk: boolean = false
    local readable: any = nil
    local writable: any = nil
    local err: any = nil
    selectOk, readable, writable, err = pcall(function(): (any, any, any)
      return socketModule.select(rs, ws, timeoutSeconds)
    end)
    if not selectOk then
      return { readable = {}, writable = {}, err = tostring(readable) }
    end
    local outR: HttpConnectionApi[] = {}
    local outW: HttpConnectionApi[] = {}
    if readable ~= nil then
      for i: integer = 1, #readable do
        local found: HttpConnectionApi | nil = byId[tostring(readable[i])]
        if found ~= nil then outR[#outR + 1] = found! end
      end
    end
    if writable ~= nil then
      for i: integer = 1, #writable do
        local found: HttpConnectionApi | nil = byId[tostring(writable[i])]
        if found ~= nil then outW[#outW + 1] = found! end
      end
    end
    local errorText: string | nil = nil
    if err ~= nil and err ~= "timeout" then
      errorText = tostring(err)
    end
    return { readable = outR, writable = outW, err = errorText }
  end,
}

class SocketTransport implements HttpTransportApi {
  sel: SocketSelector,

  constructor()
    if socketModule == nil then
      error("LuaSocket is required for real TCP: install lua-socket or use the memory transport")
    end
    self.sel = SocketSelector.new()
  end,

  listen(host: string, port: integer, backlog: integer): ListenResult
    local server, err = socketModule.bind(host, port, backlog)
    if server == nil then
      return { listener = nil, err = tostring(err) }
    end
    return { listener = SocketListener.new(server, host, port), err = nil }
  end,

  selector(): HttpSelectorApi
    return self.sel
  end,

  now(): number
    return socketModule.gettime()
  end,
}

return {
  SocketConnection = SocketConnection,
  SocketListener = SocketListener,
  SocketSelector = SocketSelector,
  SocketTransport = SocketTransport,
}
