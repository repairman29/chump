#!/usr/bin/env bash
# chump-fleet-bootstrap.sh — META-066
#
# Idempotent orchestrator that installs every required launchd plist + git
# hook so the productization layer (META-063/064/065 + INFRA-1257/1258)
# is actually ACTIVE on this machine, not just on disk.
#
# Each entry in scripts/setup/bootstrap-manifest.yaml has a `check`
# command that returns 0 iff already installed. The bootstrap runs the
# `install` command only when `check` fails.
#
# Usage:
#   bash scripts/setup/chump-fleet-bootstrap.sh                # install missing
#   bash scripts/setup/chump-fleet-bootstrap.sh --check        # audit only (exits non-zero if anything missing)
#   bash scripts/setup/chump-fleet-bootstrap.sh --only ID,…    # install just these IDs
#   bash scripts/setup/chump-fleet-bootstrap.sh --skip ID,…    # install all except these IDs
#   bash scripts/setup/chump-fleet-bootstrap.sh --priority P0  # only P0 entries
#
# Bypass: CHUMP_FLEET_BOOTSTRAP_CHECK=0 disables the check side-effect (still installs).
#
# Source: META-066 (2026-05-15 keystone — productizes the productization layer).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/setup/bootstrap-manifest.yaml"

[[ -f "$MANIFEST" ]] || { echo "ERROR: manifest missing at $MANIFEST" >&2; exit 1; }

# ── REQUIRED_DAEMONS (INFRA-1594) ─────────────────────────────────────────────
# Daemons whose absence makes the host fleet-incomplete even when the manifest
# audit says "all green". Format: "launchd_label|install_script_path".
#
# Only include entries whose install script actually exists in this repo.
# 2026-05-16 M4 incident: host ran runner plists but no paramedic → PRs stuck
# DIRTY for hours. This array closes that gap.
REQUIRED_DAEMONS=(
    "com.chump.paramedic|scripts/setup/install-paramedic.sh"
    "com.chump.bot-merge-watchdog|scripts/setup/install-bot-merge-watchdog.sh"
    "com.chump.claude-reaper|scripts/setup/install-claude-reaper.sh"
    "com.chump.stale-process-watchdog|scripts/setup/install-stale-process-watchdog.sh"
    "com.chump.main-health-watchdog|scripts/setup/install-main-health-watchdog.sh"
    # INFRA-2124: OAuth refresh daemon — fills CLAUDE.md INFRA-622 5-min refresh
    # promise. Without this, ~/.chump/oauth-token.json goes stale within hours
    # and headless `claude -p` subprocesses (Oracle, JIT scheduler) silently
    # return "Not logged in". Symptom cascade: INFRA-2122 Oracle silent fail.
    "com.chump.oauth-refresh|scripts/setup/install-oauth-refresh-launchd.sh"
    # META-162: deliberator — tallies fleet votes, emits consensus_result, escalates NO_QUORUM.
    "com.chump.deliberator|scripts/setup/install-deliberator-launchd.sh"
    # EFFECTIVE-264 (EFFECTIVE-088 activation): conductor — autonomous proposer that
    # detects a wedged fleet by ground truth + emits a self-rescue consensus proposal
    # (dry-run by default; arm with CHUMP_CONDUCTOR_ACT=1). Pairs with the deliberator.
    "com.chump.conductor|scripts/setup/install-conductor-launchd.sh"
    # INFRA-2239: Curator supervisor — L3 detection+file+dispatch+restart daemon.
    # Without this, silently failing curators go undetected (32-hour incident
    # 2026-05-30). Runs every 300s via StartInterval launchd, not KeepAlive.
    "com.chump.curator-supervisor|scripts/setup/install-curator-supervisor.sh"
    # INFRA-2324: Trunk Health Sentinel — 60s daemon that detects main ci.yml RED
    # and autonomously triggers fix-class actions (gap-file at 5m, Sonnet dispatch
    # at 15m, operator-recall at 60m). Without this, a red trunk blinds the
    # fleet to its own queue-burn and bot-merge stalls every PR BEHIND it.
    "com.chump.trunk-sentinel|scripts/setup/install-trunk-sentinel.sh"
    # INFRA-2280: META-118 scheduling activation — novel-wedge-classifier (15-min)
    # and cascade-unblock-detector (5-min). Without these, the META-118 chain
    # (INFRA-2067..2071) is plumbed but executes zero times.
    "com.chump.novel-wedge-classifier|scripts/setup/install-meta-118-daemons.sh"
    "com.chump.cascade-unblock-detector|scripts/setup/install-meta-118-daemons.sh"
    # RESILIENT-068: Farmer — un-killable control-plane tender. KeepAlive=true,
    # pure bash, no cargo dep. Without this, the pause-deadlock self-seals
    # (RESILIENT-066 root cause) and the fleet cannot auto-recover.
    "dev.chump.farmer|scripts/setup/install-farmer-launchd.sh"
    "com.chump.wake-recovery|scripts/setup/install-wake-recovery.sh"
)
UID_VAL="$(id -u)"

