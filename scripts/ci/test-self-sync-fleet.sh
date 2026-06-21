#!/usr/bin/env bash
# RESILIENT-152 — fleet self-sync regression test.
#
# Proves the load-bearing properties of _self_sync_fleet_scripts() in
# scripts/ops/github-webhook-receiver.py by importing the REAL function and
# running it against a throwaway git repo (no replica — the durable-fix
# doctrine forbids testing a hand-rolled copy of the logic):
#
#   1. a merged change to a runtime path (scripts/ or docs/dispatch/routing.yaml)
#      reaches the fleet's main checkout after a push-to-main webhook;
#   2. canonical state (.chump/state.db) is byte-for-byte UNTOUCHED;
#   3. the call is idempotent (a second run updates nothing);
#   4. a non-main ref is a no-op (the function is always-on by design).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.."
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
RECEIVER="$REPO_ROOT/scripts/ops/github-webhook-receiver.py"

if [[ ! -f "$RECEIVER" ]]; then
  echo "FAIL: receiver not found at $RECEIVER"; exit 1
fi

RECEIVER="$RECEIVER" python3 - <<'PY'
import importlib.util, os, subprocess, sys, tempfile, pathlib, shutil

RECEIVER = os.environ["RECEIVER"]
tmp = pathlib.Path(tempfile.mkdtemp(prefix="selfsync-"))
fails = []
def check(cond, msg):
    print(("  ok: " if cond else "  FAIL: ") + msg)
    if not cond:
        fails.append(msg)

# Point cache/ambient at temp BEFORE import so module-level constants don't
# touch real fleet state.
os.environ["CHUMP_CACHE_DB"] = str(tmp / "cache.db")
os.environ["CHUMP_AMBIENT_LOG"] = str(tmp / "ambient.jsonl")

spec = importlib.util.spec_from_file_location("ghwr", RECEIVER)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

def git(cwd, *a, check=True):
    return subprocess.run(["git", "-C", str(cwd), *a], check=check,
                          capture_output=True, text=True)

# ── Build a fake origin + main checkout ───────────────────────────────────────
origin = tmp / "origin.git"
checkout = tmp / "checkout"
subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
subprocess.run(["git", "clone", "-q", str(origin), str(checkout)], check=True)
git(checkout, "config", "user.email", "t@t")
git(checkout, "config", "user.name", "t")
git(checkout, "checkout", "-q", "-b", "main")

(checkout / "scripts" / "dispatch").mkdir(parents=True)
(checkout / "scripts" / "foo.sh").write_text("echo OLD\n")
(checkout / "docs" / "dispatch").mkdir(parents=True)
(checkout / "docs" / "dispatch" / "routing.yaml").write_text("model_class: OLD\n")
git(checkout, "add", "scripts/foo.sh", "docs/dispatch/routing.yaml")
git(checkout, "commit", "-q", "-m", "seed")
git(checkout, "push", "-q", "-u", "origin", "main")

# Canonical state the fleet mutates — present + UNCOMMITTED, must never be touched.
(checkout / ".chump").mkdir()
state_path = checkout / ".chump" / "state.db"
state_path.write_text("CANONICAL_STATE_v1_do_not_clobber\n")
state_before = state_path.read_bytes()

# ── Advance origin/main with NEW versions of both runtime paths ────────────────
c2 = tmp / "c2"
subprocess.run(["git", "clone", "-q", str(origin), str(c2)], check=True)
git(c2, "config", "user.email", "t@t")
git(c2, "config", "user.name", "t")
git(c2, "checkout", "-q", "main")
(c2 / "scripts" / "foo.sh").write_text("echo NEW\n")
(c2 / "docs" / "dispatch" / "routing.yaml").write_text("model_class: NEW\n")
git(c2, "add", "scripts/foo.sh", "docs/dispatch/routing.yaml")
git(c2, "commit", "-q", "-m", "ship fix")
git(c2, "push", "-q", "origin", "main")

# Pre-state: checkout still OLD; origin/main ref in checkout is STALE (no fetch yet).
check((checkout / "scripts" / "foo.sh").read_text() == "echo OLD\n", "pre: script is OLD")

# ── Run the REAL function (monkeypatch _repo_root onto the throwaway checkout) ─
mod._repo_root = lambda: checkout

n = mod._self_sync_fleet_scripts({"ref": "refs/heads/main", "after": "deadbeefcafe"})
check(n == 2, f"sync updated both runtime paths (got {n})")
check((checkout / "scripts" / "foo.sh").read_text() == "echo NEW\n", "script reached checkout (OLD->NEW)")
check((checkout / "docs" / "dispatch" / "routing.yaml").read_text() == "model_class: NEW\n", "routing.yaml reached checkout")
check(state_path.read_bytes() == state_before, "STATE UNTOUCHED (.chump/state.db byte-identical)")

# ── Idempotency: a second run changes nothing ─────────────────────────────────
n2 = mod._self_sync_fleet_scripts({"ref": "refs/heads/main", "after": "deadbeefcafe"})
check(n2 == 0, f"idempotent: second run is a no-op (got {n2})")

# ── Guard: a non-main ref is a no-op ──────────────────────────────────────────
check(mod._self_sync_fleet_scripts({"ref": "refs/heads/feature"}) == 0, "non-main ref is a no-op")

# ── The fleet_self_sync ambient event was emitted ─────────────────────────────
ambient = pathlib.Path(os.environ["CHUMP_AMBIENT_LOG"])
emitted = ambient.exists() and "fleet_self_sync" in ambient.read_text()
check(emitted, "fleet_self_sync ambient event emitted")

shutil.rmtree(tmp, ignore_errors=True)
print("")
if fails:
    print(f"FAIL: test-self-sync-fleet ({len(fails)} assertion(s) failed)")
    sys.exit(1)
print("PASS: test-self-sync-fleet (cure reaches the fleet; state stays untouched)")
PY
rc=$?
exit $rc
