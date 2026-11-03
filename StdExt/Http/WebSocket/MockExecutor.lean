/-
Stage-B mock executor for the WebSocket lifecycle model
(docs/std-websocket/websocket-prototype-results.md §5, 段階B).

A deterministic, purely functional driver that executes the `Lifecycle.step`
effects against a manually controlled mock backend. Unlike `LifecycleTests`,
which feeds model events directly, this executor exposes the *operations an
asynchronous runtime performs* (user calls, owner scheduling, backend
callbacks) and maps every history it produces onto a model event history.

Design choices imitated from existing implementations:
- The executor stays sans-I/O (pure state + explicit input events), following
  the layering of this repo's frame layer and the Python `websockets`
  sans-io protocol (`websockets.protocol.Protocol.events_received` /
  `data_to_send`).
- Registered operations retain their buffers until the completion callback,
  mirroring the libuv `uv_write` contract recorded in
  docs/std-websocket/websocket-dependency-contracts.md (C1).
- Immediate registration failure is modelled after `uv_write` returning an
  error synchronously: nothing is retained by the backend and the model is fed
  a `.failed` completion for the started operation.
- Exhaustive bounded exploration of command interleavings follows the approach
  of Rust `loom` (bounded model checking of schedules), scaled down to the
  depth used by `LifecycleTests`.
-/
import StdExt.Http.WebSocket.Lifecycle

namespace Std.Http.WebSocket.Lifecycle.Mock

/--
Operations currently registered with the mock backend. While an operation is
listed here the backend retains its buffer/resources; it leaves the list only
through an explicit completion command (callback), never implicitly.
-/
structure Backend where
  /-- Registered writes awaiting their completion callback (at most one, which
  the correspondence check enforces against `State.writing`). -/
  writes : List Write := []
  /-- Registered reads awaiting data, EOF, or cancellation. -/
  reads : List Nat := []
  /-- Registered control operations awaiting their completion callback. -/
  controls : List Control := []
  /-- Registration order of writes: the outbound serialization (D3). -/
  wireLog : List Write := []
  /-- The backend reported that it ended. Registered operations survive this
  until their callbacks run. -/
  ended : Bool := false
  deriving Repr, BEq

structure Executor where
  model : State := {}
  backend : Backend := {}
  /-- Controls reserved by the model but not yet registered. -/
  pendingControls : List Control := []
  /-- The model event history this executor run corresponds to. -/
  history : List Event := []
  /-- Requests whose submitter still waits for a result. -/
  waiters : List Nat := []
  /-- Every `.result` effect in order, matched against `State.results`. -/
  resultsSeen : List (Nat × Outcome) := []
  /-- Results delivered to a live waiter. -/
  delivered : List (Nat × Outcome) := []
  /-- Results confirmed after the waiter disappeared; still retained. -/
  orphaned : List (Nat × Outcome) := []
  /-- The next registration throws synchronously (uv_write-style failure). -/
  registrationFault : Bool := false
  /-- Write whose registration just failed; its `.failed` completion is owed. -/
  faultedWrite : Option Nat := none
  released : Bool := false
  deriving Repr

/--
One step an asynchronous runtime can take: a user call, an owner scheduling
decision, or a backend callback. Deliberately finer grained than model events
so that races (late starts, reordered completions) are expressible.
-/
inductive Command where
  /-- User calls send; a result waiter is registered. -/
  | send (bytes : Nat)
  /-- The waiter for a request stops waiting (task dropped, owner exception). -/
  | abandonWaiter
  /-- User requests a graceful local close. -/
  | close
  /-- Owner reserves the next outbound frame. -/
  | pump
  /-- Owner registers the reserved frame with the backend. -/
  | dispatch
  /-- The next backend registration fails synchronously. -/
  | injectRegistrationFault
  /-- Backend write completion callback. -/
  | completeWrite (outcome : Outcome)
  | beginRead
  /-- Backend read completion callback. -/
  | completeRead
  | peerClose
  | deadline
  | abortSession
  /-- The backend reports its end (EOF, fatal error). Completes nothing. -/
  | backendEnds
  /-- Owner registers a reserved control operation with the backend. -/
  | registerControl (index : Nat)
  /-- Owner withdraws a control operation that was never registered. -/
  | withdrawControl (index : Nat)
  /-- Backend control-operation completion callback. -/
  | completeControl (index : Nat) (outcome : Outcome)
  | release
  deriving Repr, BEq

