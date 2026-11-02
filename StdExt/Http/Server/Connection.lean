/-
Extension proposal for `Std.Http.Server`: upgrade-capable connection loop.

This is `Std.Http.Server.Connection`'s request/response loop extended with one
terminal state: when the handler answers `UpgradableResponse.upgrade`, the
server flushes buffered output, writes the informational switching head through
the H1 machine (which encodes 1xx responses directly, leaving the writer
untouched), extracts the bytes the reader buffered past the request head, and
hands an `Upgraded` stream to the continuation. The socket stays owned by the
server: it is closed when the continuation finishes, fails, or the server
shuts down.

Apart from the handler result type and this terminal state, the loop is
intentionally identical to the standard library's implementation so the
extension can be read as a patch against `Std.Http.Server.Connection`.
-/
import Std.Http.Server
import StdExt.Http.Server.Upgrade

namespace Std.Http.Server

open Std Async TCP Protocol
open Time

/--
Events produced by the async select loop. Mirrors the private `Recv` type of
`Std.Http.Server.Connection`, with the response carrying an
`UpgradableResponse`.
-/
private inductive Recv (β : Type) where
  | bytes (x : Option ByteArray)
  | responseBody (x : Option Chunk)
  | bodyInterest (x : Bool)
  | response (x : Except IO.Error (UpgradableResponse β))
  | timeout
  | shutdown
  | close

/--
The set of I/O sources to wait on during a single poll iteration.
-/
private structure PollSources (α β : Type) where
  socket : Option α
  expect : Option Nat
  response : Option (Std.Channel (Except IO.Error (UpgradableResponse β)))
  responseBody : Option β
  requestBody : Option Body.Stream
  timeout : Millisecond.Offset
  keepAliveTimeout : Option Millisecond.Offset
  headerTimeout : Option Timestamp
  connectionContext : CancellationContext

/--
Waits for the next I/O event across all active sources described by `sources`.
-/
private def pollNextEvent
    {α σ β : Type} [Transport α] [UpgradableHandler σ] [Body β]
    (config : Config) (handler : σ) (sources : PollSources α β)
    : Async (Recv β) := do
  let expectedBytes := sources.expect
    |>.getD config.defaultPayloadBytes
    |>.min config.maximumRecvSize
    |>.toUInt64

  let mut selectables : Array (Selectable (Recv β)) := #[
    .case sources.connectionContext.doneSelector (fun _ => do
      let reason ← sources.connectionContext.getCancellationReason
      match reason with
      | some .deadline => pure .timeout
      | _ => pure .shutdown)
  ]

  if let some socket := sources.socket then
    selectables := selectables.push
      (.case (Transport.recvSelector socket expectedBytes) (Recv.bytes · |> pure))

    if sources.keepAliveTimeout.isNone then
      if let some timeout := sources.headerTimeout then
        selectables := selectables.push
          (.case (← Selector.sleep (timeout - (← Timestamp.now)).toMilliseconds) (fun _ => pure .timeout))
      else
        selectables := selectables.push
          (.case (← Selector.sleep sources.timeout) (fun _ => pure .timeout))
    else
      selectables := selectables.push
        (.case (← Selector.sleep sources.timeout) (fun _ => pure .close))

  if let some responseBody := sources.responseBody then
    selectables := selectables.push
      (.case (Body.recvSelector responseBody) (Recv.responseBody · |> pure))

  if let some requestBody := sources.requestBody then
    selectables := selectables.push
      (.case (requestBody.interestSelector) (Recv.bodyInterest · |> pure))

  if let some response := sources.response then
    selectables := selectables.push
      (.case response.recvSelector (Recv.response · |> pure))

  try Selectable.one selectables
  catch e =>
    UpgradableHandler.onFailure handler e
    pure .close

