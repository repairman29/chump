#!/usr/bin/env bash
# RESILIENT-320: role-aware node installer (--role factory|data|embed) and
# capacity worker sizing. Hermetic: sources the manifest lib, no host changes.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"
INSTALL="$REPO_ROOT/scripts/setup/chump-node-install.sh"
fail() { echo "[FAIL] $*" >&2; exit 1; }
pass() { echo "[PASS] $*"; }
# shellcheck disable=SC1090
source "$LIB"

has() { case " $1 " in *" $2 "*) return 0;; esac; return 1; }

# 1. rosters match the gap's role definitions
F="$(organ_role_units_for factory)"; D="$(organ_role_units_for data)"; E="$(organ_role_units_for embed)"
for u in chump-cj-worker.service chump-pr-lander.timer chump-integrator.timer chump-node-orchestrator.service \
         chump-disk-monitor.service chump-main-health-watchdog.service chump-stale-worktree-reaper.timer; do
  has "$F" "$u" || fail "factory roster missing $u"
done
for u in chump-node-orchestrator.service chump-disk-monitor.service chump-main-health-watchdog.service chump-postgrest.service; do
  has "$D" "$u" || fail "data roster missing $u"
done
has "$D" chump-pr-lander.timer && fail "data roster must NOT include pr-lander"
has "$D" chump-rot-reaper.timer && fail "data roster must NOT include PR reapers"
[[ "$E" == "chump-node-orchestrator.service chump-disk-monitor.service" ]] || fail "embed roster wrong: $E"
[[ -z "$(organ_role_units_for brain)$(organ_role_units_for muscle)$(organ_role_units_for all)" ]] || fail "legacy roles must have no unit roster"
pass "factory/data/embed unit rosters match the role definitions"

# 2. every rostered unit exists in the real manifest (no typos)
for u in $F $D $E; do
  grep -Eq "^(enabled|disabled)?[[:space:]#]*(enabled|disabled)?[[:space:]]+$u([[:space:]]|$)" "$MANIFEST" || fail "rostered unit not in manifest: $u"
done
pass "all rostered units are declared in organ-manifest.txt"

# 3. legacy role filters unchanged; capacity roles get a broad tag filter
[[ "$(organ_role_filter_for muscle)" == "muscle" ]] || fail "muscle filter changed"
[[ "$(organ_role_filter_for brain)" == "brain,data,janitor,trust" ]] || fail "brain filter changed"
[[ -n "$(organ_role_filter_for factory)" && -n "$(organ_role_filter_for data)" && -n "$(organ_role_filter_for embed)" ]] || fail "capacity roles need a tag filter"
pass "role tag filters ok"

# 4. worker sizing: clamp(1, cores-1), minus 1 with embeds
chk() { [[ "$(organ_worker_count "$1" "$2")" == "$3" ]] || fail "organ_worker_count $1 $2 = $(organ_worker_count "$1" "$2"), want $3"; }
chk 1 0 1; chk 2 0 1; chk 4 0 3; chk 4 1 2; chk 8 0 7; chk 8 1 6; chk 2 1 1; chk 0 0 1
pass "worker count = clamp(1,cores-1) minus 1 with embeds (CJ 4-core+embeds -> 2)"

# 5. installer accepts the new roles and still rejects junk
out="$(bash "$INSTALL" --role bogus 2>&1)"; rc=$?
[[ $rc -eq 2 && "$out" == *factory\|data\|embed* ]] || fail "installer should reject bogus role listing new roles (rc=$rc: $out)"
grep -q 'brain|muscle|all|factory|data|embed) ;;' "$INSTALL" || fail "installer role case missing new roles"
pass "installer role validation covers factory|data|embed"
