/-
Extension proposal for `Std.Http`: WebSocket upgrade API (RFC 6455 §4).

The ergonomic entry point is `WebSocket.upgrade`: given a request head and a
connection callback, it validates the opening handshake and produces an
`UpgradableResponse` — either `.upgrade` with the `101 Switching Protocols`
head and a continuation that wraps the handed-over byte stream into a
`WebSocket`, or a `.normal` error response when the handshake is invalid. This
mirrors axum's `WebSocketUpgrade.on_upgrade` layered over the generic handoff
primitive, as proposed in the risk/return report (appendix A.5).
-/
import StdExt.Http.Server.Upgrade
import StdExt.Http.Server.Connection
import StdExt.Http.Server.Serve
import StdExt.Http.WebSocket.Crypto
import StdExt.Http.WebSocket.Frame
import StdExt.Http.WebSocket.Connection

namespace Std.Http.WebSocket

open Std.Async
open Std.Http.Server (Upgraded UpgradableResponse)

/--
The handshake GUID fixed by RFC 6455 §1.3.
-/
def handshakeGuid : String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

/--
Computes the `Sec-WebSocket-Accept` value for a `Sec-WebSocket-Key`.
-/
def acceptKey (key : String) : String :=
  Internal.base64Encode (Internal.sha1 (key ++ handshakeGuid).toUTF8)

/--
Reasons the opening handshake can be rejected.
-/
inductive HandshakeError where
  /-- The request method is not GET. -/
  | methodNotAllowed
  /-- The `Upgrade` header is missing or does not contain `websocket`. -/
  | missingUpgrade
  /-- The `Connection` header does not contain the `upgrade` token. -/
  | missingConnectionUpgrade
  /-- `Sec-WebSocket-Version` is not `13`. -/
  | unsupportedVersion
  /-- `Sec-WebSocket-Key` is missing or not a 16-byte Base64 value. -/
  | invalidKey
  /-- The `Origin` header was rejected by the caller's policy. -/
  | originRejected
deriving Repr, BEq

/--
Case-insensitively checks whether a comma-separated header value contains a
token.
-/
private def hasToken (value : String) (token : String) : Bool :=
  value.splitOn "," |>.any fun part =>
    part.trimAscii.toString.toLower == token

/--
Returns a header value as a string, if present.
-/
private def headerValue? (headers : Headers) (name : String) : Option String := do
  let name ← Header.Name.ofString? name
  return toString (← headers.get? name)

/--
Validates the client's opening handshake (RFC 6455 §4.2.1) and returns the
`Sec-WebSocket-Key` on success. Pure, so policies can be unit-tested.
-/
def checkHandshake (request : Request.Head)
    (checkOrigin : Option String → Bool := fun _ => true) :
    Except HandshakeError String := do
  if request.method != .get then
    throw .methodNotAllowed
  let upgradeHeader := headerValue? request.headers "upgrade"
  unless upgradeHeader.any (hasToken · "websocket") do
    throw .missingUpgrade
  let connectionHeader := headerValue? request.headers "connection"
  unless connectionHeader.any (hasToken · "upgrade") do
    throw .missingConnectionUpgrade
  unless headerValue? request.headers "sec-websocket-version" == some "13" do
    throw .unsupportedVersion
  let some key := headerValue? request.headers "sec-websocket-key"
    | throw .invalidKey
  -- A Base64 encoding of 16 bytes is always 24 characters ending in "==".
  unless key.length == 24 do
    throw .invalidKey
  unless checkOrigin (headerValue? request.headers "origin") do
    throw .originRejected
  return key

/--
Builds the `101 Switching Protocols` response head for a validated key.
-/
def switchingProtocolsHead (key : String) : Response.Head := {
  status := .switchingProtocols
  headers := Headers.empty
    |>.insert! "Upgrade" "websocket"
    |>.insert! "Connection" "Upgrade"
    |>.insert! "Sec-WebSocket-Accept" (acceptKey key)
}

/--
Options for `WebSocket.upgrade`.
-/
structure UpgradeOptions where
  /-- Connection limits passed to the resulting `WebSocket`. -/
  config : Config := {}
  /--
  Origin policy: receives the raw `Origin` header (or `none` when absent, e.g.
  for non-browser clients) and decides whether to accept the handshake.
  -/
  checkOrigin : Option String → Bool := fun _ => true

/--
Builds a plain-text error response.
-/
private def textResponse (status : Status) (message : String)
    (extraHeaders : List (String × String) := []) : Async (Response Body.Any) := do
  let body ← Body.Full.ofString (message ++ "\n")
  let builder := Response.new.status status
    |>.header! "Content-Type" "text/plain; charset=utf-8"
  let builder := extraHeaders.foldl (fun b (k, v) => b.header! k v) builder
  return ((builder.body body : Response Body.Full) : Response Body.Any)

/--
The HTTP error response reported to the client for a rejected handshake.
-/
def HandshakeError.response : HandshakeError → Async (Response Body.Any)
  | .methodNotAllowed =>
    textResponse .methodNotAllowed "WebSocket handshake requires GET" [("Allow", "GET")]
  | .missingUpgrade =>
    textResponse .badRequest "missing `Upgrade: websocket` header"
  | .missingConnectionUpgrade =>
    textResponse .badRequest "missing `Connection: upgrade` header"
  | .unsupportedVersion =>
    textResponse .upgradeRequired "unsupported WebSocket version"
      [("Sec-WebSocket-Version", "13")]
  | .invalidKey =>
    textResponse .badRequest "missing or invalid `Sec-WebSocket-Key` header"
  | .originRejected =>
    textResponse .forbidden "origin not allowed"

/--
Validates the opening handshake and produces the handler answer.

On success the answer is `UpgradableResponse.upgrade`: the server writes the
`101 Switching Protocols` head and then invokes `onConnect` with a `WebSocket`
over the handed-over byte stream. When `onConnect` returns or throws, a best-
effort close frame is sent and the server tears the connection down.

On failure the answer is a `.normal` HTTP error response describing the
problem.
-/
def upgrade (request : Request.Head) (onConnect : WebSocket → Async Unit)
    (options : UpgradeOptions := {}) :
    Async (UpgradableResponse Body.Any) := do
  match checkHandshake request options.checkOrigin with
  | .error error =>
    return .normal (← error.response)
  | .ok key =>
    let fallback ← textResponse .badRequest "connection cannot be upgraded"
    return .upgrade (switchingProtocolsHead key) fallback fun upgraded => do
      let socket ← WebSocket.ofUpgraded upgraded options.config
      try
        onConnect socket
      finally
        -- Idempotent: a no-op if the closing handshake already happened.
        try socket.close 1000 catch _ => pure ()

end Std.Http.WebSocket
