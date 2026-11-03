import Std

namespace Std.Http.WebSocket.Lifecycle

inductive Outcome where
  | written
  | cancelled
  | failed
  deriving Repr, BEq, DecidableEq

inductive WriteKind where
  | data (requestId bytes : Nat)
  | close
  deriving Repr, BEq, DecidableEq

structure Write where
  id : Nat
  kind : WriteKind
  deriving Repr, BEq, DecidableEq

/--
A control operation requested from the backend. Unlike a data/Close write it
is created by the model itself, but it still follows the same ledger shape:
reserved (`.control` effect), registered (`controlStart`), completed
(`controlDone`), and retained until completion.
-/
inductive ControlKind where
  /-- Ask the backend to abort its pending I/O. -/
  | abort
  /-- Half-close the send direction after the Close exchange completed. -/
  | finishSend
  deriving Repr, BEq, DecidableEq

structure Control where
  id : Nat
  kind : ControlKind
  started : Bool := false
  deriving Repr, BEq, DecidableEq

structure State where
  accepting : Bool := true
  stopping : Bool := false
  closeStarted : Bool := false
  closeWritten : Bool := false
  peerClosed : Bool := false
  backendEnded : Bool := false
  released : Bool := false
  nextId : Nat := 0
  queue : List (Nat × Nat) := []
  reserved : Option Write := none
  writing : Option Write := none
  reading : Option Nat := none
  controls : List Control := []
  results : List (Nat × Outcome) := []
  deriving Repr, BEq, DecidableEq

inductive Event where
  | submit (bytes : Nat)
  | localClose
  | peerClose
  | abort
  | deadline
  | reserve
  | start (id : Nat)
  | writeDone (id : Nat) (outcome : Outcome)
  | beginRead
  | readDone (id : Nat)
  /-- The executor registered a reserved control operation with the backend. -/
  | controlStart (id : Nat)
  /-- The backend completed a control operation, or the executor withdrew an
  unregistered one (`.cancelled` only). -/
  | controlDone (id : Nat) (outcome : Outcome)
  | backendDone
  | release
  deriving Repr, BEq, DecidableEq

def Event.isRelease : Event → Bool
  | .release => true
  | _ => false

inductive Effect where
  | accepted (id : Nat)
  | result (id : Nat) (outcome : Outcome)
  | write (operation : Write)
  | read (id : Nat)
  /-- A control operation was reserved; the executor must register and
  complete it. Release is refused while it is outstanding. -/
  | control (id : Nat) (kind : ControlKind)
  | releaseOwned
  deriving Repr, BEq, DecidableEq

inductive Error where
  | closed
  | capacity
  | invalidEvent
  | busy
  deriving Repr, BEq, DecidableEq

structure Limits where
  requests : Nat
  bytes : Nat
  deriving Repr

/--
Initial capacity defaults (D4). Estimated from existing implementations, not
measured: 32 outstanding requests matches the Python websockets `max_queue`
default (Lean Std channels default to unbounded and give no precedent), and
1 MiB retained payload matches both this extension's `Config.maxMessageBytes`
default — so one maximal legal message can always be accepted — and the
Python websockets `max_size` default. See
`docs/std-websocket/websocket-behavior-policy.md` §4.7 for sources.
-/
def Limits.default : Limits := ⟨32, 1 <<< 20⟩

def WriteKind.byteCount : WriteKind → Nat
  | .data _ bytes => bytes
  | .close => 0

def retainedBytes (s : State) : Nat :=
  (s.queue.map Prod.snd).sum +
    (s.reserved.map (·.kind.byteCount)).getD 0 +
    (s.writing.map (·.kind.byteCount)).getD 0

def outstanding (s : State) : Nat :=
  s.queue.length +
    (if s.reserved.any (fun w => match w.kind with | .data .. => true | _ => false)
      then 1 else 0) +
    (if s.writing.any (fun w => match w.kind with | .data .. => true | _ => false)
      then 1 else 0)

def quiet (s : State) : Bool :=
  !s.accepting && s.backendEnded && s.queue.isEmpty &&
    s.reserved.isNone && s.writing.isNone && s.reading.isNone && s.controls.isEmpty

private def settle (s : State) (items : List (Nat × Outcome)) : State × List Effect :=
  ({ s with results := s.results ++ items },
    items.map fun (id, outcome) => .result id outcome)

