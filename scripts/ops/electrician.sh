#!/usr/bin/env bash
# electrician.sh — the full-time WIRER. Deterministic, no LLM.
# ChumpOS builds organs (LLM) but kept failing to WIRE them (run on the server).
# The electrician closes that: every shift it reconciles DESIRED (the repo's own
# chump-*.service/.timer unit files) against RUNNING (systemd on this node), and
# installs/enables/repairs whatever is dark. Repo-as-manifest: a new unit file in
# the repo IS a new hire; nothing built stays unpowered. Idempotent, pure exec.
set -uo pipefail
REPO_ROOT="${CHUMP_REPO_ROOT:-/root/Projects/chump}"
cd "$REPO_ROOT" 2>/dev/null || { echo "[electrician] no repo root"; exit 1; }
git fetch origin main -q 2>/dev/null && git merge --ff-only origin/main -q 2>/dev/null || true
SYSD=/etc/systemd/system
wired=0; started=0; healed=0; reloaded=0
shopt -s nullglob
for uf in scripts/dispatch/chump-*.service scripts/dispatch/chump-*.timer; do
  name="$(basename "$uf")"
  if [ ! -f "$SYSD/$name" ] || ! cmp -s "$uf" "$SYSD/$name"; then
    cp "$uf" "$SYSD/$name" && wired=$((wired+1)) && reloaded=1
  fi
done
[ "$reloaded" = 1 ] && systemctl daemon-reload 2>/dev/null
# enable+start every timer (idempotent); start standalone (non-oneshot) services
for uf in scripts/dispatch/chump-*.timer; do
  name="$(basename "$uf")"
  systemctl is-active --quiet "$name" || { systemctl enable --now "$name" 2>/dev/null && started=$((started+1)); }
done
for uf in scripts/dispatch/chump-*.service; do
  name="$(basename "$uf")"
  grep -qiE 'Type=oneshot' "$uf" && continue    # oneshots are timer-driven
  systemctl is-active --quiet "$name" || { systemctl enable --now "$name" 2>/dev/null && started=$((started+1)); }
done
# heal anything failed (reset-failed so its timer/Restart can re-run)
for u in $(systemctl list-units 'chump-*' --state=failed --no-legend 2>/dev/null | awk '{print $1}'); do
  systemctl reset-failed "$u" 2>/dev/null; systemctl start "$u" 2>/dev/null && healed=$((healed+1))
done
active=$(systemctl list-timers 'chump-*' --no-legend 2>/dev/null | grep -c chump)
failed=$(systemctl list-units 'chump-*' --state=failed --no-legend 2>/dev/null | wc -l | tr -d ' ')
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null
printf '{"ts":"%s","kind":"electrician_reconciled","wired":%d,"started":%d,"healed":%d,"active_timers":%d,"failed":%d}\n' \
  "$ts" "$wired" "$started" "$healed" "$active" "$failed" >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null
echo "[electrician $ts] wired=$wired started=$started healed=$healed active_timers=$active failed=$failed"
exit 0
