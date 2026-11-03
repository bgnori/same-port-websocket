/-
Real-TCP capability probes for the lifecycle session (stage C, D1/D5).

These tests answer the question recorded in
docs/std-websocket/websocket-async-executor-results.md §6: how pending recvs
behave on the actual Lean Std TCP/libuv backend, and whether the session keeps
its retention obligation when nothing can force them to complete.

Probes:
1. A peer write half-close (`shutdown`) resolves a pending recv as EOF, while
   the opposite direction keeps working — the graceful path needs no special
   interruption capability as long as the peer cooperates.
2. The sanctioned cancellation route (selector unregister → `cancelRecv`)
   abandons a pending read wait without losing the socket: data sent later is
   still received by a fresh recv.
3. Std TCP exposes no abort for a pending plain recv or an in-flight write.
   The backend reports this honestly (`abort` fails instead of pretending),
   release stays refused while the read is outstanding, and only a real peer
   EOF resolves it — the retention obligation under a silent peer.
4. The full graceful close runs on a real TCP socket pair and its history
   replays through the pure model.
-/
import StdExt.Http.WebSocket.AsyncExecutor

namespace StdExtTests.TcpBackendTests

open Std.Async
open Std.Async.TCP
open Std.Net
open Std.Http.WebSocket.Lifecycle
open Std.Http.WebSocket.Lifecycle.AsyncExecutor

private def limits : Limits := ⟨2, 8⟩

def expect (what : String) (r : Except Error α) : Async α :=
  match r with
  | .ok a => pure a
  | .error e => throw (IO.userError s!"{what} failed: {repr e}")

def expectError (what : String) (r : Except Error α) (expected : Error) :
    Async Unit :=
  match r with
  | .error e =>
    unless e == expected do
      throw (IO.userError s!"{what}: expected {repr expected}, got {repr e}")
  | .ok _ => throw (IO.userError s!"{what}: expected {repr expected}, got success")

def check (what : String) (cond : Bool) : Async Unit := do
  unless cond do throw (IO.userError s!"check failed: {what}")

/-- Connects a loopback socket pair on an ephemeral port. -/
def socketPair : Async (Socket.Client × Socket.Client) := do
  let server ← Socket.Server.mk
  server.bind (.v4 ⟨IPv4Addr.ofParts 127 0 0 1, 0⟩)
  server.listen 8
  let addr ← server.getSockName
  let pending ← server.accept.async
  let client ← Socket.Client.mk
  client.connect addr
  let accepted ← EAsync.await pending
  return (accepted, client)

/--
The real Std TCP capabilities (D5): writes complete through the libuv promise,
`shutdown` half-closes the send direction, and there is no exposed way to
abort a pending plain recv or an in-flight write — so `abort` reports the
incapacity instead of faking success.
-/
def tcpBackend (sock : Socket.Client) : Backend where
  write bytes := sock.send bytes
  read n := sock.recv? n
  finishSend := sock.shutdown
  abort := throw (IO.userError "Std TCP exposes no abort for pending I/O")

/--
A TCP backend whose reads go through the selector route, which probe 2 showed
to be abandonable. `abort` closes a cancel channel; the losing recv selector
is unregistered (`cancelRecv`), so a pending read resolves promptly without
peer cooperation. The read buffer is only released after the race resolves —
cancellation completes the operation, it does not free retained resources
while the backend still holds them.
-/
def cancellableTcpBackend (sock : Socket.Client) : IO Backend := do
  let cancel ← Std.CloseableChannel.new (α := Unit)
  return {
    write := fun bytes => sock.send bytes
    read := fun n =>
      Selectable.one #[
        .case (sock.recvSelector n) pure,
        .case cancel.recvSelector
          (fun _ => throw (IO.userError "read abandoned by abort"))]
    finishSend := sock.shutdown
    abort := do
      if !(← cancel.isClosed) then cancel.close
  }

/-- Probe 1: peer half-close resolves a pending recv as EOF (and only that
direction). -/
private def probePeerEof : IO Unit := do
  Async.block do
    let (accepted, client) ← socketPair
    let pending ← (accepted.recv? 4096).async
    client.shutdown
    let data ← EAsync.await pending
    check "pending recv resolves as EOF on peer shutdown" data.isNone
    -- shutdown is a write half-close: the reverse direction still works.
    accepted.send "late".toUTF8
    let got ← client.recv? 4096
    check "half-closed peer still receives" (got == some "late".toUTF8)

/-- Probe 2: abandoning a read wait through the selector route keeps the
socket usable. -/
private def probeSelectorCancel : IO Unit := do
  Async.block do
    let (accepted, client) ← socketPair
    let sleepSelector ← Selector.sleep 50
    let winner ← Selectable.one #[
      .case (accepted.recvSelector 4096) (fun _ => pure "data"),
      .case sleepSelector (fun _ => pure "timeout")]
    check "silent socket loses the race" (winner == "timeout")
    -- The unregister path ran cancelRecv; the socket must remain usable.
    client.send "later".toUTF8
    let got ← accepted.recv? 4096
    check "cancelled read wait does not break the socket"
      (got == some "later".toUTF8)

