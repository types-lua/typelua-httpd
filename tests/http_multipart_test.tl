import T from "tlua_test"
import mp from "../lib/http_multipart"

local BOUNDARY: string = "----typeluaBoundary42"

local function simpleBody(): string
  return "--" .. BOUNDARY .. "\r\n"
    .. "Content-Disposition: form-data; name=\"title\"\r\n"
    .. "\r\n"
    .. "hello world\r\n"
    .. "--" .. BOUNDARY .. "\r\n"
    .. "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n"
    .. "Content-Type: text/plain\r\n"
    .. "\r\n"
    .. "line1\r\n--not-boundary\r\nline2\r\n"
    .. "--" .. BOUNDARY .. "--\r\n"
end

local function sourceChunks(chunks: string[]): () -> string | nil
  local index: integer = 0
  return function(): string | nil
    index = index + 1
    if index > #chunks then return nil end
    return chunks[index]
  end
end

local function byteChunks(body: string): string[]
  local chunks: string[] = {}
  for i: integer = 1, #body do
    chunks[#chunks + 1] = string.sub(body, i, i)
  end
  return chunks
end

return {
  ["content type and boundary parsing"] = function(): void
    local parsed = mp.parseContentType("multipart/form-data; boundary=\"abc\"; charset=UTF-8")
    T.eq(parsed.mediaType, "multipart/form-data", "media type")
    T.eq(parsed.params["boundary"], "abc", "quoted boundary")
    T.eq(parsed.params["charset"], "UTF-8", "param")
    T.eq(mp.boundaryFrom("multipart/form-data; boundary=xyz"), "xyz", "boundaryFrom")
    T.eq(mp.boundaryFrom("text/plain; boundary=xyz"), nil, "wrong media type")
  end,

  ["reader streams fields and files"] = function(): void
    local chunks: string[] = {}
    local body: string = simpleBody()
    local i: integer = 1
    while i <= #body do
      local last: integer = i + 6
      if last > #body then last = #body end
      chunks[#chunks + 1] = string.sub(body, i, last)
      i = last + 1
    end
    local reader = mp.MultipartReader.new({
      boundary = BOUNDARY,
      source = sourceChunks(chunks),
      requireDisposition = true,
    })
    local title: any = reader:nextPart()
    T.ok(title ~= nil, "title part")
    T.eq(title:meta().name, "title", "title name")
    T.eq(title:meta().filename, nil, "field filename")
    T.eq(title:readAll(), "hello world", "title value")

    local file: any = reader:nextPart()
    T.ok(file ~= nil, "file part")
    T.eq(file:meta().name, "file", "file name")
    T.eq(file:meta().filename, "a.txt", "filename")
    T.eq(file:meta().contentType, "text/plain", "content type")
    T.eq(file:readAll(), "line1\r\n--not-boundary\r\nline2", "file bytes")
    T.eq(reader:nextPart(), nil, "no more parts")
  end,

  ["one byte at a time and all split points"] = function(): void
    local body: string = simpleBody()
    for cut: integer = 1, #body do
      local parser = mp.MultipartParser.new({ boundary = BOUNDARY })
      parser:feed(string.sub(body, 1, cut))
      parser:feed(string.sub(body, cut + 1))
      local fields: string[] = {}
      local data: string[] = {}
      local current: string = ""
      local done: boolean = false
      while not done do
        local ev = parser:next()
        if ev.kind == "needMore" then
          T.ok(false, "needMore after complete split at " .. tostring(cut))
          break
        elseif ev.kind == "error" then
          error("split " .. tostring(cut) .. ": " .. ev.error)
        elseif ev.kind == "partStart" then
          current = ev.part!.name
        elseif ev.kind == "partData" then
          data[#data + 1] = current .. "=" .. ev.data
        elseif ev.kind == "partEnd" then
          fields[#fields + 1] = current
        elseif ev.kind == "end" then
          done = true
        end
      end
      T.eq(table.concat(fields, ","), "title,file", "part order at split " .. tostring(cut))
      T.ok(string.find(table.concat(data, "\0"), "title=hello world", 1, true) ~= nil, "title at split " .. tostring(cut))
    end

    local parser = mp.MultipartParser.new({ boundary = BOUNDARY })
    local current: string = ""
    local fileData: string[] = {}
    local done: boolean = false
    for i: integer = 1, #body do
      parser:feed(string.sub(body, i, i))
      while true do
        local ev = parser:next()
        if ev.kind == "needMore" then
          break
        elseif ev.kind == "error" then
          error(ev.error)
        elseif ev.kind == "partStart" then
          current = ev.part!.name
        elseif ev.kind == "partData" then
          if current == "file" then fileData[#fileData + 1] = ev.data end
        elseif ev.kind == "end" then
          done = true
          break
        end
      end
    end
    T.ok(done, "byte feed completes")
    T.eq(table.concat(fileData), "line1\r\n--not-boundary\r\nline2", "byte file data")
  end,

  ["filename* and empty parts"] = function(): void
    local body: string = "--" .. BOUNDARY .. "\r\n"
      .. "Content-Disposition: form-data; name=\"f\"; filename*=UTF-8''na%C3%AFve.txt\r\n"
      .. "\r\n"
      .. "\r\n"
      .. "--" .. BOUNDARY .. "\r\n"
      .. "Content-Disposition: form-data; name=\"empty\"\r\n"
      .. "\r\n"
      .. "\r\n"
      .. "--" .. BOUNDARY .. "--\r\n"
    local reader = mp.MultipartReader.new({
      boundary = BOUNDARY,
      source = sourceChunks({ body }),
    })
    local file: any = reader:nextPart()
    T.eq(file:meta().filename, "naïve.txt", "RFC 5987 filename")
    T.eq(file:readAll(), "", "empty file")
    local field: any = reader:nextPart()
    T.eq(field:meta().name, "empty", "empty field")
    T.eq(field:readAll(), "", "empty value")
    T.eq(reader:nextPart(), nil, "end")
  end,

  ["limits and truncation"] = function(): void
    local body: string = simpleBody()
    local partCapped = mp.MultipartParser.new({ boundary = BOUNDARY, maxPartBytes = 4 })
    partCapped:feed(body)
    local cappedError: string = ""
    while true do
      local ev = partCapped:next()
      if ev.kind == "error" then cappedError = ev.error; break end
      if ev.kind == "end" or ev.kind == "needMore" then break end
    end
    T.ok(#cappedError > 0, "part cap")

    local partCount = mp.MultipartParser.new({ boundary = BOUNDARY, maxParts = 1 })
    partCount:feed(body)
    local countError: string = ""
    while true do
      local ev = partCount:next()
      if ev.kind == "error" then countError = ev.error; break end
      if ev.kind == "end" or ev.kind == "needMore" then break end
    end
    T.ok(#countError > 0, "part count cap")

    local truncated = mp.MultipartReader.new({
      boundary = BOUNDARY,
      source = sourceChunks({ string.sub(body, 1, 60) }),
    })
    local okCall = pcall(function(): void truncated:nextPart() end)
    T.ok(not okCall, "truncation errors")

    T.raises(function(): void
      mp.MultipartParser.new({ boundary = "bad\r\nboundary" })
    end)
  end,

  ["binary payload and CRLF preservation"] = function(): void
    local payload: string = "\0\1\2\r\n\255\254--" .. BOUNDARY .. "x"
    local body: string = "--" .. BOUNDARY .. "\r\n"
      .. "Content-Disposition: form-data; name=\"bin\"; filename=\"b.bin\"\r\n"
      .. "\r\n"
      .. payload .. "\r\n"
      .. "--" .. BOUNDARY .. "--\r\n"
    local reader = mp.MultipartReader.new({ boundary = BOUNDARY, source = sourceChunks(byteChunks(body)) })
    local part: any = reader:nextPart()
    T.eqBytes(part:readAll(), payload, "binary preserved")
  end,
}
