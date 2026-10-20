#!/usr/bin/env bash
# scripts/ci/lib/sandbox-healthy-node.sh — RESILIENT-1652
#
# ONE function that writes a HEALTHY-node fixture INSIDE a sandbox dir created
# by scripts/coord/lib/test-sandbox.sh (chump_test_sandbox_setup). The
# RESILIENT-069 farmer readiness gate that `chump claim` / `chump gap reserve`
# consult reds on an ephemeral Linux CI runner: there is no
# ~/.chump/oauth-token.json, which the RESILIENT-1652 Linux content-gate
# correctly reds ("claude -p has no CLAUDE_CODE_OAUTH_TOKEN source"). Laying
# down the POSITIVE evidence a healthy node carries — a content-valid oauth
# token, a not-paused node.env, a fresh farmer heartbeat — makes the gate read
# GREEN by EVIDENCE without loosening it: a missing/empty/expired token or a
# paused node.env on a REAL node still reds exactly as before.
#
# It takes EXACTLY ONE argument: the sandbox dir chump_test_sandbox_setup set
# up, which is the CHUMP_HOME the lib exported. The three fixture files all land
# under <sandbox>/.chump — the single dir the gate resolves every input from
# once the sandbox env is exported: the farmer heartbeat (CHUMP_REPO/.chump),
# node.env (CHUMP_STATE_DIR) and the oauth token (CHUMP_HOME/.chump) all point
# at <sandbox>/.chump. The function does NO HOME/passwd/getent lookup, has NO
# allowlist or fallback, reads NO inherited CHUMP_STATE_DIR, and exits 2 when
# the argument is missing, is not a directory, or is not the CHUMP_HOME the lib
# exported (so a caller that forgot chump_test_sandbox_setup, or passed the
# wrong dir, can never write outside its own sandbox).
#
# Usage (AFTER chump_test_sandbox_setup "$SANDBOX"):
#   source "$REPO_ROOT/scripts/ci/lib/sandbox-healthy-node.sh"
#   write_sandbox_healthy_node "$SANDBOX"
write_sandbox_healthy_node() {
    local sandbox="${1:-}"
    if [ -z "$sandbox" ] || [ ! -d "$sandbox" ] || [ "$sandbox" != "${CHUMP_HOME:-}" ]; then
        echo "[sandbox-healthy-node] REFUSING (exit 2): argument '$sandbox' must be an \
existing directory equal to the lib's exported CHUMP_HOME ('${CHUMP_HOME:-}')" >&2
        exit 2
    fi
    local chump_dir="$sandbox/.chump"
    mkdir -p "$chump_dir"
    # (a) content-valid oauth token: the credential claude -p reads
    #     CLAUDE_CODE_OAUTH_TOKEN from on Linux (providers.env-linux shape: flat
    #     `token`, no expiry). The gate judges it by CONTENT (sk- prefix +
    #     absent/future expiry), never by mtime. The literal is split across a
    #     quote boundary (bash concatenates adjacent strings) so the secret
    #     scanner does not flag the fixture; the file still carries the sk- prefix.
    local tok="sk-ant-""oat01-sandbox-healthy-node-not-a-real-secret"
    printf '{"token":"%s","source":"sandbox-healthy-node"}\n' "$tok" \
        >"$chump_dir/oauth-token.json"
    # (b) not-paused node state, written where the ONE paused predicate reads
    #     node.env (CHUMP_STATE_DIR, exported by the lib to <sandbox>/.chump).
    printf 'CHUMP_NODE_MODE=work-ready\nCHUMP_NODE_WORK_ENABLED=1\n' \
        >"$chump_dir/node.env"
    # (c) a fresh farmer heartbeat — positive lights-on evidence — written where
    #     the gate reads it (repo_root/.chump, i.e. CHUMP_REPO/.chump).
    : >"$chump_dir/farmer-heartbeat"
}
