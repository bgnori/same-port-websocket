/-
Frame-adapter tests on a real TCP pair: the test acts as a masked WebSocket
client, the `MessageSession` drives the lifecycle session on the server side.

Verifies that the frame layer now produces the model events that tests
previously injected by hand: a peer Close frame feeds `peerClose`, Pings are
answered through the same serialized send path as data (so the Pong cannot
overtake into the post-Close region), and the recorded history replays
through the pure model.
-/
import StdExtTests.TcpBackendTests
import StdExt.Http.WebSocket.FrameAdapter

namespace StdExtTests.FrameAdapterTests

open Std.Async
open Std.Async.TCP
open Std.Http.WebSocket (Frame Opcode)
open Std.Http.WebSocket.Lifecycle
open Std.Http.WebSocket.Lifecycle.AsyncExecutor
open Std.Http.WebSocket.Lifecycle.FrameAdapter
open StdExtTests.TcpBackendTests (expect check socketPair cancellableTcpBackend)

private def limits : Limits := ⟨4, 4096⟩

private def mask : ByteArray := ByteArray.mk #[0x11, 0x22, 0x33, 0x44]

private def closeCode1000 : ByteArray := ByteArray.mk #[0x03, 0xE8]

/-- The session's fixed Close reply frame (code 1000). -/
private def closeReply : ByteArray :=
  Frame.encode { opcode := .close, payload := closeCode1000 }

private def expectOk (what : String) (r : Except Error α) : Async Unit :=
  match r with
  | .ok _ => pure ()
  | .error e => throw (IO.userError s!"{what} failed: {repr e}")

/-- Client-side frame reader (server frames are unmasked). -/
private partial def recvFrame (client : Socket.Client) (buffer : IO.Ref ByteArray) :
    Async Frame := do
  let bytes ← buffer.get
  match Frame.decode? bytes false 4096 with
  | .ok (some (frame, consumed)) =>
    buffer.set (bytes.extract consumed bytes.size)
    return frame
  | .ok none =>
    let some chunk ← client.recv? 4096
      | throw (IO.userError "client: unexpected EOF")
    buffer.modify (· ++ chunk)
    recvFrame client buffer
  | .error e => throw (IO.userError s!"client decode error: {e.message}")

private def echoScenario : IO Unit := do
  Async.block do
    let (accepted, client) ← socketPair
    let session ← Session.new (← cancellableTcpBackend accepted) closeReply limits
    let ms ← MessageSession.new session
    let clientBuffer ← IO.mkRef ByteArray.empty
    -- Text echo.
    client.send (Frame.encode { opcode := .text, payload := "hi".toUTF8 } (some mask))
    let .ok (.message frame) ← ms.nextInbound
      | throw (IO.userError "expected a text message")
    check "text payload" (frame.opcode == .text && frame.payload == "hi".toUTF8)
    discard <| expect "submit echo" (← ms.submitFrame { opcode := .text, payload := frame.payload })
    expectOk "flush echo" (← ms.flushOutbound)
    let echoed ← recvFrame client clientBuffer
    check "echo arrives unmasked" (echoed.opcode == .text && echoed.payload == "hi".toUTF8)
    -- A Ping is answered automatically through the same send path; the data
    -- frame behind it is still delivered.
    client.send (Frame.encode { opcode := .ping, payload := "p".toUTF8 } (some mask))
    client.send (Frame.encode { opcode := .text, payload := "yo".toUTF8 } (some mask))
    let .ok (.message frame2) ← ms.nextInbound
      | throw (IO.userError "expected the data frame after the ping")
    check "data after ping" (frame2.payload == "yo".toUTF8)
    expectOk "flush pong" (← ms.flushOutbound)
    let pong ← recvFrame client clientBuffer
    check "automatic pong" (pong.opcode == .pong && pong.payload == "p".toUTF8)
    -- The peer Close is detected by the frame layer, which feeds `peerClose`.
    client.send (Frame.encode { opcode := .close, payload := closeCode1000 } (some mask))
    let .ok (.closeReceived payload) ← ms.nextInbound
      | throw (IO.userError "expected the close notification")
    check "close payload" (payload == closeCode1000)
    expectOk "flush close reply" (← ms.flushOutbound)
    let closeFrame ← recvFrame client clientBuffer
    check "close reply" (closeFrame.opcode == .close && closeFrame.payload == closeCode1000)
    -- Half-close, peer EOF, teardown.
    let kind ← expect "runControl" (← session.runControl)
    check "half-close control" (kind == .finishSend)
    check "peer sees EOF" ((← client.recv? 4096) == none)
    client.shutdown
    let .ok .ended ← ms.nextInbound
      | throw (IO.userError "expected the inbound end")
    discard <| expect "backendEnded" (← session.backendEnded)
    discard <| expect "release" (← session.release)
    let final ← session.model
    check "released" final.released
    check "history replays"
      (match Session.replay limits (← session.history) with
        | .ok replayed => replayed == final
        | .error _ => false)

def test : IO Unit := do
  echoScenario
  IO.println "PASS: frame adapter echo, auto-pong and close handshake on real TCP replay through the model"

end StdExtTests.FrameAdapterTests
