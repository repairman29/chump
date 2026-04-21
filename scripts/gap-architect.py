#!/usr/bin/env python3.12
"""
gap-architect.py — LLM-driven sprint planning agent for Chump.

Reads strategic project docs, calls Claude to generate 20+ concrete gaps,
deduplicates against existing open gaps, assigns correct IDs, appends to
docs/gaps.yaml, and ships a PR.

Usage:
  python3.12 scripts/gap-architect.py                # full run: generate + file + ship
  python3.12 scripts/gap-architect.py --dry-run      # print gaps, don't write or ship
  python3.12 scripts/gap-architect.py --count 30     # request 30 gaps instead of 20
  python3.12 scripts/gap-architect.py --no-ship      # write to gaps.yaml but don't PR
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import anthropic
import yaml

# ── Load .env if present ──────────────────────────────────────────────────────
def _load_dotenv() -> None:
    """Load .env from repo root (or parent dirs) into environment (no python-dotenv dep).

    Strategy: start from the directory containing this script file, walk up looking
    for a .env that exists. Also try git rev-parse --show-toplevel as a fallback.
    This correctly handles worktree layouts where .env lives in the parent project dir.
    """
    # Start from the script's own directory and walk up
    script_dir = Path(__file__).resolve().parent
    candidates: list[Path] = []

    # Walk from script_dir upward looking for .env
    p = script_dir
    for _ in range(6):
        if (p / ".env").exists():
            candidates.append(p)
        p = p.parent

    # Also try git rev-parse and its parents
    try:
        git_root = Path(
            subprocess.check_output(
                ["git", "rev-parse", "--show-toplevel"], stderr=subprocess.DEVNULL
            ).decode().strip()
        )
        for _ in range(4):
            if (git_root / ".env").exists() and git_root not in candidates:
                candidates.append(git_root)
            git_root = git_root.parent
    except Exception:
        pass

    for root in candidates:
        env_file = root / ".env"
        if not env_file.exists():
            continue
        with env_file.open() as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip().strip('"').strip("'")
                if not os.environ.get(key):  # also override empty-string inherited vars
                    os.environ[key] = val

_load_dotenv()

# ── Repo paths ────────────────────────────────────────────────────────────────
REPO_ROOT = Path(
    subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], stderr=subprocess.DEVNULL
    ).decode().strip()
)
GAPS_YAML = REPO_ROOT / "docs" / "gaps.yaml"
RESEARCH_PLAN = REPO_ROOT / "docs" / "RESEARCH_PLAN_2026Q3.md"
RED_LETTER = REPO_ROOT / "docs" / "RED_LETTER.md"
FINDINGS_MD = REPO_ROOT / "docs" / "FINDINGS.md"

# ── Dedup stop-words ──────────────────────────────────────────────────────────
STOP_WORDS = {
    "a", "an", "the", "and", "or", "of", "in", "for", "to", "with",
    "on", "at", "by", "from", "up", "as", "is", "it", "be", "do",
    "vs", "via", "per", "via", "vs.", "—", "-", "n", "v",
}

# ── Required gap fields ───────────────────────────────────────────────────────
REQUIRED_FIELDS = {"id", "title", "domain", "priority", "effort", "description"}


# ─────────────────────────────────────────────────────────────────────────────
# Context loading
# ─────────────────────────────────────────────────────────────────────────────

def read_truncated(path: Path, max_lines: int) -> str:
    """Read a file, truncated to max_lines."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
        truncated = lines[:max_lines]
        if len(lines) > max_lines:
            truncated.append(f"\n... [truncated at {max_lines} lines] ...")
        return "\n".join(truncated)
    except FileNotFoundError:
        return f"[FILE NOT FOUND: {path}]"


def load_gaps_yaml() -> dict:
    """Parse gaps.yaml and return the full data structure."""
    with GAPS_YAML.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def extract_open_gap_summaries(gaps_data: dict) -> list[dict]:
    """Return list of {id, title, domain} for all open gaps."""
    result = []
    for gap in gaps_data.get("gaps", []):
        if gap.get("status") == "open":
            result.append({
                "id": gap.get("id", ""),
                "title": gap.get("title", ""),
                "domain": gap.get("domain", ""),
            })
    return result


