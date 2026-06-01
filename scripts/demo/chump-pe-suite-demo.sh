#!/usr/bin/env bash
# chump-pe-suite-demo.sh — 5-beat P&E Suite demo with synthetic fixtures
#
# INFRA-2234 / META-127 C8
# Runs the full 5-minute demo without a real customer repo or live NATS broker.
# All output is synthetic; the fixture is self-contained.
#
# Usage:
#   bash scripts/demo/chump-pe-suite-demo.sh [--beat N]
#
# Options:
#   --beat N    Run only beat N (1-5). Default: all beats in sequence.
#   --fast      Skip inter-beat pauses (useful for CI / screenshot pipelines).
#   --help      Show this help.

set -euo pipefail

REPO_DIR="${TMPDIR:-/tmp}/synthetic-api"
SUITE_VERSION="v1.0.0"
INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CONSENSUS_ID="CONSENSUS-001"
ONLY_BEAT=""
FAST=0

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --beat) ONLY_BEAT="$2"; shift 2 ;;
    --fast) FAST=1; shift ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

pause() {
  [[ $FAST -eq 1 ]] && return
  sleep "${1:-2}"
}

hr() { printf '\n%s\n\n' "$(printf '─%.0s' {1..72})"; }

run_beat() { [[ -z "$ONLY_BEAT" || "$ONLY_BEAT" == "$1" ]]; }

# ─────────────────────────────────────────────────────────────────────────────
# Setup: scaffold the synthetic repo fixture
# ─────────────────────────────────────────────────────────────────────────────

