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
  | backendDone
  | release
  deriving Repr, BEq, DecidableEq

inductive Effect where
  | accepted (id : Nat)
  | result (id : Nat) (outcome : Outcome)
  | write (operation : Write)
  | read (id : Nat)
  | abortBackend
  | finishSend
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
    s.reserved.isNone && s.writing.isNone && s.reading.isNone

private def settle (s : State) (items : List (Nat × Outcome)) : State × List Effect :=
  ({ s with results := s.results ++ items },
    items.map fun (id, outcome) => .result id outcome)

private def stop (s : State) : State × List Effect :=
  let requestAbort := !s.stopping && !s.backendEnded
  let queued := s.queue.map fun (id, _) => (id, Outcome.cancelled)
  let reserved := match s.reserved with
    | some ⟨_, .data id _⟩ => [(id, Outcome.cancelled)]
    | _ => []
  let (s, effects) := settle
    { s with accepting := false, stopping := true, queue := [], reserved := none }
    (queued ++ reserved)
  (s, effects ++ if requestAbort then [.abortBackend] else [])

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
    Except Error (State × List Effect) := do
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
    let (t, effects) := stop s
    -- A peer Close cancels unsent data but still permits the Close reply.
    return ({ t with stopping := s.stopping, peerClosed := true },
      if s.stopping then effects else
        effects.filter (· != .abortBackend) ++
          if s.closeWritten && !s.peerClosed then [.finishSend] else [])
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
    if s.closeWritten && s.peerClosed && !s.stopping then
      return (s, effects ++ [.finishSend])
    return (s, effects)
  | .beginRead =>
    if s.stopping || s.backendEnded || s.released then throw .closed
    if s.reading.isSome then throw .busy
    return ({ s with nextId := s.nextId + 1, reading := some s.nextId }, [.read s.nextId])
  | .readDone id =>
    if s.reading != some id then throw .invalidEvent
    return ({ s with reading := none }, [])
  | .backendDone =>
    let (s, effects) := stop s
    return ({ s with backendEnded := true }, effects.filter (· != .abortBackend))

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
  exact ⟨h.1.1.2, h.1.2⟩

theorem stopping_rejects_start (s : State) (id : Nat) (h : s.stopping = true) :
    startWrite s id = .error .closed := by
  simp [startWrite, h]
  rfl

theorem revoked_rejects_submit (limits : Limits) (s : State) (bytes : Nat)
    (h : s.accepting = false) :
    step limits s (.submit bytes) = .error .closed := by
  simp [step, h]
  rfl

theorem close_rejects_data_start (s : State) (id request bytes : Nat)
    (hc : s.closeStarted = true)
    (hr : s.reserved = some ⟨id, .data request bytes⟩)
    (hs : s.stopping = false) (hl : s.released = false)
    (hw : s.writing = none) :
    startWrite s id = .error .closed := by
  simp [startWrite, hc, hr, hs, hl, hw]
  rfl

end Std.Http.WebSocket.Lifecycle