def get_highest_ids(gaps_data: dict) -> dict[str, int]:
    """Return dict of prefix -> highest numeric ID seen (e.g. {'EVAL': 72, 'COG': 34})."""
    highest: dict[str, int] = {}
    for gap in gaps_data.get("gaps", []):
        gap_id = gap.get("id", "")
        m = re.match(r"^([A-Z]+)-(\d+)$", gap_id)
        if m:
            prefix = m.group(1)
            num = int(m.group(2))
            if num > highest.get(prefix, 0):
                highest[prefix] = num
    return highest


def build_open_gap_list_text(open_gaps: list[dict]) -> str:
    """Format open gaps as compact text for the prompt context."""
    lines = []
    for g in open_gaps:
        lines.append(f"- {g['id']}: {g['title']} [{g['domain']}]")
    return "\n".join(lines)


def build_context_block(count: int) -> str:
    """Assemble the full context block for the Claude prompt (<12k tokens target)."""
    # 1. Research plan (first 200 lines)
    research_plan_text = read_truncated(RESEARCH_PLAN, 200)

    # 2. Red Letter (first 100 lines — newest issue is at top)
    red_letter_text = read_truncated(RED_LETTER, 100)

    # 3. FINDINGS.md (first 60 lines — at-a-glance table + honest limits)
    findings_text = read_truncated(FINDINGS_MD, 60)

    # 4. Open gap IDs+titles from gaps.yaml
    gaps_data = load_gaps_yaml()
    open_gaps = extract_open_gap_summaries(gaps_data)
    open_gaps_text = build_open_gap_list_text(open_gaps)

    # 2 example gaps for schema reference (pull real entries)
    example_gaps_text = _pull_example_gaps(gaps_data)

    context = f"""# Chump Sprint Planning Context

## Strategic Research Plan (docs/RESEARCH_PLAN_2026Q3.md — first 200 lines)
{research_plan_text}

## Red Letter Adversarial Review (docs/RED_LETTER.md — newest issue)
{red_letter_text}

## Empirical Findings Index (docs/FINDINGS.md — at-a-glance)
{findings_text}

## Currently Open Gaps (for deduplication — do NOT repeat these)
{open_gaps_text}

## Schema Reference (two example gaps from gaps.yaml — match this format exactly)
{example_gaps_text}

## Valid domains:
consciousness, memory, eval, autonomy, acp, competitive, fleet, reliability, infra,
frontier, product, agent

## Valid priorities: P0, P1, P2, P3
## Valid efforts: xs, s, m, l
"""
    return context, gaps_data, open_gaps


def _pull_example_gaps(gaps_data: dict) -> str:
    """Pull two representative open gaps for schema examples."""
    open_gaps = [g for g in gaps_data.get("gaps", []) if g.get("status") == "open"]
    # Pick two with different domains/sizes if possible
    examples = []
    seen_domains = set()
    for g in open_gaps:
        if len(examples) >= 2:
            break
        d = g.get("domain", "")
        if d not in seen_domains:
            seen_domains.add(d)
            # Minimal fields for the example
            ex = {k: v for k, v in g.items() if k in (
                "id", "title", "domain", "priority", "effort",
                "status", "description", "acceptance_criteria", "depends_on"
            )}
            examples.append(ex)
    if len(examples) < 2 and open_gaps:
        ex = {k: v for k, v in open_gaps[-1].items() if k in (
            "id", "title", "domain", "priority", "effort",
            "status", "description", "acceptance_criteria", "depends_on"
        )}
        examples.append(ex)
    return yaml.dump(examples, default_flow_style=False, allow_unicode=True)


# ─────────────────────────────────────────────────────────────────────────────
# Claude API call
# ─────────────────────────────────────────────────────────────────────────────