MODE="install"   # install | check
ONLY=""
SKIP=""
PRI_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)    MODE="check"; shift ;;
        --only)     ONLY="$2"; shift 2 ;;
        --skip)     SKIP="$2"; shift 2 ;;
        --priority) PRI_FILTER="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

# ── INFRA-2515: A2A always-on — ensure the consensus flags are set ─────────────
# Operator mandate (2026-06-05): the A2A coordination layer must ALWAYS be on.
# Set the recv-side + subscribe-side flags in the launchd user-session domain so
# every fleet daemon/worker spawned afterwards inherits them. Idempotent +
# best-effort; runs on real bootstraps (not --check audits) and only where
# launchctl exists (macOS). fleet-doctor's a2a-consensus check enforces this.
if [[ "$MODE" != "check" ]] && command -v launchctl >/dev/null 2>&1; then
    launchctl setenv CHUMP_FLEET_RECV_SIDE_V0 1 2>/dev/null || true
    launchctl setenv CHUMP_A2A_LAYER 1 2>/dev/null || true
    echo "[bootstrap] INFRA-2515: A2A flags set (CHUMP_FLEET_RECV_SIDE_V0=1, CHUMP_A2A_LAYER=1)"
fi

# Parse the manifest (YAML → tab-separated rows: id\tpriority\tinstall\tcheck).
# We use python3 because awk + YAML is misery.
parse_manifest() {
    python3 -c "
import sys
try:
    import yaml
except ImportError:
    print('ERROR: pyyaml required (pip3 install pyyaml)', file=sys.stderr)
    sys.exit(3)
data = yaml.safe_load(open('$MANIFEST'))
for e in data.get('installers', []):
    eid = e.get('id', '')
    pri = e.get('priority', 'P2')
    install = e.get('install', '').replace('\t', ' ')
    check = e.get('check', '').replace('\t', ' ')
    print(f'{eid}\t{pri}\t{install}\t{check}')
"
}

# Filter by --only / --skip / --priority.
should_run() {
    local id="$1" pri="$2"
    if [[ -n "$ONLY" ]] && ! echo ",$ONLY," | grep -q ",$id,"; then return 1; fi
    if [[ -n "$SKIP" ]] && echo ",$SKIP," | grep -q ",$id,"; then return 1; fi
    if [[ -n "$PRI_FILTER" ]] && [[ "$pri" != "$PRI_FILTER" ]]; then return 1; fi
    return 0
}

INSTALLED=0
SKIPPED_HEALTHY=0
SKIPPED_FILTERED=0
INSTALLED_LIST=()
FAILED=0
FAILED_LIST=()
MISSING_AT_CHECK=()

cd "$REPO_ROOT"

# Process P0 first, then P1, then P2 (rough dep ordering — manifest authors
# put depends_on in the right column anyway).
for pri in P0 P1 P2 P3; do
    while IFS=$'\t' read -r id pri_actual install check; do
        [[ -z "$id" ]] && continue
        [[ "$pri_actual" != "$pri" ]] && continue
        if ! should_run "$id" "$pri_actual"; then
            SKIPPED_FILTERED=$((SKIPPED_FILTERED + 1))
            continue
        fi

        # Check if already installed.
        if eval "$check" >/dev/null 2>&1; then
            SKIPPED_HEALTHY=$((SKIPPED_HEALTHY + 1))
            [[ "$MODE" == "check" ]] && echo "  ok      $id"
            continue
        fi

        if [[ "$MODE" == "check" ]]; then
            MISSING_AT_CHECK+=("$id")
            echo "  MISSING $id  (would run: $install)"
            continue
        fi

        # Install.
        echo "[bootstrap] installing $id ($pri_actual): $install"
        if eval "$install" >/dev/null 2>&1; then
            INSTALLED=$((INSTALLED + 1))
            INSTALLED_LIST+=("$id")
        else
            rc=$?
            FAILED=$((FAILED + 1))
            FAILED_LIST+=("$id:rc=$rc")
            echo "[bootstrap] FAILED $id (rc=$rc); continuing" >&2
        fi
    done < <(parse_manifest)