/-- Probe 3: with a silent peer, nothing can force the pending recv; the
session keeps the retention obligation until a real EOF. -/
private def probeSilentPeerRetention : IO Unit := do
  Async.block do
    let (accepted, client) ← socketPair
    let session ← Session.new (tcpBackend accepted) "CLOSE".toUTF8 limits
    discard <| expect "beginRead" (← session.beginRead)
    discard <| expect "submit" (← session.submit "abc".toUTF8)
    discard <| expect "deadline" (← session.deadline)
    -- The abort capability is missing and must fail, not fake completion.
    let kind ← expect "runControl" (← session.runControl)
    check "abort control attempted" (kind == .abort)
    -- The read is still outstanding: release must stay refused.
    expectError "release under silent peer" (← session.release) .busy
    -- Only the peer resolves the read on this backend.
    client.shutdown
    let data ← expect "awaitRead" (← session.awaitRead)
    check "read resolved only by peer EOF" data.isNone
    discard <| expect "backendEnded" (← session.backendEnded)
    discard <| expect "release" (← session.release)
    let final ← session.model
    check "cancelled request settled" (final.results == [(1, .cancelled)])
    check "history replays"
      (match Session.replay limits (← session.history) with
        | .ok replayed => replayed == final
        | .error _ => false)

/-- Probe 4: the graceful close runs end to end on a real TCP pair. -/
private def probeGraceful : IO Unit := do
  Async.block do
    let (accepted, client) ← socketPair
    let session ← Session.new (tcpBackend accepted) "CLOSE".toUTF8 limits
    discard <| expect "beginRead" (← session.beginRead)
    discard <| expect "submit abc" (← session.submit "abc".toUTF8)
    discard <| expect "submit defg" (← session.submit "defg".toUTF8)
    discard <| expect "requestClose" (← session.requestClose)
    for payload in ["abc", "defg", "CLOSE"] do
      discard <| expect s!"dispatch {payload}" (← session.dispatch)
      let outcome ← expect s!"awaitWrite {payload}" (← session.awaitWrite)
      check s!"{payload} written" (outcome == .written)
    -- TCP may segment arbitrarily; compare the accumulated stream.
    let expected := "abcdefgCLOSE".toUTF8
    let mut received := ByteArray.empty
    while received.size < expected.size do
      let some chunk ← client.recv? 4096
        | throw (IO.userError "peer saw EOF before all frames arrived")
      received := received ++ chunk
    check "stream serialization preserved" (received == expected)
    discard <| expect "peerClosed" (← session.peerClosed)
    let kind ← expect "runControl" (← session.runControl)
    check "half-close control" (kind == .finishSend)
    check "peer sees EOF after half-close" ((← client.recv? 4096) == none)
    client.shutdown
    let data ← expect "awaitRead" (← session.awaitRead)
    check "read EOF" data.isNone
    discard <| expect "backendEnded" (← session.backendEnded)
    discard <| expect "release" (← session.release)
    let final ← session.model
    check "results written in order"
      (final.results == [(1, .written), (2, .written)])
    check "history replays"
      (match Session.replay limits (← session.history) with
        | .ok replayed => replayed == final
        | .error _ => false)

/-- Probe 5: with the selector-based read, abort recovers the pending read
promptly without any peer cooperation, so the session reaches quiet and
releases in bounded time — busy does not persist. -/
private def probeAbortRecoversRead : IO Unit := do
  Async.block do
    let (accepted, _client) ← socketPair
    let session ← Session.new (← cancellableTcpBackend accepted) "CLOSE".toUTF8 limits
    discard <| expect "beginRead" (← session.beginRead)
    discard <| expect "submit" (← session.submit "abc".toUTF8)
    discard <| expect "deadline" (← session.deadline)
    -- The abort capability now exists: it abandons the read wait.
    let kind ← expect "runControl" (← session.runControl)
    check "abort control" (kind == .abort)
    -- The read resolves through our own action; the silent peer is not needed.
    let data ← expect "awaitRead" (← session.awaitRead)
    check "read recovered by abort" data.isNone
    discard <| expect "backendEnded" (← session.backendEnded)
    discard <| expect "release" (← session.release)
    let final ← session.model
    check "cancelled request settled" (final.results == [(1, .cancelled)])
    check "history replays"
      (match Session.replay limits (← session.history) with
        | .ok replayed => replayed == final
        | .error _ => false)

def test : IO Unit := do
  probePeerEof
  probeSelectorCancel
  probeSilentPeerRetention
  probeGraceful
  probeAbortRecoversRead
  IO.println "PASS: TCP capability probes (EOF, selector cancel, retention under silence, graceful, abort recovery)"

end StdExtTests.TcpBackendTests
