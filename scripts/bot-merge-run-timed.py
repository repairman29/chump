#!/usr/bin/env python3
"""Run a subprocess with a wall-clock timeout; stream merged stdout/stderr.

INFRA-028: on timeout the process is killed and the last 20 captured lines are
printed to stderr (subprocess output is also streamed live to stdout).
"""
from __future__ import annotations

import collections
import subprocess
import sys
import threading


def main() -> int:
    argv = sys.argv[1:]
    if len(argv) < 3 or argv[1] != "--":
        print(
            "usage: bot-merge-run-timed.py <seconds> -- <command...>",
            file=sys.stderr,
        )
        return 2
    try:
        max_secs = int(argv[0])
    except ValueError:
        print(
            "usage: bot-merge-run-timed.py <seconds> -- <command...>",
            file=sys.stderr,
        )
        return 2
    cmd = argv[2:]
    last: collections.deque[str] = collections.deque(maxlen=20)

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    except OSError as e:
        print(f"[bot-merge] failed to spawn {cmd!r}: {e}", file=sys.stderr)
        return 126

    def pump() -> None:
        assert proc.stdout is not None
        try:
            for line in iter(proc.stdout.readline, ""):
                if not line:
                    break
                sys.stdout.write(line)
                sys.stdout.flush()
                last.append(line.rstrip("\n\r"))
        finally:
            proc.stdout.close()

    th = threading.Thread(target=pump, daemon=True)
    th.start()
    try:
        proc.wait(timeout=max_secs)
    except subprocess.TimeoutExpired:
        proc.kill()
        try:
            proc.wait(timeout=15)
        except Exception:
            pass
        th.join(timeout=5)
        print(
            f"[bot-merge] TIMEOUT after {max_secs}s: {' '.join(cmd)}",
            file=sys.stderr,
        )
        if last:
            print("[bot-merge] Last lines from subprocess:", file=sys.stderr)
            for ln in last:
                print(ln, file=sys.stderr)
        return 124

    th.join(timeout=2)
    rc = proc.returncode
    return 0 if rc is None else rc


if __name__ == "__main__":
    sys.exit(main())
