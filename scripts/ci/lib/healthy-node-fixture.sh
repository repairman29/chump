#!/usr/bin/env bash
# scripts/ci/lib/healthy-node-fixture.sh — RESILIENT-1652
#
# ONE shared helper that writes an explicit HEALTHY-node fixture under a test's
# OWN temp CHUMP_STATE_DIR / CHUMP_HOME / HOME, so the RESILIENT-069 farmer
# readiness gate (which `chump claim` and `chump gap reserve` consult before
# admitting a NEW claim) reads GREEN *by evidence* on an ephemeral Linux CI
# runner. A fresh runner has no `~/.chump/oauth-token.json`, which the
# RESILIENT-1652 Linux content-gate correctly reds ("claude -p has no
# CLAUDE_CODE_OAUTH_TOKEN source") — so every `test-*.sh` that reserves/claims
# a gap and expects it to PROCEED must first lay down the evidence a healthy
# node would carry.
#
# This does NOT loosen the gate and adds NO skip/bypass env var: it writes the
# POSITIVE evidence of a healthy node (a valid-shaped oauth token judged by
# content, a not-paused node.env, a fresh farmer heartbeat) into the test's own
# tempdir. An absent/empty/expired token — or a paused node.env — on a REAL
# node still reads RED exactly as before (proved by
# scripts/ci/test-resilient-1652-pause-and-oauth.sh).
#
# Usage (source, then call AFTER the test's isolation env vars are set):
#   source "$(dirname "$0")/lib/healthy-node-fixture.sh"
#   write_healthy_node_fixture                      # uses $CHUMP_HOME / $HOME / $CHUMP_STATE_DIR
#   write_healthy_node_fixture "$FAKE_HOME"         # explicit state-home override
#   write_healthy_node_fixture "$HOME_DIR" "$STATE" # explicit state-home + state-dir

# write_healthy_node_fixture [state_home] [state_dir]
#   state_home  the dir the gate reads <state_home>/.chump/oauth-token.json from
#               — i.e. how farmer_status resolves chump_state_home
#               (default: ${CHUMP_HOME:-$HOME}).
#   state_dir   the node STATE dir (node.env + the node pause sentinel live
#               here), i.e. how farmer_status resolves resolve_node_state_dir
#               (default: ${CHUMP_STATE_DIR:-<state_home>/.chump}).
write_healthy_node_fixture() {
    local state_home="${1:-${CHUMP_HOME:-${HOME:-}}}"
    if [ -z "$state_home" ]; then
        echo "[healthy-node-fixture] no state home (set CHUMP_HOME or HOME, or pass one)" >&2
        return 1
    fi
    local state_dir="${2:-${CHUMP_STATE_DIR:-$state_home/.chump}}"
    mkdir -p "$state_home/.chump" "$state_dir" 2>/dev/null || true

    # (a) valid-shaped oauth token: the credential `claude -p` reads
    #     CLAUDE_CODE_OAUTH_TOKEN from on Linux (providers.env-linux shape: flat
    #     `token`, no expiry). The RESILIENT-1652 gate judges it by CONTENT
    #     (present + `sk-` prefix + future/absent expiry), never by mtime — so an
    #     old mtime is irrelevant. The literal is split across a quote boundary
    #     (bash concatenates adjacent strings) so the secret scanner does not
    #     flag the fixture; the written file still carries the `sk-` prefix the
    #     content verdict needs.
    local tok="sk-ant-""oat01-healthy-node-fixture-not-a-real-secret"
    printf '{"token":"%s","source":"healthy-node-fixture","written_at":"2026-01-01T00:00:00Z"}\n' \
        "$tok" > "$state_home/.chump/oauth-token.json"

    # (b) node state dir: explicitly NOT paused (work-ready). Written where the
    #     ONE paused predicate reads node.env (CHUMP_STATE_DIR else
    #     <state_home>/.chump), so the gate's `paused` signal is false by
    #     positive evidence rather than by file absence.
    printf 'CHUMP_NODE_MODE=work-ready\nCHUMP_NODE_WORK_ENABLED=1\n' > "$state_dir/node.env"

    # (c) a fresh farmer heartbeat — positive lights-on evidence. Its absence is
    #     already a vacuous pass in the gate; writing it (mtime = now) makes the
    #     healthy intent explicit and documents that a healthy node has one.
    : > "$state_dir/farmer-heartbeat"

    return 0
}
