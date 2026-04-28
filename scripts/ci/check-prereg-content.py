#!/usr/bin/env python3
# INFRA-113: validate that an EVAL-* / RESEARCH-* preregistration file
# locks the methodology contract before data collection. The pre-commit
# guard at scripts/git-hooks/pre-commit only checks file *existence*; an
# empty file passes. This script enforces *content* — a one-line file
# satisfying the existence gate but violating docs/RESEARCH_INTEGRITY.md
# is rejected here.
#
# Required content (each must appear in the file body, ignoring template
# angle-bracket placeholders the author hasn't filled in):
#   1. Sample size       — explicit n per cell ≥ 25 (template default n=50)
#   2. Judge identity    — at least one concrete non-Anthropic judge or
#                          human-judge mention (per RESEARCH_INTEGRITY.md
#                          rules barring Anthropic-only panels)
#   3. A/A baseline plan — explicit reference to A/A or baseline noise
#                          floor as the comparator
#   4. Effect threshold  — a numeric threshold attached to delta / Δ /
#                          effect (mechanism-analysis bar)
#   5. Prohibited-claims — pointer to docs/RESEARCH_INTEGRITY.md or an
#                          explicit prohibited-claims attestation
#
# Plus structural requirements:
#   - Required section headers present (Hypothesis, Design, Sample size,
#     Primary metric, Decision rule).
#   - Filled body length ≥ 400 chars after stripping placeholders, headers,
#     and blank lines.
#   - Unfilled `<...>` template placeholders ≤ 5 (so partial fill-in is OK
#     for genuinely-irrelevant fields, but a wholesale unfilled template
#     is rejected).
#
# Usage:
#   check-prereg-content.py <GAP-ID> <prereg-file-path>
#   echo "$content" | check-prereg-content.py <GAP-ID> --stdin
#
# Exit 0 on pass; 1 on fail with diagnostic on stderr.

import argparse
import re
import sys
from pathlib import Path


def strip_template_noise(text: str) -> str:
    """Remove markdown headers, blank lines, and `<...>` placeholders so
    the remaining length reflects what the author actually wrote."""
    out_lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#"):
            continue
        if stripped.startswith(">") or stripped.startswith("---"):
            continue
        no_placeholders = re.sub(r"<[^>\n]{0,200}>", "", stripped)
        if no_placeholders.strip():
            out_lines.append(no_placeholders)
    return "\n".join(out_lines)


REQUIRED_SECTIONS = [
    ("hypothesis",     re.compile(r"^##\s*\d*\.?\s*Hypothesis\b", re.MULTILINE | re.IGNORECASE)),
    ("design",         re.compile(r"^##\s*\d*\.?\s*Design\b",     re.MULTILINE | re.IGNORECASE)),
    ("sample size",    re.compile(r"^###?\s*\d*\.?\s*Sample size\b", re.MULTILINE | re.IGNORECASE)),
    ("primary metric", re.compile(r"^##\s*\d*\.?\s*Primary metric\b", re.MULTILINE | re.IGNORECASE)),
    ("decision rule",  re.compile(r"^##\s*\d*\.?\s*Decision rule\b", re.MULTILINE | re.IGNORECASE)),
]

# Concrete non-Anthropic judge tokens. Anthropic-only panels are forbidden
# by docs/RESEARCH_INTEGRITY.md, so the file must name at least one of
# these (or a human judge) somewhere in a "judge" context.
NON_ANTHROPIC_JUDGES = re.compile(
    r"\b(GPT-?\d|gpt[-_]?\d|OpenAI|Gemini|Llama|Qwen|Mistral|DeepSeek|"
    r"Together|Groq|external|human(?:\s+judge)?|Jeff)\b",
    re.IGNORECASE,
)


def check_required_sections(text: str) -> list[str]:
    missing = []
    for label, pattern in REQUIRED_SECTIONS:
        if not pattern.search(text):
            missing.append(label)
    return missing


