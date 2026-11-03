/-
Test driver: WebSocket unit tests (crypto, frames, handshake, close reasons)
plus the lifecycle-model suites in StdExtTests/.
-/
import StdExt
import StdExtTests
import StdExt.Http.WebSocket.Lifecycle
import StdExt.Http.WebSocket.MockExecutor
import StdExt.Http.WebSocket.AsyncExecutor
import StdExt.Http.WebSocket.FrameAdapter
import StdExt.Http.WebSocket.LifecycleUpgrade

open StdExtTests

section WebSocketTests

open Std.Http
open Std.Http.WebSocket

private def hexOf (bytes : ByteArray) : String := Id.run do
  let digits := "0123456789abcdef".toList.toArray
  let mut out := ""
  for i in [0:bytes.size] do
    let b := bytes[i]!
    out := out.push digits[b.toNat >>> 4]!
    out := out.push digits[b.toNat &&& 15]!
  return out

-- FIPS 180-4 / RFC 3174 test vectors (including a multi-chunk input).
#guard hexOf (Internal.sha1 "abc".toUTF8) == "a9993e364706816aba3e25717850c26c9cd0d89d"
#guard hexOf (Internal.sha1 "".toUTF8) == "da39a3ee5e6b4b0d3255bfef95601890afd80709"
#guard hexOf (Internal.sha1 "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".toUTF8) ==
  "84983e441c3bd26ebaae4aa1f95129e5e54670f1"

-- RFC 4648 §10 test vectors.
#guard Internal.base64Encode ByteArray.empty == ""
#guard Internal.base64Encode "f".toUTF8 == "Zg=="
#guard Internal.base64Encode "fo".toUTF8 == "Zm8="
#guard Internal.base64Encode "foo".toUTF8 == "Zm9v"
#guard Internal.base64Encode "foob".toUTF8 == "Zm9vYg=="
#guard Internal.base64Encode "fooba".toUTF8 == "Zm9vYmE="
#guard Internal.base64Encode "foobar".toUTF8 == "Zm9vYmFy"

-- RFC 6455 §1.3 handshake example.
#guard acceptKey "dGhlIHNhbXBsZSBub25jZQ==" == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

-- RFC 6455 §5.7: a masked "Hello" text frame from the client.
private def rfcMaskedHello : Bool :=
  let bytes : ByteArray :=
    ⟨#[0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]⟩
  match Frame.decode? bytes true 1024 with
  | .ok (some (frame, consumed)) =>
    frame.fin && frame.opcode == .text && frame.payload == "Hello".toUTF8 &&
      consumed == bytes.size
  | _ => false

#guard rfcMaskedHello

-- Masked encode followed by server-side decode restores the payload.
private def maskedRoundTrip : Bool :=
  let payload := "Hello, WebSocket!".toUTF8
  let key : ByteArray := ⟨#[0x37, 0xfa, 0x21, 0x3d]⟩
  let bytes := Frame.encode { opcode := .binary, payload } (maskKey := some key)
  match Frame.decode? bytes true 1024 with
  | .ok (some (frame, consumed)) =>
    frame.fin && frame.opcode == .binary && frame.payload == payload &&
      consumed == bytes.size
  | _ => false

#guard maskedRoundTrip

-- Server-to-client frames are unmasked and use the 16-bit extended length.
private def serverLongFrame : Bool := Id.run do
  let mut payload := ByteArray.empty
  for i in [0:300] do
    payload := payload.push i.toUInt8
  let bytes := Frame.encode { opcode := .binary, payload }
  match Frame.decode? bytes false 1024 with
  | .ok (some (frame, consumed)) =>
    return frame.payload == payload && consumed == bytes.size
  | _ => return false

#guard serverLongFrame

-- Incomplete input requests more bytes instead of failing.
#guard match Frame.decode? ⟨#[0x81]⟩ true 1024 with
  | .ok none => true
  | _ => false
#guard match Frame.decode? ⟨#[0x81, 0x85, 0x37, 0xfa]⟩ true 1024 with
  | .ok none => true
  | _ => false

-- Per-frame protocol violations.
private def decodesToError (bytes : ByteArray) (expected : ProtocolError) : Bool :=
  match Frame.decode? bytes true 1024 with
  | .error error => error == expected
  | _ => false

#guard decodesToError ⟨#[0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]⟩ .unmaskedFrame
#guard decodesToError ⟨#[0xC1, 0x80, 0, 0, 0, 0]⟩ .reservedBitsSet
#guard decodesToError ⟨#[0x83, 0x80, 0, 0, 0, 0]⟩ (.unknownOpcode 3)
#guard decodesToError ⟨#[0x09, 0x80, 0, 0, 0, 0]⟩ .fragmentedControl
#guard decodesToError ⟨#[0x89, 0xFE, 0, 126, 0, 0, 0, 0]⟩ .controlTooLarge
#guard decodesToError ⟨#[0x82, 0xFE, 0, 5, 0, 0, 0, 0]⟩ .nonMinimalLength
#guard decodesToError ⟨#[0x82, 0xFE, 0xFF, 0xFF, 0, 0, 0, 0]⟩ (.payloadTooLarge 65535)

#guard validCloseCode 1000 && validCloseCode 1011 && validCloseCode 3000 &&
  validCloseCode 4999
#guard !validCloseCode 999 && !validCloseCode 1004 && !validCloseCode 1005 &&
  !validCloseCode 1006 && !validCloseCode 1015 && !validCloseCode 2999 &&
  !validCloseCode 5000

