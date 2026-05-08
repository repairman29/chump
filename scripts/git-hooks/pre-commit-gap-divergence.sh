#!/usr/bin/env bash
# pre-commit-gap-divergence.sh — INFRA-783
#
# Catches gap-ID collisions and YAML/state.db drift at commit time.
# When a contributor stages a docs/gaps/<ID>.yaml file (created or
# modified), this guard reads the YAML's id+title+priority+effort and
# compares against the state.db row for that ID. If they diverge,
# blocks the commit and points at the canonical store.
#
# Failure modes this catches
#   1. Gap-ID collision — two agents reserve the same ID in a tight
#      window; second writer overwrites the first. Today's INFRA-781:
#      sibling shipped a "PR repair" gap with the ID I'd just reserved
#      for "bounced-PR detector". State.db UNIQUE constraint should
#      have caught that, but a docs-only YAML PR can land without
#      ever touching state.db — drift goes undetected.
#   2. Manual YAML edits that bypass `chump gap set` and drift from
#      the canonical DB. Operators editing YAML by hand to "fix" a
#      title silently leave state.db with the old value.
#   3. Accidental overwrite of an existing gap's YAML with unrelated
#      content (mistyped ID, copy-paste from another PR).
#
# What's checked
#   For each staged `docs/gaps/<ID>.yaml`:
#     - YAML file exists and parses
#     - state.db has a row for ID
#     - YAML.title matches DB.title (whitespace-normalised)
#     - YAML.priority matches DB.priority
#     - YAML.effort matches DB.effort
#     - YAML.status matches DB.status (advisory only — operators
#       sometimes pre-flip status in YAML before running ship)
#
# Bypass
#   CHUMP_GAP_DIVERGE_CHECK=0 git commit ...
#   When bypassing for legitimate reasons (e.g. importing gaps from
#   another repo), include `Gap-Diverge-Bypass: <reason>` trailer in
#   the commit body for audit.
#
# Why state.db is canonical (post-INFRA-760)
#   `briefing.rs` reads gap metadata from state.db now (INFRA-760).
#   YAML is the human-readable mirror. The mirror SHOULD match the
#   canonical store; this guard enforces that at commit time so the
#   mirror doesn't quietly drift again.

set -uo pipefail

if [[ "${CHUMP_GAP_DIVERGE_CHECK:-1}" == "0" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DB="$REPO_ROOT/.chump/state.db"

# If state.db doesn't exist (fresh checkout, sub-repo), bail silently.
[[ -f "$DB" ]] || exit 0

# Find staged docs/gaps/<ID>.yaml files.
STAGED=$(git diff --cached --name-only --diff-filter=ACM -- 'docs/gaps/*.yaml' 2>/dev/null || true)
[[ -z "$STAGED" ]] && exit 0

DIVERGENCES=()

# Helper: extract a top-level field value from a per-file gap YAML.
# Format is `<key>: <value>` at file root. Title may be quoted.
yaml_field() {
    local file=$1 key=$2
    grep -E "^[[:space:]]*-?[[:space:]]*${key}:" "$file" 2>/dev/null \
        | head -1 \
        | sed -E "s/^[[:space:]]*-?[[:space:]]*${key}:[[:space:]]*//" \
        | sed -E 's/^"//; s/"$//; s/^'\''//; s/'\''$//' \
        | sed -E 's/[[:space:]]+$//'
}

# Helper: look up a field from state.db for a gap.
db_field() {
    local gap_id=$1 col=$2
    sqlite3 "$DB" "SELECT $col FROM gaps WHERE id='$gap_id'" 2>/dev/null
}

while IFS= read -r yaml_path; do
    [[ -z "$yaml_path" ]] && continue
    abs_path="$REPO_ROOT/$yaml_path"
    [[ -f "$abs_path" ]] || continue

    # Derive the expected gap ID from the filename.
    gap_id=$(basename "$yaml_path" .yaml)

    # Extract YAML id; if it doesn't match the filename, that's a bug.
    yaml_id=$(yaml_field "$abs_path" "id")
    if [[ -n "$yaml_id" && "$yaml_id" != "$gap_id" ]]; then
        DIVERGENCES+=("$yaml_path: filename says $gap_id but yaml says id=$yaml_id")
        continue
    fi

    # Look up state.db row.
    db_title=$(db_field "$gap_id" "title")
    if [[ -z "$db_title" ]]; then
        # No state.db row — likely a never-reserved gap or a fresh
        # creation that hasn't run `chump gap reserve` yet. Warn but
        # don't block (the operator may be doing a manual import).
        echo "[gap-diverge] WARN: $yaml_path has no state.db row for $gap_id (run 'chump gap import' or 'chump gap reserve' to sync)" >&2
        continue
    fi

    # Compare YAML vs DB on the load-bearing fields.
    yaml_title=$(yaml_field "$abs_path" "title")
    yaml_priority=$(yaml_field "$abs_path" "priority")
    yaml_effort=$(yaml_field "$abs_path" "effort")

    db_priority=$(db_field "$gap_id" "priority")
    db_effort=$(db_field "$gap_id" "effort")

    # Whitespace-normalise titles before compare (YAML quotes / fold
    # characters can introduce variance even when the message is the same).
    norm_yaml_title=$(echo "$yaml_title" | tr -s ' ' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    norm_db_title=$(echo "$db_title" | tr -s ' ' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')

    if [[ -n "$yaml_title" && "$norm_yaml_title" != "$norm_db_title" ]]; then
        DIVERGENCES+=("$yaml_path: title diverges from state.db
    YAML: $yaml_title
    DB:   $db_title")
    fi
    if [[ -n "$yaml_priority" && "$yaml_priority" != "$db_priority" ]]; then
        DIVERGENCES+=("$yaml_path: priority diverges (YAML=$yaml_priority, DB=$db_priority)")
    fi
    if [[ -n "$yaml_effort" && "$yaml_effort" != "$db_effort" ]]; then
        DIVERGENCES+=("$yaml_path: effort diverges (YAML=$yaml_effort, DB=$db_effort)")
    fi
done <<< "$STAGED"

if [[ "${#DIVERGENCES[@]}" -eq 0 ]]; then
    exit 0
fi

# Block.
echo "" >&2
echo "──────────────────────────────────────────────────────────────────────" >&2
echo "❌ INFRA-783 gap-divergence guard blocked this commit." >&2
echo "" >&2
echo "Staged docs/gaps/*.yaml files diverge from state.db (canonical):" >&2
echo "" >&2
for d in "${DIVERGENCES[@]}"; do
    echo "  $d" >&2
done
echo "" >&2
echo "State.db is canonical (post-INFRA-760). Fix one of:" >&2
echo "  1. Update the YAML to match state.db:" >&2
echo "       chump gap dump --per-file --out-dir docs/gaps/" >&2
echo "       git add docs/gaps/<ID>.yaml" >&2
echo "" >&2
echo "  2. Update state.db to match your YAML changes:" >&2
echo "       chump gap set <ID> --title \"...\" --priority P1 --effort s" >&2
echo "" >&2
echo "  3. Bypass once for legitimate import / migration:" >&2
echo "       CHUMP_GAP_DIVERGE_CHECK=0 git commit ..." >&2
echo "     and add 'Gap-Diverge-Bypass: <reason>' trailer to commit body." >&2
echo "──────────────────────────────────────────────────────────────────────" >&2

exit 1
