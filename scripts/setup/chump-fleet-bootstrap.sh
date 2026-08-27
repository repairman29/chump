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
    # RESILIENT-214: intervention-watchdog — wires INFRA-3489/COTG-2.1 onto a live
    # 30-min schedule. Runs `chump intervention-watchdog --apply` so every human
    # touch is logged as an autonomy_defect + deduped self-heal gap. Without this
    # plist the watchdog is callable but never invoked, so its downstream
    # consumers (fleet-brief, ops-audit) never fire.
    "com.chump.intervention-watchdog|scripts/setup/install-intervention-watchdog.sh"
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
    # RESILIENT-256: wip-watchdog — snapshots stale uncommitted work into the
    # object store (refs/wip/…) so a `git reset --hard` stops being
    # unrecoverable. REQUIRED rather than optional because the 2026-08-09 loss
    # (~574 lines, 13h uncommitted, gone for good) is exactly what an
    # opt-in-and-therefore-uninstalled data-loss guard fails to prevent.
    "dev.chump.wip-watchdog|scripts/setup/install-wip-watchdog-launchd.sh"
    # ZERO-WASTE-039: stranded-work — daily fleet-wide sweep for dirty
    # checkouts / ahead-branches / aged stashes that no gate or picker ever
    # sees (the 2026-08-05 almanac Phase D incident: +313 lines dirty for
    # 4-5 days, invisible to the fleet, re-shipped independently as #3477).
    "dev.chump.stranded-work|scripts/setup/install-stranded-work-launchd.sh"
    "com.chump.wake-recovery|scripts/setup/install-wake-recovery.sh"
    "com.chump.fleet-pool-keeper|scripts/setup/install-fleet-pool-keeper.sh"
    # RESILIENT-220: inventory-rebuild-cadence — weekly `chump inventory rebuild`
    # so META-271's 9 tech-debt/dead-code detector classes don't go silently
    # unused again. Found sitting at zero findings for ~2 months with no cadence
    # driving it; deliberately REQUIRED (not optional) so this doesn't become
    # yet another built-but-never-run daemon.
    "com.chump.inventory-rebuild-cadence|scripts/setup/install-inventory-rebuild-cadence.sh"
    # RESILIENT-070: ghost-gap-reaper — closes status=open gaps whose closed_pr
    # already points at a shipped PR. Was opt-in-only (RESILIENT-066 installer
    # existed but nothing called it), so hosts silently accumulated ghost gaps
    # until the L2-SLO-5 pause-deadlock threshold was hit and an operator had
    # to close 21 of them by hand.
    "com.chump.ghost-gap-reaper|scripts/setup/install-ghost-gap-reaper-launchd.sh"
    "com.chump.chumpd|scripts/setup/install-chumpd.sh"
    # INFRA-1808: bootstrap-auto-install — self-installing hourly cron for
    # this very script. Solves the bootstrap problem on first manual run so
    # it never reverts to "shipped but not installed" again.
    "com.chump.bootstrap-auto-install|scripts/setup/install-bootstrap-auto-launchd.sh"
    # RESILIENT-354: almanac-summarize-watchdog — supervises the almanac
    # summarize fleet launcher (restarts it within one cycle if dead, pages
    # the operator on served-repo coverage drop below floor). The watchdog
    # script + installer shipped in #4064 but were never added here, so the
    # exact failure the gap describes (launcher SIGTERM'd 2026-08-10, never
    # restarted, chump stuck at 68.6% summarized for 10 days) could still
    # recur on any host that never ran the installer by hand. REQUIRED so
    # this can't become another shipped-but-uninstalled daemon.
    "com.chump.almanac-summarize-watchdog|scripts/setup/install-almanac-summarize-watchdog.sh"
    # INFRA-1564: three dev scripts with install contracts + clear automation
    # intent that were never wired into a manifest or launchctl — same
    # code-on-disk-not-active pattern as the INFRA-1546 monitor plists.
    "com.chump.decomposition-hint-tracker|scripts/setup/install-decomposition-hint-tracker-launchd.sh"
    "com.chump.refresh-model-prices|scripts/setup/install-refresh-model-prices-launchd.sh"
    "com.chump.fleet-version-skew-detect|scripts/setup/install-fleet-version-skew-detect-launchd.sh"
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
        # INFRA-1808: chmod +x any install-*.sh the manifest is about to run —
        # resilience against the exact perm-bit failure mode that hid
        # install-bot-merge-watchdog.sh (shipped 0644, never ran) for days.
        for script_ref in $install; do
            [[ "$script_ref" == scripts/setup/install-*.sh ]] && chmod +x "$REPO_ROOT/$script_ref" 2>/dev/null || true
        done
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
# Independent of the manifest loop: verify each daemon is REGISTERED + ACTIVE.
# On macOS uses launchctl; on Linux uses systemctl --user.
MISSING_DAEMONS=()
OS_KIND="macos"
[[ "$(uname -s)" == "Linux" ]] && OS_KIND="linux"

for entry in "${REQUIRED_DAEMONS[@]}"; do
    label="${entry%%|*}"
    installer="${entry##*|}"
    if [[ ! -f "$REPO_ROOT/$installer" ]]; then
        continue
    fi
    
    is_active=0
    if [[ "$OS_KIND" == "macos" ]]; then
        if launchctl print "gui/${UID_VAL}/${label}" >/dev/null 2>&1; then
            is_active=1
        fi
    else
        # systemd unit name for com.chump.chumpd is chumpd.service
        unit_name="${label#com.chump.}"
        unit_name="${unit_name#dev.chump.}"
        [[ "$label" == "com.chump.chumpd" ]] && unit_name="chumpd"
        if systemctl --user is-active "${unit_name}.service" >/dev/null 2>&1; then
            is_active=1
        fi
    fi

    if [[ "$is_active" -eq 1 ]]; then
        [[ "$MODE" == "check" ]] && echo "  ok      daemon:$label"
        continue
    fi
    MISSING_DAEMONS+=("$label|$installer")
    if [[ "$MODE" == "check" ]]; then
        echo "  MISSING daemon:$label  (run: bash $installer)"
    else
        # install mode: run the installer idempotently.
        # INFRA-1808: chmod +x before invoking (see manifest-loop comment above).
        chmod +x "$REPO_ROOT/$installer" 2>/dev/null || true
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
