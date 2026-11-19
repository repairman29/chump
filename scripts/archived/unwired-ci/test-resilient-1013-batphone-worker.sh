#!/usr/bin/env bash
# test-resilient-1013-batphone-worker.sh — RESILIENT-1013
#
# Validates that scripts/dispatch/worker.sh can pick + claim a gap purely
# from the shared gap API (GET /api/gaps/next + POST /api/gap/claim/:id)
# with NO local gap store — the "distributed workers, central queue" fix
# for the 2-core Oracle bottleneck. A node with just a checkout + creds +
# CHUMP_GAP_API_URL must be able to join the fleet.
#
# Strategy: extract the `remote_pick_and_claim_gap` function body out of
# worker.sh (rather than sourcing the whole script, which would run the
# live fleet loop) and exercise it against a tiny local mock HTTP server
# that stands in for the batphone gap API.

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "=== RESILIENT-1013 batphone worker (remote gap API) ==="
echo

# 1. worker.sh has the remote-picker function and is wired into the main pick block.
if grep -q "^remote_pick_and_claim_gap() {" "$WORKER"; then
    ok "worker.sh defines remote_pick_and_claim_gap()"
else
    fail "worker.sh missing remote_pick_and_claim_gap() — RESILIENT-1013 not implemented"
fi

if grep -qE 'CHUMP_GAP_API_URL:-.*\}.*\]\]; then' "$WORKER" && \
   grep -q 'remote_pick_and_claim_gap "\$remote_gap_json_file"' "$WORKER"; then
    ok "main pick loop branches on CHUMP_GAP_API_URL and calls the remote picker"
else
    fail "main pick loop does not branch to the remote picker on CHUMP_GAP_API_URL"
fi

if bash -n "$WORKER"; then
    ok "worker.sh syntax-clean"
else
    fail "worker.sh syntax error"
fi

# 2. Functional: extract the function body and drive it against a mock API.
start_line="$(awk '/^remote_pick_and_claim_gap\(\) \{/{print NR; exit}' "$WORKER")"
end_line="$(awk -v s="$start_line" 'NR>=s && /^}/{print NR; exit}' "$WORKER")"

if [[ -z "$start_line" || -z "$end_line" ]]; then
    fail "could not locate remote_pick_and_claim_gap() function boundaries"
else
    ok "extracted remote_pick_and_claim_gap() at lines $start_line-$end_line"

    TMPDIR_TEST="$(mktemp -d)"
    trap 'kill "${MOCK_PID:-0}" 2>/dev/null || true; rm -rf "$TMPDIR_TEST"' EXIT

    cat > "$TMPDIR_TEST/mock_api.py" <<'PYEOF'
import http.server, json, sys, threading

PORT = int(sys.argv[1])
claimed = {"count": 0}

class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/api/gaps/next"):
            self._send(200, {"gap": {"id": "RESILIENT-1013-MOCK", "title": "mock gap",
                                      "domain": "RESILIENT", "priority": "P2", "effort": "m"}})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.startswith("/api/gap/claim/"):
            claimed["count"] += 1
            self._send(200, {"gap_id": "RESILIENT-1013-MOCK", "status": "claimed"})
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        pass

srv = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
srv.serve_forever()
PYEOF

    MOCK_PORT=18913
    python3 "$TMPDIR_TEST/mock_api.py" "$MOCK_PORT" &
    MOCK_PID=$!
    sleep 0.5

    # Pull only the function body into an isolated harness (no `set -e`,
    # no fleet-loop side effects from sourcing the whole worker.sh).
    {
        echo '#!/usr/bin/env bash'
        echo 'log() { :; }'
        sed -n "${start_line},${end_line}p" "$WORKER"
    } > "$TMPDIR_TEST/fn.sh"
    chmod +x "$TMPDIR_TEST/fn.sh"

    out_file="$TMPDIR_TEST/gap.json"
    picked="$(
        CHUMP_GAP_API_URL="http://127.0.0.1:${MOCK_PORT}" \
        FLEET_PRIORITY_FILTER="P0,P1,P2" \
        FLEET_EFFORT_FILTER="xs,s,m" \
        FLEET_DOMAIN_FILTER="" \
        AGENT_ID="1" \
        CHUMP_SESSION_ID="test-session" \
        bash -c "source '$TMPDIR_TEST/fn.sh'; remote_pick_and_claim_gap '$out_file'"
    )"
    rc=$?

    if [[ "$rc" -eq 0 && "$picked" == "RESILIENT-1013-MOCK" ]]; then
        ok "remote picker returns the gap id claimed via the mock batphone API"
    else
        fail "remote picker did not return expected gap id (got '$picked', rc=$rc) — without RESILIENT-1013 this must fail since the function does not exist"
    fi

    if [[ -f "$out_file" ]] && grep -q "RESILIENT-1013-MOCK" "$out_file"; then
        ok "remote picker writes single-gap JSON to the output file for downstream consumers"
    else
        fail "remote picker did not write expected gap JSON to output file"
    fi

    kill "$MOCK_PID" 2>/dev/null || true
    trap - EXIT
    rm -rf "$TMPDIR_TEST"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
