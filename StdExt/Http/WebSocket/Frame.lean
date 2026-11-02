/-
Extension proposal for `Std.Http`: RFC 6455 WebSocket frame layer.

This layer is sans-I/O: encoding returns bytes, decoding consumes a prefix of a
byte buffer. All protocol invariants that can be checked per frame are checked
here (reserved bits, opcodes, masking direction, control-frame constraints,
minimal length encoding, size limits), so the I/O layer above only wires bytes.
-/

namespace Std.Http.WebSocket

/--
WebSocket frame opcodes (RFC 6455 §5.2).
-/
inductive Opcode where
  /-- Continuation of a fragmented message. -/
  | continuation
  /-- UTF-8 text message. -/
  | text
  /-- Binary message. -/
  | binary
  /-- Connection close control frame. -/
  | close
  /-- Ping control frame. -/
  | ping
  /-- Pong control frame. -/
  | pong
deriving BEq, Repr, Inhabited

namespace Opcode

/--
Returns `true` for control opcodes (close, ping, pong).
-/
def isControl : Opcode → Bool
  | .close | .ping | .pong => true
  | _ => false

/--
The wire value of the opcode.
-/
def toUInt8 : Opcode → UInt8
  | .continuation => 0x0
  | .text => 0x1
  | .binary => 0x2
  | .close => 0x8
  | .ping => 0x9
  | .pong => 0xA

/--
Parses a wire opcode. Reserved opcodes yield `none`.
-/
def ofUInt8? : UInt8 → Option Opcode
  | 0x0 => some .continuation
  | 0x1 => some .text
  | 0x2 => some .binary
  | 0x8 => some .close
  | 0x9 => some .ping
  | 0xA => some .pong
  | _ => none

end Opcode

/--
A single WebSocket frame. Payloads are stored unmasked.
-/
structure Frame where
  /-- Final frame of a message. -/
  fin : Bool := true
  /-- The frame opcode. -/
  opcode : Opcode
  /-- The (unmasked) payload. -/
  payload : ByteArray := ByteArray.empty

/--
Protocol violations detected while decoding or assembling frames
(RFC 6455 §5, §8).
-/
inductive ProtocolError where
  /-- RSV1-3 set without a negotiated extension. -/
  | reservedBitsSet
  /-- Reserved opcode on the wire. -/
  | unknownOpcode (code : UInt8)
  /-- Client-to-server frame without masking (RFC 6455 §5.1). -/
  | unmaskedFrame
  /-- Server-to-client frame with masking (RFC 6455 §5.1). -/
  | maskedFrame
  /-- Fragmented control frame (RFC 6455 §5.5). -/
  | fragmentedControl
  /-- Control frame with payload over 125 bytes (RFC 6455 §5.5). -/
  | controlTooLarge
  /-- Frame or message larger than the configured limit. -/
  | payloadTooLarge (size : Nat)
  /-- Payload length not encoded in the minimal number of bytes. -/
  | nonMinimalLength
  /-- Text message payload is not valid UTF-8 (RFC 6455 §8.1). -/
  | invalidUtf8
  /-- Continuation frame without a message in progress. -/
  | unexpectedContinuation
  /-- New data frame while a fragmented message is in progress. -/
  | expectedContinuation
  /-- Close payload of length 1 or with an invalid close code. -/
  | invalidClosePayload
deriving Repr, BEq

namespace ProtocolError

/--
The close code to send to the peer for this violation.
-/
def closeCode : ProtocolError → UInt16
  | .invalidUtf8 => 1007
  | .payloadTooLarge _ => 1009
  | _ => 1002

/--
Human-readable description for diagnostics.
-/
def message : ProtocolError → String
  | .reservedBitsSet => "reserved bits set"
  | .unknownOpcode code => s!"unknown opcode {code}"
  | .unmaskedFrame => "client frame is not masked"
  | .maskedFrame => "server frame is masked"
  | .fragmentedControl => "fragmented control frame"
  | .controlTooLarge => "control frame payload over 125 bytes"
  | .payloadTooLarge size => s!"payload of {size} bytes exceeds the limit"
  | .nonMinimalLength => "payload length is not minimally encoded"
  | .invalidUtf8 => "text payload is not valid UTF-8"
  | .unexpectedContinuation => "continuation frame without a message in progress"
  | .expectedContinuation => "expected a continuation frame"
  | .invalidClosePayload => "invalid close frame payload"

