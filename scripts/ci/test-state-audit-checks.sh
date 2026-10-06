#!/usr/bin/env bash
# META-1051/META-1049: state-audit-checks.py — node-last-seen-vs-expected-up,
# auth-status-vs-real-probe, cycle-kind-vs-PR-merged and gap-done-vs-running-hash. Both divergences are exercised, targets come from
# config (no hard-coded hostnames/IPs), and an unanswerable check is UNKNOWN, never
# a false AGREE. Pure local; fixtures only.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SA="$ROOT/scripts/coord/state-audit-checks.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }; bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

NOW="2026-08-12T12:00:00Z"                       # a Wednesday, 12:00 UTC
NOWE="$(python3 -c "import datetime as d; print(int(d.datetime.fromisoformat('2026-08-12T12:00:00+00:00').timestamp()))")"
mkdir -p "$T/n"
seen() { printf '%s' "$1" > "$T/n/$2"; }          # a "last seen" epoch file read via a command source
seen $((NOWE - 120))    fresh                      # 2 min ago
seen $((NOWE - 7200))   stale                      # 2 h ago
printf '#!/usr/bin/env bash\nexit %s\n' 0 > "$T/probe-alive"; printf '#!/usr/bin/env bash\nexit %s\n' 1 > "$T/probe-dead"
chmod +x "$T/probe-alive" "$T/probe-dead"
for k in ship wip; do echo "$k" > "$T/kind-$k"; done
for m in merged open; do echo "$m" > "$T/pr-$m"; done
echo done > "$T/gap-done"; echo open > "$T/gap-open"
FIXH=1111111aaaa2222222bbbb3333333cccc4444dd; OLDH=9999999ffff0000000eeee1111111aaaa2222bb
echo "$FIXH" > "$T/h-fix"; echo "$OLDH" > "$T/h-old"; echo "${FIXH:0:9}" > "$T/h-fix-short"
printf '#!/usr/bin/env bash\n[[ "$1" == "$2" ]]\n' > "$T/contains"; chmod +x "$T/contains"
echo "ok-live" > "$T/status-ok"; echo "auth_dead: expired" > "$T/status-dead"; echo "???" > "$T/status-weird"

