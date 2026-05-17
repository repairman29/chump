#!/usr/bin/env python3
"""migrate-ci-jobs-to-self-hosted.py — INFRA-1540

Surgically migrate the macOS-safe ci.yml jobs from `ubuntu-latest` to the
self-hosted `[self-hosted, macOS, ARM64]` runner pool. Adds the fork-PR
security guard (INFRA-1534 AC #7) on every migrated job.

Idempotent. Run with --dry-run to preview.

Jobs migrated: rollup stubs + required gates + lightweight rollups. NOT the
heavy jobs (clippy, cargo-test, audit, coverage, e2e-pwa, e2e-golden-path,
tauri-cowork-e2e) — those have apt-get install for Linux Tauri deps and
need per-job analysis (Phase 2 of INFRA-1540).
"""
import argparse
import re
import sys
from pathlib import Path

MIGRATE_JOBS = [
    'changes', 'test', 'pr-hygiene', 'e2e-battle-sim', 'test-e2e',
    'clippy-stub', 'clippy-required',
    'cargo-test-stub', 'cargo-test-required',
    'fast-checks-stub', 'fast-checks-required',
    'audit-stub', 'audit-required',
    'integration-test',
]

# Marker comment so a future audit can find migrated jobs.
MARKER = '# INFRA-1540: self-hosted macOS-ARM64 runner (Phase 1 migration)'
GUARD = "if: github.event.pull_request.head.repo.fork == false"
NEW_RUNS_ON = "runs-on: [self-hosted, macOS, ARM64]"


def _job_body_span(src: str, job: str) -> tuple[int, int] | None:
    """Return (start, end) byte offsets bounding the job's header+body
    (from the `  jobname:` line up to but not including the next 2-space
    job header). Returns None if not found."""
    header = re.search(rf'^(  {re.escape(job)}:\s*\n)', src, re.MULTILINE)
    if not header:
        return None
    body_start = header.end()
    # Find next job header (2-space-indent identifier ending in colon).
    next_header = re.search(r'^  [a-zA-Z][a-zA-Z0-9_-]*:\s*\n', src[body_start:], re.MULTILINE)
    body_end = body_start + next_header.start() if next_header else len(src)
    return (header.start(), body_end)


def migrate(src: str, jobs: list[str], dry: bool) -> tuple[str, list[str]]:
    """Return (new_src, list_of_migrated_job_names)."""
    out = src
    migrated = []
    for job in jobs:
        span = _job_body_span(out, job)
        if not span:
            print(f"  SKIP {job}: header not found", file=sys.stderr)
            continue
        body_start, body_end = span
        body = out[body_start:body_end]

        if 'self-hosted' in body and MARKER not in body:
            print(f"  SKIP {job}: already on self-hosted (non-INFRA-1540)")
            continue
        if MARKER in body:
            print(f"  ALREADY MIGRATED {job}")
            continue

        # Find this job's `runs-on: ubuntu-latest` line within its body.
        runs_match = re.search(r'^(    runs-on: ubuntu-latest)\s*$',
                               body, re.MULTILINE)
        if not runs_match:
            print(f"  SKIP {job}: no `runs-on: ubuntu-latest`")
            continue

        # 1. Replace runs-on. Insert marker comment immediately above.
        new_body = (
            body[:runs_match.start()]
            + f"    {MARKER}\n    {NEW_RUNS_ON}"
            + body[runs_match.end():]
        )

        # 2. Handle the `if:` guard. Scan the WHOLE job body for an existing
        # job-level `if:` (4-space indent, before `steps:`).
        steps_match = re.search(r'^    steps:\s*$', new_body, re.MULTILINE)
        scan_end = steps_match.start() if steps_match else len(new_body)
        if_match = re.search(r'^    if:\s*(.+)$', new_body[:scan_end], re.MULTILINE)
        if if_match:
            existing_cond = if_match.group(1).strip()
            if 'fork == false' in existing_cond:
                # already guarded — leave as-is
                pass
            else:
                # Extend with AND.
                old_line = if_match.group(0)
                new_line = (
                    f"    if: ({existing_cond}) "
                    "&& github.event.pull_request.head.repo.fork == false"
                )
                new_body = new_body.replace(old_line, new_line, 1)
        else:
            # No existing if — add one immediately after our new runs-on line.
            new_runs_full = f"    {MARKER}\n    {NEW_RUNS_ON}"
            new_body = new_body.replace(
                new_runs_full,
                new_runs_full + f"\n    {GUARD}",
                1,
            )

        out = out[:body_start] + new_body + out[body_end:]
        migrated.append(job)
        print(f"  MIGRATED {job}")
    return out, migrated


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--ci-yml', default='.github/workflows/ci.yml')
    p.add_argument('--dry-run', action='store_true')
    args = p.parse_args()

    src = Path(args.ci_yml).read_text()
    new_src, migrated = migrate(src, MIGRATE_JOBS, args.dry_run)
    if args.dry_run:
        if new_src == src:
            print("DRY-RUN: no changes")
        else:
            # Print unified diff summary.
            import difflib
            diff = difflib.unified_diff(
                src.splitlines(keepends=True),
                new_src.splitlines(keepends=True),
                fromfile=args.ci_yml,
                tofile=f'{args.ci_yml}.new',
            )
            sys.stdout.writelines(diff)
        sys.exit(0)
    if new_src == src:
        print("no changes")
        sys.exit(0)
    Path(args.ci_yml).write_text(new_src)
    print(f"\nwrote {args.ci_yml}: migrated {len(migrated)} job(s)")


if __name__ == '__main__':
    main()
