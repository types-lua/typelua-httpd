import T from "tlua_test"
import base64 from "../lib/http_base64"
import sha1 from "../lib/http_sha1"

return {
  ["base64 vectors"] = function(): void
    T.eq(base64.encode(""), "", "empty")
    T.eq(base64.encode("f"), "Zg==", "one")
    T.eq(base64.encode("fo"), "Zm8=", "two")
    T.eq(base64.encode("foo"), "Zm9v", "three")
    T.eq(base64.encode("foobar"), "Zm9vYmFy", "six")
    T.eq(base64.decode("Zg=="), "f", "decode one")
    T.eq(base64.decode("Zm8="), "fo", "decode two")
    T.eq(base64.decode("Zm9vYmFy"), "foobar", "decode six")
    T.eqBytes(base64.decode("AAEC/w=="), "\0\1\2\255", "binary")
    T.raises(function(): void base64.decode("bad") end)
    T.raises(function(): void base64.decode("!!!!") end)
    T.raises(function(): void base64.decode("A===") end)
  end,

  ["sha1 vectors"] = function(): void
    T.eq(sha1.hex(sha1.digest("")), "da39a3ee5e6b4b0d3255bfef95601890afd80709", "empty")
    T.eq(sha1.hex(sha1.digest("abc")), "a9993e364706816aba3e25717850c26c9cd0d89d", "abc")
    T.eq(
      sha1.hex(sha1.digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
      "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
      "long vector"
    )
    T.eq(
      sha1.hex(sha1.digest(string.rep("a", 1000))),
      "291e9a6c66994949b57ba5e650361e98fc36b1ba",
      "multi-block"
    )
    T.eq(
      base64.encode(sha1.digest("dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11")),
      "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
      "websocket accept"
    )
  end,
}