inductive Failure where
  /-- The model refused the event: the command is impossible here (pruned). -/
  | rejected (error : Error)
  /-- No such operation at the executor level (pruned). -/
  | invalid (reason : String)
  /-- Executor and model disagree: a bug, never pruned. -/
  | mismatch (reason : String)
  deriving Repr, BEq

def Failure.isMismatch : Failure → Bool
  | .mismatch _ => true
  | _ => false

/--
Routes one effect into the executor. Never feeds further model events; the
only command needing a follow-up event (`dispatch` under a registration
fault) chains it explicitly.
-/
private def applyEffect (ex : Executor) : Effect → Except Failure Executor
  | .accepted id => pure { ex with waiters := ex.waiters ++ [id] }
  | .result id outcome =>
    let ex := { ex with resultsSeen := ex.resultsSeen ++ [(id, outcome)] }
    if ex.waiters.contains id then
      pure { ex with
        waiters := ex.waiters.filter (· != id)
        delivered := ex.delivered ++ [(id, outcome)] }
    else
      -- The waiter vanished: the result is still confirmed and retained.
      pure { ex with orphaned := ex.orphaned ++ [(id, outcome)] }
  | .write w =>
    if ex.registrationFault then
      -- Registration threw synchronously: the backend retained nothing and
      -- no bytes reached the wire. The owner owes a `.failed` completion.
      pure { ex with registrationFault := false, faultedWrite := some w.id }
    else
      pure { ex with backend := { ex.backend with
        writes := ex.backend.writes ++ [w]
        wireLog := ex.backend.wireLog ++ [w] } }
  | .read id =>
    pure { ex with backend := { ex.backend with reads := ex.backend.reads ++ [id] } }
  | .control id kind =>
    pure { ex with pendingControls := ex.pendingControls ++ [{ id := id, kind := kind }] }
  | .releaseOwned =>
    -- Releasing with unexecuted effects or registered I/O is forbidden.
    if ex.backend.writes.isEmpty && ex.backend.reads.isEmpty &&
        ex.backend.controls.isEmpty && ex.pendingControls.isEmpty &&
        ex.faultedWrite.isNone then
      pure { ex with released := true }
    else
      throw (.mismatch "releaseOwned while backend work is outstanding")

/-- Feeds one model event and routes the resulting effects. -/
private def runEvent (limits : Limits) (ex : Executor) (event : Event) :
    Except Failure Executor := do
  match step limits ex.model event with
  | .error e => throw (.rejected e)
  | .ok (model, effects) =>
    let ex := { ex with model, history := ex.history ++ [event] }
    effects.foldlM applyEffect ex

/--
Backend callbacks for registered operations must be accepted by the model;
a refusal is a correspondence bug, not an impossible schedule.
-/
private def runCallback (limits : Limits) (ex : Executor) (event : Event) :
    Except Failure Executor :=
  match runEvent limits ex event with
  | .error (.rejected e) =>
    throw (.mismatch s!"model refused backend callback: {repr e}")
  | r => r

