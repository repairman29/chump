#!/usr/bin/env bash
# test-preflight-ci-parity.sh — INFRA-1867 (INFRA-1861 slice b)
#
# Smoke-check: every `run:` step in .github/workflows/ci.yml is EITHER
# mirrored in `chump preflight` (src/preflight.rs) OR listed as Tier-D in
# docs/process/CI_GATES_INVENTORY.md OR explicitly allowlisted in
# scripts/ci/preflight-ci-parity-exceptions.txt.
#
# Exit 0 — all CI gates accounted for (pass).
# Exit 1 — one or more gates lack a mirror and are not allowlisted (fail).
# Exit 2 — bad environment (missing file, etc.).
#
# Bypass: CHUMP_SKIP_PARITY_CHECK=1 — emergency escape hatch.
#         When set, the check exits 0 with a warning (no ambient emit).
#
# Ambient emit: kind=ci_parity_drift emitted for each unmirrored gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

WORKFLOWS_DIR=".github/workflows"
PREFLIGHT_SRC="src/preflight.rs"
GATES_INVENTORY="docs/process/CI_GATES_INVENTORY.md"
EXCEPTIONS_FILE="scripts/ci/preflight-ci-parity-exceptions.txt"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"

# ── Bypass ────────────────────────────────────────────────────────────────────
if [[ "${CHUMP_SKIP_PARITY_CHECK:-0}" == "1" ]]; then
    echo "[ci-parity] WARN: CHUMP_SKIP_PARITY_CHECK=1 — skipping parity check" >&2
    exit 0
fi

# ── Sanity checks ─────────────────────────────────────────────────────────────
for f in "$PREFLIGHT_SRC" "$GATES_INVENTORY"; do
    if [[ ! -f "$f" ]]; then
        echo "[ci-parity] FAIL: required file missing: $f" >&2
        exit 2
    fi
done

if [[ ! -d "$WORKFLOWS_DIR" ]]; then
    echo "[ci-parity] FAIL: workflows dir missing: $WORKFLOWS_DIR" >&2
    exit 2
fi

# ── Delegate to Python (portable, handles multi-line YAML run: blocks) ────────
exec python3 - \
    "$PREFLIGHT_SRC" "$GATES_INVENTORY" "$EXCEPTIONS_FILE" \
    "$AMBIENT_LOG" "$WORKFLOWS_DIR/ci.yml" \
    <<'PYEOF'

import re
import sys
import os
import pathlib

preflight_src  = pathlib.Path(sys.argv[1])
gates_inv      = pathlib.Path(sys.argv[2])
exceptions_f   = pathlib.Path(sys.argv[3])
ambient_log    = pathlib.Path(sys.argv[4])
ci_yml         = pathlib.Path(sys.argv[5])


# ── Helpers ───────────────────────────────────────────────────────────────────

def info(msg):  print(f"[ci-parity] INFO: {msg}")
def ok(msg):    print(f"[ci-parity] PASS: {msg}")
def fail(msg):  print(f"[ci-parity] FAIL: {msg}", file=sys.stderr)

def emit_ambient(gate_name, ci_path):
    """Append a ci_parity_drift event to ambient.jsonl (best-effort)."""
    import datetime
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    line = (
        '{"ts":"' + ts + '",'
        '"kind":"ci_parity_drift",'
        '"gate_name":"' + gate_name.replace('"', '\\"') + '",'
        '"ci_path":"' + ci_path.replace('"', '\\"') + '"}\n'
    )
    try:
        ambient_log.parent.mkdir(parents=True, exist_ok=True)
        with ambient_log.open("a") as fh:
            fh.write(line)
    except Exception:
        pass  # best-effort; never block the test


# ── 1. Extract Tier-D gate entries from CI_GATES_INVENTORY.md ────────────────
# Tier D section: lines in table after "## Tier D" until the next "## ".
# We collect the first-column cell (gate name/description/filename).

tier_d_entries = set()
in_tier_d = False
for line in gates_inv.read_text().splitlines():
    if line.startswith("## Tier D"):
        in_tier_d = True
        continue
    if in_tier_d and line.startswith("## "):
        break
    if in_tier_d and line.startswith("| "):
        parts = line.split("|")
        if len(parts) >= 2:
            cell = parts[1].strip().strip("`")
            if cell and cell.lower() != "gate":
                tier_d_entries.add(cell)

