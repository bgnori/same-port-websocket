/-
End-to-end connection-loop test (stage C): run a real `serveUpgradable` server
whose WebSocket endpoint is driven by the lifecycle model
(`Lifecycle.Upgrade.upgrade`), connect a real TCP client that performs the
RFC 6455 opening handshake, exchange frames, and close.

This exercises the model-backed owner loop under the actual connection loop and
confirms the termination contract is shared with plain HTTP: the server owns
`Transport.close` on both paths; the WebSocket continuation needs nothing
special from it. A plain HTTP request on the same server is checked too.
-/
import StdExtTests.TcpBackendTests
import StdExt.Http.WebSocket.LifecycleUpgrade

namespace StdExtTests.LifecycleUpgradeTests

open Std.Async
open Std.Async.TCP
open Std.Net
open Std.Http
open Std.Http.Server
open Std.Http.WebSocket (Frame Opcode)
open Std.Http.WebSocket.Lifecycle.FrameAdapter
open Std.Http.WebSocket.Lifecycle.Upgrade
open StdExtTests.TcpBackendTests (check)

/-- Minimal upgrade-capable handler: WS path uses the lifecycle echo owner,
everything else is a plain 200 text response (same server, same teardown). -/
structure EchoHandler where

private def plainOk : Async (Response Body.Any) := do
  let body ← Body.Full.ofString "plain\n"
  return ((Response.new.status .ok |>.header! "Content-Type" "text/plain"
    |>.body body : Response Body.Full) : Response Body.Any)

instance : UpgradableHandler EchoHandler where
  ResponseBody := Body.Any
  onRequest _ request := do
    if toString request.line.uri.path == "/ws/socket" then
      Std.Http.WebSocket.Lifecycle.Upgrade.upgrade request.line
    else
      .normal <$> plainOk
  onFailure _ _ := pure ()

private def mask : ByteArray := ByteArray.mk #[0x37, 0xFA, 0x21, 0x3D]

private def handshakeRequest : ByteArray :=
  ("GET /ws/socket HTTP/1.1\r\n" ++
   "Host: 127.0.0.1\r\n" ++
   "Upgrade: websocket\r\n" ++
   "Connection: Upgrade\r\n" ++
   "Sec-WebSocket-Version: 13\r\n" ++
   "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n").toUTF8

/-- Reads from the client until the HTTP header terminator, returning the head
and any leftover bytes. -/
private partial def readHead (client : Socket.Client) (acc : ByteArray) :
    Async (String × ByteArray) := do
  let text := String.fromUTF8! acc
  match (text.splitOn "\r\n\r\n") with
  | head :: _rest :: _ =>
    let headLen := head.toUTF8.size + 4
    return (head, acc.extract headLen acc.size)
  | _ =>
    let some chunk ← client.recv? 4096
      | throw (IO.userError "client: EOF during handshake")
    readHead client (acc ++ chunk)

/-- Reads one frame from the client, buffering across recvs. -/
private partial def readFrame (client : Socket.Client) (buffer : IO.Ref ByteArray) :
    Async Frame := do
  let bytes ← buffer.get
  match Frame.decode? bytes false 65536 with
  | .ok (some (frame, consumed)) =>
    buffer.set (bytes.extract consumed bytes.size)
    return frame
  | .ok none =>
    let some chunk ← client.recv? 4096
      | throw (IO.userError "client: EOF while reading a frame")
    buffer.modify (· ++ chunk)
    readFrame client buffer
  | .error e => throw (IO.userError s!"client decode: {e.message}")

private def scenario : IO Unit := do
  Async.block do
    let server ← serveUpgradable (.v4 ⟨IPv4Addr.ofParts 127 0 0 1, 0⟩) EchoHandler.mk
    let some (addr : SocketAddress) := server.localAddr
      | throw (IO.userError "server has no local address")
    try
      -- Plain HTTP on the same server.
      let http ← Socket.Client.mk
      http.connect addr
      http.send ("GET /plain HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").toUTF8
      let (head, _) ← readHead http ByteArray.empty
      check "plain HTTP responds" ((head.splitOn "200").length > 1)
      http.shutdown
      -- WebSocket handshake + echo + close on the same server.
      let client ← Socket.Client.mk
      client.connect addr
      client.send handshakeRequest
      let (head, leftover) ← readHead client ByteArray.empty
      check "handshake 101" ((head.splitOn "101").length > 1)
      check "accept header present"
        ((head.toLower.splitOn "sec-websocket-accept").length > 1)
      let buffer ← IO.mkRef leftover
      -- Echo a text message.
      client.send (Frame.encode { opcode := .text, payload := "ping".toUTF8 } (some mask))
      let echoed ← readFrame client buffer
      check "echo payload" (echoed.opcode == .text && echoed.payload == "ping".toUTF8)
      -- Automatic Pong for a Ping.
      client.send (Frame.encode { opcode := .ping, payload := "x".toUTF8 } (some mask))
      let pong ← readFrame client buffer
      check "auto pong" (pong.opcode == .pong && pong.payload == "x".toUTF8)
      -- Close handshake.
      client.send (Frame.encode { opcode := .close, payload := ByteArray.mk #[0x03, 0xE8] } (some mask))
      let closed ← readFrame client buffer
      check "close reply" (closed.opcode == .close)
      client.shutdown
    finally
      server.shutdown
      server.waitShutdown

def test : IO Unit := do
  scenario
  IO.println "PASS: lifecycle-backed WebSocket upgrade over a real serveUpgradable server"

end StdExtTests.LifecycleUpgradeTests
