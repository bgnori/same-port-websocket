# same-port-websocket

RFC 6455 WebSocket for Lean 4's `Std.Http` — served on the **same port** as
your HTTP server, through a server-owned connection handoff (`Upgrade`).

Unlike implementations that run their own socket server next to the HTTP
server, this library extends the `Std.Http` connection loop with an upgrade
terminal state (`serveUpgradable`): the HTTP server validates the opening
handshake, writes `101 Switching Protocols`, and hands the *same connection*
to your WebSocket continuation. The server keeps owning the socket and its
teardown (Cowboy-style), so HTTP requests and WebSocket sessions share one
port, one accept loop, and one termination contract.

The module names deliberately live under `StdExt.*` / `Std.Http.*`: the code
is written as an extension proposal for the Lean standard library, so an
eventual upstreaming is a file rename.

## Status

- HTTP/1.1 upgrade, frame layer, message API (fragmentation, Ping→Pong,
  UTF-8 validation, close handshake): working, Autobahn-conformant
  (case classes 1–7, 9; `permessage-deflate` not implemented).
- A formally modelled connection-lifecycle layer (pure state machine with
  Lean-checked theorems, deterministic executors, real-TCP capability probes)
  is developed alongside; see the documentation.

## Quick start

```sh
lake build          # builds the library and the `wsecho` demo server
lake test           # lifecycle model, executors, TCP probes, end-to-end tests
.lake/build/bin/wsecho 8080
# → ws://127.0.0.1:8080/ws-echo/socket
```

Conformance:

```sh
python3 -m unittest discover -s tests -p 'test_ws_*.py'   # stdlib-only suites
bash tests/autobahn.sh                                     # original Autobahn|Testsuite (Docker)
```

## Documentation

Design, contracts, verification results, and the development ledger live in
[docs/](docs/README.md) (Japanese). Start with
[docs/README.md](docs/README.md); the current public API is described in
[docs/std-websocket-extension.md](docs/std-websocket-extension.md).

This library was extracted from
[bgnori/LeanWebStudy](https://github.com/bgnori/LeanWebStudy), where it is
exercised by a real web application.

## License

[Apache-2.0](LICENSE)
