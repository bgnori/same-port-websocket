#!/usr/bin/env bash
# Runs the original Autobahn|Testsuite (Docker required) against the StdExt
# WebSocket echo endpoint. Without Docker, use the stdlib conformance suite:
#   python3 -m unittest discover -s tests -p 'test_ws_autobahn.py'
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8090
command -v docker >/dev/null || {
  echo "docker is required for the original Autobahn|Testsuite." >&2
  echo "Run the stdlib suite instead: python3 -m unittest discover -s tests -p 'test_ws_autobahn.py'" >&2
  exit 1
}

lake build leanwebstudy
.lake/build/bin/leanwebstudy "$PORT" &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT

for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

mkdir -p reports
docker run --rm --network=host \
  -v "$PWD/tools/autobahn:/config:ro" \
  -v "$PWD/reports:/reports" \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /config/fuzzingclient.json

echo "Autobahn report: reports/ws-echo/index.html"
