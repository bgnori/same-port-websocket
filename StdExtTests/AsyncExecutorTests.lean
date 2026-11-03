/-
Stage-C first slice tests: run the lifecycle model against the real
`Std.Async` runtime and the `Std.Http.Internal.Mock` transport (the backend
candidate named in websocket-prototype-results.md §5, 段階C).

Each scenario drives a `Session`, then replays the recorded model event
history through the pure `Lifecycle.step` and checks it reproduces the final
model state — the executor-history-to-model correspondence on a real backend.
-/
import StdExt.Http.WebSocket.AsyncExecutor

namespace StdExtTests.AsyncExecutorTests

open Std.Async
open Std.Http.Internal
open Std.Http.WebSocket.Lifecycle
open Std.Http.WebSocket.Lifecycle.AsyncExecutor

private def limits : Limits := ⟨2, 8⟩

private def closeBytes : ByteArray := "CLOSE".toUTF8

private def closeChan (chan : Std.CloseableChannel ByteArray) : IO Unit := do
  if !(← chan.isClosed) then chan.close

/--
The mock transport's real capabilities, with no success-shaped fallbacks:
writes complete through the channel send task (and fail on a closed channel),
`finishSend` half-closes the server-to-client direction, and `abort` closes
both directions, which resolves pending reads — the strongest interruption
this backend actually offers.
-/
private def mockBackend (server : Mock.Server) : Backend where
  write bytes := server.send bytes
  read n := server.recv? (some n)
  finishSend := closeChan (Mock.Server.getSendChan server)
  abort := do
    closeChan (Mock.Server.getSendChan server)
    closeChan (Mock.Server.getRecvChan server)

private def expect (what : String) (r : Except Error α) : Async α :=
  match r with
  | .ok a => pure a
  | .error e => throw (IO.userError s!"{what} failed: {repr e}")

private def expectError (what : String) (r : Except Error α) (expected : Error) :
    Async Unit :=
  match r with
  | .error e =>
    unless e == expected do
      throw (IO.userError s!"{what}: expected {repr expected}, got {repr e}")
  | .ok _ => throw (IO.userError s!"{what}: expected {repr expected}, got success")

private def check (what : String) (cond : Bool) : Async Unit := do
  unless cond do throw (IO.userError s!"check failed: {what}")

/-- The recorded history must replay through the pure model to the final state. -/
private def checkReplay (session : Session) : Async Unit := do
  let final ← session.model
  let history ← session.history
  match Session.replay limits history with
  | .ok replayed =>
    check "replayed state equals session state" (replayed == final)
  | .error e =>
    throw (IO.userError s!"history replay rejected: {repr e}")

/-- Graceful close over the mock transport, including the half-close wait. -/
private def gracefulScenario : IO Unit := do
  let (client, server) ← Mock.new
  Async.block do
    let session ← Session.new (mockBackend server) closeBytes limits
    discard <| expect "beginRead" (← session.beginRead)
    discard <| expect "submit abc" (← session.submit "abc".toUTF8)
    discard <| expect "submit defg" (← session.submit "defg".toUTF8)
    discard <| expect "requestClose" (← session.requestClose)
    for payload in ["abc", "defg", "CLOSE"] do
      discard <| expect s!"dispatch {payload}" (← session.dispatch)
      let outcome ← expect s!"awaitWrite {payload}" (← session.awaitWrite)
      check s!"{payload} written" (outcome == .written)
      check s!"{payload} on the wire" ((← client.tryRecv?) == some payload.toUTF8)
    discard <| expect "peerClosed" (← session.peerClosed)
    let kind ← expect "runControl" (← session.runControl)
    check "half-close control" (kind == .finishSend)
    check "client sees EOF after half-close" ((← client.recv?) == none)
    -- The peer goes away entirely; the pending read resolves as EOF.
    closeChan (Mock.Client.getSendChan client)
    let data ← expect "awaitRead" (← session.awaitRead)
    check "read EOF" data.isNone
    discard <| expect "backendEnded" (← session.backendEnded)
    discard <| expect "release" (← session.release)
    checkReplay session
    let final ← session.model
    check "released" final.released
    check "results written in order"
      (final.results == [(1, .written), (2, .written)])

/-- A broken write path: the failure settles the request and aborts. -/
private def writeFailureScenario : IO Unit := do
  let (client, server) ← Mock.new
  Async.block do
    let session ← Session.new (mockBackend server) closeBytes limits
    discard <| expect "submit" (← session.submit "abc".toUTF8)
    -- Break the write direction before the write is dispatched.
    closeChan (Mock.Server.getSendChan server)
    discard <| expect "dispatch" (← session.dispatch)
    let outcome ← expect "awaitWrite" (← session.awaitWrite)
    check "write failed, not faked as success" (outcome == .failed)
    check "nothing on the wire" ((← client.tryRecv?) == none)
    let kind ← expect "runControl" (← session.runControl)
    check "abort control" (kind == .abort)
    discard <| expect "backendEnded" (← session.backendEnded)
    discard <| expect "release" (← session.release)
    checkReplay session
    check "failure settled" ((← session.model).results == [(0, .failed)])

/-- Deadline with a pending read: abort resolves the read, then release. -/
private def deadlineScenario : IO Unit := do
  let (client, server) ← Mock.new
  Async.block do
    let session ← Session.new (mockBackend server) closeBytes limits
    discard <| expect "beginRead" (← session.beginRead)
    discard <| expect "submit" (← session.submit "abc".toUTF8)
    discard <| expect "deadline" (← session.deadline)
    -- The revoked queue entry must not reach the backend.
    expectError "dispatch after deadline" (← session.dispatch) .closed
    check "nothing on the wire" ((← client.tryRecv?) == none)
    let kind ← expect "runControl" (← session.runControl)
    check "abort control" (kind == .abort)
    -- The backend abort resolved the pending read as EOF.
    let data ← expect "awaitRead" (← session.awaitRead)
    check "read resolved by abort" data.isNone
    discard <| expect "backendEnded" (← session.backendEnded)
    discard <| expect "release" (← session.release)
    checkReplay session
    check "queued request cancelled"
      ((← session.model).results == [(1, .cancelled)])

def test : IO Unit := do
  gracefulScenario
  writeFailureScenario
  deadlineScenario
  IO.println "PASS: async executor sessions on the Std mock transport replay through the model"

end StdExtTests.AsyncExecutorTests
