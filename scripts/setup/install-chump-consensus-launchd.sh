#!/usr/bin/env bash
# install-chump-consensus-launchd.sh — INFRA-2160 (META-125/C9)
#
# Installer entrypoint for the consensus AGGREGATOR daemon named in the
# META-125 design doc (docs/strategy/LIVE_A2A_CONSENSUS_2026-05-29.md, C8/C9).
# By the time META-125 shipped (closed_pr #2781), C8 "chump-consensus-
# aggregator-daemon" was realized as the curator-opus-deliberator role
# (scripts/coord/deliberator-loop.sh) rather than a standalone binary — it
# already does exactly what C8 specced: tally FEEDBACK kind=vote/preference
# events per corr_id and emit the aggregated decision. Its installer
# (install-deliberator-launchd.sh, RESILIENT-212) already exists under that
# name. This script is the C9 entrypoint the gap asked for: it delegates to
# the canonical installer (no second plist driving the same script — that
# would double-execute the tally loop) and adds the observability contract
# this gap's AC asked for but the original filing left as TODO.
#
# ── AC1: events emitted on success / failure / timeout ─────────────────────
#   success (quorum reached, verdict PASSED or FAILED):
#     kind=consensus_result   {"corr_id":..,"verdict":"PASSED|FAILED",
#                               "yes":N,"no":N,"abstain":N,"total":N}
#   timeout (deadline passed, no quorum, past grace window):
#     kind=operator_recall    {"reason":"NO_QUORUM", "corr_id":..}
#   every tick (liveness, regardless of actionable work):
#     kind=deliberator_heartbeat   {"role":"deliberator"}
#   All three are ambient.jsonl lines written by _emit_kind() in
#   scripts/coord/deliberator-loop.sh. launchd-level failure (script itself
#   crashes / non-zero exit) is NOT an ambient event — it is captured by
#   StandardErrorPath below (/tmp/chump-deliberator.err.log) since a dead
#   process can't reliably self-report; see fleet-doctor's a2a-consensus
#   check for the daemon-alive cross-check.
#
# ── AC2: cost tracking ───────────────────────────────────────────────────
#   $0 API cost. deliberator-loop.sh is pure bash + jq + python3 (tally
#   arithmetic + ISO8601 parsing) — it never shells out to `claude -p` or
#   any LLM endpoint, so there is nothing to meter against the operator's
#   token budget. Cost tracking for this daemon reduces to wall-clock +
#   launchd's own accounting (`launchctl list com.chump.deliberator` last
#   exit status), not an api-cost-leaderboard line item.
#
# ── AC3: failure-class taxonomy ─────────────────────────────────────────
#   Exit codes from deliberator-loop.sh tick (canonical, see its own header):
#     0  actionable            — not a failure
#     1  quiet (no proposals)  — not a failure, expected steady-state
#     2  bad subcommand/arg    — PERMANENT: config/invocation bug, will not
#                                 self-resolve on retry; fix the plist/args
#     3  ambient log missing   — TRANSIENT: worktree not yet initialized or
#                                 .chump-locks wiped by a reaper; next tick
#                                 (StartInterval) retries and typically clears
#   NO_QUORUM escalation (kind=operator_recall) is itself a TRANSIENT
#   condition from the daemon's point of view — it's a fleet-consensus
#   failure, not a daemon failure; the daemon operated correctly by
#   detecting and reporting it.
#
# ── AC4: smoke test ──────────────────────────────────────────────────────
#   bash scripts/setup/install-chump-consensus-launchd.sh --smoke-test
#   (also runnable standalone any time after install, no re-install needed)
#
# Usage:
#   bash install-chump-consensus-launchd.sh              # install + load
#   bash install-chump-consensus-launchd.sh --smoke-test  # verify observability, no install

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

LABEL="com.chump.deliberator"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
OUT_LOG="/tmp/chump-deliberator.out.log"
ERR_LOG="/tmp/chump-deliberator.err.log"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO/.chump-locks/ambient.jsonl}"

_smoke_test() {
    echo "[install-chump-consensus-launchd] smoke test — aggregator daemon (${LABEL})"
    local ok=1

    if [[ -f "$PLIST" ]]; then
        echo "  [ok]   plist present: $PLIST"
    else
        echo "  [FAIL] plist missing: $PLIST — run this script without --smoke-test first"
        ok=0
    fi

    if command -v launchctl >/dev/null 2>&1; then
        if launchctl list 2>/dev/null | grep -q "$LABEL"; then
            echo "  [ok]   launchctl reports ${LABEL} loaded"
        else
            echo "  [FAIL] launchctl does NOT report ${LABEL} loaded"
            ok=0
        fi
    else
        echo "  [skip] launchctl not available on this platform"
    fi

    if [[ -f "$AMBIENT" ]]; then
        if grep -q '"kind":"deliberator_heartbeat"' "$AMBIENT" 2>/dev/null; then
            echo "  [ok]   deliberator_heartbeat has fired at least once"
        else
            echo "  [warn] no deliberator_heartbeat seen yet — run: launchctl start ${LABEL}"
        fi
        if grep -q '"kind":"consensus_result"' "$AMBIENT" 2>/dev/null; then
            echo "  [ok]   consensus_result has fired at least once (aggregator has resolved a real vote)"
        else
            echo "  [info] no consensus_result yet — expected until a proposal reaches quorum/deadline"
        fi
    else
        echo "  [FAIL] ambient log not found at $AMBIENT"
        ok=0
    fi

    echo "  [info] force one tick now: CHUMP_FLEET_RECV_SIDE_V0=1 bash ${REPO}/scripts/coord/deliberator-loop.sh audit"
    echo "  [info] tail logs: tail -f ${OUT_LOG} ${ERR_LOG}"

    if [[ "$ok" == "1" ]]; then
        echo "[install-chump-consensus-launchd] smoke test PASSED"
        return 0
    else
        echo "[install-chump-consensus-launchd] smoke test FAILED"
        return 1
    fi
}

if [[ "${1:-}" == "--smoke-test" ]]; then
    _smoke_test
    exit $?
fi

DELIBERATOR_INSTALLER="$SCRIPT_DIR/install-deliberator-launchd.sh"
if [[ ! -x "$DELIBERATOR_INSTALLER" && ! -f "$DELIBERATOR_INSTALLER" ]]; then
    echo "[install-chump-consensus-launchd] FATAL: canonical installer missing: $DELIBERATOR_INSTALLER" >&2
    exit 1
fi

echo "[install-chump-consensus-launchd] delegating to canonical aggregator installer: install-deliberator-launchd.sh"
bash "$DELIBERATOR_INSTALLER"

echo "[install-chump-consensus-launchd] verify with: bash $0 --smoke-test"
