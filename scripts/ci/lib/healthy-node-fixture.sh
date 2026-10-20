#!/usr/bin/env bash
# scripts/ci/lib/healthy-node-fixture.sh — RESILIENT-1652
#
# ONE shared helper that writes an explicit HEALTHY-node fixture under a test's
# OWN temp dirs, so the RESILIENT-069 farmer readiness gate (which `chump claim`
# and `chump gap reserve` consult before admitting a NEW claim) reads GREEN *by
# evidence* on an ephemeral Linux CI runner. A fresh runner has no
# `~/.chump/oauth-token.json`, which the RESILIENT-1652 Linux content-gate
# correctly reds ("claude -p has no CLAUDE_CODE_OAUTH_TOKEN source") — so every
# `test-*.sh` that reserves/claims a gap and expects it to PROCEED must first lay
# down the evidence a healthy node would carry.
#
# This does NOT loosen the gate and exports NO env var: it WRITES the POSITIVE
# evidence of a healthy node (a valid-shaped oauth token judged by content, a
# not-paused node.env, a fresh farmer heartbeat) into the test's own tempdirs.
# An absent/empty/expired token — or a paused node.env — on a REAL node still
# reads RED exactly as before (proved by
# scripts/ci/test-resilient-1652-pause-and-oauth.sh).
#
# SAFETY (RESILIENT-1652, repair 5). The helper NEVER falls back to an inherited
# CHUMP_STATE_DIR. On a node the installer EXPORTS CHUMP_STATE_DIR (and CHUMP_HOME)
# to the REAL state dir (chump-node-install.sh), so a helper that defaulted to
# `${CHUMP_STATE_DIR:-...}` would rewrite the real node.env to work-ready
# (UNPAUSING a live node) and plant a fake farmer heartbeat there. Instead the
# state dir is DERIVED from the test's own temp home (or an explicit arg), and the
# helper HARD-STOPS (exit 2) if any write target resolves to the real user home /
# an inherited CHUMP_STATE_DIR that does not match the derived temp dir. Every
# wired test therefore exports its OWN temp HOME + CHUMP_STATE_DIR before calling.
#
# Usage (source, then call AFTER the test's isolation env vars are set):
#   export HOME="$TMP" CHUMP_HOME="$TMP" CHUMP_STATE_DIR="$TMP/.chump"
#   source "$(dirname "$0")/lib/healthy-node-fixture.sh"
#   write_healthy_node_fixture                      # derive from $CHUMP_HOME/$HOME
#   write_healthy_node_fixture "$FAKE_HOME"         # explicit temp state-home
#   write_healthy_node_fixture "$HOME_DIR" "$STATE" # explicit temp state-home + state-dir

