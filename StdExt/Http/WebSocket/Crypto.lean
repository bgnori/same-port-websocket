/-
Extension proposal for `Std.Http`: minimal cryptographic helpers needed by the
RFC 6455 opening handshake (`Sec-WebSocket-Accept` = Base64(SHA-1(key ++
GUID))). SHA-1 is used here only for the handshake challenge, as mandated by
RFC 6455 §1.3 — not as a general-purpose secure hash.
-/

namespace Std.Http.WebSocket.Internal

/--
Rotates a 32-bit word left by `n` bits.
-/
@[inline]
private def rotl (n : Nat) (x : UInt32) : UInt32 :=
  (x <<< n.toUInt32) ||| (x >>> (32 - n).toUInt32)

/--
Computes the SHA-1 digest (20 bytes) of `message`, per FIPS 180-4.
-/
def sha1 (message : ByteArray) : ByteArray := Id.run do
  -- Pad: append 0x80, zero bytes until length ≡ 56 (mod 64), then the
  -- original length in bits as a 64-bit big-endian integer.
  let bitLength : UInt64 := message.size.toUInt64 * 8
  let mut data := message.push 0x80
  while data.size % 64 != 56 do
    data := data.push 0
  for i in [0:8] do
    data := data.push (bitLength >>> ((7 - i.toUInt64) * 8)).toUInt8

  let mut h0 : UInt32 := 0x67452301
  let mut h1 : UInt32 := 0xEFCDAB89
  let mut h2 : UInt32 := 0x98BADCFE
  let mut h3 : UInt32 := 0x10325476
  let mut h4 : UInt32 := 0xC3D2E1F0

  for chunk in [0:data.size / 64] do
    let base := chunk * 64

    -- Message schedule.
    let mut w : Array UInt32 := Array.emptyWithCapacity 80
    for i in [0:16] do
      let o := base + i * 4
      w := w.push <|
        (data[o]!.toUInt32 <<< 24) ||| (data[o + 1]!.toUInt32 <<< 16) |||
        (data[o + 2]!.toUInt32 <<< 8) ||| data[o + 3]!.toUInt32
    for i in [16:80] do
      w := w.push (rotl 1 (w[i - 3]! ^^^ w[i - 8]! ^^^ w[i - 14]! ^^^ w[i - 16]!))

    -- Compression.
    let mut a := h0
    let mut b := h1
    let mut c := h2
    let mut d := h3
    let mut e := h4

    for i in [0:80] do
      let (f, k) :=
        if i < 20 then ((b &&& c) ||| ((~~~b) &&& d), (0x5A827999 : UInt32))
        else if i < 40 then (b ^^^ c ^^^ d, 0x6ED9EBA1)
        else if i < 60 then ((b &&& c) ||| (b &&& d) ||| (c &&& d), 0x8F1BBCDC)
        else (b ^^^ c ^^^ d, 0xCA62C1D6)
      let temp := rotl 5 a + f + e + k + w[i]!
      e := d
      d := c
      c := rotl 30 b
      b := a
      a := temp

    h0 := h0 + a
    h1 := h1 + b
    h2 := h2 + c
    h3 := h3 + d
    h4 := h4 + e

  let mut digest := ByteArray.emptyWithCapacity 20
  for h in [h0, h1, h2, h3, h4] do
    for i in [0:4] do
      digest := digest.push (h >>> ((3 - i.toUInt32) * 8)).toUInt8
  return digest

private def base64Alphabet : Array Char :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray

/--
Encodes bytes using standard Base64 with padding (RFC 4648 §4).
-/
def base64Encode (data : ByteArray) : String := Id.run do
  let mut out := ""
  let mut i := 0
  while i + 2 < data.size do
    let n := (data[i]!.toNat <<< 16) ||| (data[i + 1]!.toNat <<< 8) ||| data[i + 2]!.toNat
    out := out.push base64Alphabet[(n >>> 18) &&& 63]!
    out := out.push base64Alphabet[(n >>> 12) &&& 63]!
    out := out.push base64Alphabet[(n >>> 6) &&& 63]!
    out := out.push base64Alphabet[n &&& 63]!
    i := i + 3
  match data.size - i with
  | 1 =>
    let n := data[i]!.toNat <<< 16
    out := out.push base64Alphabet[(n >>> 18) &&& 63]!
    out := out.push base64Alphabet[(n >>> 12) &&& 63]!
    out := out ++ "=="
  | 2 =>
    let n := (data[i]!.toNat <<< 16) ||| (data[i + 1]!.toNat <<< 8)
    out := out.push base64Alphabet[(n >>> 18) &&& 63]!
    out := out.push base64Alphabet[(n >>> 12) &&& 63]!
    out := out.push base64Alphabet[(n >>> 6) &&& 63]!
    out := out ++ "="
  | _ => pure ()
  return out

end Std.Http.WebSocket.Internal
