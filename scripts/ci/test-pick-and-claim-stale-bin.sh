#!/usr/bin/env bash
# test-pick-and-claim-stale-bin.sh — CREDIBLE-1703
# A contract-skewed target/release/chump must be skipped (PATH fallback), and a
# command failure must read claim_cmd_failed, never claim_race_lost.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/scripts/dispatch" "$TMP/repo/target/release" "$TMP/home" "$TMP/path" "$TMP/locks"
cp "$REPO_ROOT"/scripts/dispatch/*.py "$TMP/repo/scripts/dispatch/"
cat > "$TMP/repo/target/release/chump" <<'B'
#!/usr/bin/env bash
echo "chump claim: unknown flag: --role" >&2; exit 2
B
cat > "$TMP/path/chump" <<'B'
#!/usr/bin/env bash
if [ "${2:-}" = "--help" ]; then echo "usage: chump claim --role R"; exit 0; fi
exit 0
B
chmod +x "$TMP/repo/target/release/chump" "$TMP/path/chump"
export HOME="$TMP/home" AMBIENT_JSONL="$TMP/ambient.jsonl" PATH="$TMP/path:$PATH"
unset CHUMP_BIN
cd "$TMP/repo/scripts/dispatch"
python3 - "$TMP" <<'PY'
import sys, json, pathlib
sys.path.insert(0, ".")
import _pick_and_claim_gap as m
tmp = pathlib.Path(sys.argv[1])
chosen = m._resolve_chump_bin()
assert chosen == str(tmp / "path" / "chump"), chosen
assert "chump_bin_skew" in (tmp / "ambient.jsonl").read_text()
# stale binary alone: failure must classify as claim_cmd_failed
import os
os.environ["CHUMP_BIN"] = str(tmp / "repo/target/release/chump")
ok, kind = m.claim_gap_detail("INFRA-1", "s", tmp / "locks")
assert (ok, kind) == (False, "claim_cmd_failed"), (ok, kind)
assert "unknown flag" in m._LAST_CLAIM_ERROR
del os.environ["CHUMP_BIN"]
ok, kind = m.claim_gap_detail("INFRA-1", "s", tmp / "locks")
assert ok and kind == "", (ok, kind)
print("[PASS] stale bin skipped, claim_cmd_failed classified, PATH fallback claims")
PY