cat > "$T/cfg.json" <<J
{"nodes": [
  {"id": "silent-while-up",  "last_seen": {"type": "command", "cmd": "cat $T/n/stale"}, "expected_up": {"always": true}, "max_silence_secs": 1800},
  {"id": "healthy",          "last_seen": {"type": "command", "cmd": "cat $T/n/fresh"}, "expected_up": {"always": true}, "max_silence_secs": 1800},
  {"id": "off-schedule",     "last_seen": {"type": "command", "cmd": "cat $T/n/stale"},
     "expected_up": {"windows": [{"days": ["sat","sun"], "start": "08:00", "end": "18:00"}]}, "max_silence_secs": 1800},
  {"id": "in-window-silent", "last_seen": {"type": "command", "cmd": "cat $T/n/stale"},
     "expected_up": {"windows": [{"days": ["wed"], "start": "09:00", "end": "17:00"}]}, "max_silence_secs": 1800},
  {"id": "no-data",          "last_seen": {"type": "file", "path": "$T/does-not-exist"}, "expected_up": {"always": true}}
 ],
 "auth": [
  {"id": "false-ok",   "status": {"type": "file", "path": "$T/status-ok"},   "ok_values": ["ok","live"], "dead_values": ["dead","expired"], "probe_cmd": "$T/probe-dead"},
  {"id": "false-dead", "status": {"type": "file", "path": "$T/status-dead"}, "ok_values": ["ok","live"], "dead_values": ["dead","expired"], "probe_cmd": "$T/probe-alive"},
  {"id": "agree-ok",   "status": {"type": "file", "path": "$T/status-ok"},   "ok_values": ["ok","live"], "dead_values": ["dead","expired"], "probe_cmd": "$T/probe-alive"},
  {"id": "agree-dead", "status": {"type": "file", "path": "$T/status-dead"}, "ok_values": ["ok","live"], "dead_values": ["dead","expired"], "probe_cmd": "$T/probe-dead"},
  {"id": "unreadable", "status": {"type": "file", "path": "$T/status-weird"}, "ok_values": ["ok"], "dead_values": ["dead"], "probe_cmd": "$T/probe-alive"},
  {"id": "no-probe",   "status": {"type": "file", "path": "$T/status-ok"},   "ok_values": ["ok","live"], "dead_values": ["dead"]}
 ],
 "cycles": [
  {"id": "false-shipped",   "kind": {"type": "file", "path": "$T/kind-ship"}, "pr_merged": {"type": "file", "path": "$T/pr-open"}},
  {"id": "false-unshipped", "kind": {"type": "file", "path": "$T/kind-wip"},  "pr_merged": {"type": "file", "path": "$T/pr-merged"}},
  {"id": "cyc-agree-ship",  "kind": {"type": "file", "path": "$T/kind-ship"}, "pr_merged": {"type": "file", "path": "$T/pr-merged"}},
  {"id": "cyc-agree-wip",   "kind": {"type": "file", "path": "$T/kind-wip"},  "pr_merged": {"type": "file", "path": "$T/pr-open"}},
  {"id": "cyc-no-pr",       "kind": {"type": "file", "path": "$T/kind-ship"}, "pr_merged": {"type": "file", "path": "$T/nope"}}
 ],
 "gaps": [
  {"id": "done-not-running", "status": {"type": "file", "path": "$T/gap-done"}, "fix_hash": {"type": "file", "path": "$T/h-fix"}, "running_hash": {"type": "file", "path": "$T/h-old"}},
  {"id": "done-and-running", "status": {"type": "file", "path": "$T/gap-done"}, "fix_hash": {"type": "file", "path": "$T/h-fix"}, "running_hash": {"type": "file", "path": "$T/h-fix"}},
  {"id": "done-running-short", "status": {"type": "file", "path": "$T/gap-done"}, "fix_hash": {"type": "file", "path": "$T/h-fix"}, "running_hash": {"type": "file", "path": "$T/h-fix-short"}},
  {"id": "done-ancestor-cmd", "status": {"type": "file", "path": "$T/gap-done"}, "fix_hash": {"type": "file", "path": "$T/h-fix"}, "running_hash": {"type": "file", "path": "$T/h-old"}, "contains_cmd": "$T/contains {fix} {fix}"},
  {"id": "not-done",         "status": {"type": "file", "path": "$T/gap-open"}, "fix_hash": {"type": "file", "path": "$T/h-fix"}, "running_hash": {"type": "file", "path": "$T/h-old"}},
  {"id": "no-running-hash",  "status": {"type": "file", "path": "$T/gap-done"}, "fix_hash": {"type": "file", "path": "$T/h-fix"}, "running_hash": {"type": "file", "path": "$T/nope"}}
 ]}
