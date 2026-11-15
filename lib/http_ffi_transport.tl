--- LuaJIT FFI transport: real TCP and TLS without LuaSocket or LuaSec.
---
--- This adapter is optional. It targets POSIX systems (Linux is exercised by
--- CI) and needs only the LuaJIT FFI plus the system `libc` and OpenSSL
--- shared libraries. Lua 5.4 has no FFI, so there the memory transport or an
--- application-provided `HttpTransportApi` remains the dependency-free path.
---
--- The LuaSocket/LuaSec adapters are untouched: choose a transport explicitly
--- at construction time. Nothing here is loaded unless `FfiSocketTransport`
--- or `FfiTlsTransport` is instantiated.

local ffiOk: boolean = false
local ffiModule: any = nil
local ffiProbed: boolean = false

local cdefsDone: boolean = false

local AF_INET: integer = 2
local SOCK_STREAM: integer = 1
local SOCK_NONBLOCK: integer = 0x800
local SOCK_CLOEXEC: integer = 0x80000

local SOL_SOCKET: integer = 1
local SO_REUSEADDR: integer = 2
local MSG_NOSIGNAL: integer = 0x4000

local POLLIN: integer = 1
local POLLOUT: integer = 4
local POLLERR: integer = 8
local POLLHUP: integer = 16
local POLLNVAL: integer = 32

local EINTR: integer = 4
local EAGAIN: integer = 11

local SSL_FILETYPE_PEM: integer = 1
local SSL_ERROR_SSL: integer = 1
local SSL_ERROR_WANT_READ: integer = 2
local SSL_ERROR_WANT_WRITE: integer = 3
local SSL_ERROR_SYSCALL: integer = 5
local SSL_ERROR_ZERO_RETURN: integer = 6

local SSL_MODE_ENABLE_PARTIAL_WRITE: integer = 1
local SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER: integer = 2

local SSL_TLSEXT_ERR_OK: integer = 0
local SSL_TLSEXT_ERR_NOACK: integer = 2

local CDEF: string = [[
typedef struct pollfd { int fd; short events; short revents; } pollfd;
typedef struct sockaddr { unsigned short sa_family; char sa_data[14]; } sockaddr;
typedef struct in_addr { uint32_t s_addr; } in_addr;
typedef struct sockaddr_in {
  unsigned short sin_family;
  uint16_t sin_port;
  in_addr sin_addr;
  char sin_zero[8];
} sockaddr_in;
typedef unsigned int socklen_t;
typedef struct { long tv_sec; long tv_nsec; } timespec;

int socket(int domain, int type, int protocol);
int connect(int fd, const sockaddr *addr, socklen_t len);
int setsockopt(int fd, int level, int optname, const void *optval, socklen_t optlen);
int bind(int fd, const sockaddr *addr, socklen_t len);
int listen(int fd, int backlog);
int accept4(int fd, sockaddr *addr, socklen_t *len, int flags);
int close(int fd);
int recv(int fd, void *buf, size_t len, int flags);
int send(int fd, const void *buf, size_t len, int flags);
int poll(pollfd *fds, unsigned long nfds, int timeout);
int getsockname(int fd, sockaddr *addr, socklen_t *len);
int getpeername(int fd, sockaddr *addr, socklen_t *len);
int inet_pton(int af, const char *src, void *dst);
const char *inet_ntop(int af, const void *src, char *dst, socklen_t size);
uint16_t htons(uint16_t hostshort);
uint16_t ntohs(uint16_t netshort);
int clock_gettime(int clk_id, timespec *tp);
char *strerror(int errnum);

typedef struct ssl_ctx_st SSL_CTX;
typedef struct ssl_st SSL;
typedef struct ssl_method_st SSL_METHOD;

const SSL_METHOD *TLS_server_method(void);
SSL_CTX *SSL_CTX_new(const SSL_METHOD *meth);
void SSL_CTX_free(SSL_CTX *ctx);
int SSL_CTX_use_certificate_chain_file(SSL_CTX *ctx, const char *file);
int SSL_CTX_use_PrivateKey_file(SSL_CTX *ctx, const char *file, int type);
int SSL_CTX_check_private_key(const SSL_CTX *ctx);
void SSL_CTX_set_verify(SSL_CTX *ctx, int mode, void *cb);
long SSL_CTX_ctrl(SSL_CTX *ctx, int cmd, long larg, void *parg);
int SSL_CTX_set_cipher_list(SSL_CTX *ctx, const char *str);
int SSL_CTX_set_ciphersuites(SSL_CTX *ctx, const char *str);

typedef int (*SSL_ALPNSelectCallback)(
  SSL *ssl,
  const unsigned char **out,
  unsigned char *outlen,
  const unsigned char *inp,
  unsigned int inlen,
  void *arg
);
void SSL_CTX_set_alpn_select_cb(SSL_CTX *ctx, SSL_ALPNSelectCallback cb, void *arg);
void SSL_get0_alpn_selected(const SSL *ssl, const unsigned char **data, unsigned int *len);

SSL *SSL_new(SSL_CTX *ctx);
void SSL_free(SSL *ssl);
int SSL_set_fd(SSL *ssl, int fd);
int SSL_accept(SSL *ssl);
int SSL_read(SSL *ssl, void *buf, int num);
int SSL_write(SSL *ssl, const void *buf, int num);
int SSL_get_error(const SSL *ssl, int ret);
int SSL_pending(const SSL *ssl);
int SSL_shutdown(SSL *ssl);

unsigned long ERR_get_error(void);
void ERR_error_string_n(unsigned long e, char *buf, size_t len);
void ERR_clear_error(void);
]]

