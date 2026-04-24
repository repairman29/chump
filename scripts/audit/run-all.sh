#!/usr/bin/env bash
# scripts/audit/run-all.sh — INFRA-044 static/license/CVE sweep dispatcher
#
# Runs the "Stage A: Static & license sweep" slice of the AI pre-audit pipeline
# described in docs/EXPERT_REVIEW_PANEL.md. Each tool is optional; missing tools
# are recorded as SKIPPED in the aggregated report rather than aborting the run.
#
# Usage:
#   scripts/audit/run-all.sh                # run all six tools, write report
#   scripts/audit/run-all.sh --tool clippy  # run only one tool
#   scripts/audit/run-all.sh --no-install   # do not try to cargo-install missing tools
#   AUDIT_AUTO_FILE_GAPS=1 scripts/audit/run-all.sh   # append critical findings to docs/gaps.yaml
#
# Output:
#   docs/audit/findings-YYYY-MM-DD.md    — aggregated, severity-tiered report
#   docs/audit/raw/<tool>-YYYY-MM-DD.log — raw per-tool output
#
# Tools invoked (each is optional and skipped if not installed):
#   1. cargo clippy --all-targets -- -W clippy::pedantic    (code quality)
#   2. cargo deny check                                      (licenses, advisories, bans)
#   3. cargo audit                                           (CVE / RUSTSEC)
#   4. cargo udeps                                           (unused deps; requires nightly)
#   5. cargo machete                                         (unused deps; stable)
#   6. lychee docs/ README.md                                (doc link rot)
#
# Exit code:
#   0 — dispatcher finished; report written. Individual tool failures do NOT
#       fail the run (they're recorded in the report instead). This is so CI
#       can run the sweep weekly without blocking on transient network /
#       advisory-db flakes.
#   1 — dispatcher itself failed (cwd wrong, can't write report, etc.)

set -uo pipefail

# Resolve repo root by walking up from this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || { echo "[audit] cannot cd to repo root"; exit 1; }

DATE="$(date -u +%Y-%m-%d)"
OUT_DIR="docs/audit"
RAW_DIR="$OUT_DIR/raw"
REPORT="$OUT_DIR/findings-$DATE.md"
mkdir -p "$RAW_DIR"

SELECTED_TOOL=""
NO_INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool) SELECTED_TOOL="$2"; shift 2 ;;
    --no-install) NO_INSTALL=1; shift ;;
    -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
    *) echo "[audit] unknown arg: $1"; exit 1 ;;
  esac
done

# Arrays track per-tool results so we can summarize at the end.
declare -a TOOL_NAMES=()
declare -a TOOL_STATUS=()   # OK | SKIPPED | FAIL
declare -a TOOL_SUMMARY=()  # short one-line description
declare -a TOOL_SEVERITY=() # info | low | medium | high | critical

run_tool() {
  local name="$1"
  local cmd="$2"
  local severity_on_fail="$3"   # severity tier if the command exits non-zero
  local install_hint="${4:-}"

  if [[ -n "$SELECTED_TOOL" && "$SELECTED_TOOL" != "$name" ]]; then
    return 0
  fi

  TOOL_NAMES+=("$name")
  local binary="${cmd%% *}"
  # For `cargo <sub>` style commands, also check for cargo-<sub>.
  local sub=""
  if [[ "$binary" == "cargo" ]]; then
    sub="$(echo "$cmd" | awk '{print $2}')"
  fi

  # Presence check.
  local present=0
  if command -v "$binary" >/dev/null 2>&1; then
    if [[ -n "$sub" && "$sub" != "clippy" && "$sub" != "check" ]]; then
      # `cargo <sub>` subcommands live on PATH as cargo-<sub>.
      if command -v "cargo-$sub" >/dev/null 2>&1; then
        present=1
      fi
    else
      present=1
    fi
  fi

  if [[ $present -eq 0 ]]; then
    TOOL_STATUS+=("SKIPPED")
    TOOL_SUMMARY+=("not installed${install_hint:+ — install: $install_hint}")
    TOOL_SEVERITY+=("info")
    echo "[audit] $name — SKIPPED (not installed)"
    return 0
  fi

  echo "[audit] $name — running…"
  local raw_log="$RAW_DIR/$name-$DATE.log"
  local rc=0
  # shellcheck disable=SC2086
  bash -c "$cmd" >"$raw_log" 2>&1 || rc=$?

  if [[ $rc -eq 0 ]]; then
    TOOL_STATUS+=("OK")
    TOOL_SUMMARY+=("clean")
    TOOL_SEVERITY+=("info")
    echo "[audit] $name — OK"
  else
    TOOL_STATUS+=("FAIL")
    # Summarize: count warnings/errors heuristically.
    local warns errs
    warns=$(grep -c -iE '^warning' "$raw_log" 2>/dev/null || echo 0)
    errs=$(grep -c -iE '^error' "$raw_log" 2>/dev/null || echo 0)
    TOOL_SUMMARY+=("exit=$rc warnings=$warns errors=$errs — see $raw_log")
    TOOL_SEVERITY+=("$severity_on_fail")
    echo "[audit] $name — FAIL (exit=$rc, severity=$severity_on_fail)"
  fi
}