def exec (limits : Limits) (ex : Executor) : Command → Except Failure Executor
  | .send bytes => runEvent limits ex (.submit bytes)
  | .abandonWaiter =>
    match ex.waiters with
    | [] => throw (.invalid "no waiter")
    | _ :: rest => pure { ex with waiters := rest }
  | .close => runEvent limits ex .localClose
  | .pump => runEvent limits ex .reserve
  | .dispatch => do
    match ex.model.reserved with
    | none => throw (.invalid "no reserved frame")
    | some w =>
      let ex ← runEvent limits ex (.start w.id)
      match ex.faultedWrite with
      | some id =>
        -- The failure is owed to the model immediately; it must accept it.
        runCallback limits { ex with faultedWrite := none } (.writeDone id .failed)
      | none => pure ex
  | .injectRegistrationFault =>
    if ex.registrationFault then throw (.invalid "fault already armed")
    else pure { ex with registrationFault := true }
  | .completeWrite outcome => do
    match ex.backend.writes with
    | [] => throw (.invalid "no registered write")
    | w :: rest =>
      -- The model only admits a cancelled completion while stopping; the
      -- mock backend never cancels unprompted, so prune that schedule.
      if outcome == .cancelled && !ex.model.stopping then
        throw (.rejected .invalidEvent)
      let ex ← runCallback limits ex (.writeDone w.id outcome)
      pure { ex with backend := { ex.backend with writes := rest } }
  | .beginRead => runEvent limits ex .beginRead
  | .completeRead => do
    match ex.backend.reads with
    | [] => throw (.invalid "no registered read")
    | id :: rest =>
      let ex ← runCallback limits ex (.readDone id)
      pure { ex with backend := { ex.backend with reads := rest } }
  | .peerClose => runEvent limits ex .peerClose
  | .deadline => runEvent limits ex .deadline
  | .abortSession => runEvent limits ex .abort
  | .backendEnds => do
    let ex ← runEvent limits ex .backendDone
    pure { ex with backend := { ex.backend with ended := true } }
  | .registerControl index => do
    match ex.pendingControls[index]? with
    | none => throw (.invalid "no such pending control")
    | some c =>
      let ex ← runEvent limits ex (.controlStart c.id)
      let ex := { ex with pendingControls := ex.pendingControls.filter (·.id != c.id) }
      if ex.registrationFault then
        -- Synchronous registration failure of a control operation.
        runCallback limits { ex with registrationFault := false }
          (.controlDone c.id .failed)
      else
        pure { ex with backend := { ex.backend with
          controls := ex.backend.controls ++ [{ c with started := true }] } }
  | .withdrawControl index => do
    match ex.pendingControls[index]? with
    | none => throw (.invalid "no such pending control")
    | some c =>
      let ex ← runEvent limits ex (.controlDone c.id .cancelled)
      pure { ex with pendingControls := ex.pendingControls.filter (·.id != c.id) }
  | .completeControl index outcome => do
    match ex.backend.controls[index]? with
    | none => throw (.invalid "no such registered control")
    | some c =>
      let ex ← runCallback limits ex (.controlDone c.id outcome)
      pure { ex with backend := { ex.backend with
        controls := ex.backend.controls.filter (·.id != c.id) } }
  | .release => runEvent limits ex .release

/-- No data frame is registered after the Close frame, and data frames are
registered in acceptance order (the user-visible serialization of D3). -/
def wireOrdered (log : List Write) : Bool :=
  go none false log
where
  go (lastRequest : Option Nat) (closed : Bool) : List Write → Bool
    | [] => true
    | w :: rest =>
      if closed then false
      else match w.kind with
        | .data request _ => lastRequest.all (· < request) && go (some request) false rest
        | .close => go lastRequest true rest

private def sameElements (xs ys : List Control) : Bool :=
  xs.length == ys.length && xs.all (ys.contains ·)

/--
The executor/model correspondence: backend ledgers mirror the model's
operation state, results are confirmed exactly once, the wire order respects
the approved send/close serialization, and a released session has no
registered or pending backend work.
-/
def consistent (ex : Executor) : Bool :=
  ex.backend.writes == ex.model.writing.toList &&
  ex.backend.reads == ex.model.reading.toList &&
  sameElements ex.backend.controls (ex.model.controls.filter (·.started)) &&
  sameElements ex.pendingControls (ex.model.controls.filter (!·.started)) &&
  ex.resultsSeen == ex.model.results &&
  ex.delivered.length + ex.orphaned.length == ex.resultsSeen.length &&
  wireOrdered ex.backend.wireLog &&
  ex.released == ex.model.released &&
  (!ex.released || (ex.backend.writes.isEmpty && ex.backend.reads.isEmpty &&
    ex.backend.controls.isEmpty && ex.pendingControls.isEmpty))

end Std.Http.WebSocket.Lifecycle.Mock
