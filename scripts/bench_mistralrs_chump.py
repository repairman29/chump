#!/usr/bin/env python3
"""
Micro-benchmark in-process mistral.rs via the Chump binary (minimal Provider path).

Each configuration starts a fresh process (model + ISQ loaded per run). Use --warmup
for one throwaway run per config before timed runs.

Example:
  cargo build --release --features mistralrs-metal -p chump
  ./scripts/bench-mistralrs-chump.sh --model Qwen/Qwen3-4B --isq 4,6,8 --runs 2 --warmup

See docs/MISTRALRS_BENCHMARKS.md for protocol and CSV columns.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import platform
import socket
import statistics
import subprocess
import sys
import time
import uuid


def _parse_int_list(s: str) -> list[int]:
    out: list[int] = []
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        out.append(int(part))
    return out


def _parse_bool_list(s: str) -> list[str]:
    """Values like '0,1' for env vars that use 1/0."""
    return [p.strip() for p in s.split(",") if p.strip()]


def _median(xs: list[float]) -> float:
    if not xs:
        return float("nan")
    return float(statistics.median(xs))


def main() -> int:
    p = argparse.ArgumentParser(description="Benchmark Chump in-process mistral.rs (CSV output).")
    p.add_argument(
        "--binary",
        default=os.environ.get("CHUMP_BENCH_BINARY", ""),
        help="Path to chump executable (default: ./target/release/chump from repo root)",
    )
    p.add_argument(
        "--repo-root",
        default="",
        help="Repo root (default: parent of scripts/ containing this file)",
    )
    p.add_argument("--model", default=os.environ.get("CHUMP_MISTRALRS_MODEL", "Qwen/Qwen3-4B"))
    p.add_argument(
        "--isq",
        default="8",
        help="Comma-separated CHUMP_MISTRALRS_ISQ_BITS values (e.g. 4,6,8)",
    )
    p.add_argument(
        "--paged",
        default="0",
        help="Comma-separated CHUMP_MISTRALRS_PAGED_ATTN values (0 or 1)",
    )
    p.add_argument(
        "--force-cpu",
        default="0",
        help="Comma-separated CHUMP_MISTRALRS_FORCE_CPU values (0 or 1)",
    )
    p.add_argument(
        "--moqe",
        default="0",
        help="Comma-separated CHUMP_MISTRALRS_MOQE values (0 or 1)",
    )
    p.add_argument("--runs", type=int, default=1, help="Timed runs per config (after warmup)")
    p.add_argument(
        "--warmup",
        action="store_true",
        help="One untimed run per config before timed runs",
    )
    p.add_argument(
        "--prompt",
        default="Reply with exactly one line: BENCH_OK",
        help="User message passed as argv to chump (single-shot minimal agent)",
    )
    p.add_argument("--prompt-file", help="Read prompt from file (overrides --prompt)")
    p.add_argument(
        "--output",
        "-o",
        default="",
        help="Write CSV rows here as well as stdout",
    )
    p.add_argument(
        "--summary",
        action="store_true",
        help="Append one extra row per config with wall_seconds = median of timed runs",
    )
    args = p.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    root = args.repo_root or os.path.dirname(here)
    binary = args.binary or os.path.join(root, "target", "release", "chump")
    if not os.path.isfile(binary) or not os.access(binary, os.X_OK):
        print(f"error: missing executable binary: {binary}", file=sys.stderr)
        print("  build: cargo build --release --features mistralrs-infer -p chump", file=sys.stderr)
        print("     or: cargo build --release --features mistralrs-metal -p chump", file=sys.stderr)
        return 1

    if args.prompt_file:
        with open(args.prompt_file, encoding="utf-8") as f:
            prompt = f.read().strip()
    else:
        prompt = args.prompt

    if not prompt:
        print("error: empty prompt", file=sys.stderr)
        return 1

    isq_vals = _parse_int_list(args.isq)
    paged_vals = _parse_bool_list(args.paged)
    cpu_vals = _parse_bool_list(args.force_cpu)
    moqe_vals = _parse_bool_list(args.moqe)
    if not isq_vals:
        isq_vals = [8]
    if not paged_vals:
        paged_vals = ["0"]
    if not cpu_vals:
        cpu_vals = ["0"]
    if not moqe_vals:
        moqe_vals = ["0"]

    run_group = str(uuid.uuid4())[:8]
    host = socket.gethostname()
    ts_start = dt.datetime.now(dt.timezone.utc).isoformat()
    revision = os.environ.get("CHUMP_MISTRALRS_HF_REVISION", "")

    fieldnames = [
        "run_group",
        "ts_utc",
        "host",
        "platform",
        "bench_model",
        "hf_revision",
        "isq_bits",
        "paged_attn",
        "force_cpu",
        "moqe",
        "run_kind",
        "run_index",
        "wall_seconds",
        "exit_code",
        "stdout_bytes",
        "stderr_bytes",
    ]

    rows: list[dict[str, object]] = []

    def one_run(
        *,
        isq: int,
        paged: str,
        force_cpu: str,
        moqe: str,
        run_kind: str,
        run_index: int,
    ) -> None:
        env = os.environ.copy()
        env["CHUMP_INFERENCE_BACKEND"] = "mistralrs"
        env["CHUMP_MISTRALRS_MODEL"] = args.model
        env["CHUMP_MISTRALRS_ISQ_BITS"] = str(isq)
        env["CHUMP_MISTRALRS_PAGED_ATTN"] = paged
        env["CHUMP_MISTRALRS_FORCE_CPU"] = force_cpu
        env["CHUMP_MISTRALRS_MOQE"] = moqe
        env["OPENAI_MODEL"] = args.model
        # Bench in-process primary; avoid accidental HTTP cascade.
        env.pop("OPENAI_API_BASE", None)
        env.pop("CHUMP_CASCADE_ENABLED", None)
        if revision:
            env["CHUMP_MISTRALRS_HF_REVISION"] = revision

        t0 = time.perf_counter()
        proc = subprocess.run(
            [binary, prompt],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
            timeout=None,
        )
        wall = time.perf_counter() - t0
        rows.append(
            {
                "run_group": run_group,
                "ts_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
                "host": host,
                "platform": platform.platform(),
                "bench_model": args.model,
                "hf_revision": revision,
                "isq_bits": isq,
                "paged_attn": paged,
                "force_cpu": force_cpu,
                "moqe": moqe,
                "run_kind": run_kind,
                "run_index": run_index,
                "wall_seconds": round(wall, 4),
                "exit_code": proc.returncode,
                "stdout_bytes": len(proc.stdout.encode("utf-8")),
                "stderr_bytes": len(proc.stderr.encode("utf-8")),
            }
        )
        if proc.returncode != 0:
            tail = proc.stderr[-2000:] if proc.stderr else ""
            print(f"warning: exit {proc.returncode} isq={isq} paged={paged} cpu={force_cpu}", file=sys.stderr)
            if tail:
                print(tail, file=sys.stderr)

    for isq in isq_vals:
        for paged in paged_vals:
            for force_cpu in cpu_vals:
                for moqe in moqe_vals:
                    idx = 0
                    if args.warmup:
                        one_run(
                            isq=isq,
                            paged=paged,
                            force_cpu=force_cpu,
                            moqe=moqe,
                            run_kind="warmup",
                            run_index=idx,
                        )
                        idx += 1
                    wall_samples: list[float] = []
                    for r in range(args.runs):
                        one_run(
                            isq=isq,
                            paged=paged,
                            force_cpu=force_cpu,
                            moqe=moqe,
                            run_kind="timed",
                            run_index=idx,
                        )
                        wall_samples.append(float(rows[-1]["wall_seconds"]))  # type: ignore[arg-type]
                        idx += 1
                    if args.summary and wall_samples:
                        rows.append(
                            {
                                "run_group": run_group,
                                "ts_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
                                "host": host,
                                "platform": platform.platform(),
                                "bench_model": args.model,
                                "hf_revision": revision,
                                "isq_bits": isq,
                                "paged_attn": paged,
                                "force_cpu": force_cpu,
                                "moqe": moqe,
                                "run_kind": "median",
                                "run_index": -1,
                                "wall_seconds": round(_median(wall_samples), 4),
                                "exit_code": 0,
                                "stdout_bytes": "",
                                "stderr_bytes": "",
                            }
                        )

    w = sys.stdout
    writer = csv.DictWriter(w, fieldnames=fieldnames, extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        writer.writerow(row)  # type: ignore[arg-type]
    w.flush()

    if args.output:
        out_path = args.output
        if not os.path.isabs(out_path):
            out_path = os.path.join(root, out_path)
        with open(out_path, "w", encoding="utf-8", newline="") as f:
            wr = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
            wr.writeheader()
            for row in rows:
                wr.writerow(row)  # type: ignore[arg-type]

    print(f"# bench_mistralrs_chump: group={run_group} started={ts_start} rows={len(rows)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
