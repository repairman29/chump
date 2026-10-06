#!/usr/bin/env bash
# ZERO-WASTE-128: wiring-triage.py turns each finding into exactly one of
# WIRE / ALLOWLIST-DORMANT / ARCHIVE-DEAD, records who/why for allowlisted items,
# and does not re-flag them on a re-scan. Fixture findings, all three outcomes.
# Pure local; no network.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export TRI="$ROOT/scripts/ops/wiring-triage.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }; bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

R="$T/repo"; mkdir -p "$R/scripts/coord"
git -C "$R" init -q; git -C "$R" config user.email ci@chump.test; git -C "$R" config user.name CI
mk() { printf '#!/usr/bin/env bash\n# %s\ntrue\n' "$2" > "$R/scripts/coord/$1"; }
mk fresh-beat.sh      "fresh-beat.sh — runs every 10 min"
mk ancient-orphan.sh  "ancient-orphan.sh — runs every 10 min"
mk parked-tool.sh     "parked-tool.sh — runs every 10 min"
mk old-but-referenced.sh "old-but-referenced.sh — runs every 10 min"
printf '#!/usr/bin/env bash\nbash scripts/coord/old-but-referenced.sh\n' > "$R/scripts/coord/user.sh"
NOW=1800000000                      # fixed "now" so ages are deterministic
OLD=$((NOW - 400*86400)); NEW=$((NOW - 3*86400))
git -C "$R" add -A
GIT_AUTHOR_DATE="@$OLD" GIT_COMMITTER_DATE="@$OLD" git -C "$R" -c commit.gpgsign=false commit -q -m "old files"
echo "# touched" >> "$R/scripts/coord/fresh-beat.sh"
git -C "$R" add -A
GIT_AUTHOR_DATE="@$NEW" GIT_COMMITTER_DATE="@$NEW" git -C "$R" -c commit.gpgsign=false commit -q -m "touch fresh"

F="$T/findings.jsonl"
for a in fresh-beat ancient-orphan parked-tool old-but-referenced; do
  printf '{"detector":"D1","name":"no-scheduler","severity":"med","artifact":"scripts/coord/%s.sh","detail":"x","evidence":{}}\n' "$a"
done > "$F"
tri() { python3 "$TRI" --repo "$R" --findings "$F" --now "$NOW" "$@" 2>"$T/err.txt"; }
dec() { python3 -c "
import sys, json
for l in sys.stdin:
    r = json.loads(l); print(r['artifact'].split('/')[-1], r['triage']['decision'])" ; }

# 1. No allowlist yet: recent -> WIRE; old+unreferenced -> ARCHIVE-DEAD; old but referenced -> WIRE
got="$(tri | dec | sort | tr '\n' ';')"
want="ancient-orphan.sh ARCHIVE-DEAD;fresh-beat.sh WIRE;old-but-referenced.sh WIRE;parked-tool.sh ARCHIVE-DEAD;"
[[ "$got" == "$want" ]] && ok "WIRE for recent/referenced items, ARCHIVE-DEAD for old + unreferenced ones" || bad "decisions: $got"

# 2. Allowlist parked-tool.sh: who + why recorded, decision becomes ALLOWLIST-DORMANT
python3 "$TRI" allow --repo "$R" --artifact scripts/coord/parked-tool.sh --detector D1 --by "jordan" \
    --reason "kept for the manual failover drill; intentionally unscheduled" >/dev/null
[[ -f "$R/docs/process/wiring-allowlist.jsonl" ]] && ok "allowlist file created" || bad "no allowlist file"
got="$(tri --show-allowlisted | python3 -c "
import sys, json
for l in sys.stdin:
    r = json.loads(l)
    if r['triage']['decision'] == 'ALLOWLIST-DORMANT':
        t = r['triage']; print(r['artifact'].split('/')[-1], t['decided_by'], '|', t['reason'])")"
[[ "$got" == "parked-tool.sh jordan | kept for the manual failover drill; intentionally unscheduled" ]] \
    && ok "ALLOWLIST-DORMANT records who decided and why" || bad "allowlisted record: $got"

# 3. Re-scan does not re-flag the allowlisted item (it vanishes from actionable output)
got="$(tri | dec | sort | tr '\n' ';')"
want="ancient-orphan.sh ARCHIVE-DEAD;fresh-beat.sh WIRE;old-but-referenced.sh WIRE;"
[[ "$got" == "$want" ]] && ok "re-scan does not re-flag the allowlisted item" || bad "rescan: $got"
grep -q 'ALLOWLIST-DORMANT=1' "$T/err.txt" && ok "the suppressed item is still counted in the summary" || bad "summary: $(cat "$T/err.txt")"

# 4. Exactly one decision per finding; all three outcomes covered
python3 - "$T" <<'PY' && ok "exactly one of the three decisions per finding; all three outcomes exercised" || bad "decision cardinality"
import json, subprocess, sys
t = sys.argv[1]
out = subprocess.run(["python3", f"{__import__('os').environ.get('TRI')}", "--repo", f"{t}/repo", "--findings", f"{t}/findings.jsonl",
                      "--now", "1800000000", "--show-allowlisted"], capture_output=True, text=True).stdout
rows = [json.loads(l) for l in out.splitlines()]
assert len(rows) == 4
for r in rows:
    assert r["triage"]["decision"] in ("WIRE", "ALLOWLIST-DORMANT", "ARCHIVE-DEAD") and "why" in r["triage"], r
assert {r["triage"]["decision"] for r in rows} == {"WIRE", "ALLOWLIST-DORMANT", "ARCHIVE-DEAD"}
PY

# 5. An allowlist entry with no owner or no reason is refused (and not honored if hand-edited in)
python3 "$TRI" allow --repo "$R" --artifact scripts/coord/ancient-orphan.sh --detector D1 --by "" --reason "because" >/dev/null 2>&1; [[ $? -eq 2 ]] \
    && ok "allow without --by is rejected" || bad "ownerless allow accepted"
python3 "$TRI" allow --repo "$R" --artifact scripts/coord/ancient-orphan.sh --detector D1 --by "jordan" --reason "  " >/dev/null 2>&1; [[ $? -eq 2 ]] \
    && ok "allow without a reason is rejected" || bad "reasonless allow accepted"
echo '{"artifact":"scripts/coord/ancient-orphan.sh","detector":"D1","decided_by":"","reason":"hand edited"}' >> "$R/docs/process/wiring-allowlist.jsonl"
got="$(tri | dec | grep ancient-orphan)"
[[ "$got" == "ancient-orphan.sh ARCHIVE-DEAD" ]] && ok "a hand-edited entry missing its owner is not honored" || bad "ownerless entry honored: $got"
python3 "$TRI" allow --repo "$R" --artifact scripts/coord/parked-tool.sh --detector D1 --by "x" --reason "y" >/dev/null 2>&1; [[ $? -eq 2 ]] \
    && ok "duplicate allowlist entries are rejected" || bad "duplicate accepted"

echo "=== wiring triage: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