# --- Tool dispatch table ------------------------------------------------------

run_tool "clippy" \
  "cargo clippy --workspace --all-targets -- -W clippy::pedantic" \
  "medium" \
  "rustup component add clippy"

run_tool "cargo-deny" \
  "cargo deny check" \
  "critical" \
  "cargo install cargo-deny --locked"

run_tool "cargo-audit" \
  "cargo audit" \
  "critical" \
  "cargo install cargo-audit --locked"

run_tool "cargo-udeps" \
  "cargo +nightly udeps --workspace" \
  "low" \
  "rustup install nightly && cargo install cargo-udeps --locked"

run_tool "cargo-machete" \
  "cargo machete" \
  "low" \
  "cargo install cargo-machete --locked"

run_tool "lychee" \
  "lychee --no-progress --exclude-path target --exclude-path .git docs README.md" \
  "low" \
  "cargo install lychee --locked"

# --- Write aggregated report --------------------------------------------------

severity_rank() {
  case "$1" in
    critical) echo 4 ;;
    high) echo 3 ;;
    medium) echo 2 ;;
    low) echo 1 ;;
    *) echo 0 ;;
  esac
}

# Emit the report.
{
  echo "# Audit findings — $DATE"
  echo ""
  echo "Generated by \`scripts/audit/run-all.sh\` (INFRA-044)."
  echo "Scope: Stage A of the AI pre-audit pipeline (static + license + CVE sweep)."
  echo "See \`docs/EXPERT_REVIEW_PANEL.md\` for the framing."
  echo ""
  echo "## Summary"
  echo ""
  echo "| Tool | Status | Severity | Summary |"
  echo "|------|--------|----------|---------|"
  for i in "${!TOOL_NAMES[@]}"; do
    printf "| %s | %s | %s | %s |\n" \
      "${TOOL_NAMES[$i]}" "${TOOL_STATUS[$i]}" "${TOOL_SEVERITY[$i]}" "${TOOL_SUMMARY[$i]}"
  done
  echo ""
  echo "## Severity tiers"
  echo ""
  echo "- **critical** — CVE, license conflict, or advisory-db hit. Must auto-file a gap."
  echo "- **high** — build-breaking warning promoted to error by CI."
  echo "- **medium** — clippy-pedantic lints; review batch-ship a fix."
  echo "- **low** — dead deps, doc link rot. File a janitor gap when count > 10."
  echo "- **info** — tool ran clean or was skipped."
  echo ""
  echo "## Raw logs"
  echo ""
  for name in "${TOOL_NAMES[@]}"; do
    echo "- [\`$name-$DATE.log\`](raw/$name-$DATE.log)"
  done
  echo ""
  echo "## Next steps"
  echo ""
  echo "1. Review critical / high findings."
  echo "2. File follow-up gaps for fixes (set \`AUDIT_AUTO_FILE_GAPS=1\` to auto-stage)."
  echo "3. Re-run weekly; compare against prior \`findings-*.md\` for regressions."
} >"$REPORT"

echo ""
echo "[audit] report written: $REPORT"

# --- Auto-file gaps for critical findings (opt-in) ----------------------------

if [[ "${AUDIT_AUTO_FILE_GAPS:-0}" == "1" ]]; then
  critical_tools=()
  for i in "${!TOOL_NAMES[@]}"; do
    if [[ "${TOOL_STATUS[$i]}" == "FAIL" && "${TOOL_SEVERITY[$i]}" == "critical" ]]; then
      critical_tools+=("${TOOL_NAMES[$i]}")
    fi
  done
  if [[ ${#critical_tools[@]} -gt 0 ]]; then
    echo "[audit] critical findings detected in: ${critical_tools[*]}"
    echo "[audit] append the following to docs/gaps.yaml (use scripts/gap-reserve.sh for a real ID):"
    for t in "${critical_tools[@]}"; do
      cat <<EOF

# --- auto-suggested gap (INFRA-044 sweep $DATE) ---
# - id: INFRA-TBD
#   title: "Address critical $t findings from $DATE sweep"
#   domain: infra
#   priority: P1
#   effort: s
#   source_doc: $REPORT
#   status: open
#   description: >
#     Auto-filed by scripts/audit/run-all.sh. Raw: $RAW_DIR/$t-$DATE.log.
#   acceptance_criteria:
#     - $t re-runs clean
#     - Report $DATE shows no critical hits
EOF
    done
  else
    echo "[audit] no critical findings — no gaps to file."
  fi
fi

exit 0
