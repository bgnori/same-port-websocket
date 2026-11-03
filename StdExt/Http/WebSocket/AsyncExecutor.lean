/-
Stage-C first slice: bind the lifecycle model to a real asynchronous backend
through `Std.Async` (docs/std-websocket/websocket-prototype-results.md §5,
段階C; see docs/std-websocket/websocket-mock-executor-results.md for the
stage-B executor this follows).

Every I/O operation of a session goes through `Lifecycle.step` first: an event
the model rejects performs no backend I/O, and every backend completion is fed
back as a model event. The session records the model event history so a run on
a real backend can be replayed through the pure model (`replay`).

Scope and honesty notes:
- The backend is an explicit capability record (`Backend`). Capabilities map
  to what Lean Std/libuv actually provides (writes observed via completion
  promises, no in-flight write cancellation, `cancelRecv`-style read
  cancellation, `shutdown`-style half-close). A backend must not fake a
  capability it lacks (D5).
- This slice is single-owner: the caller (one logical task) drives
  `dispatch`/`awaitWrite`/`beginRead`/`awaitRead`/`runControl` sequentially.
  The mailbox/lock discipline for concurrent user calls is future work; the
  user-facing serialization itself is already fixed by D3 and enforced by the
  model (one write slot, Close ordering).
- Registration failures surface as task failures here (libuv's synchronous
  `uv_write` error becomes a failed completion); the distinction between the
  two is exercised in the pure `MockExecutor`.
-/
import StdExt.Http.WebSocket.Lifecycle

namespace Std.Http.WebSocket.Lifecycle.AsyncExecutor

open Std.Async

/--
The capabilities a backend offers to a session. Each field corresponds to a
contract verified against the backend's documentation or source; none of them
may be implemented as a success-shaped no-op.
-/
structure Backend where
  /-- Registers a write; the action resolves at write completion and the
  buffer must stay retained by the backend until then. -/
  write : ByteArray → Async Unit
  /-- Receives the next chunk; `none` is EOF. -/
  read : UInt64 → Async (Option ByteArray)
  /-- Half-closes the send direction (TCP `shutdown`, HTTP/2 END_STREAM). -/
  finishSend : Async Unit
  /-- Aborts what the backend can abort (for example pending reads via
  `cancelRecv`). Must not pretend to interrupt uninterruptible I/O. -/
  abort : Async Unit

private structure SessionState where
  model : State := {}
  history : List Event := []
  /-- Accepted payloads, retained until their write completion. -/
  payloads : List (Nat × ByteArray) := []
  /-- In-flight write: operation id, settled request (if data), task. -/
  writeTask : Option (Nat × Option Nat × AsyncTask Unit) := none
  /-- In-flight read: operation id and task. -/
  readTask : Option (Nat × AsyncTask (Option ByteArray)) := none

/--
A session owner binding the lifecycle model to a `Backend`.
-/
structure Session where
  private mk ::
  limits : Limits
  /-- Encoded Close frame handed to the backend when the model schedules the
  Close write. Frame encoding stays outside the lifecycle model. -/
  closeFrame : ByteArray
  backend : Backend
  private ref : IO.Ref SessionState

def Session.new (backend : Backend) (closeFrame : ByteArray)
    (limits : Limits := .default) : BaseIO Session := do
  return { limits, closeFrame, backend, ref := ← IO.mkRef {} }

namespace Session

/-- Feeds one event to the model; on success records it and drops the payloads
of any request that the model settled (written, failed, or cancelled). -/
private def stepRecord (s : Session) (event : Event) :
    Async (Except Error (List Effect)) := do
  s.ref.modifyGet fun st =>
    match step s.limits st.model event with
    | .error e => (.error e, st)
    | .ok (model, effects) =>
      let settled := effects.filterMap fun
        | .result id _ => some id
        | _ => none
      (.ok effects, { st with
        model := model
        history := st.history ++ [event]
        payloads := st.payloads.filter (!settled.contains ·.1) })

/-- The recorded model event history of this session. -/
def history (s : Session) : BaseIO (List Event) :=
  return (← s.ref.get).history

/-- The current model state (for tests and introspection). -/
def model (s : Session) : BaseIO State :=
  return (← s.ref.get).model

/--
Replays an event history through the pure model from the initial state.
A session run on a real backend is valid iff its history replays to its
final model state.
-/
def replay (limits : Limits) (events : List Event) : Except Error State :=
  events.foldlM (fun s event => (step limits s event).map Prod.fst) ({} : State)

/-- Submits a payload; on acceptance it is retained until write completion. -/
def submit (s : Session) (payload : ByteArray) : Async (Except Error Nat) := do
  s.ref.modifyGet fun st =>
    match step s.limits st.model (.submit payload.size) with
    | .error e => (.error e, st)
    | .ok (model, _) =>
      let id := st.model.nextId
      (.ok id, { st with
          model := model
          history := st.history ++ [.submit payload.size]
          payloads := st.payloads ++ [(id, payload)] })

