#!/usr/bin/env python3
# INFRA-079: cross-judge audit guard for EVAL-* / RESEARCH-* gap closures.
#
# Background: EVAL-074 (PR #549) shipped a "DeepSeek over-compliance,
# −30pp gotcha regression p=0.0007" claim based on a single
# Llama-3.3-70B judge. The cross-judge audit (PR #551) flipped the
# finding to a Llama-judge artifact (κ=0.40, gotcha 52% agreement).
# Cost of the retraction: ~$1.50 + half a day + three follow-up
# amendment PRs. The standing rule from docs/RESEARCH_INTEGRITY.md —
# "any claim that depends on judge labels must include a cross-judge
# audit on the same JSONL before it is stamped as a result" — is
# documented but not enforced.
#
# This checker enforces it. When closing an EVAL-* or RESEARCH-* gap
# to status: done, the gap MUST satisfy at least one of:
#
#   (a) cross_judge_audit: <path>           — gap entry in gaps.yaml
#                                              names a JSONL artifact
#                                              under logs/ab/ that
#                                              contains ≥2 distinct
#                                              judge families.
#   (b) single_judge_waived: true           — gap entry has waiver
#       single_judge_waiver_reason: <text>    flag + reason ≥ 20 chars.
#   (c) preregistration declares scope      — docs/eval/preregistered/
#                                              <gid>.md contains a
#                                              "Single judge scope"
#                                              attestation paragraph.
#
# Bypass: CHUMP_CROSS_JUDGE_CHECK=0 (justify in PR body).
#
# Usage:
#   check-cross-judge.py <GAP-ID> --gap-block <path-to-yaml-fragment>
#                              [--prereg <path-to-prereg.md>]
#                              [--repo-root <path>]
#
# The "gap block" file is the YAML for one gap entry — typically the
# slice of docs/gaps.yaml from `- id: <GID>` to the next `- id:`. The
# pre-commit hook extracts and pipes it; the test harness writes a
# fixture file directly.
#
# Exit 0 on pass, 1 on fail with diagnostic on stderr.

import argparse
import json
import re
import sys
from pathlib import Path

# Family classification — keys are case-insensitive substrings, values
# are family labels. Order matters: more specific matches go first.
JUDGE_FAMILIES: list[tuple[str, str]] = [
    ("claude",    "anthropic"),
    ("anthropic", "anthropic"),
    ("gpt",       "openai"),
    ("o1",        "openai"),
    ("o3",        "openai"),
    ("openai",    "openai"),
    ("gemini",    "google"),
    ("google",    "google"),
    ("llama",     "meta"),
    ("meta-",     "meta"),
    ("qwen",      "alibaba"),
    ("mistral",   "mistral"),
    ("mixtral",   "mistral"),
    ("deepseek",  "deepseek"),
    ("phi",       "microsoft"),
    ("yi-",       "01ai"),
    ("human",     "human"),
    ("jeff",      "human"),
]


def classify_family(model: str) -> str | None:
    if not model:
        return None
    m = model.lower()
    for token, family in JUDGE_FAMILIES:
        if token in m:
            return family
    return None


def parse_field(gap_text: str, field: str) -> str | None:
    """Pull a top-level scalar field out of a gap YAML block."""
    pattern = re.compile(rf"^\s+{re.escape(field)}\s*:\s*(.*)$", re.MULTILINE)
    m = pattern.search(gap_text)
    if not m:
        return None
    return m.group(1).strip().strip('"').strip("'")


def families_in_jsonl(path: Path) -> tuple[set[str], int]:
    """Walk a JSONL file looking for judge identifiers. Returns (families,
    rows_inspected). Recognises the common keys produced by the AB
    harness: `judge_model`, `judge`, `judge_id`, plus nested
    `judges[*].model`."""
    families: set[str] = set()
    rows = 0
    try:
        with path.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                rows += 1
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                candidates: list[str] = []
                for k in ("judge_model", "judge", "judge_id"):
                    v = obj.get(k)
                    if isinstance(v, str):
                        candidates.append(v)
                jl = obj.get("judges")
                if isinstance(jl, list):
                    for j in jl:
                        if isinstance(j, dict):
                            for k in ("model", "name", "id"):
                                v = j.get(k)
                                if isinstance(v, str):
                                    candidates.append(v)
                        elif isinstance(j, str):
                            candidates.append(j)
                for c in candidates:
                    fam = classify_family(c)
                    if fam:
                        families.add(fam)
    except FileNotFoundError:
        return set(), 0
    return families, rows


