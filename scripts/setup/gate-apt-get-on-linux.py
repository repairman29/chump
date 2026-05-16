#!/usr/bin/env python3
"""gate-apt-get-on-linux.py — INFRA-1542 Phase 2

Find every `sudo apt-get install` step in .github/workflows/ci.yml and
ensure the containing STEP carries `if: runner.os == 'Linux'`. After
gating, the same workflow can run on either ubuntu-latest or
[self-hosted, macOS, ARM64] without hard-failing the apt-get on macOS.

The workspace's chump-desktop crate uses Tauri v2, which on macOS uses
native WebKit + Cocoa and needs no system libs — the apt-get install of
webkit2gtk / libgtk-3-dev / librsvg2-dev / etc. is a pure Linux-runner
prerequisite.

Idempotent. --dry-run shows the diff without writing.
"""
import argparse
import re
import sys
from pathlib import Path

MARKER = "# INFRA-1542: apt-get gated on Linux (macOS uses native WebKit)"
GUARD = "runner.os == 'Linux'"

# A step starts with `      - ` (6 spaces, dash, space). Step keys are indented
# 8 spaces inside it (`        if:`, `        run:`, `        name:`, ...).
STEP_START_RE = re.compile(r'^      - ')


def is_step_start(line: str) -> bool:
    return bool(STEP_START_RE.match(line))


def gate(src: str) -> tuple[str, int]:
    """Return (new_src, num_steps_gated)."""
    lines = src.splitlines(keepends=True)
    n = len(lines)
    # First pass: find every step boundary [start, end_exclusive].
    step_starts = [i for i, line in enumerate(lines) if is_step_start(line)]
    step_starts.append(n)  # sentinel
    steps = [(step_starts[i], step_starts[i + 1]) for i in range(len(step_starts) - 1)]

    # Second pass: for each step, decide whether to gate.
    edits = []  # (line_index, action, new_line)  — applied right-to-left to keep indices valid
    gated = 0
    for s, e in steps:
        body = ''.join(lines[s:e])
        if 'sudo apt-get install' not in body:
            continue
        # Find existing `if:` line within this step's body (8-space indent).
        if_lineno = None
        for k in range(s + 1, e):
            if re.match(r'^        if:\s', lines[k]):
                if_lineno = k
                break
        if if_lineno is None:
            # Insert a new `if:` line right after the step start (s).
            new_line = f"        if: {GUARD}  {MARKER}\n"
            edits.append((s + 1, 'insert', new_line))
            gated += 1
        else:
            existing = lines[if_lineno]
            m = re.match(r'^        if:\s*(.+?)\s*$', existing)
            cond = m.group(1).strip() if m else ''
            if 'runner.os' in cond:
                continue  # already gated
            # Extend with AND.
            new = f"        if: ({cond}) && {GUARD}  {MARKER}\n"
            edits.append((if_lineno, 'replace', new))
            gated += 1

    # Apply edits high-to-low so indices stay valid.
    for idx, action, new_line in sorted(edits, key=lambda x: -x[0]):
        if action == 'insert':
            lines.insert(idx, new_line)
        else:
            lines[idx] = new_line
    return ''.join(lines), gated


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--ci-yml', default='.github/workflows/ci.yml')
    p.add_argument('--dry-run', action='store_true')
    args = p.parse_args()
    src = Path(args.ci_yml).read_text()
    new_src, n_gated = gate(src)
    if args.dry_run:
        if new_src == src:
            print("DRY-RUN: no changes (already gated)")
            return 0
        import difflib
        diff = difflib.unified_diff(
            src.splitlines(keepends=True),
            new_src.splitlines(keepends=True),
            fromfile=args.ci_yml,
            tofile=f'{args.ci_yml}.new',
        )
        sys.stdout.writelines(diff)
        print(f"\n[gate-apt-get] would gate {n_gated} step(s)", file=sys.stderr)
        return 0
    if new_src == src:
        print("[gate-apt-get] no changes (already gated)")
        return 0
    Path(args.ci_yml).write_text(new_src)
    print(f"[gate-apt-get] gated {n_gated} apt-get step(s)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