/-- Revokes acceptance of new submissions (graceful close intent). -/
def requestClose (s : Session) : Async (Except Error Unit) := do
  return (← s.stepRecord .localClose).map fun _ => ()

/-- Records a peer Close observed by the frame layer. -/
def peerClosed (s : Session) : Async (Except Error Unit) := do
  return (← s.stepRecord .peerClose).map fun _ => ()

/-- Records a deadline expiry; started I/O stays tracked. -/
def deadline (s : Session) : Async (Except Error Unit) := do
  return (← s.stepRecord .deadline).map fun _ => ()

/-- Records that the backend ended (EOF or fatal error reported upstream). -/
def backendEnded (s : Session) : Async (Except Error Unit) := do
  return (← s.stepRecord .backendDone).map fun _ => ()

/--
Reserves the next outbound frame and registers its write with the backend.
If the model refuses (nothing to send, close already started, stopping),
no backend I/O happens.
-/
def dispatch (s : Session) : Async (Except Error Nat) := do
  match ← s.stepRecord .reserve with
  | .error e => return .error e
  | .ok _ =>
    let st ← s.ref.get
    let some w := st.model.reserved | return .error .invalidEvent
    match ← s.stepRecord (.start w.id) with
    | .error e => return .error e
    | .ok _ =>
      let (request, bytes) := match w.kind with
        | .data request _ =>
          (some request, (st.payloads.lookup request).getD ByteArray.empty)
        | .close => (none, s.closeFrame)
      let task ← (s.backend.write bytes).async
      s.ref.modify fun st => { st with writeTask := some (w.id, request, task) }
      return .ok w.id

/--
Awaits the in-flight write and feeds its completion to the model. The payload
is released only here, mirroring the libuv buffer-retention contract.
-/
def awaitWrite (s : Session) : Async (Except Error Outcome) := do
  let st ← s.ref.get
  let some (id, _request, task) := st.writeTask | return .error .invalidEvent
  let outcome ← try
    EAsync.await task
    pure Outcome.written
  catch _ => pure Outcome.failed
  match ← s.stepRecord (.writeDone id outcome) with
  | .error e => return .error e
  | .ok _ =>
    s.ref.modify fun st => { st with writeTask := none }
    return .ok outcome

/-- Starts a read and registers it with the backend. -/
def beginRead (s : Session) (maxBytes : UInt64 := 16384) :
    Async (Except Error Nat) := do
  match ← s.stepRecord .beginRead with
  | .error e => return .error e
  | .ok effects =>
    let some id := effects.findSome? (fun
        | .read id => some id
        | _ => none)
      | return .error .invalidEvent
    let task ← (s.backend.read maxBytes).async
    s.ref.modify fun st => { st with readTask := some (id, task) }
    return .ok id

/--
Awaits the in-flight read. EOF (and, in this slice, read errors) are reported
as `none` and also recorded as the backend ending. Distinguishing data, EOF,
cancellation and failure per event remains a documented simplification.
-/
def awaitRead (s : Session) : Async (Except Error (Option ByteArray)) := do
  let st ← s.ref.get
  let some (id, task) := st.readTask | return .error .invalidEvent
  let data ← try EAsync.await task catch _ => pure none
  match ← s.stepRecord (.readDone id) with
  | .error e => return .error e
  | .ok _ =>
    s.ref.modify fun st => { st with readTask := none }
    if data.isNone then
      match ← s.stepRecord .backendDone with
      | .error e => return .error e
      | .ok _ => return .ok none
    else
      return .ok data

/--
Registers and executes the first reserved control operation. The control is
completed with the actual result of the capability call; a failure is
recorded as `.failed`, never upgraded to success.
-/
def runControl (s : Session) : Async (Except Error ControlKind) := do
  let st ← s.ref.get
  let some c := st.model.controls.find? (!·.started) | return .error .invalidEvent
  match ← s.stepRecord (.controlStart c.id) with
  | .error e => return .error e
  | .ok _ =>
    let outcome ← try
      (match c.kind with
        | .abort => s.backend.abort
        | .finishSend => s.backend.finishSend)
      pure Outcome.written
    catch _ => pure Outcome.failed
    match ← s.stepRecord (.controlDone c.id outcome) with
    | .error e => return .error e
    | .ok _ => return .ok c.kind

/--
Releases the session. Succeeds only when the model is quiet; additionally
asserts that the adapter retains no task or payload, which would be a bug.
-/
def release (s : Session) : Async (Except Error Unit) := do
  match ← s.stepRecord .release with
  | .error e => return .error e
  | .ok _ =>
    let st ← s.ref.get
    if st.writeTask.isSome || st.readTask.isSome || !st.payloads.isEmpty then
      throw (IO.userError
        s!"release while the adapter retains tasks or payloads: \
          write={(st.writeTask.map (·.1))}, read={(st.readTask.map (·.1))}, \
          payloads={st.payloads.map (·.1)}")
    return .ok ()

end Session

end Std.Http.WebSocket.Lifecycle.AsyncExecutor
