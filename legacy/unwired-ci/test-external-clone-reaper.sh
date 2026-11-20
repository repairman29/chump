#!/usr/bin/env bash
# Smoke test for scripts/ops/external-clone-reaper.sh (MISSION-035).
# Asserts:
#   (a) script is executable
#   (b) --help exits 0
#   (c) empty tree: exits 0, reaps nothing
#   (d) Budget trigger: 5 clone dirs with controlled sizes; small budget causes
#       LRU (oldest-mtime) eviction until under budget; newest survives.
#   (e) Budget large + young clones: no reap
#   (f) budget-gb 0 is accepted (emergency-clear mode) — does not error
#   (g) Path-prefix safety: env pointing at /etc (or other non-.chump path) is
#       refused rather than rm -rf'd
#   (h) Per-repo independence: reaping repo A doesn't touch repo B
#   (i) Ambient emit: kind=external_clone_reaped emitted
#   (j) Age trigger: clones with mtime older than max-age-d reap even when
#       total disk is under budget

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/external-clone-reaper.sh"

WORK_DIR="$(mktemp -d /tmp/clone-reaper-test-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

EXTERNAL_ROOT="$WORK_DIR/external"
AMBIENT="$WORK_DIR/ambient.jsonl"
touch "$AMBIENT"

export CHUMP_EXTERNAL_ROOT="$EXTERNAL_ROOT"
export CHUMP_AMBIENT_PATH="$AMBIENT"
# Override locks root to a temp dir so no real leases interfere.
export CHUMP_LOCKS_ROOT="$WORK_DIR/locks"
mkdir -p "$CHUMP_LOCKS_ROOT"
# Allow EXTERNAL_ROOT to live outside $HOME/.chump/ in unit tests.
export CHUMP_EXTERNAL_ROOT_ALLOW_OUTSIDE=1

PASS=0
FAIL=0
_ok()  { echo "[test] (${1}) $2: OK";  PASS=$((PASS+1)); }
_fail(){ echo "[test] FAIL (${1}) $2"; echo "       $3"; FAIL=$((FAIL+1)); }

# ── (a) executable ────────────────────────────────────────────────────────
if [[ -x "$REAPER" ]]; then
    _ok a "executable"
else
    _fail a "executable" "reaper not executable: $REAPER"
fi

# ── (b) --help ────────────────────────────────────────────────────────────
if "$REAPER" --help >/dev/null 2>&1; then
    _ok b "--help exits 0"
else
    _fail b "--help exits 0" "--help returned non-zero"
fi

# ── (c) empty tree ────────────────────────────────────────────────────────
mkdir -p "$EXTERNAL_ROOT"
out=$("$REAPER" 2>&1)
if echo "$out" | grep -q 'repos=0'; then
    _ok c "empty tree reports repos=0"
else
    _fail c "empty tree reports repos=0" "got: $out"
fi

# ── helpers: make a clone dir with controlled mtime and size ─────────────
_mk_clone() {
    # _mk_clone <owner> <repo> <mtime_spec YYYYMMDDhhmm> <size_mb>
    local owner="$1" repo="$2" mtime_spec="$3" size_mb="$4"
    local cdir="$EXTERNAL_ROOT/$owner/$repo/clone"
    mkdir -p "$cdir"
    # Create a file of the desired size so du reports something meaningful.
    dd if=/dev/zero of="$cdir/content.bin" bs=1048576 count="$size_mb" 2>/dev/null
    touch -t "$mtime_spec" "$cdir"
}

# ── (d) Budget trigger ────────────────────────────────────────────────────
# Create 5 repos, each with a small clone. Budget set tight so oldest are evicted.
# mtimes: oldest → newest (202601 … 202605)
_mk_clone alpha repo-d1 202601010001 2   # oldest, ~2 MB
_mk_clone alpha repo-d2 202602010001 2
_mk_clone alpha repo-d3 202603010001 2
_mk_clone alpha repo-d4 202604010001 2
_mk_clone alpha repo-d5 202605010001 2   # newest, ~2 MB; total ~10 MB

# Budget = 6 MB → should evict oldest 2 (repo-d1, repo-d2) leaving 3 (6 MB).
# Convert 6 MB → GB (0.000006 is awkward; use 0.000006 string, reaper accepts decimals).
# Actually use a simple fraction — 0.006 GB = ~6 MB so 3 clones remain.
# The test sets max-age-d to a large value (365) so age trigger doesn't fire.
"$REAPER" --execute --budget-gb 0.006 --max-age-d 365 >/dev/null 2>&1
remaining_d=$(find "$EXTERNAL_ROOT/alpha" -mindepth 2 -maxdepth 2 -type d -name clone | wc -l | tr -d ' ')
if [[ "$remaining_d" -le "3" ]]; then
    _ok d "budget trigger evicts LRU clones (remaining=$remaining_d)"
else
    _fail d "budget trigger evicts LRU clones" "expected ≤3 remaining, got $remaining_d"
fi
# Newest (repo-d5) must survive.
if [[ -d "$EXTERNAL_ROOT/alpha/repo-d5/clone" ]]; then
    _ok "d.newest" "newest clone (repo-d5) survived budget eviction"
else
    _fail "d.newest" "newest clone (repo-d5) survived" "repo-d5/clone was removed"
fi
# Oldest (repo-d1) must be gone.
if [[ ! -d "$EXTERNAL_ROOT/alpha/repo-d1/clone" ]]; then
    _ok "d.oldest" "oldest clone (repo-d1) was reaped"