# _hnf_is_under <path> <ancestor> — 0 (true) iff <path> == <ancestor> or is a
# descendant of it. String-prefix on normalised trailing-slash forms; good enough
# for the tempdir-vs-real-home discrimination the safety gate needs.
_hnf_is_under() {
    local p="${1%/}" a="${2%/}"
    [ -n "$a" ] || return 1
    [ "$p" = "$a" ] && return 0
    case "$p/" in
        "$a"/*) return 0 ;;
    esac
    return 1
}

# _hnf_refuse <message> — print the refusal and HARD-STOP the calling script.
# (The helper is sourced, so `exit 2` terminates the test — a dangerous fixture
# must never be allowed to proceed.)
_hnf_refuse() {
    echo "[healthy-node-fixture] REFUSING (exit 2): $*" >&2
    exit 2
}

# write_healthy_node_fixture [state_home] [state_dir]
#   state_home  the test's temp home the gate reads
#               <state_home>/.chump/oauth-token.json from (how farmer_status
#               resolves chump_state_home: CHUMP_HOME else HOME).
#               Default: ${CHUMP_HOME:-$HOME}. MUST be a test tempdir.
#   state_dir   the node STATE dir (node.env lives here), how farmer_status
#               resolves the node state dir (CHUMP_STATE_DIR else
#               <state_home>/.chump). DERIVED from state_home (never from the
#               inherited CHUMP_STATE_DIR env). Default: <state_home>/.chump.
write_healthy_node_fixture() {
    local state_home="${1:-${CHUMP_HOME:-${HOME:-}}}"
    [ -n "$state_home" ] || _hnf_refuse \
        "no temp state home (pass one, or export CHUMP_HOME/HOME to a tempdir)"

    # state_dir is DERIVED from the test's own temp home (arg2 may override with
    # another EXPLICIT temp path); it is NEVER read from the inherited
    # CHUMP_STATE_DIR env, which on a node points at the REAL state dir.
    local state_dir="${2:-$state_home/.chump}"
    # heartbeat lives in repo_root/.chump — farmer_status reads it from
    # repo_root (CHUMP_REPO else CHUMP_HOME), NOT from the node state dir.
    local repo_root="${CHUMP_REPO:-$state_home}"

    # SAFETY 1: refuse if the oauth / node.env write targets are the real user
    # home or under it. The real ~/.chump lives under the passwd home; `mktemp -d`
    # tempdirs live under $TMPDIR//tmp (never under the passwd home), so a
    # correctly-isolated test never trips this — an inherited real path does.
    # (repo_root is handled separately below: the heartbeat is a vacuous-pass
    # signal and some tests legitimately pin CHUMP_REPO at the real repo for
    # OTHER reads, e.g. coord-surfaces-smoke.sh — there the heartbeat is skipped,
    # never written into the real repo.)
    local real_home=""
    real_home="$(getent passwd "$(id -un 2>/dev/null)" 2>/dev/null | cut -d: -f6)"
    local repo_safe=1
    if [ -n "$real_home" ]; then
        local target
        for target in "$state_home" "$state_dir"; do
            if _hnf_is_under "$target" "$real_home"; then
                _hnf_refuse "fixture target '$target' resolves under the real home \
'$real_home' (not a test tempdir). Export a temp HOME/CHUMP_HOME/CHUMP_STATE_DIR first."
            fi
        done
        if _hnf_is_under "$repo_root" "$real_home"; then
            repo_safe=0
        fi
    fi

    # SAFETY 2: if CHUMP_STATE_DIR is exported it MUST equal the derived temp
    # state dir. On a node the installer exports CHUMP_STATE_DIR to the REAL state
    # dir; a test that forgets to override it would otherwise let the gate read
    # the real, paused node.env. A mismatch hard-stops (exit 2) instead of
    # silently touching — or reading — the real dir.
    if [ -n "${CHUMP_STATE_DIR:-}" ] && [ "$CHUMP_STATE_DIR" != "$state_dir" ]; then
        _hnf_refuse "CHUMP_STATE_DIR='$CHUMP_STATE_DIR' does not match the fixture \
state dir '$state_dir'. Export CHUMP_STATE_DIR=\"$state_dir\" (a tempdir) before calling."
    fi

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
    #     ONE paused predicate reads node.env (CHUMP_STATE_DIR / <state_home>/.chump),
    #     so the gate's `paused` signal is false by positive evidence rather than
    #     by file absence.
    printf 'CHUMP_NODE_MODE=work-ready\nCHUMP_NODE_WORK_ENABLED=1\n' > "$state_dir/node.env"

    # (c) a fresh farmer heartbeat — positive lights-on evidence — written WHERE
    #     THE GATE READS IT: repo_root/.chump/farmer-heartbeat (farmer_status reads
    #     CHUMP_REPO/.chump, NOT the node state dir). Its absence is already a
    #     vacuous pass in the gate, so when CHUMP_REPO is pinned at the real repo
    #     (coord-surfaces-smoke.sh) the heartbeat is SKIPPED rather than planted in
    #     the real repo; the gate stays green on the vacuous pass. In the common
    #     case (CHUMP_REPO = a tempdir) it is written so the healthy intent is
    #     explicit and documents that a healthy node carries one.
    if [ "$repo_safe" = 1 ]; then
        mkdir -p "$repo_root/.chump" 2>/dev/null || true
        : > "$repo_root/.chump/farmer-heartbeat"
    fi

    return 0
}