/-- Reserves a control operation in the ledger and notifies the executor. -/
private def reserveControl (s : State) (kind : ControlKind) : State × List Effect :=
  ({ s with
      nextId := s.nextId + 1
      controls := s.controls ++ [{ id := s.nextId, kind := kind }] },
    [.control s.nextId kind])

/-- Cancels not-yet-started outbound work without requesting a backend abort. -/
private def stopCore (s : State) : State × List Effect :=
  let queued := s.queue.map fun (id, _) => (id, Outcome.cancelled)
  let reserved := match s.reserved with
    | some ⟨_, .data id _⟩ => [(id, Outcome.cancelled)]
    | _ => []
  settle { s with accepting := false, stopping := true, queue := [], reserved := none }
    (queued ++ reserved)

private def stop (s : State) : State × List Effect :=
  let requestAbort := !s.stopping && !s.backendEnded
  let (t, effects) := stopCore s
  if requestAbort then
    let (t, more) := reserveControl t .abort
    (t, effects ++ more)
  else (t, effects)

def startWrite (s : State) (id : Nat) : Except Error (State × List Effect) := do
  if s.stopping || s.released then throw .closed
  if s.writing.isSome then throw .busy
  let some w := s.reserved | throw .invalidEvent
  if w.id != id then throw .invalidEvent
  match w.kind with
  | .data .. =>
    if s.closeStarted || s.peerClosed then throw .closed
    return ({ s with reserved := none, writing := some w }, [.write w])
  | .close =>
    if s.closeStarted then throw .closed
    return ({ s with reserved := none, writing := some w, closeStarted := true }, [.write w])

def releaseOwned (s : State) : Except Error (State × List Effect) :=
  if quiet s && !s.released then
    .ok ({ s with released := true }, [.releaseOwned])
  else .error .busy

def step (limits : Limits) (s : State) (event : Event) :
    Except Error (State × List Effect) :=
  -- Release is terminal: a late event must not restart a released session.
  if s.released && !event.isRelease then throw .closed
  else do
  match event with
  | .release => releaseOwned s
  | .start id => startWrite s id
  | .submit bytes =>
    if !s.accepting || s.released then throw .closed
    if outstanding s >= limits.requests || retainedBytes s + bytes > limits.bytes then
      throw .capacity
    let id := s.nextId
    return ({ s with nextId := id + 1, queue := s.queue ++ [(id, bytes)] }, [.accepted id])
  | .localClose => return ({ s with accepting := false }, [])
  | .abort | .deadline => return stop s
  | .peerClose =>
    -- A peer Close cancels unsent data but still permits the Close reply.
    let (t, effects) := stopCore s
    let t := { t with stopping := s.stopping, peerClosed := true }
    if !s.stopping && s.closeWritten && !s.peerClosed && !s.backendEnded then
      let (t, more) := reserveControl t .finishSend
      return (t, effects ++ more)
    return (t, effects)
  | .reserve =>
    if s.stopping || s.released || s.closeStarted then throw .closed
    if s.reserved.isSome || s.writing.isSome then throw .busy
    match s.queue with
    | (request, bytes) :: rest =>
      let w := Write.mk s.nextId (.data request bytes)
      return ({ s with nextId := s.nextId + 1, queue := rest, reserved := some w }, [])
    | [] =>
      if s.accepting then throw .invalidEvent
      let w := Write.mk s.nextId .close
      return ({ s with nextId := s.nextId + 1, reserved := some w }, [])
  | .writeDone id outcome =>
    let some w := s.writing | throw .invalidEvent
    if w.id != id then throw .invalidEvent
    if outcome == .cancelled && !s.stopping then throw .invalidEvent
    let s := { s with writing := none }
    let (s, effects) : State × List Effect := match w.kind with
      | .data request _ => settle s [(request, outcome)]
      | .close => ({ s with closeWritten := outcome == .written }, [])
    if outcome != .written then
      let (s, cancelled) := stop s
      return (s, effects ++ cancelled)
    if s.closeWritten && s.peerClosed && !s.stopping && !s.backendEnded then
      let (s, more) := reserveControl s .finishSend
      return (s, effects ++ more)
    return (s, effects)
  | .beginRead =>
    if s.stopping || s.backendEnded || s.released then throw .closed
    if s.reading.isSome then throw .busy
    return ({ s with nextId := s.nextId + 1, reading := some s.nextId }, [.read s.nextId])
  | .readDone id =>
    if s.reading != some id then throw .invalidEvent
    return ({ s with reading := none }, [])
  | .controlStart id =>
    let some c := s.controls.find? (·.id == id) | throw .invalidEvent
    if c.started then throw .invalidEvent
    return ({ s with controls := s.controls.map fun c =>
      if c.id == id then { c with started := true } else c }, [])
  | .controlDone id outcome =>
    let some c := s.controls.find? (·.id == id) | throw .invalidEvent
    -- A control that was never registered can only be withdrawn.
    if !c.started && outcome != .cancelled then throw .invalidEvent
    return ({ s with controls := s.controls.filter (·.id != id) }, [])
  | .backendDone =>
    let (t, effects) := stopCore s
    return ({ t with backendEnded := true }, effects)

