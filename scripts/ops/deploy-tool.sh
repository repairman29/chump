#!/usr/bin/env bash
# scripts/ops/deploy-tool.sh — INFRA-3502 (COTG-5.1)
#
# Deploy a shipped tool to a *usable customer surface* (a URL/app), never a
# repo. This is the "auto-deploy to a usable surface" arm of COTG-5: a tool
# that merges is worthless to a user who cannot audit code until it is live
# somewhere they can actually click.
#
# The safety invariant (COTG-3.1 outcome-verification, borrowed from
# auto-deploy.sh's canary gate): NEVER expose an unverified artifact to the
# customer. So the flow is a stage-then-verify-then-promote sequence:
#
#   (1) deploy      → push the built tool to an ephemeral per-lap STAGE surface
#                     (a Vercel preview URL, a Dokku app, etc.). The deploy
#                     command prints the stage URL on its last stdout line.
#   (2) DoD-on-stage→ run the Definition-of-Done / outcome-verification command
#                     against the STAGE surface (default: liveness curl of
#                     GET /api/health on the stage URL). This is COTG-3.1's
#                     verification, run against stage — the customer never sees
#                     an unverified surface.
#   (3) promote     → ONLY if the DoD passed, atomically FLIP the already-built
#                     stage artifact to the customer-facing surface
#                     (default: `vercel promote <stage>`). This is a promotion
#                     of the SAME verified artifact — NO fresh build, NO
#                     re-deploy. A failing DoD blocks here and the customer
#                     surface is never touched.
#
# build-vs-source (COTG-S.3): the deploy/promote mechanism is a *commodity* —
# this script wraps an existing hosted platform (Vercel preview→promote) or a
# self-hosted equivalent (Dokku/e2b) rather than reimplementing a deploy engine.
# Every step is a single injectable command string, so the substrate is
# swappable and the whole flow is drivable with stubs (no real network in CI).
#
# Idempotent-ish: a blocked DoD exits non-zero WITHOUT promoting, so a retry
# re-stages + re-verifies from scratch. A successful run prints the customer
# URL on stdout as its LAST line (and only then).
#
# Environment overrides (the injectable seams — all default to the Vercel path):
#   CHUMP_REPO_ROOT         — chump repo root (ambient.jsonl lives under here).
#                             Default: resolved relative to this script.
#   CHUMP_TOOL_TARGET       — directory of the tool/repo to deploy.
#                             Default: current working directory.
#   CHUMP_TOOL_DEPLOY_CMD   — command that deploys to a stage surface and prints
#                             the stage URL as its LAST stdout line. Runs with
#                             cwd = CHUMP_TOOL_TARGET. Default: `vercel deploy`.
#   CHUMP_TOOL_DOD_CMD      — Definition-of-Done / outcome-verification command
#                             run against the stage surface. The stage URL is
#                             exported as STAGE_URL (and substituted for the
#                             literal token {URL}). Exit 0 = pass → promote;
#                             non-zero = fail → block, never promote.
#                             Default: curl -fsS "$STAGE_URL/api/health".
#   CHUMP_TOOL_PROMOTE_CMD  — command that FLIPS the already-built stage artifact
#                             to the customer surface. STAGE_URL is exported and
#                             {URL} is substituted. MUST NOT rebuild/redeploy.
#                             Default: `vercel promote "$STAGE_URL"`.
#   CHUMP_TOOL_CUSTOMER_URL  — the customer-facing URL printed after a successful
#                             promote. Default: the stage URL (best effort when
#                             the platform doesn't report the production URL).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
LOG_DIR="$REPO_ROOT/.chump-locks/deploy-tool-logs"
mkdir -p "$LOG_DIR" "$(dirname "$AMBIENT")" 2>/dev/null || true
LOG="$LOG_DIR/deploy-tool-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"

# scanner-anchor: "kind":"tool_deployed_stage"
# scanner-anchor: "kind":"tool_dod_passed"
# scanner-anchor: "kind":"tool_promoted"
# scanner-anchor: "kind":"tool_promote_blocked"
emit_ambient() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind" >> "$LOG"
}

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# jstr — JSON-escape a value for safe interpolation into the extra field.
jstr() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

TARGET="${CHUMP_TOOL_TARGET:-$(pwd)}"
DEPLOY_CMD="${CHUMP_TOOL_DEPLOY_CMD:-vercel deploy}"
# Defaults kept in single-quoted if-blocks (NOT inline ${VAR:-...} defaults):
# the nested ${STAGE_URL%/} expansion mis-parses inside a ${VAR:-default}
# and leaks the default into a caller-supplied command. STAGE_URL is exported
# below, so these single-quoted defaults expand correctly under `bash -c`.
if [[ -n "${CHUMP_TOOL_DOD_CMD:-}" ]]; then
    DOD_CMD="$CHUMP_TOOL_DOD_CMD"          # Definition-of-Done on the stage surface
