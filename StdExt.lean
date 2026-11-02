/-
`StdExt`: extension proposals for the Lean standard library, developed in this
repository so they can be exercised against a real application before being
proposed upstream.

- `StdExt.Http.Server.*` — a connection-handoff (upgrade) API for
  `Std.Http.Server`, designed after the survey in
  docs/application-study/websocket-risk-return-report.md (appendix A).
- `StdExt.Http.WebSocket*` — an RFC 6455 WebSocket implementation layered on
  the handoff API.

The code lives in the `Std.Http` namespaces it extends; only the *module*
names carry the `StdExt` prefix, so upstreaming is a file rename.
-/
import StdExt.Http.Server.Upgrade
import StdExt.Http.Server.Connection
import StdExt.Http.Server.Serve
import StdExt.Http.WebSocket.Crypto
import StdExt.Http.WebSocket.Frame
import StdExt.Http.WebSocket.Connection
import StdExt.Http.WebSocket