else
    _fail "d.oldest" "oldest clone (repo-d1) reaped" "repo-d1/clone still exists"
fi

# ── (e) Large budget + young clones: no reap ─────────────────────────────
# Fresh slate for this test — repo-d3/d4/d5 survived; use a very large budget
# and a very large max-age-d; nothing should be reaped.
before_count=$(find "$EXTERNAL_ROOT/alpha" -mindepth 2 -maxdepth 2 -type d -name clone | wc -l | tr -d ' ')
"$REAPER" --execute --budget-gb 9999 --max-age-d 36500 >/dev/null 2>&1
after_count=$(find "$EXTERNAL_ROOT/alpha" -mindepth 2 -maxdepth 2 -type d -name clone | wc -l | tr -d ' ')
if [[ "$before_count" -eq "$after_count" ]]; then
    _ok e "large budget + young clones: no reap"
else
    _fail e "large budget + young clones: no reap" \
        "before=$before_count after=$after_count — something was reaped unexpectedly"
fi

# ── (f) --budget-gb 0 is accepted (not an error) ─────────────────────────
# budget=0 means "evict everything"; reaper MUST accept it and return 0.
if "$REAPER" --dry-run --budget-gb 0 >/dev/null 2>&1; then
    _ok f "--budget-gb 0 accepted (dry-run, no error)"
else
    _fail f "--budget-gb 0 accepted" "--budget-gb 0 returned non-zero"
fi

# ── (g) Path-prefix safety ───────────────────────────────────────────────
# Point EXTERNAL_ROOT at a path outside ~/.chump/ WITHOUT the bypass flag.
# The reaper must exit non-zero (env-injection guard fires at startup).
BAD_ROOT="$WORK_DIR/not-chump-external"
mkdir -p "$BAD_ROOT/owner/repo/clone"
echo "precious" > "$BAD_ROOT/owner/repo/clone/precious.txt"
# Unset the bypass flag for this call so the guard is active.
if env CHUMP_EXTERNAL_ROOT="$BAD_ROOT" CHUMP_EXTERNAL_ROOT_ALLOW_OUTSIDE=0 \
       "$REAPER" --execute --budget-gb 0 --max-age-d 0 >/dev/null 2>&1; then
    _fail g "path-prefix safety" "reaper exited 0 — guard did NOT fire"
elif [[ -f "$BAD_ROOT/owner/repo/clone/precious.txt" ]]; then
    _ok g "path-prefix safety: guard fired (exit non-zero) and precious.txt intact"
else
    _fail g "path-prefix safety" "guard fired but precious.txt was deleted anyway!"
fi

# ── (h) Per-repo independence ─────────────────────────────────────────────
# Add two new repos under a fresh owner; each ~1 MB clone.
# Budget = 1.5 MB (0.0015 GB = ~1573 KB) — fits one clone but not two.
# LRU (repo-h1, older mtime) should be reaped; repo-h2 (newer) survives.
_mk_clone beta repo-h1 202601010001 1
_mk_clone beta repo-h2 202612010001 1
"$REAPER" --execute --budget-gb 0.0015 --max-age-d 36500 >/dev/null 2>&1
if [[ ! -d "$EXTERNAL_ROOT/beta/repo-h1/clone" ]] \
   && [[ -d "$EXTERNAL_ROOT/beta/repo-h2/clone" ]]; then
    _ok h "per-repo independence: LRU (repo-h1) reaped, repo-h2 survived"
else
    h1_exists="$([ -d "$EXTERNAL_ROOT/beta/repo-h1/clone" ] && echo yes || echo no)"
    h2_exists="$([ -d "$EXTERNAL_ROOT/beta/repo-h2/clone" ] && echo yes || echo no)"
    _fail h "per-repo independence" "repo-h1 exists=$h1_exists repo-h2 exists=$h2_exists"
fi

# ── (i) Ambient emit ──────────────────────────────────────────────────────
if grep -q '"kind":"external_clone_reaped"' "$AMBIENT"; then
    _ok i "ambient emit: kind=external_clone_reaped present"
else
    _fail i "ambient emit" "no external_clone_reaped event found in $AMBIENT"
fi

# ── (j) Age trigger ──────────────────────────────────────────────────────
# Create a new repo with a very old mtime. Budget is HUGE so budget trigger
# won't fire. Max-age-d = 1 so the old clone should be reaped by age alone.
_mk_clone gamma repo-j-old 200001010001 1  # year 2000 → very old
_mk_clone gamma repo-j-new 202612010001 1  # recent touch
"$REAPER" --execute --budget-gb 9999 --max-age-d 1 >/dev/null 2>&1
if [[ ! -d "$EXTERNAL_ROOT/gamma/repo-j-old/clone" ]] \
   && [[ -d "$EXTERNAL_ROOT/gamma/repo-j-new/clone" ]]; then
    _ok j "age trigger: old clone reaped, recent clone survived"
else
    old_exists="$([ -d "$EXTERNAL_ROOT/gamma/repo-j-old/clone" ] && echo yes || echo no)"
    new_exists="$([ -d "$EXTERNAL_ROOT/gamma/repo-j-new/clone" ] && echo yes || echo no)"
    _fail j "age trigger" "old exists=$old_exists new exists=$new_exists"
fi

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "[test-external-clone-reaper] PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "[test-external-clone-reaper] PASS"