done

# ── REQUIRED_DAEMONS pass (INFRA-1594) ────────────────────────────────────────
# Independent of the manifest loop: verify each daemon is REGISTERED + ACTIVE
# in launchd. The manifest's `check` field can pass via a heuristic grep, but
# the host can still be missing the daemon (2026-05-16 M4 incident).
MISSING_DAEMONS=()
for entry in "${REQUIRED_DAEMONS[@]}"; do
    label="${entry%%|*}"
    installer="${entry##*|}"
    # Skip if install script doesn't exist (intentional — pr-rebase-daemon
    # is referenced in CLAUDE.md but install script may not exist yet).
    if [[ ! -f "$REPO_ROOT/$installer" ]]; then
        continue
    fi
    if launchctl print "gui/${UID_VAL}/${label}" >/dev/null 2>&1; then
        [[ "$MODE" == "check" ]] && echo "  ok      daemon:$label"
        continue
    fi
    MISSING_DAEMONS+=("$label|$installer")
    if [[ "$MODE" == "check" ]]; then
        echo "  MISSING daemon:$label  (run: bash $installer)"
    else
        # install mode: run the installer idempotently.
        echo "[bootstrap] installing daemon $label: bash $installer"
        if bash "$REPO_ROOT/$installer" >/dev/null 2>&1; then
            INSTALLED=$((INSTALLED + 1))
            INSTALLED_LIST+=("daemon:$label")
        else
            rc=$?
            FAILED=$((FAILED + 1))
            FAILED_LIST+=("daemon:$label:rc=$rc")
            echo "[bootstrap] FAILED daemon $label (rc=$rc); continuing" >&2
        fi
    fi
done

# Ambient emit for audit trail.
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
if [[ -d "$(dirname "$AMBIENT")" ]]; then
    printf '{"ts":"%s","kind":"fleet_bootstrap_ran","mode":"%s","installed":%d,"skipped_healthy":%d,"failed":%d,"missing_count":%d}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$MODE" \
        "$INSTALLED" \
        "$SKIPPED_HEALTHY" \
        "$FAILED" \
        "${#MISSING_AT_CHECK[@]}" \
        >> "$AMBIENT" 2>/dev/null || true

    # INFRA-1594: emit fleet_bootstrap_incomplete in --check mode when any
    # required daemon is absent, so peer machines / paramedic can flag the
    # host-setup-drift hole that META-066 missed.
    if [[ "$MODE" == "check" ]] && (( ${#MISSING_DAEMONS[@]} > 0 )); then
        # Build comma-separated label list.
        missing_labels=""
        for entry in "${MISSING_DAEMONS[@]}"; do
            label="${entry%%|*}"
            if [[ -z "$missing_labels" ]]; then
                missing_labels="\"$label\""
            else
                missing_labels="$missing_labels,\"$label\""
            fi
        done
        printf '{"ts":"%s","kind":"fleet_bootstrap_incomplete","missing_daemons":[%s],"missing_count":%d,"host":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$missing_labels" \
            "${#MISSING_DAEMONS[@]}" \
            "$(hostname -s 2>/dev/null || echo unknown)" \
            >> "$AMBIENT" 2>/dev/null || true
    fi
fi

echo
if [[ "$MODE" == "check" ]]; then
    echo "=== bootstrap audit: $SKIPPED_HEALTHY installed, ${#MISSING_AT_CHECK[@]} manifest-missing, ${#MISSING_DAEMONS[@]} daemon-missing"
    if (( ${#MISSING_DAEMONS[@]} > 0 )); then
        echo "Missing daemons — run these installers:"
        for entry in "${MISSING_DAEMONS[@]}"; do
            label="${entry%%|*}"
            installer="${entry##*|}"
            echo "  bash $installer   # registers $label"
        done
    fi
    if (( ${#MISSING_AT_CHECK[@]} > 0 || ${#MISSING_DAEMONS[@]} > 0 )); then
        echo "Run: bash scripts/setup/chump-fleet-bootstrap.sh"
        exit 1
    fi
    exit 0
fi

echo "=== bootstrap done: $INSTALLED installed, $SKIPPED_HEALTHY already healthy, $FAILED failed"
if (( FAILED > 0 )); then
    for f in "${FAILED_LIST[@]}"; do echo "  FAILED: $f" >&2; done
    exit 1
fi
exit 0
