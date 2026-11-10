import T from "tlua_test"
import hpack from "../lib/http_hpack"

local function hex(value: string): string
  local out: string[] = {}
  for i: integer = 1, #value, 2 do
    out[#out + 1] = string.char(tonumber(string.sub(value, i, i + 1), 16) as integer)
  end
  return table.concat(out)
end

return {
  ["static indexed fields and literals"] = function(): void
    local decoder = hpack.HpackDecoder.new()
    local result = decoder:decode(string.char(0x82))
    T.eq(result.error, "", "indexed")
    T.eq(#result.headers!, 1, "one header")
    T.eq(result.headers![1].name, ":method", "method")
    T.eq(result.headers![1].value, "GET", "GET")

    local block: string = string.char(0x40, 0x0a) .. "custom-key"
      .. string.char(0x0d) .. "custom-header"
    local literal = decoder:decode(block)
    T.eq(literal.error, "", "literal with indexing")
    T.eq(literal.headers![1].name, "custom-key", "literal name")
    T.eq(literal.headers![1].value, "custom-header", "literal value")
    T.eq(decoder.dynamicSize, 55, "dynamic size")

    local again = decoder:decode(string.char(0x80 + 62))
    T.eq(again.error, "", "dynamic indexed")
    T.eq(again.headers![1].name, "custom-key", "dynamic lookup")
    T.eq(again.headers![1].value, "custom-header", "dynamic value")
  end,

  ["RFC Huffman request block"] = function(): void
    local decoder = hpack.HpackDecoder.new()
    local block = hex("828684418cf1e3c2e5f23a6ba0ab90f4ff")
    local result = decoder:decode(block)
    T.eq(result.error, "", "huffman decodes")
    T.eq(#result.headers!, 4, "four headers")
    T.eq(result.headers![1].name, ":method", "method")
    T.eq(result.headers![2].name, ":scheme", "scheme")
    T.eq(result.headers![3].name, ":path", "path")
    T.eq(result.headers![4].name, ":authority", "authority")
    T.eq(result.headers![4].value, "www.example.com", "huffman value")
    T.eq(hpack.huffmanDecode(hex("f1e3c2e5f23a6ba0ab90f4ff")), "www.example.com", "direct huffman")
  end,

  ["encoder round-trip"] = function(): void
    local headers = {
      { name = ":status", value = "200" },
      { name = "content-type", value = "text/plain; charset=utf-8" },
      { name = "content-length", value = "5" },
      { name = "x-custom", value = "hello \255" },
      { name = "set-cookie", value = "a=1" },
      { name = "set-cookie", value = "b=2" },
    }
    local block = hpack.encodeHeaders(headers)
    local decoder = hpack.HpackDecoder.new()
    local result = decoder:decode(block)
    T.eq(result.error, "", "roundtrip")
    T.eq(#result.headers!, #headers, "count")
    for i: integer = 1, #headers do
      T.eq(result.headers![i].name, headers[i].name, "name " .. tostring(i))
      T.eq(result.headers![i].value, headers[i].value, "value " .. tostring(i))
    end
    T.eq(string.sub(block, 1, 1), string.char(0x88), "status 200 uses static index")
  end,

  ["table updates and malformed blocks"] = function(): void
    local decoder = hpack.HpackDecoder.new()
    local tooLarge = decoder:decode(hpack.encodeInt(8192, 5, 0x20))
    T.ok(#tooLarge.error > 0, "table size above advertised max")

    local decoder2 = hpack.HpackDecoder.new()
    local update = hpack.encodeInt(0, 5, 0x20)
    local field = string.char(0x82)
    local after = decoder2:decode(update .. field .. update)
    T.ok(#after.error > 0, "size update after field")

    local truncated = decoder2:decode("\255")
    T.ok(#truncated.error > 0, "truncated integer")

    local badHuffman = decoder2:decode(hex("418cffffffffffffffffffffffff"))
    T.ok(#badHuffman.error > 0, "invalid huffman")

    local eosOk: boolean = false
    local eosValue: any = nil
    local eosError: any = nil
    eosOk, eosValue, eosError = pcall(hpack.huffmanDecode, hex("ffffffff"))
    T.ok(eosOk and eosValue == "" and #tostring(eosError) > 0, "EOS rejected")
  end,
}
