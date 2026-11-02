/-
Extension proposal for `Std.Http.Server`: `serveUpgradable`, the accept loop
for upgrade-capable handlers. Mirrors `Std.Http.Server.serve` exactly, but
drives connections through `serveUpgradableConnection`.
-/
import Std.Http.Server
import StdExt.Http.Server.Connection

namespace Std.Http.Server

open Std.Async TCP

@[inline]
private def frameCancellation {α : Type} (s : Server) (releaseConnectionPermit : Bool := false)
    (action : ContextAsync α) : ContextAsync α := do
  s.activeConnections.atomically (modify (· + 1))
  try
    action
  finally
    if releaseConnectionPermit then
      if let some limit := s.connectionLimit then
        limit.release

    s.activeConnections.atomically do
      modify (· - 1)

      if (← get) = 0 ∧ (← s.context.isCancelled) then
        discard <| s.shutdownPromise.send ()

/--
Starts a new HTTP/1.1 server that supports connection upgrades on the given
socket address. Identical to `Std.Http.Server.serve` except that the handler
may answer `UpgradableResponse.upgrade` to take over the connection.
-/
def serveUpgradable {σ : Type} [UpgradableHandler σ]
    (addr : Net.SocketAddress)
    (handler : σ)
    (config : Config := {}) (backlog : UInt32 := 1024) : Async Server := do

  let server ← Socket.Server.mk
  server.bind addr
  server.listen backlog
  server.noDelay
  let localAddr ← server.getSockName

  let httpServer ← Server.new config (some localAddr)

  let runServer := do
    frameCancellation httpServer (action := do
      while true do
        let permitAcquired ←
          if let some limit := httpServer.connectionLimit then
            let permit ← limit.acquire
            await permit
            pure true
          else
            pure false

        let result ← Selectable.one #[
          .case (server.acceptSelector) (fun x => pure <| some x),
          .case (← ContextAsync.doneSelector) (fun _ => pure none)
        ]

        match result with
        | some client =>
          let extensions ← do
            match (← EIO.toBaseIO client.getPeerName) with
            | .ok addr => pure <| Extensions.empty.insert (Server.RemoteAddr.mk addr)
            | .error _ => pure Extensions.empty

          ContextAsync.background
            (frameCancellation httpServer (releaseConnectionPermit := permitAcquired)
              (action := do
                serveUpgradableConnection client handler config extensions))
        | none =>
          if permitAcquired then
            if let some limit := httpServer.connectionLimit then
              limit.release
          break
    )

  background (runServer httpServer.context)

  return httpServer

end Std.Http.Server
