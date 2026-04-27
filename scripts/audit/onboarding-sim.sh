#!/usr/bin/env bash
# DOC-004 — Onboarding simulation: docs-only fresh-agent audit.
#
# Spawns a fresh Claude agent with ONLY ./docs/ (plus AGENTS.md and CLAUDE.md)
# accessible, no source tree, no Chump tooling. Asks it a first-task scenario
# and rubric-scores the output. Substitutes for a paid documentation auditor.
#
# Usage:
#   scripts/audit/onboarding-sim.sh                # run today's audit
#   scripts/audit/onboarding-sim.sh --dry-run      # print prompt + rubric only
#   scripts/audit/onboarding-sim.sh --score-only FILE  # rubric-score an existing transcript
#
# Cadence: monthly (first Monday). Low scores auto-file DOC-* gaps.

set -euo pipefail

DRY_RUN=0
SCORE_ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --score-only) SCORE_ONLY="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
DATE_STAMP="$(date -u +%Y-%m-%d)"
OUT_DIR="$REPO_ROOT/docs/audits"
OUT_FILE="$OUT_DIR/onboarding-sim-$DATE_STAMP.md"
SANDBOX="$(mktemp -d -t chump-onboarding-sim.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$OUT_DIR"

# --- Prompt the cold contributor sees -----------------------------------------
read -r -d '' PROMPT <<'EOF' || true
You are a brand-new contributor to the Chump project. You have read access to
ONLY the ./docs/ directory plus the top-level AGENTS.md and CLAUDE.md files.
You CANNOT see source code, scripts, or run commands.

Answer these four questions using ONLY what the docs tell you. Cite the file
path you got each answer from.

  1. What is the very first thing you must run at the start of every session,
     before picking a gap or editing files? Why?
  2. How do you claim a gap so other agents know you are working on it? Where
     does the claim get written?
  3. What is the difference between `gap-reserve.sh` and `gap-claim.sh`, and
     when do you use each?
  4. You have finished your work and want to ship a PR. What command do you
     use, and what does it do for you?

Format your answer as four numbered sections, each ending with a "Source:" line
listing the docs you relied on. Keep each answer under 120 words.
EOF

# --- Rubric -------------------------------------------------------------------
read -r -d '' RUBRIC <<'EOF' || true
Score each criterion 0–2 (0=missing, 1=partial, 2=correct). Max = 10.

  R1. Pre-flight identified: mentions `gap-preflight.sh`, the ambient.jsonl tail,
      OR the "fetch + status + leases" mandatory block. (0–2)
  R2. Lease semantics correct: claim writes to `.chump-locks/<session>.json`,
      NOT to docs/gaps.yaml. (0–2)
  R3. Reserve vs claim distinction: reserve = atomically picks next free ID for
      a NEW gap; claim = mark an EXISTING gap as in-flight. (0–2)
  R4. Ship pipeline: `scripts/coord/bot-merge.sh --gap <id> --auto-merge` (rebase,
      fmt/clippy/tests, push, open PR, arm auto-merge). (0–2)
  R5. Citations present: every answer cites a real file path inside docs/,
      AGENTS.md, or CLAUDE.md. (0–2)

Pass threshold: ≥ 8/10. Score < 8 auto-files a DOC-* gap describing the
specific friction (which question scored low, what the agent got wrong).
EOF

if [[ -n "$SCORE_ONLY" ]]; then
  echo "Rubric-score mode: $SCORE_ONLY"
  echo
  echo "$RUBRIC"
  echo
  echo "Score the transcript above against each criterion, then write totals to"
  echo "$OUT_FILE under a '## Score' section."
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "=== PROMPT ==="
  echo "$PROMPT"
  echo
  echo "=== RUBRIC ==="
  echo "$RUBRIC"
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "error: 'claude' CLI not on PATH — install Claude Code or run --dry-run" >&2
  exit 3
fi

# Build docs-only sandbox: copy docs/, AGENTS.md, CLAUDE.md into a temp dir.
mkdir -p "$SANDBOX/docs"
cp -R "$REPO_ROOT/docs/." "$SANDBOX/docs/"
[[ -f "$REPO_ROOT/AGENTS.md" ]] && cp "$REPO_ROOT/AGENTS.md" "$SANDBOX/"
[[ -f "$REPO_ROOT/CLAUDE.md" ]] && cp "$REPO_ROOT/CLAUDE.md" "$SANDBOX/"

echo "Sandbox: $SANDBOX (docs-only mount)"
echo "Spawning fresh Claude agent…"

TRANSCRIPT="$(mktemp -t chump-onboarding-transcript.XXXXXX)"
(
  cd "$SANDBOX"
  printf '%s\n' "$PROMPT" \
    | claude -p --dangerously-skip-permissions \
        --add-dir "$SANDBOX/docs" \
        --add-dir "$SANDBOX" \
        2>&1 \
    | tee "$TRANSCRIPT"
) || {
  echo "warn: claude exited non-zero — transcript still captured at $TRANSCRIPT" >&2
}

# --- Write the audit doc ------------------------------------------------------
{
  echo "# Onboarding Simulation — $DATE_STAMP"
  echo
  echo "**Auditor:** \`scripts/audit/onboarding-sim.sh\` (DOC-004)"
  echo "**Mount:** docs-only (\`./docs/\` + AGENTS.md + CLAUDE.md)"
  echo "**Cadence:** monthly (first Monday). Next run: see calendar."
  echo
  echo "## Prompt"
  echo
  echo '```'
  echo "$PROMPT"
  echo '```'
  echo
  echo "## Transcript"
  echo
  echo '```'
  cat "$TRANSCRIPT"
  echo '```'
  echo
  echo "## Rubric"
  echo
  echo '```'
  echo "$RUBRIC"
  echo '```'
  echo
  echo "## Score"
  echo
  echo "_Fill in by hand or via \`--score-only\`. Total < 8 ⇒ file a DOC-* follow-up gap."
  echo "Use \`scripts/coord/gap-reserve.sh DOC \"onboarding gap: <symptom>\"\` to file._"
  echo
  echo "| Criterion | Score |"
  echo "|---|---|"
  echo "| R1 Pre-flight | _/2 |"
  echo "| R2 Lease semantics | _/2 |"
  echo "| R3 Reserve vs claim | _/2 |"
  echo "| R4 Ship pipeline | _/2 |"
  echo "| R5 Citations | _/2 |"
  echo "| **Total** | **_/10** |"
} > "$OUT_FILE"

echo
echo "Wrote $OUT_FILE"
echo "Next: rubric-score the Score section, commit, and (if < 8) file a DOC-* gap."
