#!/usr/bin/env bash
# scripts/ci/audit-branch-protection.sh — CREDIBLE-058 (2026-05-14)
#
# Verifies that every required status-check context on `main` branch protection
# matches a job name actually emitted by a GitHub Actions workflow file.
#
# Problem: when a workflow job is renamed (e.g. `test` → `test-required`),
# branch-protection still requires the OLD name, and PRs stall with "required
# check missing" errors. This script catches that drift before it bites.
#
# Two modes:
#   --live     : fetch required contexts from GitHub API (needs gh + network)
#   --baseline : read contexts from docs/baselines/branch-protection-main.json
#                (default; works offline, suitable for pre-commit)
#
# Usage:
#   scripts/ci/audit-branch-protection.sh           # baseline mode
#   scripts/ci/audit-branch-protection.sh --live    # fetch from GitHub API
#   scripts/ci/audit-branch-protection.sh --check-staged  # parse staged ci.yml
#   scripts/ci/audit-branch-protection.sh --update-baseline  # overwrite baseline
#
# Environment:
#   CHUMP_BRANCH_PROTECTION_AUDIT=0  disable (pre-commit bypass)
#   CHUMP_AMBIENT_LOG  override ambient.jsonl path
#
# Exit codes:
#   0  all required contexts match a workflow job name
#   1  drift detected
#   2  invocation error

set -euo pipefail

# CREDIBLE-058 bypass
if [[ "${CHUMP_BRANCH_PROTECTION_AUDIT:-1}" == "0" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")"
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
BASELINE="$REPO_ROOT/docs/baselines/branch-protection-main.json"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

MODE="baseline"
CHECK_STAGED=0
UPDATE_BASELINE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --live)            MODE="live"; shift ;;
        --baseline)        MODE="baseline"; shift ;;
        --check-staged)    CHECK_STAGED=1; shift ;;
        --update-baseline) UPDATE_BASELINE=1; shift ;;
        -h|--help)
            grep '^#' "$0" | head -30 | sed 's/^# \?//'
            exit 0 ;;
        *) echo "[audit-branch-protection] unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── Delegate all logic to python3 for bash 3.2 compat (macOS ships bash 3) ───
exec python3 - "$MODE" "$CHECK_STAGED" "$UPDATE_BASELINE" "$REPO_ROOT" "$WORKFLOWS_DIR" "$BASELINE" "$AMBIENT_LOG" "$@" << 'PYEOF'
import json
import os
import subprocess
import sys
import datetime

mode = sys.argv[1]
check_staged = sys.argv[2] == "1"
update_baseline = sys.argv[3] == "1"
repo_root = sys.argv[4]
workflows_dir = sys.argv[5]
baseline_path = sys.argv[6]
ambient_log = sys.argv[7]