info(f"Tier-D exempt entries loaded: {len(tier_d_entries)}")


# ── 2. Extract exceptions from allowlist ──────────────────────────────────────
allowlisted = set()
if exceptions_f.exists():
    for line in exceptions_f.read_text().splitlines():
        line = line.split("#")[0].strip()
        if line:
            allowlisted.add(line)
info(f"Allowlisted exceptions loaded: {len(allowlisted)}")


# ── 3. Extract mirrored paths from src/preflight.rs ─────────────────────────
src_text = preflight_src.read_text()

# Any string like "scripts/ci/test-foo.sh" inside preflight.rs is "mirrored"
mirrored_scripts = set(re.findall(r'"(scripts/ci/[^"]+\.sh)"', src_text))

# Cargo gates (fmt/clippy/check): mirrored if any argv literal contains them
cargo_mirrored = bool(re.search(r'"cargo"[^)]*"(fmt|clippy|check)"', src_text))

info(f"Mirrored scripts from preflight.rs: {len(mirrored_scripts)}")
info(f"Cargo (fmt/clippy/check) gates: {'MIRRORED' if cargo_mirrored else 'NOT mirrored'}")


# ── 4. Parse ci.yml to extract (job, step_name, run_cmd) tuples ───────────────
# We parse line-by-line tracking indent levels. YAML indentation is consistent
# in this file (jobs at 2sp, job-body at 4sp, steps at 6sp, step-body at 8sp).
#
# Structure we care about:
#   jobs:           (indent 0)
#     <job>:        (indent 2)
#       steps:      (indent 6)
#         - name:   (indent 8 or 10 inside steps list)
#           run: |  (indent 10)
#             <cmd> (indent 12+)

gates = []  # list of (job, step_name, run_cmd)

# Infrastructure/rollup jobs that are not real CI gates for parity purposes
INFRA_JOBS = {
    "changes", "test", "test-e2e", "coverage", "integration-test",
    "clippy-required", "cargo-test-required", "fast-checks-required",
    "audit-required",
    "tauri-cowork-e2e", "e2e-pwa", "e2e-battle-sim", "e2e-golden-path",
    # META-202: matrix orchestration job — its run: step is a template
    # expression (bash scripts/ci/${{ matrix.test }}) that cannot be resolved
    # to a concrete script. Individual gates are accounted for via the
    # fast-checks job (kept with if: false so its step list remains parseable).
    "fast-checks-matrix",
}

lines = ci_yml.read_text().splitlines()
n = len(lines)

current_job = ""
current_step_name = ""
i = 0

def leading_spaces(s):
    return len(s) - len(s.lstrip(" "))

while i < n:
    line = lines[i]
    raw = line.rstrip()
    indent = leading_spaces(raw)
    stripped = raw.strip()

    # ── Job names at indent 2 ─────────────────────────────────────────────
    # Pattern: exactly 2-space indent + word + colon (no value)
    if indent == 2 and re.match(r'^[A-Za-z0-9_-]+:\s*$', stripped):
        candidate = stripped.rstrip(":")
        if candidate not in ("on", "env", "concurrency", "jobs", "defaults"):
            current_job = candidate
            current_step_name = ""

    # ── Step name: "- name: <text>" at indent 6 or 8 ─────────────────────
    # (indent 6 = standard steps list; jobs like `pr-hygiene` use 6)
    if indent in (6, 8) and re.match(r'^-\s+name:\s+', stripped):
        m = re.match(r'^-\s+name:\s+(.+)$', stripped)
        if m:
            current_step_name = m.group(1).strip().strip('"')

    # ── run: field at indent 8 or 10 ─────────────────────────────────────
    # Inline:     run: <command>
    # Block:      run: |
    if (indent in (8, 10) and re.match(r'^run:', stripped)
            and current_job and current_step_name):
        # Inline single-line
        m_inline = re.match(r'^run:\s+(.+)$', stripped)
        if m_inline:
            run_cmd = m_inline.group(1).strip()
            gates.append((current_job, current_step_name, run_cmd))
        else:
            # Multi-line block: collect lines until dedent
            block_indent = indent + 2  # body is 2 more than run:
            run_lines = []
            j = i + 1
            while j < n:
                body_raw = lines[j].rstrip()
                if not body_raw.strip():
                    j += 1
                    continue
                if leading_spaces(body_raw) < block_indent:
                    break
                run_lines.append(body_raw.strip())
                j += 1
            run_cmd = run_lines[0] if run_lines else ""
            if run_cmd:
                gates.append((current_job, current_step_name, run_cmd))
    i += 1