local function ensureFfi(): any
  if not ffiProbed then
    ffiProbed = true
    ffiOk, ffiModule = pcall(require, "ffi")
  end
  if not ffiOk or ffiModule == nil then
    error("LuaJIT FFI is required for the FFI transport; use LuaJIT or a custom HttpTransportApi")
  end
  if not cdefsDone then
    ffiModule.cdef(CDEF)
    cdefsDone = true
  end
  return ffiModule
end

local function errnoName(ffi: any, C: any, code: integer): string
  local text: any = C.strerror(code)
  if text == nil then
    return "errno " .. tostring(code)
  end
  return ffi.string(text)
end

local function isRetryable(code: integer): boolean
  return code == EAGAIN or code == EINTR
end

local function hasBit(value: integer, bit: integer): boolean
  return math.floor(value / bit) % 2 == 1
end

local function tlsError(ffi: any, CR: any): string
  local parts: string[] = {}
  local guard: integer = 0
  while guard < 8 do
    guard = guard + 1
    local code: any = CR.ERR_get_error()
    if code == 0 then break end
    local buf: any = ffi.new("char[256]")
    CR.ERR_error_string_n(code, buf, 256)
    parts[#parts + 1] = ffi.string(buf)
  end
  if #parts == 0 then
    return "OpenSSL error (errno " .. tostring(ffi.errno()) .. ")"
  end
  return table.concat(parts, "; ")
end

local function htons(C: any, port: integer): integer
  return C.htons(port) as integer
end

local function ntohs(C: any, port: any): integer
  return C.ntohs(port) as integer
end

local function parseHost(ffi: any, C: any, host: string, addr: any): void
  local text: string = host
  if text == "" or text == "*" or text == "0.0.0.0" then
    addr.sin_addr.s_addr = 0
    return
  end
  local target: string = text
  if text == "localhost" then
    target = "127.0.0.1"
  end
  local scratch: any = ffi.new("uint8_t[4]")
  if C.inet_pton(AF_INET, target, scratch) ~= 1 then
    error("FFI transport supports IPv4 addresses only: " .. host)
  end
  addr.sin_addr.s_addr = (ffi.cast("in_addr*", scratch)[0]).s_addr
end

local function makeAddress(ffi: any, C: any, host: string, port: integer): any
  local addr: any = ffi.new("sockaddr_in")
  addr.sin_family = AF_INET
  addr.sin_port = htons(C, port)
  parseHost(ffi, C, host, addr)
  return addr
end

local function addressPort(C: any, addr: any): integer
  return ntohs(C, addr.sin_port)
end

local function addressHost(ffi: any, C: any, addr: any): string
  local buf: any = ffi.new("char[64]")
  local result: any = C.inet_ntop(AF_INET, addr.sin_addr, buf, 64)
  if result == nil then return "" end
  return ffi.string(buf)
end

local function remoteName(ffi: any, C: any, fd: integer): string
  local addr: any = ffi.new("sockaddr_in")
  local length: any = ffi.new("socklen_t[1]", ffi.sizeof("sockaddr_in"))
  local ok: any = C.getpeername(fd, ffi.cast("sockaddr*", addr), length)
  if ok ~= 0 then return "" end
  return addressHost(ffi, C, addr) .. ":" .. tostring(addressPort(C, addr))
end

local function createListener(ffi: any, C: any, host: string, port: integer, backlog: integer): (integer, string)
  local fd: any = C.socket(AF_INET, SOCK_STREAM + SOCK_NONBLOCK + SOCK_CLOEXEC, 0)
  if fd < 0 then
    return -1, "socket: " .. errnoName(ffi, C, ffi.errno())
  end
  local one: any = ffi.new("int[1]", 1)
  C.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, one, 4)
  local addr: any = makeAddress(ffi, C, host, port)
  if C.bind(fd, ffi.cast("sockaddr*", addr), ffi.sizeof("sockaddr_in")) ~= 0 then
    local message: string = "bind: " .. errnoName(ffi, C, ffi.errno())
    C.close(fd)
    return -1, message
  end
  if C.listen(fd, backlog) ~= 0 then
    local message: string = "listen: " .. errnoName(ffi, C, ffi.errno())
    C.close(fd)
    return -1, message
  end
  return fd as integer, ""
