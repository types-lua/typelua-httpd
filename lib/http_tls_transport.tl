--- TLS transport backed by LuaSocket + LuaSec.
---
--- Handshakes are non-blocking and driven by the server selector: a
--- `wantread` handshake returns wouldBlock, a `wantwrite` handshake makes the
--- connection register as writable. ALPN is negotiated before any HTTP bytes
--- are parsed so the server can choose h2 or http/1.1.

import socketTransport from "./http_socket_transport"

local socketModule: any = nil
local socketOk, loadedSocket = pcall(require, "socket")
if socketOk then socketModule = loadedSocket end

local sslModule: any = nil
local sslOk, loadedSsl = pcall(require, "ssl")
if sslOk then sslModule = loadedSsl end

type TlsOptions = {
  certificate: string,
  key: string,
  alpn?: string[],
  protocol?: string,
  ciphers?: string,
  password?: string,
}

class TlsConnection implements HttpConnectionApi {
  rawSock: any,
  sslSock: any,
  name: string,
  remote: string,
  handshaking: boolean = true,
  wantsWrite: boolean = false,
  alpn: string = "",

  constructor(rawSock: any, sslSock: any)
    self.rawSock = rawSock
    self.sslSock = sslSock
    self.name = tostring(rawSock)
    self.remote = ""
    pcall(function(): void rawSock:settimeout(0) end)
    pcall(function(): void sslSock:settimeout(0) end)
    local ok, ip, port = pcall(function(): (string | nil, integer | nil)
      return rawSock:getpeername()
    end)
    if ok and ip ~= nil then
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
    return self.wantsWrite
  end,

  needsHandshake(): boolean
    return self.handshaking
  end,

  poll(): boolean
    -- LuaSec's SSL object may hold decrypted bytes that select() cannot see
    -- on the raw socket, so TLS connections are polled every short step.
    return true
  end,

  protocol(): string
    return self.alpn
  end,

  raw(): any
    return self.rawSock
  end,

  driveHandshake(): (boolean, string)
    if not self.handshaking then
      return true, ""
    end
    local callOk: boolean = false
    local handshakeOK: any = nil
    local handshakeErr: any = nil
    callOk, handshakeOK, handshakeErr = pcall(function(): any
      return self.sslSock:dohandshake()
    end)
    if not callOk then
      return false, tostring(handshakeOK)
    end
    if handshakeOK == true then
      self.handshaking = false
      self.wantsWrite = false
      local alpnOk: boolean = false
      local selected: any = nil
      alpnOk, selected = pcall(function(): any
        return self.sslSock:getalpn()
      end)
      if alpnOk and selected ~= nil then self.alpn = tostring(selected) end
      return true, ""
    end
    local reason: string = tostring(handshakeErr)
    if reason == "wantread" or reason == "timeout" then
      self.wantsWrite = false
      return false, "wantread"
    elseif reason == "wantwrite" then
      self.wantsWrite = true
      return false, "wantwrite"
    elseif reason == "closed" then
      return false, "closed"
    end
    return false, reason
  end,

