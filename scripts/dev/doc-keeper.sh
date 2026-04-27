#!/usr/bin/env bash
# Doc keeper: periodic hygiene for docs/ (and optional paths). Read-only checks — does not edit files.
# Stronger than memory-keeper-style "ping" checks: finds broken relative Markdown links and optional stale terms.
#
# Env:
#   CHUMP_HOME / script parent       — repo root
#   DOC_KEEPER_SCAN_ROOTS            — space-separated dirs under root (default: "docs"; .cursor/rules added if present)
#   DOC_KEEPER_CHECK_LINKS=0         — skip Python link scan
#   DOC_KEEPER_STALE_SCAN=1          — enable stale-term grep (default: 0; link check runs by default)
#   DOC_KEEPER_STALE_TERMS           — egrep pattern (default: legacy tool name edit_file)
#   DOC_KEEPER_STALE_PATHS           — paths/globs for stale scan (default: docs .cursor/rules AGENTS.md)
#   DOC_KEEPER_FAIL_ON_STALE=1       — exit 1 if stale hits (default: warn only)
#
# Schedule: launchd/cron (see scripts/plists/doc-keeper.plist.example), or CI. Logs: logs/doc-keeper.log

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

LOG="$ROOT/logs/doc-keeper.log"
mkdir -p "$ROOT/logs"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

ok=0
fail=0
warn=0

# --- Relative markdown links ---
if [[ "${DOC_KEEPER_CHECK_LINKS:-1}" != "0" ]]; then
  if command -v python3 &>/dev/null; then
    scan_roots=()
    read -r -a _custom <<< "${DOC_KEEPER_SCAN_ROOTS:-docs}"
    for x in "${_custom[@]}"; do
      [[ -n "$x" ]] && scan_roots+=("$x")
    done
    if [[ -d "$ROOT/.cursor/rules" ]]; then
      have_rules=0
      for y in "${scan_roots[@]}"; do
        [[ "$y" == ".cursor/rules" ]] && have_rules=1 && break
      done
      [[ $have_rules -eq 0 ]] && scan_roots+=(".cursor/rules")
    fi
    set +e
    link_out=$(python3 "$ROOT/scripts/ci/doc-keeper-check-links.py" "$ROOT" "${scan_roots[@]}" 2>&1)
    link_rc=$?
    set -e
    if [[ -n "$link_out" ]]; then
      echo "$link_out" | tee -a "$LOG"
    fi
    if [[ $link_rc -eq 0 ]]; then
      log "Link check: no broken relative links (${scan_roots[*]})."
      ok=$((ok + 1))
    else
      log "Link check: FAILED (see BROKEN_LINK lines above / in log)."
      fail=$((fail + 1))
    fi
  else
    log "python3 not found; skipping link check."
    warn=$((warn + 1))
  fi
else
  log "DOC_KEEPER_CHECK_LINKS=0: skipping link check."
fi

# --- Stale terminology (grep; warn or fail) ---
STALE_PATTERN="${DOC_KEEPER_STALE_TERMS:-(^|[^a-z_])edit_file([^a-z_]|$)}"
STALE_GLOB="${DOC_KEEPER_STALE_PATHS:-docs .cursor/rules AGENTS.md}"
if [[ "${DOC_KEEPER_STALE_SCAN:-0}" == "1" ]]; then
  hits=""
  for g in $STALE_GLOB; do
    [[ -e "$ROOT/$g" ]] || continue
    if [[ -d "$ROOT/$g" ]]; then
      h=$(grep -R -n -E "$STALE_PATTERN" "$ROOT/$g" --include='*.md' --include='*.mdc' 2>/dev/null | head -30 || true)
    else
      h=$(grep -n -E "$STALE_PATTERN" "$ROOT/$g" 2>/dev/null | head -30 || true)
    fi
    if [[ -n "$h" ]]; then
      hits+="$h"$'\n'
    fi
  done
  if [[ -n "$hits" ]]; then
    log "Stale-term scan matched (e.g. legacy edit_file). Sample:"
    echo "$hits" | tee -a "$LOG" | head -15
    if [[ "${DOC_KEEPER_FAIL_ON_STALE:-0}" == "1" ]]; then
      log "DOC_KEEPER_FAIL_ON_STALE=1: treating as failure."
      fail=$((fail + 1))
    else
      warn=$((warn + 1))
    fi
  else
    log "Stale-term scan: no matches for pattern."
    ok=$((ok + 1))
  fi
fi

if [[ $fail -gt 0 ]]; then
  log "Doc keeper: finished with failures (ok=$ok, warn=$warn, fail=$fail)."
  exit 1
fi
log "Doc keeper: ok (ok=$ok, warn=$warn)."
exit 0
