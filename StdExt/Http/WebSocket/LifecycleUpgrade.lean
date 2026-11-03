/-
Connection-loop integration (stage C): run the lifecycle `Session` + frame
adapter as an upgrade continuation, so the model drives a real
`serveUpgradable` WebSocket connection
(docs/std-websocket/websocket-prototype-results.md §5, checklist item
"HTTP/1 backendへ接続する").

Termination-contract finding (recorded in
docs/std-websocket/websocket-async-executor-results.md):
`Server.Upgraded` is transport-agnostic and exposes only `recv`/`send`; it has
no half-close and no read cancellation (the socket is never handed to the
continuation — Cowboy-style, the server owns teardown via `Transport.close`).
So the backend built from an `Upgraded` cannot offer the same abort capability
that a raw `Socket.Client` does (see TcpBackendTests). This is honest, not a
fallback that fakes a capability:

- `finishSend` represents the owner-level commitment "no further frames will be
  sent". The model already enforces it (the Close frame is written and nothing
  more is dispatched); the wire-level FIN is emitted by the server's
  `Transport.close` when the continuation returns. So it completes as written —
  the owner guarantee holds, only the mechanism is deferred to server teardown.
- `abort` (forcing a pending recv to complete) is a capability the owner does
  not have over `Upgraded`; it is reported as failed, never faked. A silent
  peer's pending recv is resolved by peer EOF or by the server closing the
  transport on shutdown, exactly as the TCP probes recorded.
-/
import StdExt.Http.WebSocket.FrameAdapter
import StdExt.Http.WebSocket
import StdExt.Http.WebSocket.Frame

namespace Std.Http.WebSocket.Lifecycle.Upgrade

open Std.Async
open Std.Http.Server (Upgraded UpgradableResponse)
open Std.Http.WebSocket (Frame Opcode checkHandshake switchingProtocolsHead
  HandshakeError UpgradeOptions)
open Std.Http.WebSocket.Lifecycle.AsyncExecutor
open Std.Http.WebSocket.Lifecycle.FrameAdapter

/--
A `Backend` over the transport-agnostic `Upgraded` stream. See the module
comment for why `finishSend`/`abort` differ from a raw TCP backend.
-/
def upgradedBackend (io : Upgraded) (recvChunk : UInt64 := 16384) : Backend where
  write bytes := io.send bytes
  read _ := io.recv recvChunk
  -- Owner-level send quiescence; wire FIN deferred to server `Transport.close`.
  finishSend := pure ()
  -- No read cancellation through `Upgraded`; reported as failed, not faked.
  abort := throw (IO.userError "Upgraded exposes no read cancellation")

/-- The fixed Close reply frame (code 1000) the owner sends. -/
private def closeReplyFrame : ByteArray :=
  Frame.encode { opcode := .close, payload := ByteArray.mk #[0x03, 0xE8] }

/--
Drives one upgraded connection with the lifecycle model: echoes data messages,
answers Pings automatically (via the frame adapter's shared send path), replies
to a peer Close, and tears the session down through the model. Protocol
violations end the connection. Returns once the session is released or the
inbound direction ended.
-/
partial def echoOwner (ms : MessageSession) : Async Unit := do
  let rec loop : Async Unit := do
    match ← ms.nextInbound with
    | .ok (.message frame) =>
      match ← ms.submitFrame { opcode := frame.opcode, payload := frame.payload } with
      | .error _ => teardown
      | .ok _ =>
        match ← ms.flushOutbound with
        | .error _ => teardown
        | .ok _ => loop
    | .ok (.closeReceived _) =>
      -- peerClose has been fed; send our Close reply, then quiesce.
      discard <| ms.flushOutbound
      teardown
    | .ok .ended => teardown
    | .ok (.violation _) => teardown
    | .error _ => teardown
  loop
where
  /-- Finish the send side, drain the inbound direction, and release. -/
  teardown : Async Unit := do
    -- Complete any reserved control (finishSend after the Close exchange).
    discard <| ms.session.runControl
    -- Drain inbound until EOF so the backend end is observed.
    let rec drain : Async Unit := do
      match ← ms.nextInbound with
      | .ok .ended => pure ()
      | .ok _ => drain
      | .error _ => pure ()
    drain
    discard <| ms.session.backendEnded
    discard <| ms.session.release

/--
WebSocket upgrade entry point backed by the lifecycle model, mirroring
`WebSocket.upgrade`. On a valid handshake the server writes `101 Switching
Protocols` and runs `owner` with a `MessageSession`; on an invalid handshake it
answers with the appropriate HTTP error.
-/
def upgrade (request : Request.Head)
    (owner : MessageSession → Async Unit := echoOwner)
    (options : UpgradeOptions := {}) :
    Async (UpgradableResponse Body.Any) := do
  match checkHandshake request options.checkOrigin with
  | .error error => return .normal (← error.response)
  | .ok key =>
    let fallback ← (HandshakeError.invalidKey).response
    return .upgrade (switchingProtocolsHead key) fallback fun io => do
      let session ← Session.new (upgradedBackend io) closeReplyFrame
        ⟨options.config.maxMessageBytes, options.config.maxMessageBytes⟩
      let ms ← MessageSession.new session options.config.maxFrameBytes
      owner ms

end Std.Http.WebSocket.Lifecycle.Upgrade
