/-
Extension proposal for `Std.Http`: message-level WebSocket connection API.

Sits on top of `Std.Http.Server.Upgraded` (the transport-agnostic byte stream
produced by the upgrade handoff) and the sans-I/O frame layer. Handles
fragmentation, automatic Ping→Pong replies, the closing handshake, and UTF-8
validation of text messages.

Concurrency contract:
- `recv` must be driven by a single task.
- Each `send*` call writes one complete frame with a single transport write, so
  concurrent senders cannot interleave frame bytes (ordering between
  independent messages is still unspecified).
-/
import StdExt.Http.Server.Upgrade
import StdExt.Http.WebSocket.Frame

namespace Std.Http.WebSocket

open Std.Async

/--
A complete data message.
-/
inductive Message where
  /-- A UTF-8 text message. -/
  | text (content : String)
  /-- A binary message. -/
  | binary (content : ByteArray)
deriving Inhabited

/--
Close code and reason received from or sent to the peer.
-/
structure CloseInfo where
  /-- The close code (RFC 6455 §7.4). -/
  code : UInt16 := 1000
  /-- The optional UTF-8 close reason. -/
  reason : String := ""
deriving Repr, BEq, Inhabited

/--
Limits and tuning for a WebSocket connection.
-/
structure Config where
  /-- Maximum payload bytes of a single frame. -/
  maxFrameBytes : Nat := 1 <<< 20
  /-- Maximum total payload bytes of a (possibly fragmented) message. -/
  maxMessageBytes : Nat := 1 <<< 20
  /-- Read size hint for the underlying transport. -/
  recvChunkBytes : UInt64 := 16384

/--
Receive-side state. Mutated only by the single `recv` consumer.
-/
private structure RecvState where
  buffer : ByteArray := ByteArray.empty
  fragments : ByteArray := ByteArray.empty
  fragmentOpcode : Option Opcode := none
  peerClose : Option CloseInfo := none
  finished : Bool := false

/--
A server-side WebSocket connection.
-/
structure WebSocket where
  private mk ::
  private io : Server.Upgraded
  /-- The connection limits. -/
  config : Config
  private recvState : IO.Ref RecvState
  private closeSent : IO.Ref Bool

namespace WebSocket

/--
Wraps an upgraded byte stream into a WebSocket connection.
-/
def ofUpgraded (io : Server.Upgraded) (config : Config := {}) : BaseIO WebSocket := do
  return { io, config, recvState := ← IO.mkRef {}, closeSent := ← IO.mkRef false }

/--
Encodes a close frame payload, truncating the reason to fit the 125-byte
control frame limit at a UTF-8 boundary.
-/
private def closeFrame (code : UInt16) (reason : String) : Frame := Id.run do
  let mut payload := ByteArray.empty
  payload := payload.push (code >>> 8).toUInt8
  payload := payload.push code.toUInt8
  let reasonBytes := reason.toUTF8
  let mut endPos := min reasonBytes.size 123
  if endPos < reasonBytes.size then
    -- If the first excluded byte is a continuation, exclude its whole character.
    while endPos > 0 ∧ reasonBytes[endPos]! &&& 0xC0 == 0x80 do
      endPos := endPos - 1
  return { opcode := .close, payload := payload ++ reasonBytes.extract 0 endPos }

/--
Sends a close frame once; later send attempts are rejected.
-/
private def sendCloseOnce (self : WebSocket) (code : UInt16) (reason : String) :
    Async Unit := do
  let alreadySent ← self.closeSent.modifyGet fun sent => (sent, true)
  unless alreadySent do
    self.io.send ((closeFrame code reason).encode)

/--
Marks the connection finished, notifies the peer, and raises the violation.
-/
private def failProtocol (self : WebSocket) (error : ProtocolError) : Async α := do
  self.recvState.modify ({ · with finished := true })
  try sendCloseOnce self error.closeCode error.message
  catch _ => pure ()
  throw (IO.userError s!"WebSocket protocol error: {error.message}")

/--
Validates and records an incoming close frame, echoing the close handshake.
-/
private def handleClose (self : WebSocket) (payload : ByteArray) : Async Unit := do
  let info : CloseInfo ←
    if payload.size == 0 then
      pure {}
    else if payload.size == 1 then
      failProtocol self .invalidClosePayload
    else
      let code := (payload[0]!.toUInt16 <<< 8) ||| payload[1]!.toUInt16
      if ¬validCloseCode code then
        failProtocol self .invalidClosePayload
      else
        match String.fromUTF8? (payload.extract 2 payload.size) with
        | none => failProtocol self .invalidUtf8
        | some reason => pure { code, reason }
  self.recvState.modify fun s => { s with finished := true, peerClose := some info }
  try sendCloseOnce self info.code ""
  catch _ => pure ()