def check_cross_judge_audit(gap_text: str, repo_root: Path) -> tuple[bool, str]:
    audit_path_str = parse_field(gap_text, "cross_judge_audit")
    if not audit_path_str:
        return False, ""
    audit_path = repo_root / audit_path_str
    if not audit_path.exists():
        return False, (f"cross_judge_audit references missing path: "
                       f"{audit_path_str}")
    if audit_path.is_dir():
        # Allow a directory of JSONL artifacts — union the families.
        families: set[str] = set()
        rows = 0
        for f in audit_path.rglob("*.jsonl"):
            fams, r = families_in_jsonl(f)
            families |= fams
            rows += r
    else:
        families, rows = families_in_jsonl(audit_path)
    if rows == 0:
        return False, (f"cross_judge_audit artifact is empty: "
                       f"{audit_path_str}")
    if len(families) < 2:
        return False, (f"cross_judge_audit artifact {audit_path_str} has "
                       f"only {len(families)} judge family/families "
                       f"({sorted(families) or '<none classified>'}); "
                       "need ≥2 from different families")
    return True, f"cross_judge_audit OK ({sorted(families)}, {rows} rows)"


def check_single_judge_waiver(gap_text: str) -> tuple[bool, str]:
    waived = parse_field(gap_text, "single_judge_waived")
    if waived is None:
        return False, ""
    if waived.lower() != "true":
        return False, (f"single_judge_waived is set to '{waived}' — "
                       "must be literal 'true' to count")
    reason = parse_field(gap_text, "single_judge_waiver_reason")
    if not reason or len(reason) < 20:
        return False, ("single_judge_waived: true requires "
                       "single_judge_waiver_reason: <≥20 char justification>")
    return True, "single_judge_waiver OK"


SINGLE_JUDGE_SCOPE_PATTERN = re.compile(
    r"single[ -]judge\s+(scope|design|run|preregistration|study)",
    re.IGNORECASE,
)


def check_prereg_scope(prereg_text: str) -> tuple[bool, str]:
    if not prereg_text:
        return False, ""
    if SINGLE_JUDGE_SCOPE_PATTERN.search(prereg_text):
        return True, "preregistration declares single-judge scope"
    return False, ""


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Cross-judge audit guard for EVAL/RESEARCH gap closure (INFRA-079).",
    )
    ap.add_argument("gap_id")
    ap.add_argument("--gap-block", required=True,
                    help="File containing the YAML block for this gap.")
    ap.add_argument("--prereg", help="Path to docs/eval/preregistered/<gid>.md")
    ap.add_argument("--repo-root", default=".",
                    help="Repo root for resolving cross_judge_audit paths.")
    args = ap.parse_args()

    try:
        gap_text = Path(args.gap_block).read_text(encoding="utf-8")
    except FileNotFoundError:
        print(f"--gap-block file not found: {args.gap_block}", file=sys.stderr)
        return 2

    prereg_text = ""
    if args.prereg:
        try:
            prereg_text = Path(args.prereg).read_text(encoding="utf-8")
        except FileNotFoundError:
            prereg_text = ""

    repo_root = Path(args.repo_root).resolve()

    # Try each path; first to succeed wins. Collect diagnostic from
    # whichever path was attempted but rejected (helps the author fix the
    # most-promising path).
    attempted: list[str] = []
    for check_name, fn in (
        ("cross_judge_audit", lambda: check_cross_judge_audit(gap_text, repo_root)),
        ("single_judge_waiver", lambda: check_single_judge_waiver(gap_text)),
        ("preregistration scope", lambda: check_prereg_scope(prereg_text)),
    ):
        ok, msg = fn()
        if ok:
            return 0
        if msg:
            attempted.append(f"{check_name}: {msg}")

    # Nothing worked. Print a structured rejection.
    print(f"[cross-judge] {args.gap_id}: closure blocked — no cross-judge "
          "audit, waiver, or single-judge prereg scope found.", file=sys.stderr)
    print("", file=sys.stderr)
    print("To unblock, the gap entry in docs/gaps.yaml needs ONE of:", file=sys.stderr)
    print("  (a) cross_judge_audit: logs/ab/<artifact>.jsonl   "
          "(JSONL with ≥2 judge families — claude/gpt/llama/...)", file=sys.stderr)
    print("  (b) single_judge_waived: true                     "
          "AND single_judge_waiver_reason: <≥20 char justification>", file=sys.stderr)
    print("  (c) docs/eval/preregistered/<gid>.md              "
          "explicitly declares 'single judge scope' (or design/run/study)",
          file=sys.stderr)
    if attempted:
        print("", file=sys.stderr)
        print("Diagnostic from attempted paths:", file=sys.stderr)
        for a in attempted:
            print(f"  - {a}", file=sys.stderr)
    print("", file=sys.stderr)
    print("Bypass (justify in PR body): CHUMP_CROSS_JUDGE_CHECK=0 git commit ...",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