else
    DOD_CMD='curl -fsS "${STAGE_URL%/}/api/health"'   # default: liveness of GET /api/health
fi
if [[ -n "${CHUMP_TOOL_PROMOTE_CMD:-}" ]]; then
    PROMOTE_CMD="$CHUMP_TOOL_PROMOTE_CMD"  # flip the SAME stage artifact; no rebuild
else
    PROMOTE_CMD='vercel promote "$STAGE_URL"'
fi

if [[ ! -d "$TARGET" ]]; then
    log "FATAL: target dir does not exist: $TARGET"
    exit 1
fi

# ── (1) Deploy to the ephemeral STAGE surface ────────────────────────────────
# The deploy command is invoked EXACTLY ONCE. Promotion below must never
# re-invoke it — promote flips the artifact this step already built.
log "stage-deploy: target=$TARGET cmd=$DEPLOY_CMD"
DEPLOY_OUT="$(cd "$TARGET" && bash -c "$DEPLOY_CMD" 2>>"$LOG")"
DEPLOY_RC=$?
if [[ "$DEPLOY_RC" -ne 0 ]]; then
    log "FATAL: stage deploy failed (rc=$DEPLOY_RC)"
    emit_ambient "tool_promote_blocked" \
        "\"reason\":\"stage_deploy_failed\",\"rc\":$DEPLOY_RC"
    exit 1
fi
# Stage URL = last non-empty line of deploy stdout (Vercel prints the URL last).
STAGE_URL="$(printf '%s\n' "$DEPLOY_OUT" | grep -E '[^[:space:]]' | tail -n1)"
if [[ -z "$STAGE_URL" ]]; then
    log "FATAL: stage deploy produced no stage URL"
    emit_ambient "tool_promote_blocked" "\"reason\":\"no_stage_url\""
    exit 1
fi
export STAGE_URL
log "stage surface up: $STAGE_URL"
emit_ambient "tool_deployed_stage" "\"stage_url\":\"$(jstr "$STAGE_URL")\""

# ── (2) DoD / outcome-verification AGAINST THE STAGE surface ──────────────────
# COTG-3.1: the customer never sees an unverified surface. Verify on stage.
DOD_RESOLVED="${DOD_CMD//\{URL\}/$STAGE_URL}"
log "DoD-on-stage: $DOD_RESOLVED"
bash -c "$DOD_RESOLVED" >>"$LOG" 2>&1
DOD_RC=$?
if [[ "$DOD_RC" -ne 0 ]]; then
    log "BLOCKED: DoD failed on the stage surface (rc=$DOD_RC) — NOT promoting; customer surface untouched"
    emit_ambient "tool_promote_blocked" \
        "\"reason\":\"dod_failed_on_stage\",\"rc\":$DOD_RC,\"stage_url\":\"$(jstr "$STAGE_URL")\""
    exit 3
fi
log "OK: DoD passed on the stage surface"
emit_ambient "tool_dod_passed" "\"stage_url\":\"$(jstr "$STAGE_URL")\""

# ── (3) Promote: atomic flip of the ALREADY-VERIFIED stage artifact ──────────
# NO fresh build, NO re-deploy — this promotes the exact artifact step (1) built
# and step (2) verified. The deploy command is NOT re-invoked here.
PROMOTE_RESOLVED="${PROMOTE_CMD//\{URL\}/$STAGE_URL}"
log "promote (flip stage artifact -> customer surface): $PROMOTE_RESOLVED"
bash -c "$PROMOTE_RESOLVED" >>"$LOG" 2>&1
PROMOTE_RC=$?
if [[ "$PROMOTE_RC" -ne 0 ]]; then
    log "FAIL: promote failed (rc=$PROMOTE_RC) — customer surface not flipped"
    emit_ambient "tool_promote_blocked" \
        "\"reason\":\"promote_cmd_failed\",\"rc\":$PROMOTE_RC,\"stage_url\":\"$(jstr "$STAGE_URL")\""
    exit 4
fi

CUSTOMER_URL="${CHUMP_TOOL_CUSTOMER_URL:-$STAGE_URL}"
log "OK: promoted verified artifact to the customer surface"
emit_ambient "tool_promoted" \
    "\"stage_url\":\"$(jstr "$STAGE_URL")\",\"customer_url\":\"$(jstr "$CUSTOMER_URL")\""

# The customer URL is printed to stdout ONLY here, after a successful promote.
printf '%s\n' "$CUSTOMER_URL"
exit 0
