#!/usr/bin/env python3
"""INFRA-639: Read claude -p JSONL stdout, emit token_usage_partial to ambient.jsonl.

Called by worker.sh with the write-end of a named pipe:
    python3 _parse_token_usage.py <fifo> <amb_path> <gap_id> <cycle_id> <session_id>

Reads lines from <fifo>; for each line that carries a .usage object with
nonzero token counts, appends one token_usage_partial event to <amb_path>.
Exits cleanly when the write-end of the pipe is closed (EOF).
"""
import sys
import json
import os
import signal
from datetime import datetime, timezone


class _ParseTimeout(Exception):
    """RESILIENT-361: raised by SIGALRM to unblock a wedged FIFO open/read."""


def _on_alarm(signum, frame):  # noqa: ARG001
    raise _ParseTimeout()


def main() -> None:
    if len(sys.argv) < 6:
        sys.stderr.write("usage: _parse_token_usage.py <fifo> <amb> <gap_id> <cycle_id> <session_id>\n")
        sys.exit(1)

    fifo_path, amb_path, gap_id, cycle_id, session_id = sys.argv[1:6]
    amb_dir = os.path.dirname(amb_path)

    # RESILIENT-361: `open(fifo)` BLOCKS until a writer connects (wait_for_partner),
    # and the following `for raw in fh` blocks until EOF. If the claude agent dies
    # or the worker never closes the write-end, this hangs FOREVER and wedges the
    # worker that waits on us — observed 2026-08-21: two CJ workers frozen ~5h, the
    # whole fleet drought behind an all-green facade. The docstring promises "never
    # block the worker"; enforce it with a hard alarm just above the agent timeout
    # (2700s), so a live run is never cut but a dead-writer wedge is bounded.
    timeout_s = 0
    try:
        timeout_s = int(os.environ.get("CHUMP_TOKEN_PARSE_TIMEOUT_S", "3000") or 3000)
        if timeout_s > 0:
            signal.signal(signal.SIGALRM, _on_alarm)
            signal.alarm(timeout_s)
    except (ValueError, OSError, AttributeError):
        timeout_s = 0  # no SIGALRM here (non-main-thread / unsupported) — degrade

    try:
        with open(fifo_path) as fh:
            for raw in fh:
                try:
                    d = json.loads(raw.strip())
                except (ValueError, UnicodeDecodeError):
                    continue

                # Usage may appear at top level or nested under "message".
                u = d.get("usage") or (d.get("message") or {}).get("usage") or {}
                if not u:
                    continue

                inp = int(u.get("input_tokens") or 0)
                out = int(u.get("output_tokens") or 0)
                crd = int(u.get("cache_read_input_tokens") or 0)
                ccr = int(u.get("cache_creation_input_tokens") or 0)

                if not (inp or out or crd or ccr):
                    continue

                ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                line = (
                    f'{{"ts":"{ts}","kind":"token_usage_partial",'
                    f'"session_id":"{session_id}","gap_id":"{gap_id}",'
                    f'"cycle_id":"{cycle_id}",'
                    f'"input":{inp},"output":{out},'
                    f'"cache_read":{crd},"cache_creation":{ccr}}}\n'
                )
                if amb_dir:
                    os.makedirs(amb_dir, exist_ok=True)
                with open(amb_path, "a") as af:
                    af.write(line)
    except _ParseTimeout:
        # write-end never closed within the budget — the agent is gone; bail so the
        # worker's wait() returns instead of hanging on a dead pipe.
        pass
    except Exception:
        pass  # best-effort — never block the worker
    finally:
        try:
            signal.alarm(0)
        except Exception:
            pass


if __name__ == "__main__":
    main()
