--- In-memory transport used by the protocol/router/server tests.
---
--- The client side is scripted: push a connection with request bytes, call
--- server steps, then inspect the accumulated response. Time is manual so
--- idle/request timeouts are deterministic. `blockWrites` simulates kernel
--- backpressure without a real socket.

class MemoryConnection implements HttpConnectionApi {
  name: string,
  input: string,
  ipos: integer = 1,
  output: string = "",
  opos: integer = 1,
  blockWrites: boolean = false,
  inputClosed: boolean = false,
  outputClosed: boolean = false,
  remote: string,

  constructor(name: string, input: string, remote: string)
    self.name = name
    self.input = input
    self.remote = remote
  end,

  id(): string
    return self.name
  end,

  feed(data: string): void
    self.input = self.input .. data
  end,

  closeInput(): void
    self.inputClosed = true
  end,

  outputText(): string
    return string.sub(self.output, self.opos)
  end,

  takeOutput(): string
    local text: string = self:outputText()
    self.output = ""
    self.opos = 1
    return text
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

  isReadable(): boolean
    if self.ipos <= #self.input then
      return true
    end
    return self.inputClosed
  end,

  readAvailable(maxBytes: integer): ReadResult
    if self.ipos <= #self.input then
      local last: integer = self.ipos + maxBytes - 1
      if last > #self.input then last = #self.input end
      local data: string = string.sub(self.input, self.ipos, last)
      self.ipos = last + 1
      return { data = data, err = nil, closed = false, wouldBlock = false }
    end
    if self.inputClosed then
      return { data = "", err = nil, closed = true, wouldBlock = false }
    end
    return { data = "", err = nil, closed = false, wouldBlock = true }
  end,

  writeSome(data: string): WriteResult
    if self.outputClosed then
      return { written = 0, err = "closed", wouldBlock = false }
    end
    if self.blockWrites then
      return { written = 0, err = nil, wouldBlock = true }
    end
    self.output = self.output .. data
    return { written = #data, err = nil, wouldBlock = false }
  end,

  close(): void
    self.inputClosed = true
    self.outputClosed = true
  end,

  remoteAddress(): string
    return self.remote
  end,
}

class MemoryListener implements HttpListenerApi {
  pending: MemoryConnection[] = {},
  host: string,
  port: integer,

  constructor(host: string, port: integer)
    self.host = host
    self.port = port
  end,

  push(conn: MemoryConnection): void
    self.pending[#self.pending + 1] = conn
  end,

  accept(): AcceptResult
    if #self.pending == 0 then
      return { conn = nil, err = "timeout", wouldBlock = true }
    end
    local conn: MemoryConnection = table.remove(self.pending, 1)!
    return { conn = conn, err = nil, wouldBlock = false }
  end,

  close(): void
    self.pending = {}
  end,

  address(): TransportAddress
    return { host = self.host, port = self.port }
  end,
}

class MemorySelector implements HttpSelectorApi {
  constructor() end,

  select(
    readers: HttpConnectionApi[],
    writers: HttpConnectionApi[],
    timeoutSeconds: number
  ): SelectResult
    local readable: HttpConnectionApi[] = {}
    for i: integer = 1, #readers do
      if readers[i]:isReadable() then
        readable[#readable + 1] = readers[i]
      end
    end
    local writable: HttpConnectionApi[] = {}
    for i: integer = 1, #writers do
      writable[#writable + 1] = writers[i]
    end
    return { readable = readable, writable = writable, err = nil }
  end,
}

class MemoryTransport implements HttpTransportApi {
  listener: MemoryListener,
  sel: MemorySelector,
  clock: number = 0,

  constructor(host: string, port: integer)
    self.listener = MemoryListener.new(host, port)
    self.sel = MemorySelector.new()
  end,

  advance(seconds: number): void
    self.clock = self.clock + seconds
  end,

  listen(host: string, port: integer, backlog: integer): ListenResult
    self.listener.host = host
    self.listener.port = port
    return { listener = self.listener, err = nil }
  end,

  selector(): HttpSelectorApi
    return self.sel
  end,

  now(): number
    return self.clock
  end,
}

return {
  MemoryConnection = MemoryConnection,
  MemoryListener = MemoryListener,
  MemorySelector = MemorySelector,
  MemoryTransport = MemoryTransport,
}