def check_sample_size(body: str) -> str | None:
    # Match `n per cell: 50`, `n=50`, `n ≥ 48`, etc. Must be ≥ 25 to be
    # considered a serious eval (RESEARCH_INTEGRITY.md prefers n≥50).
    candidates = re.findall(
        r"n\s*(?:per\s*cell)?\s*[:=≥>]+\s*(\d+)",
        body,
        re.IGNORECASE,
    )
    if not candidates:
        return "no explicit sample size — expected `n per cell: <int>` or `n=<int>` (>= 25)"
    if not any(int(c) >= 25 for c in candidates):
        return f"sample size too small (largest n found: {max(int(c) for c in candidates)}); expected >= 25"
    return None


def check_judge_identity(body: str) -> str | None:
    # The file must mention a judge AND, in proximity, at least one
    # non-Anthropic concrete identifier. We scan each "judge" line ±2
    # neighbours.
    lines = body.splitlines()
    for i, line in enumerate(lines):
        if "judge" not in line.lower():
            continue
        window = "\n".join(lines[max(0, i - 2): i + 3])
        if NON_ANTHROPIC_JUDGES.search(window):
            return None
    return ("no concrete non-Anthropic judge identified near a `judge` reference "
            "(per RESEARCH_INTEGRITY.md, Anthropic-only panels are not acceptable)")


def check_aa_baseline(body: str) -> str | None:
    if re.search(r"\bA/A\b", body) or re.search(r"\bnoise\s*floor\b", body, re.IGNORECASE):
        return None
    return "no A/A baseline / noise-floor plan found"


def check_threshold(body: str) -> str | None:
    # A numeric threshold attached to delta/Δ/effect, e.g. "Δ ≥ 0.05" or
    # "delta > 0.10" or "effect size 0.05".
    pattern = re.compile(
        r"(?:delta|Δ|effect[ -]?size)\s*[≥≤>=<]+\s*0?\.\d+|"
        r"0?\.\d+\s*(?:delta|Δ|effect[ -]?size)|"
        r"\|Δ[^|]*?\|\s*[≥≤>=<]+\s*0?\.\d+",
        re.IGNORECASE,
    )
    if pattern.search(body):
        return None
    return "no numeric effect-size / delta threshold found"


def check_prohibited_claims(body: str) -> str | None:
    if "RESEARCH_INTEGRITY" in body or re.search(r"prohibited[ -]+claims?", body, re.IGNORECASE):
        return None
    return ("no link to docs/RESEARCH_INTEGRITY.md and no prohibited-claims "
            "attestation")


def check_placeholder_count(text: str) -> str | None:
    placeholders = re.findall(r"<[^>\n]{1,200}>", text)
    if len(placeholders) > 5:
        return f"{len(placeholders)} unfilled `<...>` template placeholders (max 5)"
    return None


def check_body_length(body: str) -> str | None:
    if len(body) < 400:
        return f"filled body length {len(body)} chars — expected >= 400 (looks like a stub)"
    return None


def validate(text: str) -> list[str]:
    failures: list[str] = []

    missing_sections = check_required_sections(text)
    if missing_sections:
        failures.append(f"missing required sections: {', '.join(missing_sections)}")

    body = strip_template_noise(text)

    for check in (
        check_body_length,
        check_placeholder_count,
        check_sample_size,
        check_judge_identity,
        check_aa_baseline,
        check_threshold,
        check_prohibited_claims,
    ):
        msg = check(body) if check is not check_placeholder_count else check(text)
        if msg:
            failures.append(msg)

    return failures


def main() -> int:
    ap = argparse.ArgumentParser(description="Validate preregistration content (INFRA-113).")
    ap.add_argument("gap_id")
    ap.add_argument("path", nargs="?", help="Path to preregistration .md, or omit with --stdin.")
    ap.add_argument("--stdin", action="store_true", help="Read content from stdin instead of path.")
    args = ap.parse_args()

    if args.stdin:
        text = sys.stdin.read()
    elif args.path:
        try:
            text = Path(args.path).read_text(encoding="utf-8")
        except FileNotFoundError:
            print(f"prereg file not found: {args.path}", file=sys.stderr)
            return 1
    else:
        ap.error("either <path> or --stdin is required")
        return 2

    failures = validate(text)
    if failures:
        print(f"[prereg-content] {args.gap_id} preregistration is incomplete:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
