#!/usr/bin/env bash
# test-fleet-health-sentinel-system-organs.sh — RESILIENT-1055
#
# Covers the RESILIENT-1055 extension to the anti-Memento sentinel: it must
# watch the SYSTEM-scope roster the --user scan is structurally blind to, heal a
# DEAD timer (active but no scheduled next fire — the decay signature that hid
# on closetjunky/cuphead 2026-09-08), and PAGE on a force-push race (≥2 rebaser
# organs active). Driven with injected fake systemctls at both scopes — no root,
# no real units.
#
# DEPTH: adversarial for the decay + race classes this PR targets — asserts the
# dead-timer heal path (start-the-service re-arm), the race page, AND the two
# negative cases (healthy organ → no heal; single rebaser → no page). GAP: does
# not exercise real sudo/polkit or a real systemd manager (that is the live
# proof in the PR body), and does not cover the --fleet cross-node grade.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SENTINEL="$REPO_ROOT/scripts/ops/fleet-health-sentinel.sh"
[[ -f "$SENTINEL" ]] || { echo "FAIL: sentinel not found at $SENTINEL" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/units"; mkdir -p "$STATE"

# ── fake SYSTEM systemctl: state lives in $STATE/<unit>.{exists,active,rt,mono}
FAKESYS="$WORK/fakesys"
cat > "$FAKESYS" <<FAKE
#!/usr/bin/env bash
S="$STATE"
cmd="\$1"; shift || true
case "\$cmd" in
  is-active)     u="\$1"; cat "\$S/\$u.active" 2>/dev/null || echo inactive ;;
  list-unit-files)
     u="\$1"; [[ -f "\$S/\$u.exists" ]] && echo "\$u enabled enabled" ;;
  show)
     u="\$1"; prop=""; for a in "\$@"; do case "\$a" in -p) : ;; NextElapse*) prop="\$a";; esac; done
     if [[ "\$prop" == NextElapseUSecRealtime ]]; then cat "\$S/\$u.rt" 2>/dev/null || echo ""; fi
     if [[ "\$prop" == NextElapseUSecMonotonic ]]; then cat "\$S/\$u.mono" 2>/dev/null || echo ""; fi ;;
  start)
     svc="\$1"; t="\${svc%.service}.timer"           # starting the oneshot re-arms its timer
     echo active > "\$S/\$t.active"; echo "" > "\$S/\$t.rt"; echo "1w 2h 3min" > "\$S/\$t.mono" ;;
  enable) # "enable --now <unit>"
     for a in "\$@"; do case "\$a" in --now) : ;; -*) : ;; *) echo active > "\$S/\$a.active";; esac; done ;;
  restart|reset-failed|daemon-reload|list-units) : ;;
  *) : ;;
esac
exit 0
FAKE
chmod +x "$FAKESYS"

# fake USER systemctl: node is clean (no failed units, no healers) so the
# --user path is a no-op and cannot mask the SYSTEM-scope assertions.
FAKEUSER="$WORK/fakeuser"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEUSER"; chmod +x "$FAKEUSER"

set_unit() { # set_unit <unit> <exists> <active> <rt> <mono>
    local u="$1"
    [[ "$2" == 1 ]] && : > "$STATE/$u.exists" || rm -f "$STATE/$u.exists"
    echo "$3" > "$STATE/$u.active"; echo "$4" > "$STATE/$u.rt"; echo "$5" > "$STATE/$u.mono"
}

run_pass() { # run_pass <sink> — one --local pass with the injected fakes
    CHUMP_SYSTEMCTL="$FAKEUSER" \
    CHUMP_SENTINEL_SYSTEMCTL_SYS="$FAKESYS" \
    CHUMP_SENTINEL_SUDO="" \
    CHUMP_SENTINEL_REQUIRED_HEALERS=" " \
    CHUMP_SENTINEL_WATCHED_HEALERS=" " \
    CHUMP_SENTINEL_SYSTEM_ORGANS="chump-organ-reconcile.timer chump-board-cycle.timer" \
    CHUMP_SENTINEL_RACE_ORGANS="chump-armed-pr-rebaser.timer chump-pr-auto-rebase.timer" \
    CHUMP_STATE_DIR="$WORK/chump-state" \
    CHUMP_AMBIENT_LOG="$WORK/ambient.jsonl" \
    CHUMP_SENTINEL_PAGE_SINK="$1" \
        bash "$SENTINEL" --local >/dev/null 2>&1
}