J
run() { python3 "$SA" --config "$T/cfg.json" --now "$NOW" --json "$@" 2>"$T/err.txt"; }
v() { python3 -c "
import sys, json
for l in sys.stdin:
    r = json.loads(l)
    if r['target'] == '$1': print(r['verdict'])"; }
out="$(run)"

# Node check
[[ "$(v silent-while-up <<<"$out")" == "DIVERGE" ]] && ok "node silent while expected up -> DIVERGE" || bad "silent-while-up: $(v silent-while-up <<<"$out")"
[[ "$(v healthy <<<"$out")" == "AGREE" ]] && ok "recently seen node -> AGREE" || bad "healthy"
[[ "$(v off-schedule <<<"$out")" == "AGREE" ]] && ok "silent OUTSIDE its expected-up window -> AGREE (silence is expected)" || bad "off-schedule"
[[ "$(v in-window-silent <<<"$out")" == "DIVERGE" ]] && ok "silent inside its weekday window -> DIVERGE" || bad "in-window-silent"
[[ "$(v no-data <<<"$out")" == "UNKNOWN" ]] && ok "no last-seen ground truth -> UNKNOWN, never a false AGREE" || bad "no-data"

# Auth check
[[ "$(v false-ok <<<"$out")" == "DIVERGE" ]] && grep -q 'false-ok' <<<"$(python3 "$SA" --config "$T/cfg.json" --now "$NOW" 2>/dev/null)" \
  && ok "reported ok but probe dead -> DIVERGE (false-ok)" || bad "false-ok"
[[ "$(v false-dead <<<"$out")" == "DIVERGE" ]] && grep -q 'false-dead' <<<"$(python3 "$SA" --config "$T/cfg.json" --now "$NOW" 2>/dev/null)" \
  && ok "reported dead but probe alive -> DIVERGE (false-dead)" || bad "false-dead"
[[ "$(v agree-ok <<<"$out")" == "AGREE" && "$(v agree-dead <<<"$out")" == "AGREE" ]] && ok "report matches probe (ok/ok and dead/dead) -> AGREE" || bad "agree cases"
[[ "$(v unreadable <<<"$out")" == "UNKNOWN" && "$(v no-probe <<<"$out")" == "UNKNOWN" ]] && ok "unrecognised status or missing probe -> UNKNOWN" || bad "unknown cases"

# Cycle kind vs PR merged (META-1049)
[[ "$(v false-shipped <<<"$out")" == "DIVERGE" ]] && ok "cycle reports ship but PR not merged -> DIVERGE (false-shipped)" || bad "false-shipped"
[[ "$(v false-unshipped <<<"$out")" == "DIVERGE" ]] && ok "cycle reports no ship but PR merged -> DIVERGE (false-unshipped)" || bad "false-unshipped"
[[ "$(v cyc-agree-ship <<<"$out")" == "AGREE" && "$(v cyc-agree-wip <<<"$out")" == "AGREE" ]] && ok "cycle kind matches PR outcome (ship+merged, wip+open) -> AGREE" || bad "cycle agree"
[[ "$(v cyc-no-pr <<<"$out")" == "UNKNOWN" ]] && ok "no PR merge ground truth -> UNKNOWN" || bad "cyc-no-pr"

# Gap done vs running hash (META-1049)
[[ "$(v done-not-running <<<"$out")" == "DIVERGE" ]] && ok "gap done but fix hash not running -> DIVERGE (done-but-not-running)" || bad "done-not-running"
[[ "$(v done-and-running <<<"$out")" == "AGREE" && "$(v done-running-short <<<"$out")" == "AGREE" ]] && ok "gap done and fix running (full or short hash) -> AGREE" || bad "done-and-running"
[[ "$(v done-ancestor-cmd <<<"$out")" == "AGREE" ]] && ok "contains_cmd exit 0 (running build has the fix) -> AGREE" || bad "contains_cmd"
[[ "$(v not-done <<<"$out")" == "AGREE" ]] && ok "gap not reported done -> AGREE (nothing to contradict)" || bad "not-done"
[[ "$(v no-running-hash <<<"$out")" == "UNKNOWN" ]] && ok "running hash unavailable -> UNKNOWN, never a false AGREE" || bad "no-running-hash"
only="$(python3 "$SA" --config "$T/cfg.json" --now "$NOW" --check gaps --json 2>/dev/null | python3 -c "import sys,json; print({json.loads(l)['check'] for l in sys.stdin})")"
[[ "$only" == "{'gap_done_vs_running_hash'}" ]] && ok "--check gaps runs only the gap check" || bad "gaps selection: $only"

# Output contract: one glanceable pipe-separated line, strict exit, check selection
text="$(python3 "$SA" --config "$T/cfg.json" --now "$NOW" 2>/dev/null)"
grep -qE '^node_last_seen_vs_expected_up\[silent-while-up\] \| expected up \| last seen 2h00m ago \| DIVERGE$' <<<"$text" \
  && ok "glanceable 'check | self_report | ground_truth | VERDICT' line" || bad "line format: $(grep silent-while-up <<<"$text")"
python3 "$SA" --config "$T/cfg.json" --now "$NOW" --strict >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "--strict exits 1 on any DIVERGE" || bad "strict rc"
python3 "$SA" --config "$T/cfg.json" --now "$NOW" >/dev/null 2>&1; [[ $? -eq 0 ]] && ok "default exit is 0 (findings are data)" || bad "default rc"
only="$(python3 "$SA" --config "$T/cfg.json" --now "$NOW" --check auth --json 2>/dev/null | python3 -c "import sys,json; print({json.loads(l)['check'] for l in sys.stdin})")"
[[ "$only" == "{'auth_status_vs_probe'}" ]] && ok "--check auth runs only the auth check" || bad "check selection: $only"

# Config-driven, host-agnostic
python3 "$SA" >/dev/null 2>"$T/e"; rc=$?
[[ $rc -eq 2 ]] && grep -q 'never hard-coded' "$T/e" && ok "no config -> exit 2 with a clear message (targets are never hard-coded)" || bad "no-config rc=$rc"
! grep -qE '([0-9]{1,3}\.){3}[0-9]{1,3}|\.(ts\.net|local|internal)\b' "$SA" "$ROOT/scripts/coord/state-audit-targets.example.json" \
  && ok "no IP addresses or internal domains hard-coded in the check or its example config" || bad "hard-coded identifier found"

echo "=== state-audit checks: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
