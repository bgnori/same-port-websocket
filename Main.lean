/-
`wsecho`: the minimal echo server targeted by the protocol conformance tests
(tests/test_ws_std.py, tests/test_ws_autobahn.py) and by the Autobahn|Testsuite
runs (tools/autobahn/).

Endpoints:
- `GET /health` — 200, readiness probe
- `GET /ws-echo/socket` — WebSocket echo over the shipped message API
  (`WebSocket.upgrade`); same-origin browser policy, non-browser clients
  (no Origin header) allowed
- `GET /ws/socket` — WebSocket echo over the lifecycle-model path
  (`Lifecycle.Upgrade.upgrade`), single-frame messages only

Usage: `wsecho <port> [maxMessageBytes]`. The optional second argument raises
the frame/message limits for the full-size Autobahn run (tools/autobahn/).
-/
import StdExt
import StdExt.Http.WebSocket.LifecycleUpgrade

open Std.Http
open Std.Http.Server

structure EchoHandler where
  httpPort : UInt16
  config : WebSocket.Config

/-- Echo every data message until the peer closes. -/
def wsEchoLoop (socket : WebSocket.WebSocket) : Std.Async.Async Unit := do
  let mut running := true
  while running do
    match ← socket.recv with
    | some (.text content) => socket.sendText content
    | some (.binary content) => socket.sendBinary content
    | none => running := false

/-- Browser requests must come from this server's own origin; non-browser
clients (no Origin header) are allowed. -/
def EchoHandler.echoOrigin (self : EchoHandler) : Option String → Bool
  | none => true
  | some origin =>
    origin == s!"http://127.0.0.1:{self.httpPort}" ||
      origin == s!"http://localhost:{self.httpPort}"

def textResponse (status : Status) (message : String) :
    Std.Async.Async (Response Body.Any) := do
  let body ← Body.Full.ofString (message ++ "\n")
  return ((Response.new.status status
    |>.header! "Content-Type" "text/plain; charset=utf-8"
    |>.body body : Response Body.Full) : Response Body.Any)

instance : UpgradableHandler EchoHandler where
  ResponseBody := Body.Any
  onRequest self request := do
    match toString request.line.uri.path with
    | "/health" => .normal <$> textResponse .ok "ok"
    | "/ws-echo/socket" =>
      WebSocket.upgrade request.line wsEchoLoop
        { config := self.config, checkOrigin := self.echoOrigin }
    | "/ws/socket" =>
      WebSocket.Lifecycle.Upgrade.upgrade request.line
        (options := { config := self.config, checkOrigin := self.echoOrigin })
    | _ => .normal <$> textResponse .notFound "not found"
  onFailure _ error := IO.eprintln s!"transport failure: {error}"

def main (args : List String) : IO Unit := do
  let (port, maxBytes?) ← match args with
    | [port] => pure (port, none)
    | [port, maxBytes] => pure (port, some maxBytes)
    | _ => throw (IO.userError "usage: wsecho <port> [maxMessageBytes]")
  let some port := port.toNat?
    | throw (IO.userError "port must be an integer")
  let config : WebSocket.Config ← match maxBytes? with
    | none => pure {}
    | some raw =>
      match raw.toNat? with
      | some n => pure { maxFrameBytes := n, maxMessageBytes := n }
      | none => throw (IO.userError "maxMessageBytes must be an integer")
  Std.Async.Async.block do
    let server ← serveUpgradable
      (.v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port := port.toUInt16 })
      (EchoHandler.mk port.toUInt16 config)
    IO.println s!"wsecho listening on http://127.0.0.1:{port}"
    server.waitShutdown
