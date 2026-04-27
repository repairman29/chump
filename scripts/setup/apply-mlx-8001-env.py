#!/usr/bin/env python3
"""Upsert MLX-lite (8001) inference lines in repo-root .env; preserves all other lines."""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENV = ROOT / ".env"

UPSERT = {
    "OPENAI_API_BASE": "http://127.0.0.1:8001/v1",
    "OPENAI_API_KEY": "not-needed",
    "OPENAI_MODEL": "mlx-community/Qwen2.5-7B-Instruct-4bit",
}

MARKER = "# --- Chump: MLX lite (8001) ---"


def main() -> int:
    raw = ENV.read_text() if ENV.exists() else ""
    lines = raw.splitlines()
    out: list[str] = []
    skip_until_blank = False
    for line in lines:
        if line.strip() == MARKER:
            skip_until_blank = True
            continue
        if skip_until_blank:
            if line.strip() == "":
                skip_until_blank = False
            continue
        key = line.split("=", 1)[0] if "=" in line else ""
        if key in UPSERT:
            continue
        out.append(line)
    while out and out[-1] == "":
        out.pop()
    out.append("")
    out.append(MARKER)
    for k, v in UPSERT.items():
        out.append(f"{k}={v}")
    out.append("")
    ENV.write_text("\n".join(out))
    print(f"Wrote MLX 8001 profile to {ENV}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
