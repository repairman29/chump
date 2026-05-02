#!/usr/bin/env bash
# check-post-infra-188-gotchas-prunable.sh — INFRA-247
#
# Decides whether docs/process/POST_INFRA_188_GOTCHAS.md is safe to
# delete. Returns:
#   exit 0 — PRUNABLE: all 4 prune criteria from the doc's footer pass
#   exit 1 — KEEP:     at least one criterion fails (with diagnostic)
#
# Criteria (mirror the doc's "Prune criteria" section):
#   1. INFRA-240 status:done in docs/gaps/INFRA-240.yaml
#   2. INFRA-247 status:done in docs/gaps/INFRA-247.yaml
#   3. No commits to the doc in the last 30 days
#   4. (informational) All 5 gotchas have an explicit disposition. This is
#      heuristic only — we count "tracked by INFRA-NNN" or "doc-only" markers
#      in the doc itself.
#
# Run from anywhere in the repo; safe under stale-binary conditions
# (no chump CLI dependency).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

DOC="docs/process/POST_INFRA_188_GOTCHAS.md"
KEEP=0

say()  { printf '\033[1;36m[gotchas-prunable]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[gotchas-prunable]\033[0m PASS %s\n' "$*"; }
fail() { printf '\033[1;33m[gotchas-prunable]\033[0m KEEP %s\n' "$*"; KEEP=1; }

# Bail fast if the doc isn't here — already pruned.
if [[ ! -f "$DOC" ]]; then
    say "$DOC already deleted — nothing to check"
    exit 0
fi

# Criterion 1: INFRA-240 closed
if [[ -f docs/gaps/INFRA-240.yaml ]] \
    && grep -qE '^\s*status:\s*done\s*$' docs/gaps/INFRA-240.yaml; then
    ok "INFRA-240 closed (38 lost per-file YAMLs restored)"
else
    fail "INFRA-240 still open — 38 lost per-file YAMLs not yet restored"
fi

# Criterion 2: INFRA-247 closed
if [[ -f docs/gaps/INFRA-247.yaml ]] \
    && grep -qE '^\s*status:\s*done\s*$' docs/gaps/INFRA-247.yaml; then
    ok "INFRA-247 closed (chump gap reserve respects linked-worktree CWD)"
else
    fail "INFRA-247 still open — chump gap reserve still walks to outer repo_root()"
fi

# Criterion 3: no edits to the doc in 30 days
last_edit_unix=$(git log -1 --format=%ct -- "$DOC" 2>/dev/null || echo 0)
now_unix=$(date +%s)
age_days=$(( (now_unix - last_edit_unix) / 86400 ))
if [[ "$last_edit_unix" -eq 0 ]]; then
    fail "could not read git log for $DOC (file untracked?)"
elif [[ "$age_days" -ge 30 ]]; then
    ok "no edits in $age_days days (>= 30)"
else
    fail "last edit was $age_days days ago (<30) — keep until +$((30 - age_days)) more days of stability"
fi

# Criterion 4 (informational): five gotchas have a disposition
gotcha_count=$(grep -cE '^## [0-9]+\. ' "$DOC" || echo 0)
disposition_count=$(grep -cE 'Tracked by|tracked by|INFRA-[0-9]+|doc-only|no good guard|no enforcement' "$DOC" || echo 0)
if [[ "$gotcha_count" -ge 5 ]] && [[ "$disposition_count" -ge 5 ]]; then
    ok "$gotcha_count gotchas / $disposition_count disposition markers (heuristic)"
else
    say "INFO: $gotcha_count gotchas, $disposition_count disposition markers (heuristic only — review manually)"
fi

echo
if [[ "$KEEP" -eq 0 ]]; then
    say "✓ PRUNABLE — all 4 criteria met. Safe to: git rm $DOC + drop the CLAUDE.md link."
    exit 0
else
    say "✗ KEEP — at least one criterion fails (see [KEEP] lines above)."
    exit 1
fi
