#!/usr/bin/env bash
# journey-odds.sh — THE JOURNEY ODDS BOARD.
#
# Jeff's ask: "how do we know / bet our way from boot and install through each
# breath." This instruments the Trek as ORDERED CHECKPOINTS and prices each
# one's P(success) from a REAL signal, so the OS always knows two numbers:
#   P(this step lands)  and  P(the whole Trek completes from here).
# It is the ROUTER'S INPUT and the "board we should be able to look at."
#
# The Trek journey (checkpoint 0..7):
#   0 BOOT      bare box reachable
#   1 INSTALL   clone + one command -> factory installed
#   2 PROVISION gap-store + eyes + creds + organs up
#   3 POINT     a real gap claimed
#   4 WORK      a worker produces a PR
#   5 GATE      CI + AC-judge
#   6 MERGE     lands on main
#   7 LIVE      merged -> RUNNING -> delivered
#
# Each checkpoint's p_success is derived from a REAL live signal (never
# hardcoded). Where a stage has NO real signal yet it is emitted with
# p_success=null and basis="uninstrumented" — an uninstrumented step IS the
# finding; we do not fabricate a number for it.
#
# p_full_trek = product of the non-null p_success values (the OS's honest odds
# of completing the whole journey from a cold box, given only the steps it can
# actually measure). n_instrumented / n_total says how much of that is real.
#
# Output:
#   ~/.chump/journey-odds.json
#     { generated_at, checkpoints:[{stage,name,signal,value,p_success,basis}],
#       p_full_trek, instrumented, total }
#   + one ambient event  kind=faculty_journey  to .chump-locks/ambient.jsonl
#     (so a dead board is itself observable — same discipline as the collector).
#
# Usage:
#   scripts/ops/journey-odds.sh            # collect + write once, print the board
#   scripts/ops/journey-odds.sh --dry-run  # print JSON to stdout, no writes
#
# Env overrides (all optional):
#   CHUMP_REPO_ROOT / REPO_ROOT   repo checkout root
#   CHUMP_JOURNEY_OUT             output json (default ~/.chump/journey-odds.json)
#   CHUMP_AMBIENT_LOG             ambient jsonl (default REPO_ROOT/.chump-locks/ambient.jsonl)
#   CHUMP_GH_REPO                 owner/repo for gh (default repairman29/chump)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

# HOST-ASSUMPTION FIX (same lesson as faculty-collector.sh): the fleet's service
# convention hardcodes Environment=HOME=/root even when User=jeff, so every tool
# that reads a per-user config from $HOME breaks silently and the board LIES
# (gh->/root/.config/gh denied => 0 merges; almanac->/root/.almanac => fake 100%).
# Resolve the RUN-USER's real home from the passwd db and reset HOME to it.
REAL_HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
[[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]] && REAL_HOME="$HOME"
export HOME="$REAL_HOME"
# PATH-HARDENING: under systemd PATH is minimal (/usr/bin:/bin) so chump/almanac
# in ~/.cargo/bin don't resolve and an unhardened run reads 0 and LIES.
export PATH="$REAL_HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# REPO-ROOT HARDENING (honest-instrument fix, 2026-08-22): the SCRIPT_DIR-derived
# or env-overridden REPO_ROOT can point at a torn-down worktree or a /root-mapped
# path under an organ run, leaving the manifest / gap store / ambient log
# UNREADABLE so the board reads spurious null/0 and LIES (this exact class wrote a
# p_full_trek=0 board while the fleet was shipping 53 PRs/24h). If the manifest
# isn't where we think it is, self-heal to the run-user's canonical checkout.
if [[ ! -f "$REPO_ROOT/scripts/ops/organ-manifest.txt" ]]; then
  for _cand in "$REAL_HOME/Projects/chump" "$SCRIPT_DIR/../.."; do
    if [[ -f "$_cand/scripts/ops/organ-manifest.txt" ]]; then
      REPO_ROOT="$(cd "$_cand" && pwd)"; break
    fi
  done
fi

OUT="${CHUMP_JOURNEY_OUT:-$REAL_HOME/.chump/journey-odds.json}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
GH_REPO="${CHUMP_GH_REPO:-repairman29/chump}"
MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"
INSTALLER="$REPO_ROOT/scripts/setup/install-helsinki-atc.sh"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
command -v jq >/dev/null 2>&1 || { echo "[journey-odds] FATAL: jq not found" >&2; exit 1; }

# ── helpers ─────────────────────────────────────────────────────────────────
# sat n d -> min(1, n/d) clamped to [0,1]; d<=0 => 0
sat() { awk -v n="$1" -v d="$2" 'BEGIN{ if(d+0<=0){printf "%.4f",0; exit} r=(n+0)/(d+0); if(r>1)r=1; if(r<0)r=0; printf "%.4f", r }'; }
# rate a b -> a/(a+b) clamped; a+b<=0 => empty (caller treats as null)
rate() { awk -v a="$1" -v b="$2" 'BEGIN{ t=(a+0)+(b+0); if(t<=0){print ""; exit} printf "%.4f", (a+0)/t }'; }

