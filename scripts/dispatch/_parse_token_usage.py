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
from datetime import datetime, timezone


def main() -> None:
    if len(sys.argv) < 6:
        sys.stderr.write("usage: _parse_token_usage.py <fifo> <amb> <gap_id> <cycle_id> <session_id>\n")
        sys.exit(1)

    fifo_path, amb_path, gap_id, cycle_id, session_id = sys.argv[1:6]
    amb_dir = os.path.dirname(amb_path)

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
    except Exception:
        pass  # best-effort — never block the worker


if __name__ == "__main__":
    main()