theorem release_requires_quiet (s t : State) (effects : List Effect)
    (h : releaseOwned s = .ok (t, effects)) : quiet s = true := by
  unfold releaseOwned at h
  split at h
  · rename_i guard
    simp only [Bool.and_eq_true] at guard
    exact guard.1
  · contradiction

theorem quiet_has_no_writes (s : State) (h : quiet s = true) :
    s.reserved = none ∧ s.writing = none := by
  simp only [quiet, Bool.and_eq_true, Option.isNone_iff_eq_none] at h
  exact ⟨h.1.1.1.2, h.1.1.2⟩

theorem quiet_has_no_controls (s : State) (h : quiet s = true) :
    s.controls = [] := by
  simp only [quiet, Bool.and_eq_true, List.isEmpty_iff] at h
  exact h.2

theorem stopping_rejects_start (s : State) (id : Nat) (h : s.stopping = true) :
    startWrite s id = .error .closed := by
  simp [startWrite, h]
  rfl

theorem revoked_rejects_submit (limits : Limits) (s : State) (bytes : Nat)
    (h : s.accepting = false) :
    step limits s (.submit bytes) = .error .closed := by
  cases hr : s.released <;> simp [step, Event.isRelease, h, hr] <;> rfl

theorem close_rejects_data_start (s : State) (id request bytes : Nat)
    (hc : s.closeStarted = true)
    (hr : s.reserved = some ⟨id, .data request bytes⟩)
    (hs : s.stopping = false) (hl : s.released = false)
    (hw : s.writing = none) :
    startWrite s id = .error .closed := by
  simp [startWrite, hc, hr, hs, hl, hw]
  rfl

/--
Release is terminal: no event can succeed on a released session, so a late
completion or peer event cannot restart it or issue new effects (S5).
-/
theorem released_is_terminal (limits : Limits) (s : State) (event : Event)
    (h : s.released = true) (t : State) (effects : List Effect) :
    step limits s event ≠ .ok (t, effects) := by
  intro hok
  cases event <;> simp [step, Event.isRelease, releaseOwned, h] at hok

set_option linter.unusedSimpArgs false in
set_option maxHeartbeats 1000000 in
/-- A reserved and an in-flight write never coexist, preserved by every step. -/
theorem step_preserves_write_exclusion (limits : Limits) (s t : State)
    (event : Event) (effects : List Effect)
    (hs : ¬(s.reserved.isSome ∧ s.writing.isSome))
    (h : step limits s event = .ok (t, effects)) :
    ¬(t.reserved.isSome ∧ t.writing.isSome) := by
  cases event <;>
    simp only [step, Event.isRelease, releaseOwned, startWrite, stop, stopCore,
      settle, reserveControl, Bool.and_true, Bool.and_false, Bool.not_true,
      Bool.not_false, ite_false, ite_true, bind, Except.bind, Functor.map,
      Except.map, throw, throwThe, MonadExceptOf.throw, pure, Except.pure] at h <;>
    (repeat' split at h) <;>
    (try obtain ⟨rfl, rfl⟩ := h) <;>
    (try (simp_all; done)) <;>
    (try simp only [Except.ok.injEq] at h) <;>
    (try (repeat' split at h)) <;>
    (try obtain ⟨rfl, rfl⟩ := h) <;>
    (try (simp_all; done)) <;>
    (cases hstop : s.stopping <;> cases hback : s.backendEnded <;>
      (try simp_all) <;>
      (try (repeat' split at h)) <;>
      (try simp_all) <;>
      (try (repeat' split at h)) <;>
      (try obtain ⟨rfl, rfl⟩ := h) <;>
      simp_all)

end Std.Http.WebSocket.Lifecycle