end

type FfiTlsOptions = {
  certificate: string,
  key: string,
  alpn?: string[],
  ciphers?: string,
  password?: string,
}

class FfiConnection implements HttpConnectionApi {
  fd: integer,
  name: string,
  remote: string,
  closedFlag: boolean = false,
  handshaking: boolean = false,
  wantsWrite: boolean = false,
  alpn: string = "",
  ffi: any,
  C: any,
  S: any,
  CR: any,
  ssl: any,

  constructor(
    ffi: any,
    C: any,
    S: any,
    CR: any,
    fd: integer,
    remote: string,
    ssl: any,
    handshaking: boolean
  )
    self.ffi = ffi
    self.C = C
    self.S = S
    self.CR = CR
    self.fd = fd
    self.remote = remote
    self.ssl = ssl
    self.handshaking = handshaking
    self.name = "ffi:" .. tostring(fd)
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
    -- OpenSSL can hold decrypted plaintext that poll() cannot see on the
    -- socket. Polling the connection each short server turn is cheaper than
    -- losing data and matches the LuaSec adapter's behaviour.
    return self.ssl ~= nil
  end,

  protocol(): string
    return self.alpn
  end,

  raw(): integer
    return self.fd
  end,

  remoteAddress(): string
    return self.remote
  end,

  driveHandshake(): (boolean, string)
    if not self.handshaking then return true, "" end
    local ret: any = self.S.SSL_accept(self.ssl)
    if ret == 1 then
      self.handshaking = false
      self.wantsWrite = false
      local data: any = self.ffi.new("const unsigned char *[1]")
      local length: any = self.ffi.new("unsigned int[1]")
      self.S.SSL_get0_alpn_selected(self.ssl, data, length)
      if length[0] > 0 and data[0] ~= nil then
        self.alpn = self.ffi.string(data[0], length[0])
      end
      return true, ""
    end
    local code: integer = self.S.SSL_get_error(self.ssl, ret) as integer
    if code == SSL_ERROR_WANT_READ then
      self.wantsWrite = false
      return false, "wantread"
    elseif code == SSL_ERROR_WANT_WRITE then
      self.wantsWrite = true
      return false, "wantwrite"
    elseif code == SSL_ERROR_ZERO_RETURN then
      return false, "closed"
    elseif code == SSL_ERROR_SYSCALL then
      local errno: integer = self.ffi.errno() as integer
      if errno == 0 and ret == 0 then return false, "closed" end
      if isRetryable(errno) then
        self.wantsWrite = false
        return false, "wantread"
      end
      return false, "TLS accept: " .. errnoName(self.ffi, self.C, errno)
    end
    return false, "TLS accept: " .. tlsError(self.ffi, self.CR)
  end,