SYSTEM_PROMPT = """\
You are a sprint planning agent for Chump, an agentic AI research platform.
Your job is to generate concrete, actionable gap entries for docs/gaps.yaml.

RULES:
1. Output ONLY a fenced YAML code block containing a list of gap objects.
2. Each gap must have ALL of these fields:
   id, title, domain, priority, effort, status, description
3. status must always be: open
4. id format: PREFIX-NNN (e.g. EVAL-073). Use placeholder IDs like EVAL-NEW-1 — the
   caller will assign real IDs. Do NOT try to predict the next real ID.
4. description must be a plain string (use YAML block scalar > or |), 2-5 sentences.
5. Optionally include: acceptance_criteria (list), depends_on (list of gap IDs), notes.
6. Do NOT repeat any gap in the "Currently Open Gaps" list.
7. Do NOT add status: in_progress, claimed_by, or claimed_at fields.
8. Match the schema of the example gaps exactly.
"""

def build_user_prompt(context: str, count: int) -> str:
    return f"""{context}

---

Generate exactly {count} concrete, actionable gaps for the Chump project.

Gap distribution to target:
- 4 gaps of effort: s  (small — 1-2 days)
- {count - 8} gaps of effort: m  (medium — 3-5 days)
- 4 gaps of effort: l  (large — 1 week+)

Coverage priorities (in order):
1. Faculty validation work: EVAL gaps covering Perception (EVAL-032), Attention
   (EVAL-028/033), Memory (EVAL-034), Metacognition (EVAL-035), Executive Function
   (EVAL-036/037), Social Cognition (EVAL-038) as called out in RESEARCH_PLAN_2026Q3.md
2. Methodology fixes flagged in RED_LETTER.md (binary-mode ablation harness fix,
   n≥50+LLM-judge requirement, A/A calibration before citing results, removal candidates
   for NULL-validated modules)
3. Infrastructure work: ambient stream, unwrap reduction, doc-deletion hook, judge
   calibration refresh
4. Product gaps: PWA, first-run onboarding, local model support, brew installer polish
5. Research gaps: external publication (RESEARCH-001 blog post), F2 non-Anthropic
   replication (EVAL-071), longitudinal learning A/B (EVAL-039)

Include proper depends_on where real dependencies exist (e.g., a sweep gap that
requires a harness flag gap to land first).

Output ONLY the YAML block. No prose before or after.
```yaml
"""


def call_claude(context: str, count: int) -> str:
    """Call Claude and return the raw text response."""
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    client = anthropic.Anthropic(api_key=api_key)

    user_prompt = build_user_prompt(context, count)

    print(f"  Calling claude-sonnet-4-6 (requesting {count} gaps)...", flush=True)

    response = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=8192,
        system=SYSTEM_PROMPT,
        messages=[
            {"role": "user", "content": user_prompt}
        ],
        cache_control={"type": "ephemeral"},
    )

    usage = response.usage
    print(
        f"  API call complete. Input tokens: {usage.input_tokens}, "
        f"output tokens: {usage.output_tokens}, "
        f"cache_read: {getattr(usage, 'cache_read_input_tokens', 0)}"
    )

    text = ""
    for block in response.content:
        if block.type == "text":
            text += block.text
    return text


# ─────────────────────────────────────────────────────────────────────────────
# YAML parsing
# ─────────────────────────────────────────────────────────────────────────────

def parse_yaml_from_response(raw_text: str) -> list[dict]:
    """
    Parse Claude's response. Handles:
    - ```yaml fence (opened or opened+closed)
    - Raw YAML list
    Falls back to regex extraction if yaml.safe_load fails.
    """
    # Strip the opening ```yaml fence (Claude was prompted to leave it open)
    text = raw_text.strip()

    # Remove any trailing ``` fence
    text = re.sub(r'```\s*$', '', text, flags=re.MULTILINE).strip()

    # Remove leading ```yaml if present
    text = re.sub(r'^```yaml\s*', '', text).strip()
    # Also handle ```yml
    text = re.sub(r'^```yml\s*', '', text).strip()

    try:
        data = yaml.safe_load(text)
        if isinstance(data, list):
            return data
        # Sometimes Claude returns a dict with a key like 'gaps'
        if isinstance(data, dict):
            for key in ("gaps", "gap_entries", "new_gaps"):
                if key in data and isinstance(data[key], list):
                    return data[key]
    except yaml.YAMLError as e:
        print(f"  WARN: yaml.safe_load failed: {e}", file=sys.stderr)

    # Fallback: try extracting individual gap blocks with regex
    return _regex_extract_gaps(text)