private def wsRequest (headers : List (String × String)) (method : Method := .get) :
    Request.Head := {
  method
  version := .v11
  headers := headers.foldl (fun acc (name, value) => acc.insert! name value) Headers.empty
}

private def validHandshakeHeaders : List (String × String) := [
  ("Host", "127.0.0.1"),
  ("Upgrade", "websocket"),
  ("Connection", "keep-alive, Upgrade"),
  ("Sec-WebSocket-Version", "13"),
  ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")]

private def handshakeOk (result : Except HandshakeError String) (key : String) : Bool :=
  match result with
  | .ok value => value == key
  | .error _ => false

private def handshakeFails (result : Except HandshakeError String)
    (expected : HandshakeError) : Bool :=
  match result with
  | .error error => error == expected
  | .ok _ => false

#guard handshakeOk (checkHandshake (wsRequest validHandshakeHeaders))
  "dGhlIHNhbXBsZSBub25jZQ=="
#guard handshakeFails (checkHandshake (wsRequest validHandshakeHeaders (method := .post)))
  .methodNotAllowed
#guard handshakeFails
  (checkHandshake (wsRequest (validHandshakeHeaders.filter (·.1 != "Upgrade"))))
  .missingUpgrade
#guard handshakeFails
  (checkHandshake (wsRequest (("Connection", "keep-alive") ::
    validHandshakeHeaders.filter (·.1 != "Connection"))))
  .missingConnectionUpgrade
#guard handshakeFails
  (checkHandshake (wsRequest (("Sec-WebSocket-Version", "8") ::
    validHandshakeHeaders.filter (·.1 != "Sec-WebSocket-Version"))))
  .unsupportedVersion
#guard handshakeFails
  (checkHandshake (wsRequest (validHandshakeHeaders.filter (·.1 != "Sec-WebSocket-Key"))))
  .invalidKey
#guard handshakeFails
  (checkHandshake (wsRequest (("Sec-WebSocket-Key", "short") ::
    validHandshakeHeaders.filter (·.1 != "Sec-WebSocket-Key"))))
  .invalidKey
#guard handshakeFails
  (checkHandshake (wsRequest validHandshakeHeaders)
    (checkOrigin := fun origin => origin.isSome))
  .originRejected
#guard handshakeOk
  (checkHandshake
    (wsRequest (("Origin", "http://127.0.0.1:8080") :: validHandshakeHeaders))
    (checkOrigin := (· == some "http://127.0.0.1:8080")))
  "dGhlIHNhbXBsZSBub25jZQ=="

-- The switching head carries the computed accept key.
#guard (switchingProtocolsHead "dGhlIHNhbXBsZSBub25jZQ==").status == .switchingProtocols
#guard ((switchingProtocolsHead "dGhlIHNhbXBsZSBub25jZQ==").headers.get?
  (Header.Name.ofString! "sec-websocket-accept")).map toString ==
  some "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

private def checkCloseReason (reason expected : String) : IO Unit := do
  let (client, server) ← Std.Http.Internal.Mock.new
  try
    Std.Async.Async.block do
      let upgraded ← Server.Upgraded.ofTransport server ByteArray.empty
      let socket ← WebSocket.ofUpgraded upgraded
      socket.close 1000 reason
      let some bytes ← client.tryRecv?
        | throw (IO.userError "Expected a close frame")
      let .ok (some (frame, consumed)) := Frame.decode? bytes false 125
        | throw (IO.userError "Expected a valid unmasked control frame of at most 125 bytes")
      unless frame.fin && frame.opcode == .close && consumed == bytes.size do
        throw (IO.userError "Expected exactly one complete close frame")
      unless frame.payload.size ≥ 2 &&
          frame.payload[0]! == 0x03 && frame.payload[1]! == 0xE8 do
        throw (IO.userError "Close frame must preserve status code 1000")
      let reasonBytes := frame.payload.extract 2 frame.payload.size
      unless String.fromUTF8? reasonBytes == some expected do
        throw (IO.userError s!"Close reason must be valid UTF-8 and equal {repr expected}")
      socket.close 1000 "second close"
      unless (← client.tryRecv?).isNone do
        throw (IO.userError "Repeated close must not send another frame")
  finally
    client.close

private def testCloseReasons : IO Unit := do
  let ascii (n : Nat) := String.ofList (List.replicate n 'a')
  checkCloseReason "" ""
  checkCloseReason "short reason" "short reason"
  checkCloseReason (ascii 123) (ascii 123)
  checkCloseReason (ascii 124) (ascii 123)
  checkCloseReason (ascii 10000) (ascii 123)
  for char in [Char.ofNat 0xE9, Char.ofNat 0x3042, Char.ofNat 0x1F600] do
    let symbol := String.singleton char
    let width := symbol.toUTF8.size
    checkCloseReason symbol symbol
    let exact := ascii (123 - width) ++ symbol
    checkCloseReason exact exact
    checkCloseReason (exact ++ "x") exact
    for prefixLength in [119:124] do
      let leading := ascii prefixLength
      let expected :=
        if prefixLength + width ≤ 123 then
          leading ++ symbol ++ ascii (123 - prefixLength - width)
        else leading
      checkCloseReason (leading ++ symbol ++ ascii 200) expected
  IO.println "PASS: WebSocket close reasons preserve UTF-8 boundaries and the 125-byte limit"

end WebSocketTests

def main : IO Unit := do
  LifecycleTests.test
  MockExecutorTests.test
  AsyncExecutorTests.test
  TcpBackendTests.test
  FrameAdapterTests.test
  LifecycleUpgradeTests.test
  testCloseReasons