end ProtocolError

/--
Returns `true` if `code` may appear in a close frame on the wire
(RFC 6455 §7.4, IANA WebSocket Close Code registry).
-/
def validCloseCode (code : UInt16) : Bool :=
  (1000 ≤ code ∧ code ≤ 1003) ∨ (1007 ≤ code ∧ code ≤ 1014) ∨
    (3000 ≤ code ∧ code ≤ 4999)

namespace Frame

/--
Applies the 4-byte XOR mask to a payload (RFC 6455 §5.3). Involutive, so it is
used for both masking and unmasking.
-/
def applyMask (key : ByteArray) (payload : ByteArray) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity payload.size
  for i in [0:payload.size] do
    out := out.push (payload[i]! ^^^ key[i % 4]!)
  return out

/--
Serializes a frame. `maskKey` must be `none` for server-to-client frames and a
4-byte key for client-to-server frames.
-/
def encode (frame : Frame) (maskKey : Option ByteArray := none) : ByteArray := Id.run do
  let len := frame.payload.size
  let mut out := ByteArray.emptyWithCapacity (len + 14)
  let finBit : UInt8 := if frame.fin then 0x80 else 0x00
  out := out.push (finBit ||| frame.opcode.toUInt8)
  let maskBit : UInt8 := if maskKey.isSome then 0x80 else 0x00
  if len ≤ 125 then
    out := out.push (maskBit ||| len.toUInt8)
  else if len < 65536 then
    out := out.push (maskBit ||| 126)
    out := out.push (len >>> 8).toUInt8
    out := out.push len.toUInt8
  else
    out := out.push (maskBit ||| 127)
    for i in [0:8] do
      out := out.push (len.toUInt64 >>> ((7 - i.toUInt64) * 8)).toUInt8
  match maskKey with
  | some key =>
    out := out ++ key ++ applyMask key frame.payload
  | none =>
    out := out ++ frame.payload
  return out

/--
Attempts to decode one frame from the front of `buffer`.

- `requireMask := true` enforces server-side reception (client frames must be
  masked); `false` enforces client-side reception (server frames must not be).
- Returns `none` when more bytes are needed, or `some (frame, consumed)` where
  `consumed` bytes must be dropped from the front of the buffer.
-/
def decode? (buffer : ByteArray) (requireMask : Bool) (maxPayload : Nat) :
    Except ProtocolError (Option (Frame × Nat)) := do
  if buffer.size < 2 then return none
  let b0 := buffer[0]!
  let b1 := buffer[1]!

  if b0 &&& 0x70 != 0 then throw .reservedBitsSet
  let fin := b0 &&& 0x80 != 0
  let some opcode := Opcode.ofUInt8? (b0 &&& 0x0F)
    | throw (.unknownOpcode (b0 &&& 0x0F))

  let masked := b1 &&& 0x80 != 0
  if requireMask ∧ ¬masked then throw .unmaskedFrame
  if ¬requireMask ∧ masked then throw .maskedFrame

  let len7 := (b1 &&& 0x7F).toNat
  if opcode.isControl then
    if ¬fin then throw .fragmentedControl
    if len7 > 125 then throw .controlTooLarge

  let mut offset := 2
  let mut payloadLength := len7
  if len7 == 126 then
    if buffer.size < 4 then return none
    payloadLength := (buffer[2]!.toNat <<< 8) ||| buffer[3]!.toNat
    if payloadLength ≤ 125 then throw .nonMinimalLength
    offset := 4
  else if len7 == 127 then
    if buffer.size < 10 then return none
    let mut length := 0
    for i in [0:8] do
      length := (length <<< 8) ||| buffer[2 + i]!.toNat
    payloadLength := length
    if payloadLength < 65536 then throw .nonMinimalLength
    offset := 10

  if payloadLength > maxPayload then throw (.payloadTooLarge payloadLength)

  let maskSize := if masked then 4 else 0
  let total := offset + maskSize + payloadLength
  if buffer.size < total then return none

  let raw := buffer.extract (offset + maskSize) total
  let payload :=
    if masked then applyMask (buffer.extract offset (offset + 4)) raw
    else raw
  return some ({ fin, opcode, payload }, total)

end Frame

end Std.Http.WebSocket
