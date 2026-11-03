/-
Frame-layer adapter for the lifecycle session (stage C: readイベント分化と
フレーム解析・配送の接続, docs/std-websocket/websocket-prototype-results.md §4).

Connects the sans-I/O frame layer (`Frame.decode?`/`Frame.encode`) to an
`AsyncExecutor.Session`:
- inbound bytes delivered by reads are assembled into frames; data messages go
  to the application, a peer Close feeds `peerClose` to the model (previously
  tests injected it by hand), and Pings are answered automatically **through
  the same serialized send path** as application data, so the Close-ordering
  contract (D3) covers control replies too;
- outbound frames are submitted as encoded bytes, so frame bytes never
  interleave and the model's capacity limits count real wire bytes.

Scope (documented limitations of this slice):
- single-frame messages only; fragmented data messages are reported as
  unsupported instead of being silently mis-handled;
- the Close reply payload is the session's fixed `closeFrame`, not an echo of
  the peer's close code;
- Pong payload tracking (matching a Pong to a Ping) is not implemented;
  unsolicited Pongs are ignored as RFC 6455 permits.
-/
import StdExt.Http.WebSocket.AsyncExecutor
import StdExt.Http.WebSocket.Frame

namespace Std.Http.WebSocket.Lifecycle.FrameAdapter

open Std.Async
open Std.Http.WebSocket (Frame Opcode ProtocolError)
open Std.Http.WebSocket.Lifecycle.AsyncExecutor

/-- What the inbound pump hands to the application. -/
inductive Inbound where
  /-- A complete single-frame data message. -/
  | message (frame : Frame)
  /-- The peer sent a Close frame. `peerClose` has been fed to the session;
  the Close reply still needs `flushOutbound`. -/
  | closeReceived (payload : ByteArray)
  /-- The inbound direction ended without a Close exchange, or the read was
  cancelled/failed; the session records the distinction in its history. -/
  | ended
  /-- A protocol violation detected by the frame layer. -/
  | violation (error : ProtocolError)

/-- A session plus the inbound reassembly buffer. -/
structure MessageSession where
  session : Session
  /-- Maximum frame payload accepted from the peer. -/
  maxPayload : Nat
  private buffer : IO.Ref ByteArray

def MessageSession.new (session : Session) (maxPayload : Nat := 1 <<< 20) :
    BaseIO MessageSession := do
  return { session, maxPayload, buffer := ← IO.mkRef ByteArray.empty }

namespace MessageSession

/-- Submits one outbound frame through the session's serialized send path. -/
def submitFrame (ms : MessageSession) (frame : Frame) : Async (Except Error Nat) :=
  ms.session.submit (frame.encode)

/--
Dispatches and awaits outbound writes until the session has nothing ready:
queued data frames and, once acceptance is revoked, the Close frame. A
dispatch refusal means there is nothing (more) to send; a write failure is
returned, never converted to success.
-/
partial def flushOutbound (ms : MessageSession) : Async (Except Error Unit) := do
  match ← ms.session.dispatch with
  | .error _ => return .ok ()
  | .ok _ =>
    match ← ms.session.awaitWrite with
    | .error e => return .error e
    | .ok _ => ms.flushOutbound

/--
Pumps inbound bytes until one application-relevant event is available.
Control frames are handled internally: a Ping submits its Pong onto the same
send queue (call `flushOutbound` afterwards), a Close feeds `peerClose` to the
session.
-/
partial def nextInbound (ms : MessageSession) : Async (Except Error Inbound) := do
  let buffer ← ms.buffer.get
  match Frame.decode? buffer true ms.maxPayload with
  | .error e => return .ok (.violation e)
  | .ok (some (frame, consumed)) =>
    ms.buffer.set (buffer.extract consumed buffer.size)
    match frame.opcode with
    | .text | .binary =>
      if !frame.fin then
        throw (IO.userError "fragmented messages are not supported in this slice")
      return .ok (.message frame)
    | .continuation => return .ok (.violation .unexpectedContinuation)
    | .ping =>
      -- The automatic Pong joins the same serialized outbound queue, then is
      -- flushed so the control reply is sent promptly rather than waiting for
      -- the next application frame.
      match ← ms.submitFrame { opcode := .pong, payload := frame.payload } with
      | .error e => return .error e
      | .ok _ =>
        match ← ms.flushOutbound with
        | .error e => return .error e
        | .ok _ => ms.nextInbound
    | .pong => ms.nextInbound
    | .close =>
      match ← ms.session.peerClosed with
      | .error e => return .error e
      | .ok _ => return .ok (.closeReceived frame.payload)
  | .ok none =>
    match ← ms.session.beginRead with
    | .error e => return .error e
    | .ok _ =>
      match ← ms.session.awaitRead with
      | .error e => return .error e
      | .ok (some bytes) =>
        ms.buffer.modify (· ++ bytes)
        ms.nextInbound
      | .ok none => return .ok .ended

end MessageSession

end Std.Http.WebSocket.Lifecycle.FrameAdapter
