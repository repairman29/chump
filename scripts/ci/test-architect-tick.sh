#!/usr/bin/env bash
# test-architect-tick.sh — RESILIENT-1634 (PHASE-R).
#
# Gate for the architect / ATC tick organ (scripts/dispatch/architect-tick.sh):
#   AC3  admission guards: refuses when another claude runs, when free disk is
#        below the 20G floor, and when the single-architect lock is held.
#   AC4  tool allowlist cannot admin-merge, --no-verify, push to main, or set a
#        bypass env var — enforced by default-deny (--permission-mode dontAsk)
#        PLUS an explicit audit that no forbidden token appears in the allowlist.
#   AC2  each run writes ~/.chump/architect/ticks/<UTC>.md and latest.md with
#        board / trunk / nodes / rollup done+total.
#   AC5  kind=architect_tick is registered and emitted per run.
#
# Pure local: a stub `claude` on PATH stands in for the real agent, so the
# behavioral assertions need no network and no credentials.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BEAT="$REPO_ROOT/scripts/dispatch/architect-tick.sh"

fails=0
ok()   { printf 'ok   - %s\n' "$*"; }
fail() { printf 'FAIL - %s\n' "$*" >&2; fails=$((fails + 1)); }

[[ -f "$BEAT" ]] || { fail "beat script missing: $BEAT"; exit 1; }

# ── 1. syntax ───────────────────────────────────────────────────────────────
if bash -n "$BEAT"; then ok "beat parses (bash -n)"; else fail "beat has a syntax error"; fi

# ── 2. AC4: the allowlist forbids every ship-side mutation ───────────────────
# The allowlist array is the enforcement surface. Assert none of its entries
# grant a forbidden capability. We read the literal ARCH_ALLOWED_TOOLS block.
allow_block="$(awk '/ARCH_ALLOWED_TOOLS=\(/{f=1} f{print} /^\)/{if(f)exit}' "$BEAT")"
[[ -n "$allow_block" ]] || fail "could not locate ARCH_ALLOWED_TOOLS block"

check_absent() { # <ERE> <label>
    if grep -qiE -e "$1" <<< "$allow_block"; then
        fail "allowlist grants forbidden capability: $2"
    else
        ok "allowlist does NOT grant: $2"
    fi
}
check_absent 'gh pr merge'                    'gh pr merge (any)'
check_absent '[-][-]admin'                    'admin merge (--admin)'
check_absent '[-][-]no-verify'                '--no-verify'
check_absent 'git push'                       'git push (any)'
check_absent 'push.*main'                     'push to main'
check_absent '_BYPASS|_SKIP|_NO_|SKIP=1'      'bypass/skip env var'

# dontAsk default-deny is what makes the positive allowlist the whole boundary.
if grep -q 'permission-mode dontAsk' "$BEAT"; then
    ok "beat runs claude with --permission-mode dontAsk (default-deny)"
else
    fail "beat does not set --permission-mode dontAsk — allowlist is not the boundary"
fi
# Belt-and-suspenders: the prompt also spells out the forbidden set.
if grep -q 'admin-merge' "$BEAT" && grep -q 'never by hand' "$BEAT"; then
    ok "prompt forbids admin-merge and by-hand arming"
else
    fail "prompt does not spell out the admin-merge / by-hand-arming prohibition"
fi

# ── 3. AC5: kind=architect_tick registered (base monolith OR events.d fragment)
FRAG="$REPO_ROOT/docs/observability/events.d/architect_tick.yaml"
if [[ -f "$FRAG" ]] && grep -q 'kind: architect_tick' "$FRAG"; then
    ok "architect_tick registered (events.d fragment)"
elif grep -q 'kind: architect_tick' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"; then
    ok "architect_tick registered (monolith)"
else
    fail "architect_tick not registered in EVENT_REGISTRY.yaml nor events.d/"
fi
# emit literal present at the emit site
if grep -q '"kind":"architect_tick"' "$BEAT"; then
    ok 'emit literal "kind":"architect_tick" present in beat'
else
    fail 'beat has no "kind":"architect_tick" emit literal'
fi

# ── behavioral harness: stub claude + sandboxed HOME/ambient ─────────────────
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
STUB_BIN="$SANDBOX/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
# Minimal architect-agent stub: print the structured report block the beat parses.
cat <<'BLOCK'
===ARCHITECT-TICK-REPORT===
board: 0 SLA breaches; 2 armed PRs green
trunk: green
nodes: cuphead healthy; disk 40G
rollup: done=1200 total=1560
findings: clean tick
===END-ARCHITECT-TICK-REPORT===
BLOCK
exit 0
STUB
chmod +x "$STUB_BIN/claude"