/--
Receives the next data message.

Control frames are handled internally: pings are answered automatically, and a
close frame completes the closing handshake. Returns `none` once the
connection is closed (cleanly or by EOF). Throws on protocol violations after
notifying the peer with the appropriate close code.
-/
def recv (self : WebSocket) : Async (Option Message) := do
  let mut result : Option Message := none
  let mut running := true
  while running do
    let st ← self.recvState.get
    if st.finished then
      running := false
    else
      match Frame.decode? st.buffer true self.config.maxFrameBytes with
      | .error error =>
        failProtocol self error
      | .ok none =>
        match ← self.io.recv self.config.recvChunkBytes with
        | some bytes =>
          self.recvState.modify fun s => { s with buffer := s.buffer ++ bytes }
        | none =>
          -- EOF without a closing handshake (abnormal closure, virtual 1006).
          self.recvState.modify ({ · with finished := true })
          running := false
      | .ok (some (frame, consumed)) =>
        self.recvState.modify fun s =>
          { s with buffer := s.buffer.extract consumed s.buffer.size }
        match frame.opcode with
        | .ping =>
          unless ← self.closeSent.get do
            self.io.send (Frame.encode { opcode := .pong, payload := frame.payload })
        | .pong => pure ()
        | .close =>
          handleClose self frame.payload
          running := false
        | .continuation =>
          match st.fragmentOpcode with
          | none => failProtocol self .unexpectedContinuation
          | some opcode =>
            let assembled := st.fragments ++ frame.payload
            if assembled.size > self.config.maxMessageBytes then
              failProtocol self (.payloadTooLarge assembled.size)
            else if frame.fin then
              self.recvState.modify fun s =>
                { s with fragments := ByteArray.empty, fragmentOpcode := none }
              if opcode == .text then
                match String.fromUTF8? assembled with
                | none => failProtocol self .invalidUtf8
                | some content =>
                  result := some (.text content)
                  running := false
              else
                result := some (.binary assembled)
                running := false
            else
              self.recvState.modify fun s => { s with fragments := assembled }
        | opcode =>
          -- .text or .binary
          if st.fragmentOpcode.isSome then
            failProtocol self .expectedContinuation
          else if frame.payload.size > self.config.maxMessageBytes then
            failProtocol self (.payloadTooLarge frame.payload.size)
          else if frame.fin then
            if opcode == .text then
              match String.fromUTF8? frame.payload with
              | none => failProtocol self .invalidUtf8
              | some content =>
                result := some (.text content)
                running := false
            else
              result := some (.binary frame.payload)
              running := false
          else
            self.recvState.modify fun s =>
              { s with fragmentOpcode := some opcode, fragments := frame.payload }
  return result

/--
The close information received from the peer, if the peer initiated or
completed the closing handshake.
-/
def peerClose? (self : WebSocket) : BaseIO (Option CloseInfo) :=
  return (← self.recvState.get).peerClose

/--
Sends a single-frame data message. Throws if the closing handshake started.
-/
private def sendDataFrame (self : WebSocket) (opcode : Opcode) (payload : ByteArray) :
    Async Unit := do
  if ← self.closeSent.get then
    throw (IO.userError "WebSocket is closing")
  self.io.send (Frame.encode { opcode, payload })

/--
Sends a data message.
-/
def send (self : WebSocket) (message : Message) : Async Unit :=
  match message with
  | .text content => sendDataFrame self .text content.toUTF8
  | .binary content => sendDataFrame self .binary content

/--
Sends a text message.
-/
def sendText (self : WebSocket) (content : String) : Async Unit :=
  sendDataFrame self .text content.toUTF8

/--
Sends a binary message.
-/
def sendBinary (self : WebSocket) (content : ByteArray) : Async Unit :=
  sendDataFrame self .binary content

/--
Sends a ping. The payload must be at most 125 bytes.
-/
def ping (self : WebSocket) (payload : ByteArray := ByteArray.empty) : Async Unit := do
  if payload.size > 125 then
    throw (IO.userError "ping payload over 125 bytes")
  if ← self.closeSent.get then
    throw (IO.userError "WebSocket is closing")
  self.io.send (Frame.encode { opcode := .ping, payload })

/--
Starts the closing handshake. To complete it cleanly, keep calling `recv`
until it returns `none` (the peer's close echo); the server tears the
connection down when the upgrade continuation returns either way.
-/
def close (self : WebSocket) (code : UInt16 := 1000) (reason : String := "") :
    Async Unit :=
  sendCloseOnce self code reason

end WebSocket

end Std.Http.WebSocket
