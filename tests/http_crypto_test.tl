import T from "tlua_test"
import base64 from "../lib/http_base64"
import sha1 from "../lib/http_sha1"

type EncodingCase = {
  raw: string,
  encoded: string,
}

return {
  ["Base64 vectors are reversible"] = function(): void
    local cases: EncodingCase[] = {
      { raw = "", encoded = "" },
      { raw = "f", encoded = "Zg==" },
      { raw = "fo", encoded = "Zm8=" },
      { raw = "foo", encoded = "Zm9v" },
      { raw = "foobar", encoded = "Zm9vYmFy" },
      { raw = "\0\1\2\255", encoded = "AAEC/w==" },
    }
    for i: integer = 1, #cases do
      local case = cases[i]
      T.eq(base64.encode(case.raw), case.encoded, "encode case " .. tostring(i))
      T.eqBytes(base64.decode(case.encoded), case.raw, "decode case " .. tostring(i))
    end
    T.raises(function(): void base64.decode("bad") end)
    T.raises(function(): void base64.decode("!!!!") end)
    T.raises(function(): void base64.decode("A===") end)
  end,

  ["SHA-1 vectors cover padding and multiple blocks"] = function(): void
    local cases: EncodingCase[] = {
      { raw = "", encoded = "da39a3ee5e6b4b0d3255bfef95601890afd80709" },
      { raw = "abc", encoded = "a9993e364706816aba3e25717850c26c9cd0d89d" },
      {
        raw = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
        encoded = "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
      },
      {
        raw = string.rep("a", 1000),
        encoded = "291e9a6c66994949b57ba5e650361e98fc36b1ba",
      },
    }
    for i: integer = 1, #cases do
      local case = cases[i]
      T.eq(sha1.hex(sha1.digest(case.raw)), case.encoded, "sha1 case " .. tostring(i))
    end
    T.eq(
      base64.encode(sha1.digest("dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11")),
      "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
      "WebSocket accept key"
    )
  end,
}