def _regex_extract_gaps(text: str) -> list[dict]:
    """Last-resort: split on '- id:' boundaries and parse each block."""
    blocks = re.split(r'\n(?=- id:)', text)
    results = []
    for block in blocks:
        block = block.strip()
        if not block.startswith("- id:") and not block.startswith("id:"):
            # Try adding list marker
            block = "- " + block if block.startswith("id:") else block
        try:
            parsed = yaml.safe_load(block)
            if isinstance(parsed, list):
                results.extend(parsed)
            elif isinstance(parsed, dict):
                results.append(parsed)
        except yaml.YAMLError:
            continue
    return results


# ─────────────────────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────────────────────

def validate_gap(gap: dict) -> tuple[bool, str]:
    """Return (is_valid, reason). A gap is valid if it has all required fields."""
    missing = REQUIRED_FIELDS - set(gap.keys())
    if missing:
        return False, f"missing fields: {', '.join(sorted(missing))}"
    if not isinstance(gap.get("title"), str) or not gap["title"].strip():
        return False, "title is empty"
    if not isinstance(gap.get("description"), str) or not gap["description"].strip():
        return False, "description is empty"
    if gap.get("status") not in ("open", None):
        # Force open
        gap["status"] = "open"
    else:
        gap["status"] = "open"
    return True, ""


# ─────────────────────────────────────────────────────────────────────────────
# Deduplication
# ─────────────────────────────────────────────────────────────────────────────

def title_overlap(a: str, b: str) -> float:
    """Word overlap ratio (Jaccard-like), ignoring stop words."""
    wa = set(a.lower().split()) - STOP_WORDS
    wb = set(b.lower().split()) - STOP_WORDS
    if not wa or not wb:
        return 0.0
    return len(wa & wb) / min(len(wa), len(wb))


def dedup_gaps(
    new_gaps: list[dict],
    open_gaps: list[dict],
    threshold: float = 0.6,
) -> tuple[list[dict], list[dict]]:
    """
    Return (kept_gaps, skipped_gaps).
    Skip any new gap whose title has >threshold word overlap with an existing open gap.
    Also skip duplicates within the new_gaps list itself.
    """
    existing_titles = [g["title"] for g in open_gaps]
    kept = []
    skipped = []
    seen_new_titles: list[str] = []

    for gap in new_gaps:
        title = gap.get("title", "")
        # Check against existing open gaps
        skip = False
        for et in existing_titles:
            if title_overlap(title, et) > threshold:
                skipped.append((gap, f"overlaps existing gap: '{et}'"))
                skip = True
                break
        if skip:
            continue
        # Check within new gaps batch (dedup within the generated set)
        for nt in seen_new_titles:
            if title_overlap(title, nt) > threshold:
                skipped.append((gap, f"duplicate within generated set: '{nt}'"))
                skip = True
                break
        if skip:
            continue
        kept.append(gap)
        seen_new_titles.append(title)

    return kept, skipped


# ─────────────────────────────────────────────────────────────────────────────
# ID assignment
# ─────────────────────────────────────────────────────────────────────────────

# Known prefix → domain mapping (for new prefixes that Claude might invent)
VALID_PREFIXES = {
    "COG", "EVAL", "MEM", "AUTO", "ACP", "COMP", "FLEET", "INFRA",
    "FRONTIER", "PRODUCT", "QUALITY", "REL", "RESEARCH", "AGT", "DOC", "SENSE",
}

