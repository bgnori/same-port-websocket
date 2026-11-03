# Autobahn|Testsuite runner for the StdExt WebSocket echo endpoint

[Autobahn|Testsuite](https://github.com/crossbario/autobahn-testsuite) is the
de-facto WebSocket protocol compatibility suite. Upstream distributes it only
as a Docker image (the `wstest` tool itself is Python 2), so it cannot run in
environments without Docker — such as this repository's devcontainer and the
current CI. Two complementary layers cover compatibility:

1. **`tests/test_ws_autobahn.py`** — a standard-library reimplementation of the
   representative behaviour of Autobahn case classes 1–7 and 9 against
   `/ws-echo/socket`. Runs everywhere Python 3 runs, including CI:

   ```sh
   lake build leanwebstudy
   python3 -m unittest discover -s tests -p 'test_ws_autobahn.py'
   ```

2. **This directory** — configuration for a run of the original suite where
   Docker is available:

   ```sh
   bash tests/autobahn.sh          # starts the server on port 8090 and runs wstest
   # open reports/ws-echo/index.html
   ```

## Excluded cases and why

| Cases | Reason |
|---|---|
| 9.1.4–9.1.6, 9.2.4–9.2.6, 9.3.*, 9.4.* | Payloads of 4–16 MiB exceed the endpoint's deliberate 1 MiB `Config.maxFrameBytes`/`maxMessageBytes` default (D4); the server correctly answers `1009 message too big`, which `wstest` scores as a failure rather than a policy. Raise the limits in `WebSocket.Config` if a full-size run is wanted. |
| 12.*, 13.* | `permessage-deflate` compression is not implemented (out of scope; docs/std-websocket/websocket-prototype-results.md §4). |

The `exclude-cases` above are a size *policy*, not a protocol gap: the 1 MiB
boundary itself is covered (case 9.1.3/9.2.3 at exactly 1 MiB pass, and
`tests/test_ws_autobahn.py` additionally asserts the `1009` close for one byte
over the limit).
