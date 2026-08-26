#!/usr/bin/env python3
"""detect_already_satisfied.py — INFRA-3808

Layer 2 of the "done-doesn't-stick" fix. Reads a worker cycle log (streaming
claude JSONL) for a gap that ended `kind=unverified_ship` (rc=0, zero edits, no
PR) and decides — on the STRONGEST, SAFEST signal — whether the agent explicitly
concluded the gap's work is ALREADY on `main`, naming the covering PR.

## Why

worker.sh classifies rc=0-with-no-PR cycles as `unverified_ship` and cools the
gap down (EFFECTIVE-441). But a cooldown only DEFERS the re-pick — the gap stays
`open` and gets re-selected forever, re-burning a full Sonnet cycle each time
just to re-conclude "already shipped." The reconciler's --check-closure-drift
can't help: it only scans gaps that ALREADY have `closed_pr` set, and this class
has `closed_pr` NULL (the gap was never linked to the PR that happened to
implement it). The one place the "already done by PR #N" fact exists is the
agent's own final conclusion in the cycle log. This detector captures it so the
worker can close the gap `already_satisfied` and stop the loop permanently.

## Signal (three-factor, high-confidence by design)

A gap is reported already-satisfied ONLY when the final assistant message has:
  1. an already-done phrase   (already implemented / already shipped / ...), AND
  2. a no-op phrase           (no diff / nothing to ship / worktree clean / ...), AND
  3. a PR reference           (PR #1234  →  the covering PR number)

All three must hold. Missing any → exit 1, print nothing (worker falls through
to the plain cooldown; nothing is closed). A commit SHA WITHOUT a PR number is
deliberately NOT enough to auto-close (calibration: --closed-pr needs an int and
we prefer to under-close). On a match, prints the PR number on stdout and exits 0.

## Usage

  detect_already_satisfied.py <cycle_log_path> <gap_id>
    exit 0 + "<pr_number>"  → agent explicitly reports gap already done by PR #N
    exit 1 + ""             → no confident already-satisfied signal
"""
import json
import re
import sys

# --- Signal vocabularies -------------------------------------------------
ALREADY_DONE = re.compile(
    r"already\s+(?:been\s+)?(?:implement|shipp|merg|complet|don|satisf|exist|"
    r"present|cover|land)",
    re.IGNORECASE,
)
# "already implements" / "already implemented exactly this"
ALREADY_IMPLEMENTS = re.compile(r"already\s+implement", re.IGNORECASE)

NOOP = re.compile(
    r"(?:no\s*[- ]?\s*(?:diff|pr\b|changes?|work)"
    r"|nothing\s+to\s+(?:ship|implement|commit|do|change)"
    r"|worktree.{0,20}clean"
    r"|clean.{0,20}worktree"
    r"|up[- ]to[- ]date\s+with\s+(?:origin/)?main"
    r"|empty(?:/|\s+or\s+)?duplicate\s+pr"
    r"|no\s+pr\b"
    r"|stale\s+claim)",
    re.IGNORECASE,
)

# Covering PR: "PR #4251", "(PR #4251)", "in #4251". Grab the last one in the
# conclusion (the agent typically states the covering PR near its final line).
PR_REF = re.compile(r"\bPR\s*#?\s*(\d{2,7})\b|\(#(\d{2,7})\)|\bin\s+#(\d{2,7})\b", re.IGNORECASE)


def final_assistant_text(path: str) -> str:
    """Concatenate the text blocks of the LAST assistant message in the log.

    The cycle log is streaming JSONL. Each assistant turn is a line
    {"type":"assistant","message":{"content":[{"type":"text","text":...}, ...]}}.
    We want the agent's closing conclusion, so we take the last assistant line
    that actually carries text (tool-only turns have no text block).
    """
    last_text = ""
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or '"type":"assistant"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if obj.get("type") != "assistant":
                    continue
                content = (obj.get("message") or {}).get("content") or []
                texts = [
                    c.get("text", "")
                    for c in content
                    if isinstance(c, dict) and c.get("type") == "text" and c.get("text")
                ]
                if texts:
                    last_text = "\n".join(texts)
    except FileNotFoundError:
        return ""
    return last_text


def detect(text: str) -> str:
    """Return covering PR number (str) if the 3-factor signal fires, else ""."""
    if not text:
        return ""
    has_done = bool(ALREADY_DONE.search(text) or ALREADY_IMPLEMENTS.search(text))
    if not has_done:
        return ""
    if not NOOP.search(text):
        return ""
    prs = [m for g in PR_REF.findall(text) for m in g if m]
    if not prs:
        return ""
    # The covering PR is whichever number the agent cites; take the last mention
    # (conclusions restate it at the end, e.g. "was already shipped in PR #4251").
    return prs[-1]


def main(argv):
    if len(argv) < 3:
        print("usage: detect_already_satisfied.py <cycle_log> <gap_id>", file=sys.stderr)
        return 2
    path, _gap_id = argv[1], argv[2]
    pr = detect(final_assistant_text(path))
    if pr:
        print(pr)
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