ARCH_HOME="$SANDBOX/arch"
AMBIENT="$SANDBOX/ambient.jsonl"
run_beat() { # extra env passed as KEY=VAL ...
    env PATH="$STUB_BIN:$PATH" \
        CHUMP_ARCHITECT_HOME="$ARCH_HOME" \
        CHUMP_AMBIENT_LOG="$AMBIENT" \
        CHUMP_ARCHITECT_TICK_CLAUDE_BIN=claude \
        CHUMP_ARCHITECT_TICK_CLAUDE_COUNT=0 \
        CHUMP_ARCHITECT_TICK_FREE_G=100 \
        CHUMP_ARCHITECT_HANDOFF_GLOB="$SANDBOX/no-such-handoff-*/HANDOFF.md" \
        "$@" bash "$BEAT" >/dev/null 2>&1
}

# ── 4. AC2: a normal run writes ticks/<UTC>.md + latest.md with the fields ───
rm -rf "$ARCH_HOME"; : > "$AMBIENT"
run_beat
if [[ -f "$ARCH_HOME/latest.md" ]] && ls "$ARCH_HOME"/ticks/*.md >/dev/null 2>&1; then
    ok "run writes latest.md and a ticks/<UTC>.md"
else
    fail "run did not write latest.md and ticks/<UTC>.md"
fi
latest="$ARCH_HOME/latest.md"
for field in 'board:' 'trunk:' 'nodes:' 'rollup: done=1200 total=1560'; do
    if grep -q "$field" "$latest" 2>/dev/null; then
        ok "latest.md carries '$field'"
    else
        fail "latest.md missing '$field'"
    fi
done

# ── 5. AC5: the run emitted kind=architect_tick with the rollup numbers ──────
if grep -q '"kind":"architect_tick"' "$AMBIENT" && grep -q '"outcome":"ran"' "$AMBIENT" \
   && grep -q '"rollup_done":1200' "$AMBIENT" && grep -q '"rollup_total":1560' "$AMBIENT"; then
    ok "ran tick emitted architect_tick with rollup_done/total"
else
    fail "ran tick did not emit architect_tick with correct rollup numbers"
    cat "$AMBIENT" >&2 || true
fi

# ── 6. AC3: admission guards each refuse with a skipped emit ─────────────────
# (a) another claude running
rm -rf "$ARCH_HOME"; : > "$AMBIENT"
run_beat CHUMP_ARCHITECT_TICK_CLAUDE_COUNT=3
if grep -q '"reason":"claude_already_running"' "$AMBIENT"; then
    ok "AC3: refuses when another claude is running (wait_quiet)"
else
    fail "AC3: did NOT refuse with another claude running"; cat "$AMBIENT" >&2 || true
fi

# (b) disk below floor (reaper can't help in the sandbox → still refuse)
rm -rf "$ARCH_HOME"; : > "$AMBIENT"
run_beat CHUMP_ARCHITECT_TICK_FREE_G=5 CHUMP_ARCHITECT_TICK_MIN_DISK_G=20
if grep -q '"reason":"disk_below_floor"' "$AMBIENT"; then
    ok "AC3: refuses when free disk < 20G floor"
else
    fail "AC3: did NOT refuse under the disk floor"; cat "$AMBIENT" >&2 || true
fi

# (c) single-architect lock held by someone else
rm -rf "$ARCH_HOME"; : > "$AMBIENT"
mkdir -p "$ARCH_HOME"
LOCKF="$ARCH_HOME/architect.lock"
# Hold the lock in a background subshell, then run the beat while it's held.
( exec 9>"$LOCKF"; flock -n 9 && sleep 5 ) &
holder=$!
sleep 0.5
run_beat
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
if grep -q '"reason":"single_architect_lock_held"' "$AMBIENT"; then
    ok "AC3: refuses when the single-architect lock is held"
else
    fail "AC3: did NOT refuse while the architect lock was held"; cat "$AMBIENT" >&2 || true
fi

echo
if (( fails > 0 )); then
    echo "FAILED: $fails assertion(s)" >&2
    exit 1
fi
echo "PASS: architect-tick gate green"