  readPlain(maxBytes: integer): ReadResult
    local parts: string[] = {}
    local total: integer = 0
    local closed: boolean = false
    while total < maxBytes and total < 1048576 do
      local want: integer = maxBytes - total
      if want > 65536 then want = 65536 end
      local buffer: any = self.ffi.new("char[?]", want)
      local count: any = self.C.recv(self.fd, buffer, want, 0)
      if count > 0 then
        local piece: string = self.ffi.string(buffer, count)
        parts[#parts + 1] = piece
        total = total + #piece
      elseif count == 0 then
        closed = true
        break
      else
        local errno: integer = self.ffi.errno() as integer
        if isRetryable(errno) then break end
        return {
          data = table.concat(parts),
          err = "recv: " .. errnoName(self.ffi, self.C, errno),
          closed = false,
          wouldBlock = false,
        }
      end
    end
    local data: string = table.concat(parts)
    if closed then
      return { data = data, err = nil, closed = true, wouldBlock = false }
    end
    if data == "" then
      return { data = "", err = nil, closed = false, wouldBlock = true }
    end
    return { data = data, err = nil, closed = false, wouldBlock = false }
  end,

  readTls(maxBytes: integer): ReadResult
    if self.handshaking then
      local ok: boolean = false
      local reason: string = ""
      ok, reason = self:driveHandshake()
      if not ok then
        if reason == "wantread" or reason == "wantwrite" then
          return { data = "", err = nil, closed = false, wouldBlock = true }
        elseif reason == "closed" then
          return { data = "", err = nil, closed = true, wouldBlock = false }
        end
        return { data = "", err = reason, closed = false, wouldBlock = false }
      end
    end

    local parts: string[] = {}
    local total: integer = 0
    local closed: boolean = false
    while total < maxBytes and total < 1048576 do
      local want: integer = maxBytes - total
      if want > 65536 then want = 65536 end
      local buffer: any = self.ffi.new("char[?]", want)
      local count: any = self.S.SSL_read(self.ssl, buffer, want)
      if count > 0 then
        local piece: string = self.ffi.string(buffer, count)
        parts[#parts + 1] = piece
        total = total + #piece
        self.wantsWrite = false
        if self.S.SSL_pending(self.ssl) <= 0 and total < maxBytes then
          -- One more SSL_read is cheap and picks up bytes that arrived in the
          -- same TLS record. It returns WANT_READ cleanly when empty.
        end
      elseif count == 0 then
        closed = true
        break
      else
        local code: integer = self.S.SSL_get_error(self.ssl, count) as integer
        if code == SSL_ERROR_WANT_READ then
          break
        elseif code == SSL_ERROR_WANT_WRITE then
          self.wantsWrite = true
          break
        elseif code == SSL_ERROR_ZERO_RETURN then
          closed = true
          break
        elseif code == SSL_ERROR_SYSCALL then
          local errno: integer = self.ffi.errno() as integer
          if errno == 0 then
            closed = true
            break
          end
          if isRetryable(errno) then break end
          return {
            data = table.concat(parts),
            err = "TLS read: " .. errnoName(self.ffi, self.C, errno),
            closed = false,
            wouldBlock = false,
          }
        else
          return {
            data = table.concat(parts),
            err = "TLS read: " .. tlsError(self.ffi, self.CR),
            closed = false,
            wouldBlock = false,
          }
        end
      end
    end
    local data: string = table.concat(parts)
    if closed then
      return { data = data, err = nil, closed = true, wouldBlock = false }
    end
    if data == "" then
      return { data = "", err = nil, closed = false, wouldBlock = true }
    end
    return { data = data, err = nil, closed = false, wouldBlock = false }
  end,

  readAvailable(maxBytes: integer): ReadResult
    if maxBytes <= 0 then
      return { data = "", err = nil, closed = false, wouldBlock = true }
    end
    if self.closedFlag then
      return { data = "", err = nil, closed = true, wouldBlock = false }
    end
    if self.ssl ~= nil then
      return self:readTls(maxBytes)
    end
    return self:readPlain(maxBytes)
  end,

  writeSome(data: string): WriteResult
    if self.closedFlag then
      return { written = 0, err = "closed", wouldBlock = false }
    end
    if self.ssl ~= nil and self.handshaking then
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
    if self.ssl ~= nil then
      local count: any = self.S.SSL_write(self.ssl, data, #data)
      if count > 0 then
        self.wantsWrite = false
        return { written = count as integer, err = nil, wouldBlock = false }
      end
      local code: integer = self.S.SSL_get_error(self.ssl, count) as integer
      if code == SSL_ERROR_WANT_WRITE then
        self.wantsWrite = true
        return { written = 0, err = nil, wouldBlock = true }
      elseif code == SSL_ERROR_WANT_READ then
        return { written = 0, err = nil, wouldBlock = true }
      elseif code == SSL_ERROR_ZERO_RETURN then
        return { written = 0, err = "closed", wouldBlock = false }
      elseif code == SSL_ERROR_SYSCALL then
        local errno: integer = self.ffi.errno() as integer
        if isRetryable(errno) then
          return { written = 0, err = nil, wouldBlock = true }
        end
        return {
          written = 0,
          err = "TLS write: " .. errnoName(self.ffi, self.C, errno),
          wouldBlock = false,
        }
      end
      return {
        written = 0,
        err = "TLS write: " .. tlsError(self.ffi, self.CR),
        wouldBlock = false,
      }
    end
    local sent: any = self.C.send(self.fd, data, #data, MSG_NOSIGNAL)
    if sent > 0 then
      return { written = sent as integer, err = nil, wouldBlock = false }
    end
    local errno: integer = self.ffi.errno() as integer
    if isRetryable(errno) then
      return { written = 0, err = nil, wouldBlock = true }
    end
    return {
      written = 0,
      err = "send: " .. errnoName(self.ffi, self.C, errno),
      wouldBlock = false,
    }
  end,

  close(): void
    if self.closedFlag then return end
    self.closedFlag = true
    if self.ssl ~= nil then
      pcall(function(): void self.S.SSL_shutdown(self.ssl) end)
      self.S.SSL_free(self.ssl)
      self.ssl = nil
    end
    if self.fd >= 0 then
      self.C.close(self.fd)
      self.fd = -1
    end
  end,
}

class FfiListener implements HttpListenerApi {
  ffi: any,
  C: any,
  S: any,
  CR: any,
  fd: integer,
  host: string,
  port: integer,
  sslContext: any,

  constructor(
    ffi: any,
    C: any,
    S: any,
    CR: any,
    fd: integer,
    host: string,
    port: integer,
    sslContext: any
  )
    self.ffi = ffi
    self.C = C
    self.S = S
    self.CR = CR
    self.fd = fd
    self.host = host
    self.port = port
    self.sslContext = sslContext
  end,

  accept(): AcceptResult
    if self.fd < 0 then
      return { conn = nil, err = "listener is closed", wouldBlock = false }
    end
    local client: any = self.C.accept4(
      self.fd,
      nil,
      nil,
      SOCK_NONBLOCK + SOCK_CLOEXEC
    )
    if client < 0 then
      local errno: integer = self.ffi.errno() as integer
      if isRetryable(errno) then
        return { conn = nil, err = nil, wouldBlock = true }
      end
      return {
        conn = nil,
        err = "accept: " .. errnoName(self.ffi, self.C, errno),
        wouldBlock = false,
      }
    end
    local fd: integer = client as integer
    local remote: string = remoteName(self.ffi, self.C, fd)
    if self.sslContext ~= nil then
      local ssl: any = self.S.SSL_new(self.sslContext)
      if ssl == nil then
        self.C.close(fd)
        return {
          conn = nil,
          err = "SSL_new: " .. tlsError(self.ffi, self.CR),
          wouldBlock = false,
        }
      end
      if self.S.SSL_set_fd(ssl, fd) ~= 1 then
        self.S.SSL_free(ssl)
        self.C.close(fd)
        return {
          conn = nil,
          err = "SSL_set_fd: " .. tlsError(self.ffi, self.CR),
          wouldBlock = false,
        }
      end
      return {
        conn = FfiConnection.new(
          self.ffi,
          self.C,
          self.S,
          self.CR,
          fd,
          remote,
          ssl,
          true
        ),
        err = nil,
        wouldBlock = false,
      }
    end
    return {
      conn = FfiConnection.new(
        self.ffi,
        self.C,
        self.S,
        self.CR,
        fd,
        remote,
        nil,
        false
      ),
      err = nil,
      wouldBlock = false,
    }
  end,

  close(): void
    if self.fd >= 0 then
      self.C.close(self.fd)
      self.fd = -1
    end
  end,

  address(): TransportAddress
    local addr: any = self.ffi.new("sockaddr_in")
    local length: any = self.ffi.new("socklen_t[1]", self.ffi.sizeof("sockaddr_in"))
    local host: string = self.host
    local port: integer = self.port
    if self.fd >= 0
      and self.C.getsockname(self.fd, self.ffi.cast("sockaddr*", addr), length) == 0
    then
      host = addressHost(self.ffi, self.C, addr)
      port = addressPort(self.C, addr)
    end
    return { host = host, port = port }
  end,
}

class FfiSelector implements HttpSelectorApi {
  ffi: any,
  C: any,

  constructor(ffi: any, C: any)
    self.ffi = ffi
    self.C = C
  end,

  select(
    readers: HttpConnectionApi[],
    writers: HttpConnectionApi[],
    timeoutSeconds: number
  ): SelectResult
    local order: integer[] = {}
    local events: map<integer, integer> = {}
    local byFd: map<integer, HttpConnectionApi> = {}

    local function add(conn: HttpConnectionApi, mask: integer): void
      local raw: any = conn as any
      local fd: integer = raw:raw() as integer
      local existing: integer | nil = events[fd]
      if existing == nil then
        order[#order + 1] = fd
        events[fd] = mask
        byFd[fd] = conn
      else
        events[fd] = existing! + mask
      end
    end

    for i: integer = 1, #readers do add(readers[i], POLLIN) end
    for i: integer = 1, #writers do add(writers[i], POLLOUT) end

    if #order == 0 then
      return { readable = {}, writable = {}, err = nil }
    end

    local fds: any = self.ffi.new("pollfd[?]", #order)
    for i: integer = 1, #order do
      fds[i - 1].fd = order[i]
      fds[i - 1].events = events[order[i]]
      fds[i - 1].revents = 0
    end
    local milliseconds: integer = math.floor(timeoutSeconds * 1000)
    if milliseconds < 0 then milliseconds = 0 end
    if milliseconds > 60000 then milliseconds = 60000 end
    local ready: any = self.C.poll(fds, #order, milliseconds)
    if ready < 0 then
      local errno: integer = self.ffi.errno() as integer
      if errno == EINTR then
        return { readable = {}, writable = {}, err = nil }
      end
      return {
        readable = {},
        writable = {},
        err = "poll: " .. errnoName(self.ffi, self.C, errno),
      }
    end
    local readable: HttpConnectionApi[] = {}
    local writable: HttpConnectionApi[] = {}
    for i: integer = 1, #order do
      local revents: integer = fds[i - 1].revents as integer
      if revents ~= 0 then
        local conn: HttpConnectionApi = byFd[order[i]]!
        if hasBit(revents, POLLIN)
          or hasBit(revents, POLLERR)
          or hasBit(revents, POLLHUP)
          or hasBit(revents, POLLNVAL)
        then
          readable[#readable + 1] = conn
        end
        if hasBit(revents, POLLOUT)
          or hasBit(revents, POLLERR)
          or hasBit(revents, POLLHUP)
        then
          writable[#writable + 1] = conn
        end
      end
    end
    return { readable = readable, writable = writable, err = nil }
  end,
}

class FfiSocketTransport implements HttpTransportApi {
  ffi: any,
  C: any,
  sel: FfiSelector,

  constructor()
    local ffi: any = ensureFfi()
    self.ffi = ffi
    self.C = ffi.C
    self.sel = FfiSelector.new(ffi, self.C)
  end,

  listen(host: string, port: integer, backlog: integer): ListenResult
    local fd: integer = -1
    local err: string = ""
    fd, err = createListener(self.ffi, self.C, host, port, backlog)
    if fd < 0 then
      return { listener = nil, err = err }
    end
    return {
      listener = FfiListener.new(
        self.ffi,
        self.C,
        nil,
        nil,
        fd,
        host,
        port,
        nil
      ),
      err = nil,
    }
  end,

  selector(): HttpSelectorApi
    return self.sel
  end,

  now(): number
    local ts: any = self.ffi.new("timespec")
    if self.C.clock_gettime(1, ts) ~= 0 then
      return os.time() as number
    end
    return (ts.tv_sec as number) + (ts.tv_nsec as number) / 1000000000
  end,
}

class FfiTlsTransport implements HttpTransportApi {
  ffi: any,
  C: any,
  S: any,
  CR: any,
  ctx: any,
  alpnCallback: any,
  alpnEntries: any[],
  sel: FfiSelector,

  constructor(options: FfiTlsOptions)
    if options.password ~= nil and options.password! ~= "" then
      error("FFI TLS does not support encrypted private keys; decrypt the key or use LuaSec")
    end
    if options.certificate == "" or options.key == "" then
      error("TLS certificate and key paths are required")
    end
    local certFile: any = io.open(options.certificate, "rb")
    if certFile == nil then
      error("TLS certificate file cannot be opened: " .. options.certificate)
    end
    certFile:close()
    local keyFile: any = io.open(options.key, "rb")
    if keyFile == nil then
      error("TLS key file cannot be opened: " .. options.key)
    end
    keyFile:close()

    local ffi: any = ensureFfi()
    self.ffi = ffi
    self.C = ffi.C
    local S: any = nil
    local CR: any = nil
    local sslOk: boolean = false
    local sslLoaded: any = nil
    sslOk, sslLoaded = pcall(ffi.load, "ssl")
    if not sslOk then
      local altOk: boolean = false
      local alt: any = nil
      altOk, alt = pcall(ffi.load, "libssl.so.3")
      if altOk then sslOk = true; sslLoaded = alt end
    end
    if not sslOk then
      error("OpenSSL libssl is required for the FFI TLS transport: " .. tostring(sslLoaded))
    end
    S = sslLoaded
    local cryptoOk: boolean = false
    local cryptoLoaded: any = nil
    cryptoOk, cryptoLoaded = pcall(ffi.load, "crypto")
    if not cryptoOk then
      local altOk: boolean = false
      local alt: any = nil
      altOk, alt = pcall(ffi.load, "libcrypto.so.3")
      if altOk then cryptoOk = true; cryptoLoaded = alt end
    end
    if not cryptoOk then
      error("OpenSSL libcrypto is required for the FFI TLS transport: " .. tostring(cryptoLoaded))
    end
    CR = cryptoLoaded
    self.S = S
    self.CR = CR
    self.sel = FfiSelector.new(ffi, self.C)

    local ctx: any = S.SSL_CTX_new(S.TLS_server_method())
    if ctx == nil then
      error("SSL_CTX_new failed: " .. tlsError(ffi, CR))
    end
    if S.SSL_CTX_use_certificate_chain_file(ctx, options.certificate) ~= 1 then
      S.SSL_CTX_free(ctx)
      error("cannot load TLS certificate: " .. tlsError(ffi, CR))
    end
    if S.SSL_CTX_use_PrivateKey_file(ctx, options.key, SSL_FILETYPE_PEM) ~= 1 then
      S.SSL_CTX_free(ctx)
      error("cannot load TLS private key: " .. tlsError(ffi, CR))
    end
    if S.SSL_CTX_check_private_key(ctx) ~= 1 then
      S.SSL_CTX_free(ctx)
      error("TLS certificate/key mismatch: " .. tlsError(ffi, CR))
    end
    S.SSL_CTX_set_verify(ctx, 0, nil)
    -- SSL_CTX_set_mode is a macro in OpenSSL: SSL_CTX_ctrl(ctx, MODE, ...).
    S.SSL_CTX_ctrl(
      ctx,
      33,
      SSL_MODE_ENABLE_PARTIAL_WRITE + SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER,
      nil
    )
    if options.ciphers ~= nil and options.ciphers! ~= "" then
      if S.SSL_CTX_set_cipher_list(ctx, options.ciphers!) ~= 1 then
        S.SSL_CTX_free(ctx)
        error("invalid TLS cipher list: " .. tlsError(ffi, CR))
      end
    end
    self.ctx = ctx
    self.alpnCallback = nil
    self.alpnEntries = {}
    local protocols: string[] = { "h2", "http/1.1" }
    if options.alpn ~= nil then protocols = options.alpn! end
    if #protocols > 0 then
      self:installAlpn(protocols)
    end
  end,

  installAlpn(protocols: string[]): void
    local ffi: any = self.ffi
    local entries: any[] = {}
    for i: integer = 1, #protocols do
      local name: string = protocols[i]
      if name == "" or #name > 255 then
        error("ALPN protocol names must be 1..255 bytes")
      end
      -- The ALPN callback returns the protocol bytes themselves, not the
      -- length-prefixed wire entry. OpenSSL copies the pointer into the
      -- selected-protocol slot, so it must stay alive for the context.
      local buffer: any = ffi.new("unsigned char[?]", #name)
      ffi.copy(buffer, name, #name)
      entries[#entries + 1] = { name = name, buffer = buffer, length = #name }
    end
    local callback: any = ffi.cast(
      "SSL_ALPNSelectCallback",
      function(
        ssl: any,
        out: any,
        outlen: any,
        inp: any,
        inlen: any,
        arg: any
      ): integer
        local wire: string = ffi.string(inp, inlen)
        local pos: integer = 1
        while pos <= #wire do
          local length: integer = string.byte(wire, pos)! as integer
          pos = pos + 1
          if length == 0 or pos + length - 1 > #wire then
            return SSL_TLSEXT_ERR_NOACK
          end
          local offered: string = string.sub(wire, pos, pos + length - 1)
          pos = pos + length
          for i: integer = 1, #entries do
            if entries[i].name == offered then
              out[0] = entries[i].buffer
              outlen[0] = entries[i].length
              return SSL_TLSEXT_ERR_OK
            end
          end
        end
        return SSL_TLSEXT_ERR_NOACK
      end
    )
    self.alpnEntries = entries
    self.alpnCallback = callback
    self.S.SSL_CTX_set_alpn_select_cb(self.ctx, callback, nil)
  end,

  listen(host: string, port: integer, backlog: integer): ListenResult
    local fd: integer = -1
    local err: string = ""
    fd, err = createListener(self.ffi, self.C, host, port, backlog)
    if fd < 0 then
      return { listener = nil, err = err }
    end
    return {
      listener = FfiListener.new(
        self.ffi,
        self.C,
        self.S,
        self.CR,
        fd,
        host,
        port,
        self.ctx
      ),
      err = nil,
    }
  end,

  selector(): HttpSelectorApi
    return self.sel
  end,

  now(): number
    local ts: any = self.ffi.new("timespec")
    if self.C.clock_gettime(1, ts) ~= 0 then
      return os.time() as number
    end
    return (ts.tv_sec as number) + (ts.tv_nsec as number) / 1000000000
  end,
}

return {
  --- Ensures the C declarations are installed and returns the FFI namespace.
  --- Useful for applications that build their own client on the same primitives.
  ensureCdefs = ensureFfi,
  FfiConnection = FfiConnection,
  FfiListener = FfiListener,
  FfiSelector = FfiSelector,
  FfiSocketTransport = FfiSocketTransport,
  FfiTlsTransport = FfiTlsTransport,
}
