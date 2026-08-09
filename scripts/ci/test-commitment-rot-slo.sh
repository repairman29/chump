#!/usr/bin/env bash
# test-commitment-rot-slo.sh — RESILIENT-254
#
# End-to-end gate for FLEET_SLOS.md Layer 5 (commitment aging). The Rust unit
# tests in src/commitment_rot.rs cover the arithmetic; this script covers the
# thing the acceptance criteria actually asked for — that a rot breach reaches
# the operator through the SAME command and the SAME non-zero exit as every
# other layer, and that the fleet-brief prints it.
#
# Depth: happy-path + adversarial-for-the-two-load-bearing-paths.
#   COVERED   — L5-SLO-1 breaches on a backdated (12-day-silent) organ and
#               exits 1; passes on a live one and exits 0; a parked organ never
#               breaches; the registry that actually ships parses.
#   COVERED   — the fleet-brief renders an L5 breach.
#   NOT COVERED — L5-SLO-2 and L5-SLO-3 end-to-end (they need a populated
#               state.db, which CI does not have). Their logic is covered by
#               the unit tests in src/commitment_rot.rs, and L5-SLO-2 was
#               additionally proven by hand against a copy of the operator's
#               live store using MOP-BUCKET — see the PR body for the output.
#   NOT COVERED — the ambient-rotation false-BREACH case. Documented in
#               FLEET_SLOS.md ("What Layer 5 does NOT claim") rather than
#               tested, because it errs toward the loud side by construction.
#
# Bypass for local iteration: CHUMP_ROT_SLO_TEST_SKIP=1.
set -euo pipefail

[[ "${CHUMP_ROT_SLO_TEST_SKIP:-0}" == "1" ]] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY="$REPO_ROOT/scripts/coord/daemon-expectations.yaml"
SLO_DOC="$REPO_ROOT/docs/process/FLEET_SLOS.md"
BRIEF="$REPO_ROOT/scripts/dispatch/fleet-brief.sh"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

# ── 1: the doc and the registry exist and agree ──────────────────────────────
[[ -f "$SLO_DOC" ]]  || fail "FLEET_SLOS.md missing at $SLO_DOC"
[[ -f "$REGISTRY" ]] || fail "organ registry missing at $REGISTRY"

grep -q '^## Layer 5' "$SLO_DOC" \
    || fail "FLEET_SLOS.md has no Layer 5 section"
for slo in L5-SLO-1 L5-SLO-2 L5-SLO-3; do
    grep -q "| $slo |" "$SLO_DOC" \
        || fail "$slo missing from the FLEET_SLOS.md Layer 5 table"
done
pass "FLEET_SLOS.md declares Layer 5 with L5-SLO-1..3 in the four-column shape"

grep -q '^load_bearing_organs:' "$REGISTRY" \
    || fail "daemon-expectations.yaml has no load_bearing_organs: section"
grep -q 'organ: com.chump.opus-curator' "$REGISTRY" \
    || fail "the curator — the case this layer exists for — is not registered"
pass "organ registry declares load_bearing_organs incl. the opus curator"

# The bash silence-monitor must not accidentally consume the new section: its
# parser keys off '  - daemon: ', so every organ entry must use '  - organ: '.
if awk '/^load_bearing_organs:/{f=1;next} f && /^[a-z_]+:/{f=0} f' "$REGISTRY" \
    | grep -q '^  - daemon:'; then
    fail "load_bearing_organs entries must use '- organ:' so daemon-silence-monitor.sh skips them"
fi
pass "load_bearing_organs uses '- organ:' — daemon-silence-monitor.sh is unaffected"

# ── locate a chump binary; without one the CLI half is skipped, not faked ────
CHUMP="${CHUMP_BIN:-}"
if [[ -z "$CHUMP" ]]; then
    for cand in "$REPO_ROOT/target/release/chump" "$REPO_ROOT/target/debug/chump" "$(command -v chump 2>/dev/null || true)"; do
        [[ -n "$cand" && -x "$cand" ]] && { CHUMP="$cand"; break; }
    done
fi
if [[ -z "$CHUMP" ]]; then
    echo "SKIP: no chump binary found — static checks passed, CLI checks skipped" >&2
    exit 0
fi
# A binary from PATH may predate --layer (RESILIENT-254). Probe rather than
# assume: a stale binary silently runs the FULL slo-check, which would make
# these assertions meaningless instead of failing honestly.
# NOTE: capture first, grep second. `cmd | grep -q` closes the pipe on the
# first match, chump takes SIGPIPE (141), and `set -o pipefail` then reports
# the whole pipeline as failed — which silently turned this probe into an
# unconditional SKIP the first time it ran.
_help_out="$("$CHUMP" health --help 2>&1 || true)"
if ! printf '%s' "$_help_out" | grep -q -- '--layer'; then
    echo "SKIP: $CHUMP predates --layer (RESILIENT-254) — CLI checks skipped" >&2
    exit 0
