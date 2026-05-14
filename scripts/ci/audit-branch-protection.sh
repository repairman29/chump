#!/usr/bin/env bash
# CREDIBLE-058: branch-protection required-check audit + alignment with
# workflow job names.
#
# Verifies that every required status check named in main's branch
# protection actually maps to a job (or rollup) name emitted by
# .github/workflows/ci.yml. Catches drift in either direction:
#
#   - Required context renamed in branch protection but ci.yml still
#     emits the old name → no PR can ever satisfy the new requirement.
#   - ci.yml renames a job (e.g. INFRA-1143's `test` → `test-required`)
#     but branch protection still requires the old name → every PR
#     blocked forever.
#
# Wired as a pre-commit hook entry that fires only when
# .github/workflows/ci.yml is in the diff (lightweight; the audit
# itself is a single gh api call + a YAML parse).
#
# Exit 0: every required context has a matching job emitter.
# Exit 1: drift detected; prints the missing contexts.
#
# Emits `kind=branch_protection_drift` to ambient.jsonl on drift.

set -euo pipefail

WORKFLOWS_DIR="${WORKFLOWS_DIR:-.github/workflows}"
REPO="${CHUMP_REPO_SLUG:-repairman29/chump}"
BRANCH="${CHUMP_DEFAULT_BRANCH:-main}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"

# Single Python helper does fetch, parse, compare, and (optionally) emit.
# Avoids shell quoting hell with multi-word check names like
# "ACP protocol smoke test (Zed / JetBrains compatible)".
#
# Env vars passed directly through the environment (not shell interpolation)
# so the heredoc can be quoted and bash doesn't try to interpret Python
# dict syntax (`"name": value` was being read as `name::` command).
export WORKFLOWS_DIR REPO BRANCH AMBIENT_LOG
python3 <<'PYEOF'
import os
import sys
import json
import subprocess
from datetime import datetime, timezone

WORKFLOWS_DIR = os.environ.get("WORKFLOWS_DIR", ".github/workflows")
REPO = os.environ.get("REPO", "repairman29/chump")
BRANCH = os.environ.get("BRANCH", "main")
AMBIENT_LOG = os.environ.get("AMBIENT_LOG", ".chump-locks/ambient.jsonl")


def fetch_required_contexts():
    """Return the set of required-status-check context names from branch protection."""
    try:
        r = subprocess.run(
            [
                "gh",
                "api",
                f"repos/{REPO}/branches/{BRANCH}/protection/required_status_checks",
            ],
            capture_output=True,
            text=True,
            timeout=20,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return None, f"gh CLI unavailable or timed out: {e}"
    if r.returncode != 0:
        return None, f"gh exit {r.returncode}: {r.stderr.strip()[:200]}"
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError as e:
        return None, f"branch-protection JSON parse: {e}"
    out = set()
    for c in (data.get("contexts") or []):
        out.add(c)
    for c in (data.get("checks") or []):
        if isinstance(c, dict) and "context" in c:
            out.add(c["context"])
    return out, None


def emitted_job_names(workflows_dir):
    """Return the set of job ids and human names from ALL workflow files
    in workflows_dir. GitHub Actions takes the displayed check name from
    `name:` if set, else the job-id."""
    try:
        import yaml  # type: ignore
    except ImportError:
        print("[audit] ERROR: PyYAML not installed (pip install pyyaml)", file=sys.stderr)
        sys.exit(2)
    out = set()
    if not os.path.isdir(workflows_dir):
        print(f"[audit] ERROR: workflows dir not found: {workflows_dir}", file=sys.stderr)
        sys.exit(2)
    for fn in sorted(os.listdir(workflows_dir)):
        if not (fn.endswith(".yml") or fn.endswith(".yaml")):
            continue
        path = os.path.join(workflows_dir, fn)
        try:
            doc = yaml.safe_load(open(path)) or {}
        except yaml.YAMLError as e:
            print(f"[audit] WARN: could not parse {path}: {e}", file=sys.stderr)
            continue
        jobs = doc.get("jobs", {}) or {}
        for job_id, body in jobs.items():
            out.add(job_id)
            if isinstance(body, dict) and "name" in body:
                n = body["name"]
                # Skip names that interpolate matrix values — can't resolve statically.
                if isinstance(n, str) and "${{" not in n:
                    out.add(n)
    return out


def emit_drift_event(missing):
    """Append a kind=branch_protection_drift line to ambient.jsonl."""
    try:
        os.makedirs(os.path.dirname(AMBIENT_LOG), exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        event = {
            "ts": ts,
            "kind": "branch_protection_drift",
            "missing_emitters": sorted(missing),
            "workflows_dir": WORKFLOWS_DIR,
            "branch": BRANCH,
        }
        with open(AMBIENT_LOG, "a") as f:
            f.write(json.dumps(event) + "\n")
    except Exception as e:
        print(f"[audit] WARN: could not write ambient event: {e}", file=sys.stderr)


required, err = fetch_required_contexts()
if required is None:
    print(f"[audit] WARN: {err}", file=sys.stderr)
    print(f"[audit] skipping audit — exit 0 to avoid blocking offline commits", file=sys.stderr)
    sys.exit(0)

emitted = emitted_job_names(WORKFLOWS_DIR)

# A required context that has NO matching emitter blocks PRs.
missing = required - emitted

if missing:
    print(f"[audit] ❌ DRIFT: required contexts in branch protection have no matching emitter in {WORKFLOWS_DIR}/*.yml", file=sys.stderr)
    for m in sorted(missing):
        print(f"  - {m!r}", file=sys.stderr)
    print("", file=sys.stderr)
    print("[audit] These checks will NEVER report on PRs — every PR will be blocked.", file=sys.stderr)
    print(f"[audit] Fix: either rename the job in a workflow file, or update branch protection contexts.", file=sys.stderr)
    emit_drift_event(missing)
    sys.exit(1)

print(f"[audit] ✓ all {len(required)} required contexts have matching emitters across {WORKFLOWS_DIR}/*.yml")
PYEOF