/--
Handles the `Expect: 100-continue` protocol for a pending request head.
-/
private def handleContinueEvent
    {σ : Type} [UpgradableHandler σ]
    (handler : σ) (machine : H1.Machine .receiving) (head : Request.Head)
    (config : Config) (connectionContext : CancellationContext)
    : Async (H1.Machine .receiving × Bool) := do

  let continueChannel : Std.Channel Bool ← Std.Channel.new
  let continueTask ← UpgradableHandler.onContinue handler head |>.asTask

  BaseIO.chainTask continueTask fun
    | .ok v => discard <| continueChannel.send v
    | .error _ => discard <| continueChannel.send false

  let canContinue ← Selectable.one #[
    .case continueChannel.recvSelector pure,
    .case connectionContext.doneSelector (fun _ => pure false),
    .case (← Selector.sleep config.lingeringTimeout) (fun _ => pure false)
  ]

  let status := if canContinue then Status.«continue» else Status.expectationFailed
  return (machine.canContinue status, !canContinue)

/--
Injects a `Date` header into a response head if `Config.generateDate` is set
and the response does not already include one.
-/
private def prepareResponseHead (config : Config) (head : Response.Head) :
    Async Response.Head := do
  if config.generateDate ∧ ¬head.headers.contains Header.Name.date then
    let now ← Std.Time.DateTime.nowAt "UTC"
    return { head with
      headers := head.headers.insert Header.Name.date
        (Header.Value.ofString! now.toRFC822String) }
  else
    return head

/--
Applies a successful handler response to the machine.
-/
private def applyResponse
    {β : Type} [Body β]
    (config : Config) (machine : H1.Machine .receiving) (res : Response β)
    : Async (H1.Machine .receiving × Option β) := do
  let size ← Body.getKnownSize res.body

  let machineSized :=
    if let some knownSize := size
      then machine.setKnownSize knownSize
      else machine

  let responseHead ← prepareResponseHead config res.line
  let machineWithHead := machineSized.send responseHead
  if machineWithHead.writer.omitBody then
    if ¬(← Body.isClosed res.body) then
      Body.close res.body
    return (machineWithHead, none)
  else
    return (machineWithHead, some res.body)

/--
All mutable state carried through the connection processing loop.
-/
private structure ConnectionState (β : Type) where
  machine : H1.Machine .receiving
  requestStream : Body.Stream
  keepAliveTimeout : Option Millisecond.Offset
  currentTimeout : Millisecond.Offset
  headerTimeout : Option Timestamp
  response : Std.Channel (Except IO.Error (UpgradableResponse β))
  respStream : Option β
  requiresData : Bool
  expectData : Option Nat
  handlerDispatched : Bool
  pendingHead : Option Request.Head

/--
Outcome of processing one I/O event: keep looping, close the connection, or
leave the HTTP loop through the upgrade terminal state.
-/
private inductive LoopAction where
  | proceed
  | close
  | upgrade (head : Response.Head) (continuation : Upgraded → Async Unit)

/--
Processes all H1 events from a single machine step, updating the connection
state.
-/
private def processH1Events
    {σ β : Type} [UpgradableHandler σ] [Body β]
    (handler : σ) (config : Config) (connectionContext : CancellationContext)
    (events : Array (H1.Event .receiving))
    (state : ConnectionState β)
    : Async (ConnectionState β) := do

  let mut st := state

  for event in events do
    match event with
    | .needMoreData expect =>
      st := { st with requiresData := true, expectData := expect }

    | .needAnswer => pure ()

    | .endHeaders head =>
      st := { st with
        currentTimeout := config.lingeringTimeout
        keepAliveTimeout := none
        headerTimeout := none
        pendingHead := some head
      }

      if let some length := head.getSize true then
        Body.setKnownSize st.requestStream (some length)

    | .«continue» =>
      if let some head := st.pendingHead then
        let (newMachine, clearPending) ←
          handleContinueEvent handler st.machine head config connectionContext
        st := { st with machine := newMachine }
        if clearPending then
          st := { st with pendingHead := none }

    | .next =>
      if ¬(← Body.isClosed st.requestStream) then
        Body.close st.requestStream

      if let some res := st.respStream then
        if ¬(← Body.isClosed res) then
          Body.close res

      let newStream ← Body.mkStream

      st := { st with
        requestStream := newStream
        response := ← Std.Channel.new
        respStream := none
        keepAliveTimeout := some config.keepAliveTimeout.val
        currentTimeout := config.keepAliveTimeout.val
        headerTimeout := none
        handlerDispatched := false
      }

    | .failed err =>
      UpgradableHandler.onFailure handler (toString err)

      if ¬(← Body.isClosed st.requestStream) then
        Body.close st.requestStream

      st := { st with requiresData := false, pendingHead := none }
      break

    | .closeBody =>
      if ¬(← Body.isClosed st.requestStream) then
        Body.close st.requestStream

    | .close => pure ()

  return st

