#!/usr/bin/env bash
# test-worker-disk-gate-before-pick.sh — RESILIENT-2220
# The worker's disk gate must run before the atomic picker (which leases the
# gap it returns), so a disk_critical pause never leaks a lease.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$REPO_ROOT/scripts/dispatch/worker.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL $*"; exit 1; }

g=$(grep -n 'chump_disk_check_pause_worker; then' "$W" | head -1 | cut -d: -f1)
p=$(grep -n 'python3 "\$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"' "$W" | head -1 | cut -d: -f1)
[ -n "$g" ] && [ -n "$p" ] || fail "markers not found (gate=$g pick=$p)"
[ "$g" -lt "$p" ] || fail "disk gate (line $g) is after picker (line $p)"
[ "$(grep -c 'chump_disk_check_pause_worker; then' "$W")" = 1 ] || fail "gate duplicated"

mkdir -p "$TMP/bin" "$TMP/leases"
cat > "$TMP/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "/dev/fake 1000000000 999000000 100 99% /fake"
EOF
chmod +x "$TMP/bin/df"
{
  echo "set -u"
  echo "REPO_ROOT=\"$REPO_ROOT\""
  echo "export CHUMP_AMBIENT_LOG=\"$TMP/ambient.jsonl\" CHUMP_DISK_PAUSE_SLEEP_S=0"
  echo "log() { :; }"
  echo "for cycle in 1 2; do"
  awk '/INFRA-975 \/ RESILIENT-2220/{f=1} f{print} /^    fi$/{if(f){exit}}' "$W"
  echo "    touch \"$TMP/leases/lease-\$cycle\""
  echo "done"
} > "$TMP/cycle.sh"
PATH="$TMP/bin:$PATH" bash "$TMP/cycle.sh" || fail "cycle skeleton errored"
n=$(ls "$TMP/leases" | wc -l)
[ "$n" = 0 ] || fail "$n lease(s) created while disk critical"
echo "PASS worker-disk-gate-before-pick (0 leases after 2 critical cycles)"
