#!/usr/bin/env python3
"""add-heavy-job-runner-overrides.py — INFRA-1542 Phase 2

Make the 8 heavy ci.yml jobs (clippy, cargo-test, audit, coverage, e2e-pwa,
e2e-golden-path, tauri-cowork-e2e, fast-checks) honor a repo-variable
override on their `runs-on` clause. Operator can flip a single job from
ubuntu-latest to [self-hosted, macOS, ARM64] without a code change:

    gh variable set RUNNER_CARGO_TEST --body '["self-hosted","macOS","ARM64"]'

The job picks up the new lane on the next workflow run. Unset variable →
default `ubuntu-latest`. Each job gets its own override var so operator
can rebalance lanes one at a time and observe.

Idempotent. --dry-run shows the diff.
"""
import argparse
import re
import sys
from pathlib import Path

# Map job-name → var-name. Snake-cased upper.
HEAVY_JOBS = {
    'clippy': 'RUNNER_CLIPPY',
    'cargo-test': 'RUNNER_CARGO_TEST',
    'audit': 'RUNNER_AUDIT',
    'coverage': 'RUNNER_COVERAGE',
    'e2e-pwa': 'RUNNER_E2E_PWA',
    'e2e-golden-path': 'RUNNER_E2E_GOLDEN_PATH',
    'tauri-cowork-e2e': 'RUNNER_TAURI_COWORK_E2E',
    'fast-checks': 'RUNNER_FAST_CHECKS',
}

MARKER = "# INFRA-1542: lane override via repo var (unset → ubuntu-latest)"


def overridden(var_name: str) -> str:
    """Build the GHA expression that resolves the override."""
    return (
        "${{ vars." + var_name + " != '' "
        "&& fromJSON(vars." + var_name + ") "
        "|| 'ubuntu-latest' }}"
    )


def patch(src: str) -> tuple[str, int]:
    out = src
    patched = 0
    for job, var in HEAVY_JOBS.items():
        # Find the job's body span.
        m = re.search(rf'^  ({re.escape(job)}):\s*\n', out, re.MULTILINE)
        if not m:
            print(f"  SKIP {job}: header not found", file=sys.stderr)
            continue
        body_start = m.end()
        nh = re.search(r'^  [a-zA-Z][a-zA-Z0-9_-]*:\s*\n', out[body_start:], re.MULTILINE)
        body_end = body_start + nh.start() if nh else len(out)
        body = out[body_start:body_end]
        if MARKER in body:
            print(f"  ALREADY OVERRIDDEN {job}")
            continue
        # Find runs-on. Could be ubuntu-latest OR already migrated to self-hosted.
        runs_match = re.search(r'^(    runs-on: )(.+)$', body, re.MULTILINE)
        if not runs_match:
            print(f"  SKIP {job}: no runs-on", file=sys.stderr)
            continue
        current = runs_match.group(2).strip()
        # Don't touch a job that's ALREADY been migrated to self-hosted (Phase 1).
        if 'self-hosted' in current:
            print(f"  SKIP {job}: already on self-hosted ({current})")
            continue
        # Only patch ubuntu-latest jobs.
        if current != 'ubuntu-latest':
            print(f"  SKIP {job}: unexpected runs-on={current!r}")
            continue
        new_line = f"    runs-on: {overridden(var)}  {MARKER}"
        new_body = (
            body[:runs_match.start()]
            + new_line
            + body[runs_match.end():]
        )
        out = out[:body_start] + new_body + out[body_end:]
        patched += 1
        print(f"  PATCHED {job}  -> var:{var}")
    return out, patched


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--ci-yml', default='.github/workflows/ci.yml')
    p.add_argument('--dry-run', action='store_true')
    args = p.parse_args()
    src = Path(args.ci_yml).read_text()
    new_src, n = patch(src)
    if args.dry_run:
        if new_src == src:
            print("DRY-RUN: no changes")
            return 0
        import difflib
        diff = difflib.unified_diff(
            src.splitlines(keepends=True),
            new_src.splitlines(keepends=True),
            fromfile=args.ci_yml,
            tofile=f'{args.ci_yml}.new',
        )
        sys.stdout.writelines(diff)
        print(f"\n[runner-overrides] would patch {n} job(s)", file=sys.stderr)
        return 0
    if new_src == src:
        print("[runner-overrides] no changes")
        return 0
    Path(args.ci_yml).write_text(new_src)
    print(f"[runner-overrides] patched {n} job(s)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