info(f"Total CI gate steps extracted from ci.yml: {len(gates)}")


# ── 5. Classify each gate ─────────────────────────────────────────────────────
def gate_script_path(run_cmd):
    """Extract the first scripts/ci/*.sh path from a run: command."""
    m = re.search(r'(scripts/ci/[^\s]+\.sh)', run_cmd)
    return m.group(1) if m else ""

def is_cargo_gate(run_cmd):
    return bool(re.match(r'cargo\s+(fmt|clippy|check)', run_cmd))

def is_tier_d(step_name, run_cmd):
    """Check against the Tier-D inventory entries."""
    for entry in tier_d_entries:
        # Match by name fragment or workflow file reference
        if entry in step_name or entry in run_cmd:
            return True
        # Entry like "gap-status-guard.yml" — check if workflow file referenced
        if entry.endswith(".yml") and entry in run_cmd:
            return True
    return False

def is_allowlisted(step_name, run_cmd, script_path):
    """Check against explicit exception list."""
    for exc in allowlisted:
        if exc == step_name or exc == script_path:
            return True
        if exc and (exc in step_name or exc in run_cmd):
            return True
    return False

def is_mirrored(run_cmd):
    """Check if the gate has a mirror in preflight.rs."""
    if is_cargo_gate(run_cmd) and cargo_mirrored:
        return True
    sp = gate_script_path(run_cmd)
    if sp and sp in mirrored_scripts:
        return True
    return False


mirrored_count = 0
tier_d_count = 0
allowlisted_count = 0
skipped_count = 0
unmirrored = []

for (job, step_name, run_cmd) in gates:
    # Skip infrastructure/meta jobs
    if job in INFRA_JOBS:
        skipped_count += 1
        continue

    sp = gate_script_path(run_cmd)

    if is_mirrored(run_cmd):
        mirrored_count += 1
    elif is_tier_d(step_name, run_cmd):
        tier_d_count += 1
    elif is_allowlisted(step_name, run_cmd, sp):
        allowlisted_count += 1
    else:
        ci_path = sp if sp else run_cmd.split()[0] if run_cmd else "unknown"
        unmirrored.append((job, step_name, ci_path, run_cmd))
        emit_ambient(step_name, ci_path)
        fail(f"Unmirrored gate in job='{job}': step='{step_name}'")
        fail(f"  run: {run_cmd[:120]}")
        fail(f"  Fix: (a) add mirror in src/preflight.rs,")
        fail(f"       (b) classify as Tier-D in docs/process/CI_GATES_INVENTORY.md,")
        fail(f"       (c) add to scripts/ci/preflight-ci-parity-exceptions.txt")

print()
print("[ci-parity] Summary:")
print(f"  Mirrored in preflight : {mirrored_count}")
print(f"  Tier-D (cannot mirror): {tier_d_count}")
print(f"  Allowlisted exceptions: {allowlisted_count}")
print(f"  Skipped (infra jobs)  : {skipped_count}")
print(f"  UNMIRRORED (FAIL)     : {len(unmirrored)}")
print()

if unmirrored:
    fail(f"{len(unmirrored)} CI gate(s) lack a preflight mirror and are not allowlisted.")
    fail("Each unaccounted gate emitted kind=ci_parity_drift to ambient.jsonl.")
    sys.exit(1)
else:
    ok(f"All {mirrored_count + tier_d_count + allowlisted_count} CI gates accounted for.")
    sys.exit(0)

PYEOF
