#!/usr/bin/env bash
# CI test for INFRA-2252: scripts/coord/local-merge-queue.sh
#
# Synths 3 pending merges against an isolated throwaway git repo (no
# network, no real GitHub calls — CHUMP_NATS_URL is left unset so the
# script exercises the flock fallback path), runs `local-merge-queue.sh
# process`, and asserts all 3 land into local main in enqueue order.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LMQ="${REPO_ROOT}/scripts/coord/local-merge-queue.sh"

ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*" >&2; exit 1; }

echo "[test-local-merge-queue] INFRA-2252 — local merge queue (offline ship path)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export CHUMP_MISSIONS_DIR="$WORK/missions"
export CHUMP_LOCK_DIR="$WORK/repo/.chump-locks"
unset CHUMP_NATS_URL || true

REPO="$WORK/repo"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main
git config user.email "test@chump.local"
git config user.name "Chump Test"
mkdir -p "$CHUMP_LOCK_DIR"
touch "$CHUMP_LOCK_DIR/ambient.jsonl"

echo "root" > README.md
git add README.md
git commit -q -m "root commit"

# 3 feature branches, each one commit ahead of main.
for i in 1 2 3; do
    git checkout -q -b "chump/gap-$i" main
    echo "feature-$i" > "feature-$i.txt"
    git add "feature-$i.txt"
    git commit -q -m "GAP-$i: add feature $i"
done
git checkout -q main

# `chump` is not necessarily on PATH in CI containers; stub it so the
# gap-status-update call inside _process_one is a harmless no-op we can
# still assert against.
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/chump" << 'EOF'
#!/usr/bin/env bash
echo "chump $*" >> "${CHUMP_STUB_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$STUB_BIN/chump"
export CHUMP_STUB_LOG="$WORK/chump-calls.log"
export PATH="$STUB_BIN:$PATH"

# ── 1. Enqueue 3 merge requests ──────────────────────────────────────────────
echo
echo "[1. Enqueue 3 pending merge requests]"
mission_ids=()
for i in 1 2 3; do
    mid="$(bash "$LMQ" enqueue "GAP-$i" "chump/gap-$i")"
    mission_ids+=("$mid")
    sleep 0.01  # keep the epoch-nanosecond filename ordering stable
done

n_pending="$(find "$CHUMP_MISSIONS_DIR" -maxdepth 1 -name 'local-merge-*.json' | wc -l | tr -d ' ')"
[[ "$n_pending" == "3" ]] && ok "3 mission files persisted to \$CHUMP_MISSIONS_DIR" \
    || fail "expected 3 pending mission files, found $n_pending"

n_queued_events="$(grep -c '"kind":"local_merge_queued"' "$CHUMP_LOCK_DIR/ambient.jsonl" || true)"
[[ "$n_queued_events" == "3" ]] && ok "3 kind=local_merge_queued events emitted" \
    || fail "expected 3 local_merge_queued events, found $n_queued_events"

# ── 2. Process the queue ─────────────────────────────────────────────────────
echo
echo "[2. Process the queue]"
bash "$LMQ" process

n_archived="$(find "$CHUMP_MISSIONS_DIR/archive" -maxdepth 1 -name 'local-merge-*.json' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$n_archived" == "3" ]] && ok "all 3 mission files archived (completed)" \
    || fail "expected 3 archived mission files, found $n_archived"

n_pending_after="$(find "$CHUMP_MISSIONS_DIR" -maxdepth 1 -name 'local-merge-*.json' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$n_pending_after" == "0" ]] && ok "no pending mission files remain" \
    || fail "expected 0 pending mission files after process, found $n_pending_after"

n_landed_events="$(grep -c '"kind":"local_merge_landed"' "$CHUMP_LOCK_DIR/ambient.jsonl" || true)"
[[ "$n_landed_events" == "3" ]] && ok "3 kind=local_merge_landed events emitted" \
    || fail "expected 3 local_merge_landed events, found $n_landed_events"

# ── 3. All 3 features landed on local main, in enqueue order ────────────────
echo
echo "[3. All 3 features landed on local main, in order]"
for i in 1 2 3; do
    [[ -f "$REPO/feature-$i.txt" ]] && ok "feature-$i.txt present on main" \
        || fail "feature-$i.txt missing from main after process"
done

log_order="$(git log --format='%s' --reverse main | grep -oE 'GAP-[0-9]+' | tr '\n' ' ')"
[[ "$log_order" == "GAP-1 GAP-2 GAP-3 " ]] && ok "commits landed in FIFO enqueue order ($log_order)" \
    || fail "expected FIFO order 'GAP-1 GAP-2 GAP-3 ', got '$log_order'"

# ── 4. state.db recorded via `chump gap set`, no GitHub calls made ─────────
echo
echo "[4. gap status recorded locally; zero GitHub calls]"
[[ -f "$CHUMP_STUB_LOG" ]] && grep -q "gap set GAP-1 --status done" "$CHUMP_STUB_LOG" \
    && ok "chump gap set --status done called for landed gaps" \
    || fail "expected 'chump gap set GAP-1 --status done' in stub log"

if grep -qiE 'gh pr|gh api|api\.github\.com' "$CHUMP_STUB_LOG" 2>/dev/null; then
    fail "local-merge-queue.sh made a GitHub-shaped call — offline contract violated"
else
    ok "no GitHub-shaped calls observed"
fi

echo
echo "[test-local-merge-queue] all checks passed."