CP=()  # each element = one checkpoint JSON object
# mkcp STAGE NAME SIGNAL VALUE P_SUCCESS BASIS   (P_SUCCESS="" -> JSON null)
mkcp() {
  local ps_json
  if [[ -z "$5" ]]; then ps_json="null"; else ps_json="$5"; fi
  jq -n \
    --argjson stage "$1" --arg name "$2" --arg signal "$3" \
    --arg value "$4" --argjson p "$ps_json" --arg basis "$6" \
    '{stage:$stage, name:$name, signal:$signal,
      value:($value|tonumber? // $value), p_success:$p, basis:$basis}'
}

# ── 0. BOOT — bare box reachable ────────────────────────────────────────────
# REAL signal: the node is up and this process is executing on it. Uptime proves
# it. (A truly unreachable box never runs this script; a booted-but-degraded box
# still scores 1.0 here because BOOT only asserts "reachable", not "healthy".)
UPTIME_S="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)"
boot_p="1.0000"
CP+=("$(mkcp 0 "BOOT" "node uptime (script executing on node)" \
        "$UPTIME_S" "$boot_p" \
        "host reachable: uptime=${UPTIME_S}s, board process is running on it")")

# ── 1. INSTALL — clone + one command -> factory installed ───────────────────
# REAL signal: of the systemd units the installer's roster declares, how many
# have an actual unit file present on the node. Fully-installed => 1.0.
inst_p=""; inst_val="0/0"; inst_basis="uninstrumented"
ROSTER="$(bash "$INSTALLER" --print-roster 2>/dev/null)"
if [[ -n "$ROSTER" ]]; then
  itot=0; ipresent=0
  while read -r unit; do
    [[ -z "$unit" ]] && continue
    itot=$((itot+1))
    if [[ -f "/etc/systemd/system/$unit" ]] || \
       systemctl cat "$unit" >/dev/null 2>&1; then
      ipresent=$((ipresent+1))
    fi
  done <<< "$ROSTER"
  if [[ "$itot" -gt 0 ]]; then
    inst_p="$(sat "$ipresent" "$itot")"
    inst_val="$ipresent/$itot"
    inst_basis="${ipresent}/${itot} rostered units have a unit file installed on this node"
  fi
fi
CP+=("$(mkcp 1 "INSTALL" "installer roster units present on node" \
        "$inst_val" "$inst_p" "$inst_basis")")

# ── 2. PROVISION — gap-store + eyes + creds + organs up ─────────────────────
# REAL signal: manifest-declared organs that are systemctl is-active. This is
# the faculty-collector's Heal endpoint, computed independently here.
p_active=0; p_total=0
if [[ -f "$MANIFEST" ]]; then
  while read -r _line; do
    u="$(awk '{print $2}' <<<"$_line")"; [[ -z "$u" ]] && continue
    p_total=$((p_total+1))
    [[ "$(systemctl is-active "$u" 2>/dev/null)" == active ]] && p_active=$((p_active+1))
  done < <(grep -E '^enabled' "$MANIFEST")
fi
prov_p=""; prov_val="0/0"; prov_basis="uninstrumented (no manifest)"
if [[ "$p_total" -gt 0 ]]; then
  prov_p="$(sat "$p_active" "$p_total")"
  prov_val="$p_active/$p_total"
  prov_basis="${p_active}/${p_total} manifest organs systemctl is-active"
fi
CP+=("$(mkcp 2 "PROVISION" "manifest organs active" \
        "$prov_val" "$prov_p" "$prov_basis")")

# ── 3. POINT — a real gap claimed ───────────────────────────────────────────
# REAL signal: the gap store is reachable with an open backlog AND at least one
# gap is currently in_progress (claimed). p = fraction of worker slots that are
# actually pointing at work (in_progress / worker slots), gated by backlog>0.
# READABILITY GATE (honest-instrument fix): a gap store we CANNOT read must go
# NULL (excluded from the product), never a hard 0 that collapses P(full Trek).
# "0 open gaps" from a wrong cwd / missing store is INDISTINGUISHABLE from a
# genuinely empty backlog, so we only score POINT when there is a readable,
# NON-EMPTY backlog to point at; otherwise the signal is ambiguous -> null.
point_p=""; point_val="0"
point_basis="uninstrumented: no readable non-empty backlog (gap store unreadable or empty — ambiguous, excluded not zeroed)"
if command -v chump >/dev/null 2>&1; then
  open_json="$( cd "$REPO_ROOT" 2>/dev/null && chump gap list --status open --json 2>/dev/null )"
  ip_json="$( cd "$REPO_ROOT" 2>/dev/null && chump gap list --status in_progress --json 2>/dev/null )"
  gaps_open="$(printf '%s' "$open_json" | grep -c '"id"' 2>/dev/null || echo 0)"
  gaps_ip="$(printf '%s' "$ip_json" | grep -c '"id"' 2>/dev/null || echo 0)"
  [[ "$gaps_open" =~ ^[0-9]+$ ]] || gaps_open=0
  [[ "$gaps_ip"   =~ ^[0-9]+$ ]] || gaps_ip=0
  # worker slots = enabled chump-worker@ units in the manifest (min 1)
  wslots="$(grep -cE '^enabled.*chump-worker@' "$MANIFEST" 2>/dev/null || echo 1)"
  [[ "$wslots" =~ ^[0-9]+$ && "$wslots" -gt 0 ]] || wslots=1
  if [[ "$gaps_open" -gt 0 ]]; then
    point_p="$(sat "$gaps_ip" "$wslots")"
    point_val="$gaps_ip"
    point_basis="${gaps_ip} gap(s) in_progress across ${wslots} worker slot(s); ${gaps_open} open in backlog"
  fi
fi
CP+=("$(mkcp 3 "POINT" "gaps in_progress vs worker slots (backlog>0)" \
        "$point_val" "$point_p" "$point_basis")")

# ── 4. WORK — a worker produces a PR ────────────────────────────────────────
# REAL signal: PRs opened in the last 24h, saturating at a full factory day.
# READABILITY GATE: an UNREACHABLE gh (auth/network) returns empty -> must go
# NULL (excluded), never a hard 0 that collapses the Trek. Only a gh call that
# SUCCEEDED and genuinely saw 0 PRs is a real 0 (workers truly not producing).
prs_json="$(gh pr list --repo "$GH_REPO" --state all --limit 300 --json createdAt 2>/dev/null)"; pr_rc=$?
work_p=""; work_basis="uninstrumented: gh unreachable (PR list read failed)"; prs_opened="0"
if [[ "$pr_rc" -eq 0 && -n "$prs_json" ]]; then
  prs_opened="$(printf '%s' "$prs_json" | jq '[.[]|select(.createdAt > (now-86400|todate))]|length' 2>/dev/null)"
  [[ "$prs_opened" =~ ^[0-9]+$ ]] || prs_opened=0
  if [[ "$prs_opened" -gt 0 ]]; then
    work_p="$(sat "$prs_opened" 60)"
    work_basis="${prs_opened} PR(s) opened in 24h (saturates at 60/day)"
  else
    work_p="0.0000"
    work_basis="0 PRs opened in 24h (gh read ok) — workers are not producing"
  fi
fi
CP+=("$(mkcp 4 "WORK" "PRs opened / 24h" \
        "$prs_opened" "$work_p" "$work_basis")")

# ── 5. GATE — CI + AC-judge ─────────────────────────────────────────────────
# REAL signal: recent CI pass-rate = success / (success + failure) over the last
# runs (skipped/queued excluded — they are not verdicts).
RUNS="$(gh run list --repo "$GH_REPO" --limit 60 --json conclusion \
        --jq '[.[]|.conclusion]' 2>/dev/null)"
ci_succ="$(printf '%s' "$RUNS" | jq '[.[]|select(.=="success")]|length' 2>/dev/null || echo 0)"
ci_fail="$(printf '%s' "$RUNS" | jq '[.[]|select(.=="failure")]|length' 2>/dev/null || echo 0)"
[[ "$ci_succ" =~ ^[0-9]+$ ]] || ci_succ=0
[[ "$ci_fail" =~ ^[0-9]+$ ]] || ci_fail=0
gate_p="$(rate "$ci_succ" "$ci_fail")"
gate_basis="uninstrumented"
if [[ -n "$gate_p" ]]; then
  gate_basis="CI pass-rate ${ci_succ}/$((ci_succ+ci_fail)) decided runs (skipped/queued excluded)"
else
  gate_p=""  # no decided runs -> null, honest
fi
CP+=("$(mkcp 5 "GATE" "CI pass-rate (success/decided)" \
        "$((ci_succ+ci_fail))" "$gate_p" "$gate_basis")")

# ── 6. MERGE — lands on main ────────────────────────────────────────────────
# REAL signal: of the PRs that RESOLVED in the last 24h, the fraction that
# merged (vs closed-unmerged). This is the true "does a green PR land" rate,
# distinct from GATE (which asks if it goes green in the first place).
merged24="$(gh pr list --repo "$GH_REPO" --state merged --limit 300 --json mergedAt \
            --jq '[.[]|select(.mergedAt > (now-86400|todate))]|length' 2>/dev/null)"
closed24="$(gh pr list --repo "$GH_REPO" --state closed --limit 300 --json closedAt,mergedAt \
            --jq '[.[]|select(.mergedAt==null and .closedAt > (now-86400|todate))]|length' 2>/dev/null)"
[[ "$merged24" =~ ^[0-9]+$ ]] || merged24=0
[[ "$closed24" =~ ^[0-9]+$ ]] || closed24=0
merge_p="$(rate "$merged24" "$closed24")"
merge_basis="uninstrumented"
if [[ -n "$merge_p" ]]; then
  merge_basis="${merged24} merged / $((merged24+closed24)) resolved in 24h (rest closed-unmerged)"
else
  merge_p=""  # nothing resolved in 24h -> null, honest
fi
CP+=("$(mkcp 6 "MERGE" "merged / resolved PRs (24h)" \
        "$merged24" "$merge_p" "$merge_basis")")

# ── 7. LIVE — merged -> RUNNING -> delivered ────────────────────────────────
# REAL signal: the merged-not-running rate. Of the organs the manifest declares
# (code that merged and is SUPPOSED to run), the fraction actually is-active.
# Reuses the PROVISION endpoint but framed as delivery: merged != running is the
# #1 recurring disease, so this is the honest "did it actually run" probability.
live_p=""; live_val="0/0"; live_basis="uninstrumented (no manifest)"
if [[ "$p_total" -gt 0 ]]; then
  live_p="$(sat "$p_active" "$p_total")"
  live_val="$p_active/$p_total"
  live_basis="${p_active}/${p_total} declared organs actually running (merged-not-running rate)"
fi
CP+=("$(mkcp 7 "LIVE" "declared organs running (merged->running)" \
        "$live_val" "$live_p" "$live_basis")")

# ── assemble ────────────────────────────────────────────────────────────────
checkpoints_json="$(printf '%s\n' "${CP[@]}" | jq -s 'sort_by(.stage)')"
# p_full_trek = product of non-null p_success; instrumented/total counts honesty
P_FULL="$(printf '%s' "$checkpoints_json" | jq '[.[].p_success|select(.!=null)] | if length==0 then null else reduce .[] as $x (1; .*$x) end')"
N_INSTR="$(printf '%s' "$checkpoints_json" | jq '[.[].p_success|select(.!=null)]|length')"
N_TOTAL="$(printf '%s' "$checkpoints_json" | jq 'length')"

DOC="$(jq -n \
      --arg ts "$NOW" \
      --argjson cp "$checkpoints_json" \
      --argjson pf "$P_FULL" \
      --argjson ni "$N_INSTR" \
      --argjson nt "$N_TOTAL" \
      '{generated_at:$ts, checkpoints:$cp, p_full_trek:$pf, instrumented:$ni, total:$nt}')"

if [[ "$DRY_RUN" == 1 ]]; then
  printf '%s\n' "$DOC"
  exit 0
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
tmp="$(mktemp "${TMPDIR:-$REAL_HOME/.chump}/journey-odds.XXXXXX.json" 2>/dev/null || echo "$OUT.tmp")"
printf '%s\n' "$DOC" > "$tmp" && mv -f "$tmp" "$OUT"

# ambient heartbeat — a dead board is observable, freshness provable from the
# stream alone (same discipline as faculty-collector's faculty_status).
mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
pf_disp="$(printf '%s' "$P_FULL" | jq -r 'if .==null then "null" else (.*10000|round/10000|tostring) end')"
printf '{"ts":"%s","kind":"faculty_journey","checkpoints":%s,"instrumented":%s,"total":%s,"p_full_trek":%s,"out":"%s"}\n' \
  "$NOW" "$N_TOTAL" "$N_INSTR" "$N_TOTAL" "$pf_disp" "$OUT" >> "$AMBIENT_LOG" 2>/dev/null || true

# ── the board (human view) ──────────────────────────────────────────────────
echo "== JOURNEY ODDS BOARD  $NOW =="
printf "  %-2s %-10s %-5s %s\n" "#" "STAGE" "P" "BASIS"
printf '%s' "$checkpoints_json" | jq -r '.[] |
  "\(.stage)\t\(.name)\t\(if .p_success==null then "n/a" else ((.p_success*100)|floor|tostring)+"%" end)\t\(.basis)"' \
  | while IFS=$'\t' read -r stg name p basis; do printf "  %-2s %-10s %-5s %s\n" "$stg" "$name" "$p" "$basis"; done
echo "  -- P(full Trek) = ${pf_disp}  (${N_INSTR}/${N_TOTAL} stages instrumented; uninstrumented excluded)"
echo "[journey-odds] wrote $OUT @ $NOW"
