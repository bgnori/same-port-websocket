/-
Stage-B tests: drive the mock executor with runtime-level commands and check
that every history it produces corresponds to the lifecycle model and keeps
the executor/model correspondence (`consistent`) at every step.
-/
import StdExt.Http.WebSocket.MockExecutor

namespace StdExtTests.MockExecutorTests

open Std.Http.WebSocket.Lifecycle
open Std.Http.WebSocket.Lifecycle.Mock

private def limits : Limits := ⟨2, 8⟩

private def run (commands : List Command) : Except Failure Executor :=
  commands.foldlM (fun ex command => do
    let ex ← exec limits ex command
    if consistent ex then pure ex
    else throw (.mismatch s!"inconsistent after {repr command}")) {}

private def fails (commands : List Command) (expected : Failure) : Bool :=
  match run commands with
  | .error actual => actual == expected
  | .ok _ => false

-- Graceful close: drain two sends, write the Close frame, answer the peer
-- Close with a half-close, and only then release.
#guard match run [
    .send 3, .send 4, .close,
    .pump, .dispatch, .completeWrite .written,
    .pump, .dispatch, .completeWrite .written,
    .pump, .dispatch, .completeWrite .written,
    .peerClose, .registerControl 0, .completeControl 0 .written,
    .backendEnds, .release] with
  | .ok ex => ex.released &&
      ex.delivered == [(0, .written), (1, .written)] && ex.orphaned == [] &&
      ex.backend.wireLog == [⟨2, .data 0 3⟩, ⟨3, .data 1 4⟩, ⟨4, .close⟩]
  | _ => false

-- Synchronous registration failure: nothing reaches the wire, the owed
-- `.failed` completion settles the request, the abort control is withdrawn.
#guard match run [
    .send 3, .pump, .injectRegistrationFault, .dispatch,
    .withdrawControl 0, .backendEnds, .release] with
  | .ok ex => ex.released && ex.delivered == [(0, .failed)] &&
      ex.backend.wireLog == []
  | _ => false

-- Reordered completions: control callback before the cancelled write.
#guard match run [
    .send 3, .pump, .dispatch, .deadline,
    .registerControl 0, .completeControl 0 .written,
    .completeWrite .cancelled, .backendEnds, .release] with
  | .ok ex => ex.released && ex.delivered == [(0, .cancelled)]
  | _ => false

-- Reordered completions: control callback after the backend ended.
#guard match run [
    .send 3, .pump, .dispatch, .deadline,
    .registerControl 0, .completeWrite .cancelled,
    .backendEnds, .completeControl 0 .failed, .release] with
  | .ok ex => ex.released
  | _ => false

-- A registered abort control blocks release until its callback runs.
#guard fails [.send 3, .pump, .dispatch, .deadline, .registerControl 0,
  .completeWrite .cancelled, .backendEnds, .release] (.rejected .busy)

-- Waiter disappearance: the result is still confirmed once and retained.
#guard match run [
    .send 3, .abandonWaiter, .close,
    .pump, .dispatch, .completeWrite .written,
    .pump, .dispatch, .completeWrite .written,
    .backendEnds, .release] with
  | .ok ex => ex.released && ex.delivered == [] && ex.orphaned == [(0, .written)]
  | _ => false

-- Revocation after reservation: the late dispatch registers nothing.
#guard fails [.send 3, .pump, .deadline, .dispatch] (.invalid "no reserved frame")

-- Peer Close before the local Close write still requires the half-close.
#guard match run [
    .close, .pump, .dispatch, .peerClose, .completeWrite .written,
    .registerControl 0, .completeControl 0 .written,
    .backendEnds, .release] with
  | .ok ex => ex.released && ex.backend.wireLog == [⟨0, .close⟩]
  | _ => false

-- A registered read blocks release even after deadline and backend end.
#guard fails [.beginRead, .deadline, .withdrawControl 0, .backendEnds,
  .release] (.rejected .busy)
#guard match run [.beginRead, .deadline, .withdrawControl 0, .backendEnds,
    .completeRead .cancelled, .release] with
  | .ok ex => ex.released
  | _ => false

-- The mock backend never cancels a write unprompted.
#guard fails [.send 3, .pump, .dispatch, .completeWrite .cancelled]
  (.rejected .invalidEvent)

-- Inbound data is delivered while live and dropped once stopping.
#guard match run [.beginRead, .completeRead (.data 3), .beginRead,
    .deadline, .completeRead (.data 5), .registerControl 0,
    .completeControl 0 .written, .backendEnds, .release] with
  | .ok ex => ex.released && ex.inbox == [(0, 3)]
  | _ => false

-- EOF ends the inbound direction; no further read can start.
#guard fails [.beginRead, .completeRead .eof, .beginRead] (.rejected .closed)

-- Release is terminal at the executor level as well.
#guard fails [.close, .pump, .dispatch, .completeWrite .written,
  .backendEnds, .release, .peerClose] (.rejected .closed)

private def commands : List Command := [
  .send 3, .send 6, .abandonWaiter, .close, .pump, .dispatch,
  .injectRegistrationFault,
  .completeWrite .written, .completeWrite .failed, .completeWrite .cancelled,
  .beginRead, .completeRead (.data 3), .completeRead .eof,
  .completeRead .cancelled, .completeRead .failed,
  .peerClose, .deadline, .abortSession, .backendEnds,
  .registerControl 0, .registerControl 1, .withdrawControl 0, .withdrawControl 1,
  .completeControl 0 .written, .completeControl 0 .failed,
  .completeControl 0 .cancelled, .completeControl 1 .written,
  .completeControl 1 .failed, .completeControl 1 .cancelled,
  .release]

private def explore (depth : Nat) (ex : Executor) (history : List Command) :
    IO Nat := do
  unless consistent ex do
    throw <| IO.userError s!"Executor correspondence failed: {repr history}"
  match depth with
  | 0 => pure 1
  | n + 1 =>
    commands.foldlM (fun count command => do
      match exec limits ex command with
      | .error failure =>
        if failure.isMismatch then
          throw <| IO.userError
            s!"Executor mismatch: {repr (history ++ [command])}: {repr failure}"
        pure count
      | .ok next =>
        let visited ← explore n next (history ++ [command])
        pure (count + visited)) 1

def test : IO Unit := do
  let count ← explore 5 {} []
  IO.println s!"PASS: mock executor deterministic traces and {count} bounded exploration nodes"

end StdExtTests.MockExecutorTests
