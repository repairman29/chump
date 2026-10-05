#!/usr/bin/env python3
# CREDIBLE-787 (CREDIBLE-274 slice): CI grep target sweep.
#
# Scans every file under scripts/ci for `grep` invocations of the form
# `grep [flags] "<pattern>" <target>` and verifies that <target> exists in
# the repository. Catches the class of bug where a grep guard references a
# file/dir that was renamed or removed, silently making the guard a no-op
# (grep exits 1 "not found" == same signal as "no match", so a missing
# target masquerades as a passing check instead of failing loud).
#
# Targets that can't be resolved statically (shell variables, /tmp paths,
# process-substitution, stdin) are skipped rather than falsely flagged —
# this sweep only reports targets that are plain repo-relative paths.
#
# Usage:
#   python3 scripts/ci/check-grep-target-sweep.py [--json]
#
# Exit codes:
#   0 — no missing targets found
#   1 — one or more missing targets found

import json
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(os.environ.get("REPO_ROOT") or Path(__file__).resolve().parents[2])
SCAN_DIR = REPO_ROOT / "scripts" / "ci"

# Matches ONLY the unambiguous single-shot form:
#   grep <boolean-flags> <"pattern"|'pattern'> <target> <terminator>
# Deliberately narrow: flags are limited to boolean (no-argument) ones so an
# arg-taking flag like -A/-B/-C/-m/-e never gets misread as consuming the
# pattern slot, the pattern must be quoted (bareword patterns are almost
# always themselves a second flag or a shell fragment in this codebase), and
# the match must be immediately followed by a clause terminator so a grep
# whose output is piped into something else (grep ... | grep ...) is never
# mistaken for a file-target lookup.
GREP_CALL_RE = re.compile(
    r"""\bgrep\s+
        (?:-[qniEFvwrlxcoPs]+\s+)*                      # boolean flags only
        (?:"[^"]*"|'[^']*')\s+                           # quoted pattern
        (?P<target>"[^"]*"|'[^']*'|[A-Za-z0-9_./-]+)     # candidate target
        (?=\s*(?:;|\)|&&|\|\||\#|$|2>))                  # must be a clause end
    """,
    re.VERBOSE,
)

# Skip candidates that clearly aren't a static repo-relative path.
SKIP_PREFIXES = ("$", "/tmp", "/dev", "-", "<", ">", "|", "&")


def strip_quotes(tok: str) -> str:
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in ("'", '"'):
        return tok[1:-1]
    return tok


# Trees that are runtime/gitignored state rather than repo-tracked content —
# a fresh checkout legitimately lacks these until something runs, so a
# missing target here is not "a broken grep guard".
RUNTIME_PATH_PREFIXES = (".chump-locks/", ".git/")

# This sweep's own regression test embeds deliberately-fake grep targets in
# a heredoc fixture — exclude it from self-scanning so the sweep doesn't
# flag its own test data as a broken guard.
SELF_TEST_FILE = "test-grep-target-sweep.sh"


def is_candidate_path(tok: str) -> bool:
    if not tok:
        return False
    if tok.startswith(SKIP_PREFIXES):
        return False
    if tok.startswith(RUNTIME_PATH_PREFIXES):
        return False
    if any(c in tok for c in ("$", "`", "*", "(", ")", "'", '"', "\\", "[", "]")):
        return False
    if tok in (".", ".."):
        return False
    # Require a path shape: either a slash, or a dotted filename extension.
    if "/" not in tok and not re.search(r"\.[A-Za-z0-9]+$", tok):
        return False
    return True


def is_locally_created(text: str, target: str) -> bool:
    """True if the same script writes `target` via shell redirection —
    a scratch file the script creates for itself (e.g. `... 2>commit.err`),
    not a repo-tracked path the grep guard depends on."""
    escaped = re.escape(target)
    return re.search(rf">>?\s*\"?{escaped}\b", text) is not None


def scan_file(path: Path):
    findings = []
    try:
        text = path.read_text(errors="ignore")
    except OSError:
        return findings
    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        # A grep whose output feeds another command isn't a file-target
        # lookup (e.g. `grep -A5 'x' f | grep -q 'y'`) — skip the whole line
        # rather than risk mis-attributing the pipeline's inner tokens.
        if "|" in line:
            continue
        for m in GREP_CALL_RE.finditer(line):
            target = strip_quotes(m.group("target"))
            if not is_candidate_path(target):
                continue
            if is_locally_created(text, target):
                continue
            findings.append((lineno, target))
    return findings


def main():
    as_json = "--json" in sys.argv[1:]

    missing = []
    if SCAN_DIR.is_dir():
        for path in sorted(SCAN_DIR.rglob("*")):
            if not path.is_file():
                continue
            if path.name in (Path(__file__).name, SELF_TEST_FILE):
                continue
            rel_source = str(path.relative_to(REPO_ROOT))
            for lineno, target in scan_file(path):
                resolved = (REPO_ROOT / target).resolve()
                try:
                    resolved.relative_to(REPO_ROOT)
                except ValueError:
                    # Escapes repo root — not a target we can/should judge.
                    continue
                if not resolved.exists():
                    missing.append(
                        {
                            "source_file": rel_source,
                            "line": lineno,
                            "target": target,
                        }
                    )

    report = {"missing_count": len(missing), "missing": missing}

    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print(f"[check-grep-target-sweep] scanned {SCAN_DIR} for grep targets")
        if missing:
            for item in missing:
                print(
                    f"[FAIL] {item['source_file']}:{item['line']} "
                    f"— missing grep target '{item['target']}'",
                    file=sys.stderr,
                )
        print(f"[check-grep-target-sweep] missing_count={len(missing)}")

    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
