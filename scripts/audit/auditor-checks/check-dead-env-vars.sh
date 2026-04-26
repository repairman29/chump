#!/usr/bin/env bash
# check-dead-env-vars.sh — find CHUMP_* env vars referenced in source code that
# have no documentation in .env.example / .env.minimal / book/src/operations.md
# / CLAUDE.md. Emits a single rollup finding (not per-var) since fixing this is
# one batch task — go through the list and either document or delete.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cd "$REPO_ROOT"
log "scanning for dead env vars..."

src_vars="$(grep -REho --include='*.rs' --include='*.sh' --exclude-dir=target --exclude-dir=node_modules \
    -E '\bCHUMP_[A-Z][A-Z0-9_]*' src/ scripts/ 2>/dev/null | sort -u || true)"

doc_vars=""
[ -f .env.example ] && doc_vars="$doc_vars $(grep -hoE '^CHUMP_[A-Z][A-Z0-9_]*' .env.example 2>/dev/null || true)"
[ -f .env.minimal ] && doc_vars="$doc_vars $(grep -hoE '^CHUMP_[A-Z][A-Z0-9_]*' .env.minimal 2>/dev/null || true)"
[ -f book/src/operations.md ] && doc_vars="$doc_vars $(grep -hoE '\bCHUMP_[A-Z][A-Z0-9_]*' book/src/operations.md 2>/dev/null || true)"
[ -f CLAUDE.md ] && doc_vars="$doc_vars $(grep -hoE '\bCHUMP_[A-Z][A-Z0-9_]*' CLAUDE.md 2>/dev/null || true)"
doc_vars=" $(echo "$doc_vars" | tr ' ' '\n' | sort -u | tr '\n' ' ') "

undoc=()
for var in $src_vars; do
    case "$doc_vars" in
        *" $var "*) continue ;;
    esac
    undoc+=("$var")
done

count="${#undoc[@]}"
if [ "$count" -eq 0 ]; then
    log "dead-env-vars done (0 undocumented)."
    exit 0
fi

# Build a JSON array of the first 10 samples for evidence.
samples_json="$(printf '%s\n' "${undoc[@]}" | head -10 | python3 -c '
import json, sys
print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))
')"

key="UNDOCUMENTED_ENV_ROLLUP"
title="Undocumented CHUMP_* env vars: ${count} found"
desc="${count} environment variables matching \`CHUMP_*\` are read from source but have no entry in \`.env.example\`, \`.env.minimal\`, \`book/src/operations.md\`, or \`CLAUDE.md\`. Operators discovering these knobs have to read source. Sample: $(printf '%s, ' "${undoc[@]:0:10}" | sed 's/, $//'). Acceptance criteria: triage the full list (run \`scripts/audit/auditor-checks/check-dead-env-vars.sh\` locally to regenerate) — for each var, either add a one-line entry to \`.env.example\` or delete the unused reference. Close this gap when count is < 25."
emit_finding "dead-env-vars" "$key" "$title" "$desc" "DOC" "P2" "m" "$samples_json"

log "dead-env-vars done (${count} undocumented, rolled up)."