def get_contexts_from_live():
    result = subprocess.run(
        ["gh", "api", "repos/{owner}/{repo}/branches/main/protection/required_status_checks",
         "--jq", "[.checks[].context]"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"[audit-branch-protection] gh api failed: {result.stderr}", file=sys.stderr)
        sys.exit(2)
    return json.loads(result.stdout)

def get_contexts_from_baseline():
    if not os.path.exists(baseline_path):
        print(f"[audit-branch-protection] baseline not found: {baseline_path}", file=sys.stderr)
        print(f"[audit-branch-protection] run: scripts/ci/audit-branch-protection.sh --update-baseline", file=sys.stderr)
        sys.exit(2)
    with open(baseline_path) as f:
        d = json.load(f)
    checks = d.get("required_status_checks", {}).get("checks", [])
    return [c["context"] for c in checks if c.get("context")]

def parse_workflow_jobs(content):
    """Parse YAML workflow content and return list of job names."""
    try:
        import yaml
        ci = yaml.safe_load(content)
        if not isinstance(ci, dict):
            return []
        names = []
        for jid, jdef in (ci.get("jobs") or {}).items():
            if isinstance(jdef, dict):
                names.append(jdef.get("name", jid))
        return names
    except ImportError:
        # Fallback: grep for 'name:' under jobs section (simple heuristic)
        names = []
        in_jobs = False
        for line in content.splitlines():
            if line.startswith("jobs:"):
                in_jobs = True
                continue
            if in_jobs and line.startswith("  ") and not line.startswith("   "):
                # Top-level key under jobs (job ID)
                pass
            if in_jobs and "    name:" in line:
                val = line.split("name:", 1)[1].strip().strip('"').strip("'")
                if val:
                    names.append(val)
        return names
    except Exception:
        return []

def has_branch_protection_rules(content):
    """Check if workflow content contains branch-protection-related settings."""
    patterns = [
        "branch_protection",
        "required_checks", 
        "enforce_admins",
        "dismiss_stale_reviews",
        "require_code_review_from_code_owners",
    ]
    content_lower = content.lower()
    for pattern in patterns:
        if pattern in content_lower:
            return True
    return False



def get_all_workflow_job_names(staged=False):
    """Return set of all job names from workflow files.

    In staged mode (--check-staged), builds a merged view that matches what
    GitHub would see after the push:
      - For workflow files that ARE staged: read the staged (index) version.
      - For workflow files that are NOT staged: read the on-disk version.
    This prevents false drift reports caused by unchanged files (e.g.
    editor-integration.yml) that define required status check jobs but are
    absent from the staged file list.
    """
    names = set()
    if staged:
        # Collect the set of workflow paths that have staged changes.
        result = subprocess.run(
            ["git", "diff", "--cached", "--name-only"],
            capture_output=True, text=True, cwd=repo_root
        )
        staged_paths = set()
        for path in result.stdout.splitlines():
            if path.startswith(".github/workflows/"):
                staged_paths.add(path)

        # For staged workflow files: read from the git index (staged content).
        for path in staged_paths:
            result2 = subprocess.run(
                ["git", "show", f":0:{path}"],
                capture_output=True, text=True, cwd=repo_root
            )
            if result2.returncode == 0:
                names.update(parse_workflow_jobs(result2.stdout))

        # For unstaged workflow files: read from disk (they are unchanged).
        # Together with the staged set above, this gives the full post-push view.
        if os.path.isdir(workflows_dir):
            for fname in os.listdir(workflows_dir):
                if not (fname.endswith(".yml") or fname.endswith(".yaml")):
                    continue
                rel_path = f".github/workflows/{fname}"
                if rel_path in staged_paths:
                    continue  # already covered by the staged read above
                fpath = os.path.join(workflows_dir, fname)
                try:
                    with open(fpath) as f:
                        names.update(parse_workflow_jobs(f.read()))
                except Exception:
                    pass
    else:
        # Read all committed workflow files from disk.
        if os.path.isdir(workflows_dir):
            for fname in os.listdir(workflows_dir):
                if not (fname.endswith(".yml") or fname.endswith(".yaml")):
                    continue
                fpath = os.path.join(workflows_dir, fname)
                try:
                    with open(fpath) as f:
                        names.update(parse_workflow_jobs(f.read()))
                except Exception:
                    pass
    return names

# Handle --update-baseline
if update_baseline:
    result = subprocess.run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print("[audit-branch-protection] could not determine repo for --update-baseline", file=sys.stderr)
        sys.exit(2)
    nwo = result.stdout.strip()
    result2 = subprocess.run(
        ["gh", "api", f"repos/{nwo}/branches/main/protection"],
        capture_output=True, text=True
    )
    if result2.returncode != 0:
        print(f"[audit-branch-protection] api failed: {result2.stderr}", file=sys.stderr)
        sys.exit(2)
    os.makedirs(os.path.dirname(baseline_path), exist_ok=True)
    with open(baseline_path, "w") as f:
        f.write(result2.stdout)
    print(f"[audit-branch-protection] updated {baseline_path} from live GitHub API")
    sys.exit(0)

# In staged mode, first check that unchanged workflow files don't contain branch-protection rules
if check_staged:
    result = subprocess.run(
        ["git", "diff", "--cached", "--name-only"],
        capture_output=True, text=True, cwd=repo_root
    )
    staged_paths = set()
    for path in result.stdout.splitlines():
        if path.startswith(".github/workflows/"):
            staged_paths.add(path)

    # Check all workflow files for branch-protection rules
    if os.path.isdir(workflows_dir):
        for fname in os.listdir(workflows_dir):
            if not (fname.endswith(".yml") or fname.endswith(".yaml")):
                continue
            rel_path = f".github/workflows/{fname}"
            if rel_path in staged_paths:
                continue  # staged file, developer is aware of it
            fpath = os.path.join(workflows_dir, fname)
            try:
                with open(fpath) as f:
                    file_content = f.read()
                if has_branch_protection_rules(file_content):
                    print(f"[audit-branch-protection] ERROR: branch-protection rule found in unstaged {rel_path}", file=sys.stderr)
                    print(f"  Remediation: either git add {rel_path} or remove the branch-protection rule", file=sys.stderr)
                    sys.exit(1)
            except Exception:
                pass


# Get required contexts
if mode == "live":
    required_contexts = get_contexts_from_live()
else:
    required_contexts = get_contexts_from_baseline()

if not required_contexts:
    print("[audit-branch-protection] no required contexts found — skip audit", file=sys.stderr)
    sys.exit(0)

# Get workflow job names
workflow_job_names = get_all_workflow_job_names(staged=check_staged)

# Find missing contexts
missing = [ctx for ctx in required_contexts if ctx not in workflow_job_names]

if not missing:
    print(f"[audit-branch-protection] OK — all {len(required_contexts)} required contexts match workflow job names")
    sys.exit(0)

# Report drift
print(f"[audit-branch-protection] DRIFT DETECTED (CREDIBLE-058):", file=sys.stderr)
print(f"  Required contexts with no matching workflow job:", file=sys.stderr)
for ctx in missing:
    print(f"    {ctx!r}", file=sys.stderr)
print("", file=sys.stderr)
print("  Known workflow jobs:", file=sys.stderr)
for name in sorted(workflow_job_names):
    print(f"    {name!r}", file=sys.stderr)
print("", file=sys.stderr)
print("  Fix: rename the workflow job to match the required context, or", file=sys.stderr)
print("  update branch protection to use the new job name, then run:", file=sys.stderr)
print("    scripts/ci/audit-branch-protection.sh --update-baseline", file=sys.stderr)

# Emit ambient event
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
event = json.dumps({
    "ts": ts,
    "kind": "branch_protection_drift",
    "event": "branch_protection_drift",
    "missing": missing,
    "required_count": len(required_contexts),
})
try:
    with open(ambient_log, "a") as f:
        f.write(event + "\n")
except Exception:
    pass

sys.exit(1)
PYEOF