setup_fixture() {
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    git init -q "$REPO_DIR"
    pushd "$REPO_DIR" > /dev/null
    git commit -q --allow-empty -m "init: synthetic-api demo fixture"
    popd > /dev/null
  fi

  mkdir -p "$REPO_DIR/.chump" "$REPO_DIR/.claude/agents"

  # Seed ambient stream
  cat > "$REPO_DIR/.chump/ambient.jsonl" <<'AMBIENT'
{"ts":"2026-05-29T14:30:00Z","kind":"fleet_start","session":"demo"}
{"ts":"2026-05-29T14:30:05Z","kind":"curator_heartbeat","role":"ci-audit"}
{"ts":"2026-05-29T14:30:10Z","kind":"curator_heartbeat","role":"target"}
{"ts":"2026-05-29T14:30:15Z","kind":"gap_filed","id":"SYNTH-001","title":"add rate limiting to /api/v1/search"}
{"ts":"2026-05-29T14:30:20Z","kind":"gap_filed","id":"SYNTH-002","title":"enable per-PR auto-merge for dependabot"}
AMBIENT

  # Seed state.db (3 open gaps via SQL inserts into a temp SQLite file)
  if command -v sqlite3 &>/dev/null && [[ ! -f "$REPO_DIR/.chump/state.db" ]]; then
    sqlite3 "$REPO_DIR/.chump/state.db" <<'SQL'
CREATE TABLE IF NOT EXISTS gaps (
  id TEXT PRIMARY KEY, title TEXT, status TEXT, priority TEXT, effort TEXT
);
INSERT INTO gaps VALUES ('SYNTH-001','add rate limiting to /api/v1/search','open','P1','s');
INSERT INTO gaps VALUES ('SYNTH-002','enable per-PR auto-merge for dependabot','open','P2','xs');
INSERT INTO gaps VALUES ('SYNTH-003','write integration test for /api/v1/auth','open','P2','s');
SQL
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Beat 1 — Install (0:00 – 0:45)
# ─────────────────────────────────────────────────────────────────────────────

beat1_install() {
  echo "$ chump-pe-suite install ~/demo/synthetic-api"
  pause 1

  local curators=(
    "curator-opus-ci-audit.md"
    "curator-opus-decompose.md"
    "curator-opus-external-collab.md"
    "curator-opus-handoff.md"
    "curator-opus-harvester.md"
    "curator-opus-infra-watcher.md"
    "curator-opus-md-links.md"
    "curator-opus-observability.md"
    "curator-opus-target.md"
    "curator-opus-orchestrator.md"
    "curator-opus-context-keeper.md"
    "curator-opus-scout.md"
    "curator-opus-fleet-brief.md"
    "curator-opus-policy.md"
  )

  echo "[pe-suite] checking substrate... NATS OK, chump-coord OK"
  echo "[pe-suite] depositing 14 curator role documents → .claude/agents/"
  for f in "${curators[@]}"; do
    # Write a minimal stub so the fixture is real on disk
    echo "# $f — synthetic fixture" > "$REPO_DIR/.claude/agents/$f"
    echo "  $f          ✓"
    pause 0.1
  done

  echo "[pe-suite] copying 7 loop scripts → .claude/scripts/coord/"
  echo "[pe-suite] bootstrapping inbox → .chump/inbox/"
  echo "[pe-suite] wiring NATS subjects chump.curator.*"

  # Emit kind=suite_installed into fixture ambient stream
  printf '{"ts":"%s","kind":"suite_installed","version":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SUITE_VERSION" \
    >> "$REPO_DIR/.chump/ambient.jsonl"

  echo "[pe-suite] emitting kind=suite_installed"
  echo "[pe-suite] done. 14 curators active. 7 loop scripts armed."
}

# ─────────────────────────────────────────────────────────────────────────────
# Beat 2 — Status (0:45 – 1:30)
# ─────────────────────────────────────────────────────────────────────────────

beat2_status() {
  echo "$ chump pe-suite status"
  pause 0.5

  printf "Chump P&E Suite — status as of %s\n\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf "REPO     %s\n" "$REPO_DIR"
  printf "SUITE    %s  (installed 00:00:31 ago)\n\n" "$SUITE_VERSION"

  printf "%-26s %-10s %-12s %s\n" "CURATOR" "STATE" "LOOP ARMED" "LAST HEARTBEAT"
  printf '%s\n' "$(printf '─%.0s' {1..67})"

  local roles=(
    ci-audit decompose external-collab handoff harvester
    infra-watcher md-links observability target orchestrator
    context-keeper scout fleet-brief policy
  )
  for r in "${roles[@]}"; do
    printf "%-26s %-10s %-12s %s\n" "$r" "active" "yes" "just now"
    pause 0.05
  done

  echo ""
  echo "14 / 14 curators active.  Gap queue: 3 open.  Consensus queue: 0 pending."
}

# ─────────────────────────────────────────────────────────────────────────────
# Beat 3 — Operator asks (1:30 – 2:00)
# ─────────────────────────────────────────────────────────────────────────────

beat3_ask() {
  cat <<'CMD'
$ chump consensus ask \
  "Should we use per-PR ship cycles or batch weekly releases for this repo?" \
  --quorum 5 \
  --timeout 60s \
  --roles ci-audit,target,infra-watcher,harvester,policy
CMD
  pause 0.5

  echo "[consensus] question registered: $CONSENSUS_ID"
  echo "[consensus] routing to 5 curators: ci-audit, target, infra-watcher, harvester, policy"
  echo "[consensus] quorum: 5 of 5 required. timeout: 60s"
  echo "[consensus] waiting for FEEDBACK..."
}

# ─────────────────────────────────────────────────────────────────────────────
# Beat 4 — Curators reply (2:00 – 4:00)
# ─────────────────────────────────────────────────────────────────────────────

beat4_replies() {
  # INFRA-2282: parallel indexed arrays — works on macOS bash 3.2 (no assoc-array support).
  # Indices are role-position-aligned across all 5 arrays.
  local ROLE_ORDER=(ci-audit target infra-watcher harvester policy)

  local POSITIONS=(
    "per-PR"
    "per-PR"
    "per-PR (conditional)"
    "per-PR"
    "per-PR"
  )

  local CONFIDENCE=(85 72 60 90 78)

  local RATIONALE=(
    "Per-PR shipping gives CI a clean signal per change. Batch cycles mean one green build masks multiple root causes. For this repo, where test coverage is sparse, we want per-PR isolation so regressions are attributable. A weekly batch would hide 3-5 failure classes simultaneously on a bad week."
    "Gap targeting assumes per-PR atomicity. Batch cycles break the intent-atomic principle: a gap's acceptance criteria spans exactly one PR. Batching would require either multi-gap PRs (hard to review) or re-filing gaps at batch time (wasted filing overhead). Per-PR keeps the gap-to-PR mapping clean."
    "Per-PR is correct if the merge queue handles throughput. If this repo ships >20 PRs/day and the queue becomes a bottleneck, a daily-batch window (not weekly) is a reasonable middle path. I am flagging this at 60% because throughput data for this repo is not yet available. Recommend revisiting after 2 weeks of observed ship rate."
    "Cross-repo harvesting requires stable commit SHAs as anchor points for cross-pollination briefs (CP-NNN). Weekly batches produce jumbo commits that are hard to pin. Per-PR gives the harvester clean primitives to extract and port. Arsenal catalog accuracy degrades with batch merges."
    "Auto-merge trust is calibrated per-PR via the trust-cliff knob (INFRA-1489). Batch cycles would require a new trust model: trust across a bundle, not per change. The per-op / per-repo override mechanism in policy assumes per-PR granularity. Switching to batch would need a policy rework not scoped in the current suite."
  )

  local CROSSREF=(
    "INFRA-2209 (consensus discipline), fleet CI failure taxonomy."
    "AGENTS.md §\"PRs are intent-atomic\"."
    "INFRA-2228 §4 substrate dependencies."
    "docs/arsenal/GLOBAL_ARSENAL.md, CP-brief format."
    "INFRA-1489 (Marcus M-E trust-cliff)."
  )

  local i role
  for i in "${!ROLE_ORDER[@]}"; do
    pause 4
    role="${ROLE_ORDER[$i]}"
    printf '\n─── FEEDBACK from curator-opus-%s %s\n' "$role" "$(printf '─%.0s' {1..40})"
    printf 'Position:   %s\n' "${POSITIONS[$i]}"
    printf 'Confidence: %d%%\n' "${CONFIDENCE[$i]}"
    printf 'Rationale:  %s\n' "${RATIONALE[$i]}" | fold -s -w 68 | sed '2,$s/^/            /'
    printf 'Cross-ref:  %s\n' "${CROSSREF[$i]}"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Beat 5 — Resolve + roadmap pivot (4:00 – 5:00)
# ─────────────────────────────────────────────────────────────────────────────

beat5_resolve() {
  local resolved_at
  resolved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  pause 1
  echo ""
  echo "[consensus] all 5 replies received in 38s (timeout was 60s)"
  echo "[consensus] $CONSENSUS_ID resolved"
  echo ""
  cat <<EOF
QUESTION  Should we use per-PR ship cycles or batch weekly releases?

DECISION  per-PR
VOTES     5 for per-PR / 0 for batch / 0 abstain
WEIGHTED  85% ci-audit + 72% target + 60% infra-watcher + 90% harvester
          + 78% policy = weighted 77% mean confidence

AMBIENT   kind=consensus_decision_emitted  id=$CONSENSUS_ID  decision=per-PR
          confidence=77  ts=$resolved_at

CAVEATS   infra-watcher flagged: revisit if ship rate >20 PRs/day.
          Recommend: schedule a re-ask in 2 weeks with observed throughput.
EOF

  # Emit the ambient event into fixture stream
  printf '{"ts":"%s","kind":"consensus_decision_emitted","id":"%s","decision":"per-PR","confidence":77}\n' \
    "$resolved_at" "$CONSENSUS_ID" \
    >> "$REPO_DIR/.chump/ambient.jsonl"

  pause 2
  echo ""
  echo "$ chump consensus roadmap-pivot $CONSENSUS_ID"
  pause 1

  echo "[roadmap-pivot] reading $CONSENSUS_ID decision: per-PR"
  echo "[roadmap-pivot] scanning open gaps for batch-ship assumptions..."
  echo "  INFRA-2241 \"batch release tooling\" — priority was P2 → demoting to P3 (conflicts per-PR decision)"
  echo "  INFRA-2199 \"per-PR auto-merge policy\" — priority was P3 → promoting to P1 (aligned with decision)"

  printf '{"ts":"%s","kind":"roadmap_pivoted","consensus_id":"%s","re_ranked":2}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CONSENSUS_ID" \
    >> "$REPO_DIR/.chump/ambient.jsonl"

  echo "[roadmap-pivot] 2 gaps re-ranked. emitting kind=roadmap_pivoted."
  echo "[roadmap-pivot] done."
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
  echo "━━━ Chump P&E Suite — 5-Minute Demo (INFRA-2234 / META-127 C8) ━━━"
  echo "    Fixture repo: $REPO_DIR"
  echo "    Run mode: ${ONLY_BEAT:+beat $ONLY_BEAT only}${ONLY_BEAT:-all beats}"
  echo "    Fast mode: $([[ $FAST -eq 1 ]] && echo yes || echo no)"
  echo ""

  setup_fixture

  if run_beat 1; then
    hr
    echo "BEAT 1 — Install (0:00 – 0:45)"
    hr
    beat1_install
  fi

  if run_beat 2; then
    hr
    echo "BEAT 2 — Status (0:45 – 1:30)"
    hr
    pause 2
    beat2_status
  fi

  if run_beat 3; then
    hr
    echo "BEAT 3 — Operator asks (1:30 – 2:00)"
    hr
    pause 2
    beat3_ask
  fi

  if run_beat 4; then
    hr
    echo "BEAT 4 — Curators reply (2:00 – 4:00)"
    hr
    beat4_replies
  fi

  if run_beat 5; then
    hr
    echo "BEAT 5 — Resolve + roadmap pivot (4:00 – 5:00)"
    hr
    beat5_resolve
  fi

  hr
  echo "Demo complete. Ambient stream at: $REPO_DIR/.chump/ambient.jsonl"
  echo "Full runbook:  docs/strategy/CHUMP_PE_SUITE_DEMO_5MIN.md"
}

main "$@"
