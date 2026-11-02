/-
Extension proposal for `Std.Http.Server`: a connection-handoff (upgrade) API.

Design (see docs/application-study/websocket-risk-return-report.md, appendix A.5):
- A.3 (Warp `responseRaw`): the handler result type gains one extra constructor
  carrying "status line + headers + a continuation receiving a bidirectional
  stream", without breaking the `Request → Response` abstraction. Like Warp, an
  upgrade carries a fallback `Response` used when the switch cannot be honored.
- A.2 (hyper `OnUpgrade`): the server itself writes the 1xx head, and the
  continuation only starts after that write completed. The stream handed to the
  continuation embeds any bytes the HTTP reader already consumed ahead
  (preread), so "neither side reads the socket across the 101 boundary" is
  guaranteed by construction, not by caller discipline.
- Cowboy: the connection (and its teardown) stays owned by the server. The
  continuation never receives the raw socket and has no `close`; the server
  closes the transport when the continuation finishes or the server shuts down.
-/
import Std.Http.Server

namespace Std.Http.Server

open Std.Async

/--
A bidirectional byte stream handed over to an upgrade continuation after the
server wrote the informational (1xx) switching response.

The stream is transport-agnostic (it works for any `Transport`): it is
expressed in the server's abstract vocabulary rather than exposing the socket,
so the API survives transports where no "stealable" socket exists.

Bytes that the HTTP reader had already buffered past the request head are
replayed first by `recv`.
-/
structure Upgraded where
  private mk ::
  /-- Bytes received by the HTTP layer beyond the request head. -/
  private pending : IO.Ref ByteArray
  /-- Receives raw bytes from the underlying transport. -/
  private recvFn : UInt64 → Async (Option ByteArray)
  /-- Sends raw bytes through the underlying transport. -/
  private sendFn : Array ByteArray → Async Unit

namespace Upgraded

/--
Wraps a transport and the preread bytes into an `Upgraded` stream. The
transport type is erased so continuations do not depend on it.
-/
def ofTransport {t : Type} [Transport t] (socket : t) (preread : ByteArray) :
    BaseIO Upgraded := do
  return {
    pending := ← IO.mkRef preread
    recvFn := fun expected => Transport.recv socket expected
    sendFn := fun data => Transport.sendAll socket data }

/--
Receives the next chunk of bytes. Bytes already read ahead by the HTTP parser
are returned first. Returns `none` when the peer closed the connection.
-/
def recv (self : Upgraded) (maxBytes : UInt64 := 16384) : Async (Option ByteArray) := do
  let buffered ← self.pending.modifyGet fun bytes => (bytes, ByteArray.empty)
  if buffered.size > 0 then
    return some buffered
  self.recvFn maxBytes

/--
Sends bytes to the peer.
-/
def send (self : Upgraded) (data : ByteArray) : Async Unit :=
  self.sendFn #[data]

/--
Sends multiple byte arrays to the peer.
-/
def sendAll (self : Upgraded) (data : Array ByteArray) : Async Unit :=
  self.sendFn data

end Upgraded

/--
Handler result for upgrade-capable servers. This extends the plain
`Response β` result with one terminal alternative, mirroring how Warp extends
WAI's `Response` with `responseRaw`.
-/
inductive UpgradableResponse (β : Type) where
  /--
  An ordinary HTTP response; the connection loop proceeds exactly as today
  (streaming body, keep-alive, pipelining).
  -/
  | normal (response : Response β)

  /--
  Requests a protocol switch. `head` must carry an informational status
  (typically `101 Switching Protocols`) plus the switching headers; the server
  writes it and only then invokes `continuation` with the byte stream.

  `fallback` is sent instead when the switch cannot be honored (HTTP/1.0 peer,
  non-1xx `head`, or a connection state that already committed a response) —
  the same contract as Warp's `responseRaw` fallback argument.

  The upgrade is a terminal state of the connection loop: the connection never
  returns to HTTP request processing, and the server closes the transport when
  the continuation returns or throws.
  -/
  | upgrade (head : Response.Head) (fallback : Response β)
      (continuation : Upgraded → Async Unit)

/--
Upgrade-capable counterpart of `Handler`. The only difference is that
`onRequest` may answer with `UpgradableResponse.upgrade`.
-/
class UpgradableHandler (σ : Type) where
  /--
  Concrete body type produced by `onRequest`, as in `Handler.ResponseBody`.
  -/
  ResponseBody : Type := Body.Any

  /--
  Body instance required by the connection loop for the response body type.
  -/
  [responseBodyInstance : Body ResponseBody]

  /--
  Called for each incoming HTTP request.
  -/
  onRequest (self : σ) (request : Request Body.Stream) :
    ContextAsync (UpgradableResponse ResponseBody)

  /--
  Called when an I/O or transport error occurs, including errors thrown by an
  upgrade continuation. Notification only; the connection closes regardless.
  -/
  onFailure (self : σ) (error : IO.Error) : Async Unit :=
    pure ()

  /--
  Called when a request includes an `Expect: 100-continue` header, as in
  `Handler.onContinue`.
  -/
  onContinue (self : σ) (request : Request.Head) : Async Bool :=
    pure true

/--
Every plain `Handler` is an `UpgradableHandler` that never upgrades, so
existing handlers work with the upgrade-capable server loop unchanged.
-/
instance (priority := low) {σ : Type} [inst : Handler σ] : UpgradableHandler σ where
  ResponseBody := inst.ResponseBody
  responseBodyInstance := inst.responseBodyInstance
  onRequest self request := .normal <$> Handler.onRequest self request
  onFailure := Handler.onFailure
  onContinue := Handler.onContinue

end Std.Http.Server