def assign_ids(gaps: list[dict], highest_ids: dict[str, int]) -> list[dict]:
    """
    Replace Claude's placeholder IDs with real sequential IDs.
    Reads the prefix from the gap's existing id (if it's a known prefix),
    otherwise falls back to domain-based prefix mapping.
    """
    # Local counter so we don't re-read YAML on each gap
    counters = dict(highest_ids)  # copy

    domain_to_prefix = {
        "consciousness": "COG",
        "memory": "MEM",
        "eval": "EVAL",
        "autonomy": "AUTO",
        "acp": "ACP",
        "competitive": "COMP",
        "fleet": "FLEET",
        "reliability": "QUALITY",
        "infra": "INFRA",
        "frontier": "FRONTIER",
        "product": "PRODUCT",
        "agent": "AGT",
    }

    result = []
    for gap in gaps:
        # Determine prefix
        raw_id = str(gap.get("id", ""))
        m = re.match(r"^([A-Z]+)", raw_id)
        prefix = m.group(1) if m else None

        # If the prefix is not a real known prefix, derive from domain
        if not prefix or prefix not in VALID_PREFIXES:
            domain = gap.get("domain", "")
            prefix = domain_to_prefix.get(domain, "EVAL")

        # Increment counter for this prefix
        counters[prefix] = counters.get(prefix, 0) + 1
        new_id = f"{prefix}-{counters[prefix]:03d}"

        gap = dict(gap)  # copy
        gap["id"] = new_id
        gap["status"] = "open"

        # Ensure field order matches gaps.yaml convention:
        # id, title, domain, priority, effort, status, description, ...
        ordered = {}
        for field in ["id", "title", "domain", "priority", "effort", "status",
                      "source_doc", "description", "acceptance_criteria",
                      "depends_on", "notes"]:
            if field in gap:
                ordered[field] = gap[field]
        # Any remaining fields
        for k, v in gap.items():
            if k not in ordered:
                ordered[k] = v

        result.append(ordered)

    return result


# ─────────────────────────────────────────────────────────────────────────────
# Write to gaps.yaml
# ─────────────────────────────────────────────────────────────────────────────

def append_gaps_to_yaml(new_gaps: list[dict]) -> None:
    """Append the new gaps to the end of docs/gaps.yaml."""
    with GAPS_YAML.open("a", encoding="utf-8") as f:
        f.write("\n")
        for gap in new_gaps:
            yaml_text = yaml.dump(
                [gap],
                default_flow_style=False,
                allow_unicode=True,
                width=88,
            )
            f.write(yaml_text)


# ─────────────────────────────────────────────────────────────────────────────
# Ship
# ─────────────────────────────────────────────────────────────────────────────