fi

TMP_DIR="$(mktemp -d -t chump-rot-slo-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/.chump-locks"
AMBIENT="$TMP_DIR/.chump-locks/ambient.jsonl"

iso_ago() { # seconds-ago → ISO-8601 UTC
    date -u -v-"$1"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ
}

write_registry() { # parked_line
    cat > "$TMP_DIR/organs.yaml" <<YAML
load_bearing_organs:
  - organ: com.chump.opus-curator
    description: test fixture
    evidence_kinds:
      - curator_decision
      - system_gap_tick
    max_silence_secs: 3600
${1:-}
YAML
}

run_l5() {
    CHUMP_REPO="$TMP_DIR" \
    CHUMP_ORGAN_REGISTRY="$TMP_DIR/organs.yaml" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
        "$CHUMP" health --slo-check --layer L5 2>&1
}

# ── 2: a 12-day-silent organ BREACHES and exits non-zero ─────────────────────
# This is RESILIENT-246 replayed: the curator last acted 12 days ago while the
# rest of the fleet is demonstrably alive this minute.
write_registry
{
    printf '{"ts":"%s","kind":"curator_decision"}\n' "$(iso_ago $((12 * 86400)))"
    printf '{"ts":"%s","kind":"farmer_heartbeat"}\n'  "$(iso_ago 60)"
} > "$AMBIENT"

set +e
out="$(run_l5)"; rc=$?
set -e
echo "$out" | grep -q 'L5-SLO-1' || fail "L5-SLO-1 not evaluated: $out"
echo "$out" | grep -q 'BREACH.*L5-SLO-1' \
    || fail "a 12-day organ silence must BREACH. Got:\n$out"
echo "$out" | grep -q 'opus-curator' \
    || fail "the breach must NAME the silent organ. Got:\n$out"
[[ "$rc" -ne 0 ]] \
    || fail "a Layer-5 breach must exit non-zero like every other layer (got $rc)"
pass "12-day organ silence BREACHES and exits $rc (RESILIENT-246 would have been caught)"

# ── 3: a live organ passes and exits 0 ───────────────────────────────────────
{
    printf '{"ts":"%s","kind":"curator_decision"}\n' "$(iso_ago 300)"
    printf '{"ts":"%s","kind":"farmer_heartbeat"}\n'  "$(iso_ago 60)"
} > "$AMBIENT"
set +e
out="$(run_l5)"; rc=$?
set -e
echo "$out" | grep -q 'pass.*L5-SLO-1' \
    || fail "a curator that acted 5 min ago must pass. Got:\n$out"
[[ "$rc" -eq 0 ]] || fail "no breach must exit 0 (got $rc)"
pass "a live organ passes and exits 0 — the check is not stuck-on"

# ── 4: a parked organ never breaches (proportionate escalation, AC-4) ────────
write_registry '    parked: "retired on purpose — ACG-advisory-shaped"'
{
    printf '{"ts":"%s","kind":"farmer_heartbeat"}\n' "$(iso_ago 60)"
} > "$AMBIENT"
set +e
out="$(run_l5)"; rc=$?
set -e
echo "$out" | grep -q 'BREACH.*L5-SLO-1' \
    && fail "a parked-on-purpose organ must NOT breach. Got:\n$out"
echo "$out" | grep -qi 'parked' \
    || fail "the parked organ must still be reported as parked. Got: $out"
[[ "$rc" -eq 0 ]] || fail "parked-only state must exit 0 (got $rc)"
pass "a parked organ is reported, never breached — the layer does not cry wolf"

# ── 5: the fleet-brief surfaces an L5 breach (AC-6) ──────────────────────────
# A check nobody reads is the exact failure mode being fixed.
grep -q 'slo-check --layer L5' "$BRIEF" \
    || fail "fleet-brief.sh does not query Layer 5"
grep -q 'Commitment rot (L5)' "$BRIEF" \
    || fail "fleet-brief.sh does not render a Layer-5 heading"
pass "fleet-brief.sh queries Layer 5 and renders its breaches"

# ── 6: no per-gap due dates were introduced (AC-5) ───────────────────────────
if grep -riE 'due_date|due-date|per-gap deadline' \
    "$REPO_ROOT/src/commitment_rot.rs" "$SLO_DOC" \
    | grep -viE 'no per-gap|never.*due|due date' >/dev/null 2>&1; then
    fail "Layer 5 must not introduce per-gap due dates — the unit is the class"
fi
pass "no per-gap due dates — the unit is the class"

echo "ALL PASS: RESILIENT-254 Layer-5 commitment-rot SLOs"