fails=0
ck() { if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1" >&2; fails=$((fails+1)); fi; }

# ── Scenario 1: DEAD organ-reconcile (active, mono=infinity) → healed ────────
echo "[1] dead reconcile timer is re-armed"
: > "$WORK/ambient.jsonl"; SINK="$WORK/sink1"; : > "$SINK"
set_unit chump-organ-reconcile.timer 1 active "" infinity      # DEAD
set_unit chump-board-cycle.timer     1 active "" "1w 2h 3min"  # healthy
set_unit chump-armed-pr-rebaser.timer 1 inactive "" ""
set_unit chump-pr-auto-rebase.timer   1 inactive "" ""
run_pass "$SINK"
ck "emitted fleet_health_self_healed for reconcile" \
   'grep -q "\"kind\":\"fleet_health_self_healed\".*chump-organ-reconcile.timer" "$WORK/ambient.jsonl"'
ck "reconcile timer ends healthy (mono no longer infinity)" \
   '[[ "$(cat "$STATE/chump-organ-reconcile.timer.mono")" != infinity ]]'
ck "healthy board-cycle NOT touched (no heal event)" \
   '! grep -q "chump-board-cycle.timer" "$WORK/ambient.jsonl"'
ck "no race page (0 rebasers active)" '! grep -q fleet_health_race_signature "$SINK"'

# ── Scenario 2: force-push RACE (2 rebasers active) → page ────────────────────
echo "[2] two active rebasers page a race signature"
: > "$WORK/ambient.jsonl"; SINK="$WORK/sink2"; : > "$SINK"
set_unit chump-organ-reconcile.timer 1 active "" "1w 2h 3min"  # healthy
set_unit chump-board-cycle.timer     1 active "" "1w 2h 3min"  # healthy
set_unit chump-armed-pr-rebaser.timer 1 active "" "1w 2h 3min"
set_unit chump-pr-auto-rebase.timer   1 active "" "1w 2h 3min"
run_pass "$SINK"
ck "race page written to sink" 'grep -q "fleet_health_race_signature" "$SINK"'
ck "race event in ambient" 'grep -q "\"kind\":\"fleet_health_race_signature\"" "$WORK/ambient.jsonl"'
ck "no false heal on healthy organs" \
   '! grep -q "\"kind\":\"fleet_health_self_healed\"" "$WORK/ambient.jsonl"'

# ── Scenario 3: single rebaser + healthy organs → silent ────────────────────
echo "[3] one rebaser + all healthy → no page, no heal"
: > "$WORK/ambient.jsonl"; SINK="$WORK/sink3"; : > "$SINK"
set_unit chump-organ-reconcile.timer 1 active "" "1w 2h 3min"
set_unit chump-board-cycle.timer     1 active "" "1w 2h 3min"
set_unit chump-armed-pr-rebaser.timer 1 active "" "1w 2h 3min"
set_unit chump-pr-auto-rebase.timer   1 inactive "" ""
run_pass "$SINK"
ck "no race page with a single active rebaser" '! grep -q fleet_health_race_signature "$SINK"'
ck "no heal event when everything is healthy" \
   '! grep -q "\"kind\":\"fleet_health_self_healed\"" "$WORK/ambient.jsonl"'

# ── Scenario 4: absent organ → skipped, never invented ──────────────────────
echo "[4] absent system organ is skipped (install organ owns provisioning)"
: > "$WORK/ambient.jsonl"; SINK="$WORK/sink4"; : > "$SINK"
set_unit chump-organ-reconcile.timer 0 inactive "" ""   # does NOT exist
set_unit chump-board-cycle.timer     1 active "" "1w 2h 3min"
set_unit chump-armed-pr-rebaser.timer 0 inactive "" ""
set_unit chump-pr-auto-rebase.timer   0 inactive "" ""
run_pass "$SINK"
ck "absent organ produced no heal and no race page" \
   '! grep -q fleet_health_race_signature "$SINK" && ! grep -q fleet_health_self_healed "$WORK/ambient.jsonl"'

echo
if [[ $fails -eq 0 ]]; then echo "PASS: all system-organ + race sentinel assertions"; exit 0
else echo "FAIL: $fails assertion(s)"; exit 1; fi
