--- Dependency-free protocol core.
---
--- This facade exports the router, parser, server state machine, static
--- files, WebSocket, multipart and the memory transport. It never loads
--- LuaSocket or LuaSec: real I/O is injected through `HttpTransportApi`.
--- Use `lib/http` (or the package root) when you want the bundled adapters.

import headers from "./http_headers"
import request from "./http_request"
import response from "./http_response"
import parser from "./http_parser"
import context from "./http_context"
import router from "./http_router"
import staticMod from "./http_static"
import server from "./http_server"
import memory from "./http_memory_transport"
import url from "./http_url"
import status from "./http_status"
import date from "./http_date"
import mime from "./http_mime"
import websocket from "./http_websocket"
import multipart from "./http_multipart"
import hpack from "./http_hpack"
import h2frame from "./http_h2_frame"
import base64 from "./http_base64"
import sha1 from "./http_sha1"

return {
  Headers = headers.Headers,
  HttpRequest = request.HttpRequest,
  HttpResponse = response.HttpResponse,
  HttpRequestParser = parser.HttpRequestParser,
  HttpContext = context.HttpContext,
  HttpRouter = router.HttpRouter,
  HttpStatic = staticMod.HttpStatic,
  HttpServer = server.HttpServer,
  MemoryTransport = memory.MemoryTransport,
  MemoryConnection = memory.MemoryConnection,
  WebSocketSession = websocket.WebSocketSession,
  WsFrameParser = websocket.WsFrameParser,
  acceptKey = websocket.acceptKey,
  MultipartParser = multipart.MultipartParser,
  MultipartReader = multipart.MultipartReader,
  HpackDecoder = hpack.HpackDecoder,
  H2FrameParser = h2frame.H2FrameParser,
  base64 = base64,
  sha1 = sha1,
  serialize = response.serialize,
  errorResponse = response.errorResponse,
  url = url,
  status = status,
  date = date,
  mime = mime,
}