def ship(gap_ids: list[str]) -> str:
    """
    Create branch, commit, push, open PR with auto-merge.
    Returns the PR number/URL.
    """
    timestamp = int(time.time())
    branch = f"claude/gap-architect-{timestamp}"
    worktree_path = REPO_ROOT

    # Create branch
    subprocess.run(
        ["git", "checkout", "-b", branch],
        cwd=worktree_path,
        check=True,
    )

    # Commit gaps.yaml
    env = os.environ.copy()
    env["CHUMP_GAP_CHECK"] = "0"
    env["CHUMP_GAPS_LOCK"] = "0"  # allow adding new gaps
    subprocess.run(
        [
            str(worktree_path / "scripts" / "chump-commit.sh"),
            str(GAPS_YAML),
            "-m",
            f"feat(infra): gap-architect — file {len(gap_ids)} new gaps [{', '.join(gap_ids[:5])}{'...' if len(gap_ids) > 5 else ''}]",
        ],
        cwd=worktree_path,
        env=env,
        check=True,
    )

    # Push and open PR via bot-merge.sh
    result = subprocess.run(
        [
            str(worktree_path / "scripts" / "bot-merge.sh"),
            "--auto-merge",
            "--skip-tests",
        ],
        cwd=worktree_path,
        env=env,
        capture_output=True,
        text=True,
    )
    output = result.stdout + result.stderr
    print(output)

    # Extract PR number from output
    pr_match = re.search(r"https://github\.com/\S+/pull/(\d+)", output)
    if pr_match:
        return pr_match.group(0)

    pr_match = re.search(r"PR #(\d+)", output)
    if pr_match:
        return pr_match.group(0)

    return "(PR URL not found in output — check above)"


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="LLM-driven sprint planning agent for Chump"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print gaps, don't write or ship",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=20,
        help="Number of gaps to request (default: 20)",
    )
    parser.add_argument(
        "--no-ship",
        action="store_true",
        help="Write to gaps.yaml but don't open a PR",
    )
    args = parser.parse_args()

    print("=" * 70)
    print("gap-architect.py — LLM-driven sprint planning")
    print("=" * 70)

    # 1. Load context
    print("\n[1/6] Loading context from strategic docs...")
    context, gaps_data, open_gaps = build_context_block(args.count)
    highest_ids = get_highest_ids(gaps_data)
    print(f"  Found {len(open_gaps)} open gaps in gaps.yaml")
    print(f"  Highest IDs per prefix: {dict(sorted(highest_ids.items()))}")

    # 2. Call Claude
    print(f"\n[2/6] Calling Claude API (requesting {args.count} gaps)...")
    raw_response = call_claude(context, args.count)

    # 3. Parse YAML
    print("\n[3/6] Parsing YAML response...")
    parsed_gaps = parse_yaml_from_response(raw_response)
    print(f"  Parsed {len(parsed_gaps)} gap candidates from response")

    # 4. Validate
    print("\n[4/6] Validating gap fields...")
    valid_gaps = []
    for gap in parsed_gaps:
        is_valid, reason = validate_gap(gap)
        if is_valid:
            valid_gaps.append(gap)
        else:
            print(f"  SKIP (invalid): {gap.get('id', '?')} / '{gap.get('title', '?')}' — {reason}")
    print(f"  {len(valid_gaps)} valid gaps after field validation")

    # 5. Dedup
    print("\n[5/6] Deduplicating against existing open gaps...")
    kept_gaps, skipped_gaps = dedup_gaps(valid_gaps, open_gaps, threshold=0.6)
    for gap, reason in skipped_gaps:
        print(f"  SKIP (dedup): '{gap.get('title', '?')}' — {reason}")
    print(f"  {len(kept_gaps)} gaps kept after dedup, {len(skipped_gaps)} skipped")

    # 6. Assign IDs
    print("\n[6/6] Assigning sequential IDs...")
    final_gaps = assign_ids(kept_gaps, highest_ids)
    for g in final_gaps:
        print(f"  + {g['id']}: {g['title']} [{g['domain']}, {g['priority']}, {g['effort']}]")

    # Summary
    print("\n" + "=" * 70)
    print(f"SUMMARY")
    print(f"  Open gaps found:    {len(open_gaps)}")
    print(f"  Generated by Claude: {len(parsed_gaps)}")
    print(f"  Valid:              {len(valid_gaps)}")
    print(f"  After dedup:        {len(kept_gaps)}")
    print(f"  Skipped (dedup):    {len(skipped_gaps)}")
    print(f"  Final gaps to file: {len(final_gaps)}")
    print("=" * 70)

    if not final_gaps:
        print("\nNo gaps to file. Exiting.")
        return

    if args.dry_run:
        print("\n[DRY RUN] Would append these gaps to docs/gaps.yaml:")
        print(yaml.dump(final_gaps, default_flow_style=False, allow_unicode=True))
        return

    # Write to gaps.yaml
    print(f"\nAppending {len(final_gaps)} gaps to {GAPS_YAML}...")
    append_gaps_to_yaml(final_gaps)
    print("  Done.")

    if args.no_ship:
        print("\n[--no-ship] Skipping PR creation.")
        return

    # Ship
    gap_ids = [g["id"] for g in final_gaps]
    print(f"\nShipping PR (branch claude/gap-architect-<ts>)...")
    pr_ref = ship(gap_ids)
    print(f"\nPR: {pr_ref}")


if __name__ == "__main__":
    main()