/--
Dispatches a pending request head to the handler if one is waiting.
-/
private def dispatchPendingRequest
    {σ : Type} [UpgradableHandler σ]
    (handler : σ) (extensions : Extensions) (connectionContext : CancellationContext)
    (state : ConnectionState (UpgradableHandler.ResponseBody σ))
    : Async (ConnectionState (UpgradableHandler.ResponseBody σ)) := do
  if let some line := state.pendingHead then
    let task ←
      UpgradableHandler.onRequest handler
        { line, body := state.requestStream, extensions } connectionContext
      |>.asTask

    BaseIO.chainTask task (discard ∘ state.response.send)
    return { state with pendingHead := none, handlerDispatched := true }
  else
    return state

/--
Attempts a single non-blocking receive from the body and feeds any available
chunk into the machine.
-/
private def tryDrainBody {β : Type} [Body β]
    (machine : H1.Machine .receiving) (body : β)
    : Async (H1.Machine .receiving × Option β) := do
  match ← Body.tryRecv body with
  | none => pure (machine, some body)
  | some (some chunk) => pure (machine.sendData #[chunk], some body)
  | some none =>
    if !(← Body.isClosed body) then Body.close body
    pure (machine.userClosedBody, none)

/--
Applies an ordinary handler response (or an upgrade fallback) to the state.
-/
private def applyNormalResponse
    {σ β : Type} [UpgradableHandler σ] [Body β]
    (handler : σ) (config : Config)
    (res : Response β) (state : ConnectionState β)
    : Async (ConnectionState β × LoopAction) := do
  if state.machine.failed then
    if ¬(← Body.isClosed res.body) then Body.close res.body
    return ({ state with handlerDispatched := false }, .proceed)
  else
    let (newMachine, newRespStream) ← applyResponse config state.machine res

    let (drainedMachine, drainedRespStream, shouldClose) ←
      match newRespStream with
      | none => pure (newMachine, none, false)
      | some body =>
        try
          let (machine, body) ← tryDrainBody newMachine body
          pure (machine, body, false)
        catch e =>
          UpgradableHandler.onFailure handler e
          pure (newMachine, some body, true)

    return ({ state with
      machine := drainedMachine
      handlerDispatched := false
      respStream := drainedRespStream }, if shouldClose then .close else .proceed)

/--
Checks whether a requested protocol switch can be honored in the current
connection state: the writer must not have committed a response, the head must
be informational, the peer must speak HTTP/1.1, and the request must carry no
unconsumed body bytes so the reader buffer contains only bytes that belong to
the next protocol. Server-side readers hold a bodyless request at
`.readBody (.fixed 0)` until the response completes, so that state is as safe
as `.complete`.
-/
private def canSwitchProtocols
    {β : Type} (state : ConnectionState β) (head : Response.Head) : Bool :=
  let readerDrained :=
    match state.machine.reader.state with
    | .complete => true
    | .readBody (.fixed 0) => true
    | _ => false
  state.machine.isWaitingMessage
    && head.status.isInformational
    && state.machine.reader.messageHead.version == .v11
    && readerDrained

/--
Processes a single async I/O event and updates the connection state.
-/
private def handleRecvEvent
    {σ β : Type} [UpgradableHandler σ] [Body β]
    (handler : σ) (config : Config)
    (event : Recv β) (state : ConnectionState β)
    : Async (ConnectionState β × LoopAction) := do

  match event with
  | .bytes (some bs) =>
    let mut st := state

    if st.keepAliveTimeout.isSome then
      st := { st with
        keepAliveTimeout := none
        headerTimeout := some <| (← Timestamp.now) + config.headerTimeout
      }

    return ({ st with machine := st.machine.feed bs }, .proceed)

  | .bytes none =>
    return ({ state with machine := state.machine.noMoreInput }, .proceed)

  | .responseBody (some chunk) =>
    return ({ state with machine := state.machine.sendData #[chunk] }, .proceed)

  | .responseBody none =>
    if let some res := state.respStream then
      if ¬(← Body.isClosed res) then Body.close res
    return ({ state with
      machine := state.machine.userClosedBody, respStream := none }, .proceed)

  | .bodyInterest interested =>
    if interested then
      let (newMachine, pulledChunk) := state.machine.pullBody
      let mut st := { state with machine := newMachine }

      if let some pulled := pulledChunk then
        try st.requestStream.send pulled.chunk pulled.incomplete
        catch e => UpgradableHandler.onFailure handler e
        if pulled.final then
          if ¬(← Body.isClosed st.requestStream) then
            Body.close st.requestStream

      return (st, .proceed)
    else
      return (state, .proceed)

  | .close => return (state, .close)

  | .timeout =>
    UpgradableHandler.onFailure handler "request header timeout"
    return ({ state with
      machine := state.machine.closeWithError .requestTimeout
      handlerDispatched := false }, .proceed)

  | .shutdown =>
    return ({ state with
      machine := state.machine.closeWithError .serviceUnavailable
      handlerDispatched := false }, .proceed)

  | .response (.error err) =>
    UpgradableHandler.onFailure handler err
    return ({ state with
      machine := state.machine.closeWithError .internalServerError
      handlerDispatched := false }, .proceed)

  | .response (.ok (.normal res)) =>
    applyNormalResponse handler config res state

  | .response (.ok (.upgrade head fallback continuation)) =>
    if state.machine.failed then
      if ¬(← Body.isClosed fallback.body) then Body.close fallback.body
      return ({ state with handlerDispatched := false }, .proceed)
    else if canSwitchProtocols state head then
      -- The fallback is unused; release its body before leaving the HTTP loop.
      if ¬(← Body.isClosed fallback.body) then Body.close fallback.body
      return ({ state with handlerDispatched := false }, .upgrade head continuation)
    else
      applyNormalResponse handler config fallback state

/--
Computes the active `PollSources` for the current connection state.
-/
private def buildPollSources
    {α β : Type} [Transport α]
    (socket : α) (connectionContext : CancellationContext) (state : ConnectionState β)
    : Async (PollSources α β) := do
  let requestBodyOpen ←
    if state.machine.canPullBody then pure !(← Body.isClosed state.requestStream)
    else pure false

  let requestBodyInterested ←
    if state.machine.canPullBody ∧ requestBodyOpen then state.requestStream.hasInterest
    else pure false

  let requestBody ←
    if state.machine.canPullBodyNow ∧ requestBodyOpen then pure (some state.requestStream)
    else pure none

  let pollSocket :=
    state.requiresData ∨ !state.handlerDispatched ∨ state.respStream.isSome ∨
    state.machine.writer.sentMessage ∨ (state.machine.canPullBody ∧ requestBodyInterested)

  return {
    socket := if pollSocket then some socket else none
    expect := state.expectData
    response := if state.handlerDispatched then some state.response else none
    responseBody := state.respStream
    requestBody := requestBody
    timeout := state.currentTimeout
    keepAliveTimeout := state.keepAliveTimeout
    headerTimeout := state.headerTimeout
    connectionContext := connectionContext
  }

/--
Performs the protocol switch after the HTTP loop reached the upgrade terminal
state.

Ordering guarantees (hyper-style):
1. The switching head is written through the machine's 1xx path and flushed
   together with any previously buffered output *before* the continuation runs.
2. The `Upgraded` stream replays bytes the HTTP reader had buffered past the
   request head, so no received byte is lost across the switch.

Ownership (Cowboy-style): the continuation is raced against server shutdown;
on shutdown the transport is closed to unblock it, and the connection task
always waits for the continuation to finish so teardown stays here.
-/
private def performUpgrade
    {α σ : Type} [Transport α] [UpgradableHandler σ]
    (socket : α) (handler : σ) (connectionContext : CancellationContext)
    (machine : H1.Machine .receiving)
    (head : Response.Head) (continuation : Upgraded → Async Unit) : Async Unit := do
  -- 1. Encode the informational head; `H1.Machine.send` writes 1xx heads
  -- directly into the output buffer without committing the writer.
  let (machine, output) := (machine.send head).takeOutput
  Transport.sendAll socket output.data

  -- 2. Hand over the reader's unconsumed bytes as the stream's preread.
  let input := machine.reader.input
  let preread := input.array.extract input.pos input.array.size
  let upgraded ← Upgraded.ofTransport socket preread

  -- 3. Run the continuation; completion or failure ends the connection.
  let done : Std.Channel (Except IO.Error Unit) ← Std.Channel.new
  let task ← (continuation upgraded).asTask
  BaseIO.chainTask task fun result => discard <| done.send result

  let finished ← Selectable.one #[
    .case done.recvSelector (fun r => pure (some r)),
    .case connectionContext.doneSelector (fun _ => pure none)
  ]

  match finished with
  | some (.ok ()) => pure ()
  | some (.error e) => UpgradableHandler.onFailure handler e
  | none =>
    -- Server shutdown: close the transport to unblock the continuation and
    -- wait for it, keeping teardown single-owned.
    Transport.close socket
    match ← Async.ofAsyncTask ((← done.recv).map Except.ok) with
    | .error e => UpgradableHandler.onFailure handler e
    | .ok () => pure ()

/--
Runs the main request/response processing loop for a single connection,
extended with the upgrade terminal state.
-/
private def handleUpgradable
    {α σ : Type} [Transport α] [UpgradableHandler σ]
    (connection : Connection α)
    (config : Config)
    (connectionContext : CancellationContext)
    (handler : σ) : Async Unit := do

  let _ : Body (UpgradableHandler.ResponseBody σ) := UpgradableHandler.responseBodyInstance

  let socket := connection.socket
  let initStream ← Body.mkStream

  let mut state : ConnectionState (UpgradableHandler.ResponseBody σ) := {
    machine := connection.machine
    requestStream := initStream
    keepAliveTimeout := some config.keepAliveTimeout.val
    currentTimeout := config.keepAliveTimeout.val
    headerTimeout := none
    response := ← Std.Channel.new
    respStream := none
    requiresData := false
    expectData := none
    handlerDispatched := false
    pendingHead := none
  }

  let mut pendingUpgrade : Option (Response.Head × (Upgraded → Async Unit)) := none

  while ¬state.machine.halted do

    -- Phase 1: advance the state machine and flush any output.
    let (newMachine, step) := state.machine.step
    state := { state with machine := newMachine }

    if step.output.size > 0 then
      try Transport.sendAll socket step.output.data
      catch e =>
        UpgradableHandler.onFailure handler e
        break

    -- Phase 2: process all events emitted by this step.
    state ← processH1Events handler config connectionContext step.events state

    -- Phase 3: dispatch any newly parsed request to the handler.
    state ← dispatchPendingRequest handler connection.extensions connectionContext state

    -- Phase 4: wait for the next IO event when any source needs attention.
    if state.requiresData ∨ state.handlerDispatched ∨ state.respStream.isSome ∨ state.machine.canPullBody then
      state := { state with requiresData := false }
      let sources ← buildPollSources socket connectionContext state
      let event ← pollNextEvent config handler sources
      let (newState, action) ← handleRecvEvent handler config event state
      state := newState
      match action with
      | .proceed => pure ()
      | .close => break
      | .upgrade head continuation =>
        pendingUpgrade := some (head, continuation)
        break

  -- Clean up HTTP-level streams.
  if ¬(← Body.isClosed state.requestStream) then
    Body.close state.requestStream

  if let some res := state.respStream then
    if ¬(← Body.isClosed res) then
      Body.close res

  -- Terminal state: either hand the connection to the upgrade continuation or
  -- close it. Either way the transport is torn down by the server.
  match pendingUpgrade with
  | some (head, continuation) =>
    try
      performUpgrade socket handler connectionContext state.machine head continuation
    finally
      Transport.close socket
  | none =>
    Transport.close socket

/--
Handles request/response processing for a single connection using an
`UpgradableHandler`. Upgrade-capable counterpart of `serveConnection`.
-/
def serveUpgradableConnection
    {t σ : Type} [Transport t] [UpgradableHandler σ]
    (client : t) (handler : σ)
    (config : Config) (extensions : Extensions := .empty) : ContextAsync Unit := do
  handleUpgradable (Connection.mk client { config := config.toH1Config } extensions)
    config (← ContextAsync.getContext) handler

end Std.Http.Server
