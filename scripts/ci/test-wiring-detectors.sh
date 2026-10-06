#!/usr/bin/env bash
# ZERO-WASTE-126: scripts/ops/wiring-detectors.py — D1 no-scheduler, D2
# never-invoked-on-documented-input, D4 no-execution-telemetry. Each detector is
# proven on a fixture shaped like a real instance (see docs/process/WIRING_DETECTORS.md)
# AND against its negative controls; each emits a machine-readable finding record.
# Pure local; no network.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DET="$ROOT/scripts/ops/wiring-detectors.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }; bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

R="$T/repo"; mkdir -p "$R/scripts/coord" "$R/scripts/ci" "$R/scripts/dispatch" "$R/docs/process"

# ── D1 fixtures ──────────────────────────────────────────────────────────────
printf '#!/usr/bin/env bash\n# unwired-beat.sh — sweeps stale state. Runs every 10 min.\necho sweep\n' > "$R/scripts/coord/unwired-beat.sh"
printf '#!/usr/bin/env bash\n# wired-beat.sh — Runs every 10 min.\necho sweep\n' > "$R/scripts/coord/wired-beat.sh"
printf '[Service]\nExecStart=/bin/bash scripts/coord/wired-beat.sh\n' > "$R/scripts/dispatch/chump-wired-beat.service"
printf '[Timer]\nOnUnitActiveSec=10min\n' > "$R/scripts/dispatch/chump-wired-beat.timer"
printf '#!/usr/bin/env bash\n# via-parent.sh — Runs every 5 min.\necho x\n' > "$R/scripts/coord/via-parent.sh"
printf '#!/usr/bin/env bash\n# parent-beat.sh — scheduled; calls the child.\nbash scripts/coord/via-parent.sh\n' > "$R/scripts/coord/parent-beat.sh"
printf '[Service]\nExecStart=/bin/bash scripts/coord/parent-beat.sh\n' > "$R/scripts/dispatch/chump-parent.service"
printf '#!/usr/bin/env bash\n# daemon.sh — runs every 30s as a long-lived loop.\nwhile true; do sleep 30; done\n' > "$R/scripts/coord/daemon.sh"
printf '#!/usr/bin/env bash\n# test-periodic.sh — asserts the beat runs every 10 min.\ntrue\n' > "$R/scripts/ci/test-periodic.sh"

# ── D2 fixtures ──────────────────────────────────────────────────────────────
printf '#!/usr/bin/env bash\n# tool-unused-input.sh — Usage: tool-unused-input.sh --input <FILE> [--mode MODE]\ntrue\n' > "$R/scripts/coord/tool-unused-input.sh"
printf '#!/usr/bin/env bash\n# tool-used-input.sh — Usage: tool-used-input.sh --src <FILE>\ntrue\n' > "$R/scripts/coord/tool-used-input.sh"
printf '#!/usr/bin/env bash\n# tool-orphan.sh — Usage: tool-orphan.sh --path <DIR>\ntrue\n' > "$R/scripts/coord/tool-orphan.sh"
printf '#!/usr/bin/env bash\nbash scripts/coord/tool-unused-input.sh --verbose\nbash scripts/coord/tool-used-input.sh --src /tmp/x\n' > "$R/scripts/coord/caller.sh"

# ── D4 fixtures ──────────────────────────────────────────────────────────────
printf '#!/usr/bin/env bash\necho running checks\n' > "$R/scripts/ci/silent-runner.sh"
printf '#!/usr/bin/env bash\nscripts/dev/ambient-emit.sh runner_done\n' > "$R/scripts/ci/loud-runner.sh"
cat > "$R/docs/process/SILENT_CHECKLIST.md" <<'M'
# Capability checklist

Run with: `./scripts/ci/silent-runner.sh`

## Tier 1 — Core (must pass)

| # | Capability | Test |
|---|-----------|------|
| C1 | Tool call | list gaps |
| C2 | Streaming | long reply |

## Tier 3 — nice to have

| # | Capability |
|---|-----------|
| C9 | Sparkles |
M
cat > "$R/docs/process/LOUD_CHECKLIST.md" <<'M'
# Another checklist

Run with: `./scripts/ci/loud-runner.sh`

## Required items (mandatory)

- [ ] first thing
- [ ] second thing
M

out="$T/findings.jsonl"
python3 "$DET" --repo "$R" --out "$out" --summary 2>"$T/summary.txt"
art() { python3 -c "import json,sys; print(' '.join(sorted(json.loads(l)['artifact'] for l in open('$out') if json.loads(l)['detector']=='$1')))"; }

# D1
[[ "$(art D1)" == "scripts/coord/unwired-beat.sh" ]] \
    && ok "D1 flags only the periodic script with no scheduler (wired, transitively-wired, daemon and test controls clean)" \
    || bad "D1 artifacts: $(art D1)"
# D2
[[ "$(art D2)" == "scripts/coord/tool-unused-input.sh" ]] \
    && ok "D2 flags the tool whose documented inputs are never passed (used-input and never-invoked controls clean)" \
    || bad "D2 artifacts: $(art D2)"
# D4
[[ "$(art D4)" == "scripts/ci/silent-runner.sh" ]] \
    && ok "D4 flags the required checklist whose runner emits no telemetry (loud runner and non-required tier clean)" \
    || bad "D4 artifacts: $(art D4)"

# D4: a runner that shows up in the ambient log is not 'no telemetry'
echo '{"kind":"x","source":"silent-runner.sh"}' > "$T/ambient.jsonl"
python3 "$DET" --repo "$R" --detector D4 --ambient "$T/ambient.jsonl" --out "$T/d4.jsonl"
[[ ! -s "$T/d4.jsonl" ]] && ok "D4 clears once the runner appears in the ambient log" || bad "D4 ignored the ambient log"

# Machine-readable finding records
python3 - "$out" <<'PY' && ok "every finding is a JSON record with detector/name/severity/artifact/detail/evidence" || bad "record schema"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
assert len(rows) == 3, rows
for r in rows:
    assert set(r) == {"detector", "name", "severity", "artifact", "detail", "evidence"}, r
    assert isinstance(r["evidence"], dict) and r["evidence"], r
names = {r["detector"]: r["name"] for r in rows}
assert names == {"D1": "no-scheduler", "D2": "never-invoked-on-documented-input", "D4": "no-execution-telemetry"}, names
d2 = next(r for r in rows if r["detector"] == "D2")
assert sorted(d2["evidence"]["never_invoked_with"]) == ["--input", "--mode"], d2
PY

# Determinism + CLI contract
python3 "$DET" --repo "$R" --out "$T/again.jsonl"
cmp -s "$out" "$T/again.jsonl" && ok "deterministic: identical repo gives byte-identical output" || bad "output differs between runs"
python3 "$DET" --repo "$R" --detector D9 >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "bad --detector exits 2" || bad "bad detector accepted"
grep -q 'D1: 1 finding' "$T/summary.txt" && grep -q 'D2: 1 finding' "$T/summary.txt" && grep -q 'D4: 1 finding' "$T/summary.txt" \
    && ok "--summary reports per-detector counts" || bad "summary: $(cat "$T/summary.txt")"

echo "=== wiring detectors: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