  readAvailable(maxBytes: integer): ReadResult
    if self.handshaking then
      local ok: boolean = false
      local reason: string = ""
      ok, reason = self:driveHandshake()
      if not ok then
        if reason == "wantread" or reason == "wantwrite" then
          return { data = "", err = nil, closed = false, wouldBlock = true }
        end
        if reason == "closed" then
          return { data = "", err = nil, closed = true, wouldBlock = false }
        end
        return { data = "", err = reason, closed = false, wouldBlock = false }
      end
    end
    -- Drain decrypted records until SSL has no more data. Selecting on the
    -- raw socket would otherwise miss bytes already buffered inside LuaSec.
    local parts: string[] = {}
    local total: integer = 0
    local closed: boolean = false
    local capped: boolean = false
    while total < 1048576 do
      local want: integer = maxBytes
      if want > 65536 then want = 65536 end
      local data, err, partial = self.sslSock:receive(want)
      local piece: string = ""
      if data ~= nil then
        piece = tostring(data)
      elseif partial ~= nil then
        piece = tostring(partial)
      end
      if #piece > 0 then
        parts[#parts + 1] = piece
        total = total + #piece
      end
      if data ~= nil then
        -- receive(n) returned a full read; try again.
      elseif err == "closed" then
        closed = true
        break
      elseif err == "timeout" or err == "wantread" then
        if #piece == 0 then break end
      elseif err == "wantwrite" then
        self.wantsWrite = true
        break
      else
        return { data = table.concat(parts), err = tostring(err), closed = false, wouldBlock = false }
      end
      if total >= 1048576 then
        capped = true
        break
      end
    end
    local text: string = table.concat(parts)
    if capped then
      -- Extremely large plaintext bursts are rare; return what we have and
      -- let the next selector round continue. A non-empty read is never
      -- reported as wouldBlock, so the server processes it now.
      return { data = text, err = nil, closed = false, wouldBlock = false }
    end
    if closed then
      return { data = text, err = nil, closed = true, wouldBlock = false }
    end
    if #text == 0 then
      return { data = "", err = nil, closed = false, wouldBlock = true }
    end
    return { data = text, err = nil, closed = false, wouldBlock = false }
  end,

  writeSome(data: string): WriteResult
    if self.handshaking then
      local ok: boolean = false
      local reason: string = ""
      ok, reason = self:driveHandshake()
      if not ok then
        if reason == "wantread" or reason == "wantwrite" then
          return { written = 0, err = nil, wouldBlock = true }
        end
        return { written = 0, err = reason, wouldBlock = false }
      end
    end
    if data == "" then
      return { written = 0, err = nil, wouldBlock = false }
    end
    local sent, err, last = self.sslSock:send(data)
    if sent ~= nil then
      return { written = math.floor(sent), err = nil, wouldBlock = false }
    end
    local written: integer = 0
    if last ~= nil then written = math.floor(last) end
    if err == "timeout" or err == "wantread" or err == "wantwrite" then
      if err == "wantwrite" then self.wantsWrite = true end
      return { written = written, err = nil, wouldBlock = true }
    end
    return { written = written, err = tostring(err), wouldBlock = false }
  end,

  close(): void
    pcall(function(): void self.sslSock:close() end)
  end,

  remoteAddress(): string
    return self.remote
  end,
}

class TlsListener implements HttpListenerApi {
  server: any,
  host: string,
  port: integer,
  config: any,

  constructor(server: any, host: string, port: integer, config: any)
    self.server = server
    self.host = host
    self.port = port
    self.config = config
    self.server:settimeout(0)
  end,

  accept(): AcceptResult
    local client, err = self.server:accept()
    if client == nil then
      if err == "timeout" then
        return { conn = nil, err = nil, wouldBlock = true }
      end
      return { conn = nil, err = tostring(err), wouldBlock = false }
    end
    local wrapped: any = nil
    local wrapOk: boolean = false
    local wrapErr: any = nil
    wrapOk, wrapped = pcall(function(): any
      return sslModule.wrap(client, self.config)
    end)
    if not wrapOk or wrapped == nil then
      if not wrapOk then wrapErr = wrapped else wrapErr = "ssl.wrap failed" end
      pcall(function(): void client:close() end)
      return { conn = nil, err = tostring(wrapErr), wouldBlock = false }
    end
    return { conn = TlsConnection.new(client, wrapped), err = nil, wouldBlock = false }
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

class TlsTransport implements HttpTransportApi {
  sel: HttpSelectorApi,
  config: any,

  constructor(options: TlsOptions)
    if socketModule == nil then
      error("LuaSocket is required for TLS: install lua-socket")
    end
    if sslModule == nil then
      error("LuaSec is required for TLS: install lua-sec")
    end
    if options.certificate == "" or options.key == "" then
      error("TLS certificate and key paths are required")
    end
    local certFile = io.open(options.certificate, "rb")
    if certFile == nil then
      error("TLS certificate file cannot be opened: " .. options.certificate)
    end
    certFile:close()
    local keyFile = io.open(options.key, "rb")
    if keyFile == nil then
      error("TLS key file cannot be opened: " .. options.key)
    end
    keyFile:close()
    local alpn: string[] = { "h2", "http/1.1" }
    if options.alpn ~= nil then alpn = options.alpn! end
    local protocol: string = "any"
    if options.protocol ~= nil then protocol = options.protocol! end
    local config: any = {
      mode = "server",
      protocol = protocol,
      certificate = options.certificate,
      key = options.key,
      alpn = alpn,
      options = "all",
    }
    if options.ciphers ~= nil then config.ciphers = options.ciphers! end
    if options.password ~= nil then config.password = options.password! end
    self.config = config
    -- Reuse the LuaSocket selector; TlsConnection:raw() exposes the
    -- underlying socket for select().
    self.sel = socketTransport.SocketSelector.new()
  end,

  listen(host: string, port: integer, backlog: integer): ListenResult
    local server, err = socketModule.bind(host, port, backlog)
    if server == nil then
      return { listener = nil, err = tostring(err) }
    end
    return { listener = TlsListener.new(server, host, port, self.config), err = nil }
  end,

  selector(): HttpSelectorApi
    return self.sel
  end,

  now(): number
    return socketModule.gettime()
  end,
}

return {
  TlsConnection = TlsConnection,
  TlsListener = TlsListener,
  TlsTransport = TlsTransport,
}
