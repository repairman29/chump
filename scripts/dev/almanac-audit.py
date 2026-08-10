#!/usr/bin/env python3
"""almanac-audit.py — CREDIBLE-209

The textual half of the bullshit boss: extracts checkable claims from a
repo's README/docs (capability statements, named commands/APIs/features) and
grounds each against that repo's OWN Almanac index — a claim naming a
symbol/command: does it exist at path:line? a claim saying "X works": is
there a test symbol/file that touches X? This mechanizes the
claimed-vs-verified discipline described in docs/CODEBASE_REALITY_MAP.md
par.0 — the same gap class that busted the v1 fleet survey (DOC-084).

Usage:
    python3 scripts/dev/almanac-audit.py <repo> [--json]
    python3 scripts/dev/almanac-audit.py /path/to/repo --docs README.md,docs/ALMANAC.md
    python3 scripts/dev/almanac-audit.py chump --index-dir ~/.almanac/indexes

<repo> is either a filesystem path to a checkout (README/docs are read from
there) or a bare name resolved to <index-dir>/<name>.db (repo_root then comes
from that index's `meta` table). Grounding is a pure sqlite lookup against
the Almanac index (`files` + `symbols` tables) — no network calls. Claim
extraction defaults to a deterministic regex pass (backtick code-spans +
trigger-verb sentences); pass --llm to additionally ask the local Ollama
cascade (http://127.0.0.1:11434, never a remote host) to pull capability
claims prose-extraction would miss. Exit code is always 0 (a signal, not a
gate — MISSION-045: ungrounded claims are triaged, not auto-filed).
"""

import argparse
import json
import os
import re
import sqlite3
import sys
import urllib.request
from pathlib import Path

DEFAULT_INDEX_DIR = Path(os.environ.get("ALMANAC_INDEX_DIR", os.path.expanduser("~/.almanac/indexes")))
DEFAULT_DOCS = ["README.md"]
OLLAMA_URL = "http://127.0.0.1:11434/api/generate"
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen2.5:14b")

# Backtick code-spans: `almanac audit <repo>`, `chump gap ship`, `fn foo()`.
CODE_SPAN_RE = re.compile(r"`([^`\n]{2,80})`")

# Sentence-ish claim triggers — the verbs a README uses to assert a capability.
CAPABILITY_VERBS = (
    "supports", "provides", "implements", "handles", "enables", "allows",
    "includes", "ships with", "built-in", "comes with", "offers",
    "guarantees", "ensures", "ships", "delivers",
)

STOPWORDS = {
    "the", "and", "for", "with", "that", "this", "from", "your", "each",
    "into", "have", "does", "when", "then", "over", "also", "than", "can",
    "will", "which", "using", "used", "used.", "about", "these", "those",
    "such", "some", "more", "most", "very", "just", "only", "even", "here",
}


def resolve_index_db(repo: str, index_dir: Path) -> Path | None:
    """<repo> as a path: match its abspath against every index's meta
    repo_root. <repo> as a bare name: <index_dir>/<name>.db directly."""
    if not index_dir.is_dir():
        return None
    p = Path(repo)
    if p.exists():
        target = str(p.resolve())
        for db in index_dir.glob("*.db"):
            root = _meta_get(db, "repo_root")
            if root and Path(root).resolve() == Path(target).resolve():
                return db
        # fall back to basename match
        candidate = index_dir / f"{p.resolve().name}.db"
        if candidate.is_file():
            return candidate
        return None
    candidate = index_dir / f"{repo}.db"
    return candidate if candidate.is_file() else None


def _meta_get(db_path: Path, key: str) -> str | None:
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        conn.close()
        return row[0] if row else None
    except sqlite3.Error:
        return None


def load_index(db_path: Path):
    """Returns (repo_root, files: list[(path,)], symbols: list[(name, path, start_line)])."""
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    repo_root = _meta_get(db_path, "repo_root") or ""
    files = [r[0] for r in conn.execute("SELECT path FROM files").fetchall()]
    symbols = conn.execute(
        "SELECT s.name, f.path, s.start_line FROM symbols s JOIN files f ON f.id = s.file_id"
    ).fetchall()
    conn.close()
    return repo_root, files, symbols


def find_docs(repo_root: str, doc_globs: list[str]) -> list[Path]:
    root = Path(repo_root) if repo_root else None
    out = []
    for pattern in doc_globs:
        p = (root / pattern) if root else Path(pattern)
        if p.is_file():
            out.append(p)
    return out


SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+")


def extract_claims_regex(text: str, doc_name: str) -> list[dict]:
    """Deterministic, network-free claim extraction: backtick code-spans are
    `symbol` claims; sentences using a capability-trigger verb are
    `capability` claims. Pure — unit-tested.

    Symbol spans and capability sentences are extracted as two independent
    passes over different units (line vs. sentence) so a code span mentioned
    in passing (e.g. "call `foo` first.") never gets folded into an unrelated
    capability sentence on the same line and pollutes its grounding tokens.
    """
    claims = []
    seen_spans = set()
    for lineno, line in enumerate(text.splitlines(), start=1):
        for m in CODE_SPAN_RE.finditer(line):
            span = m.group(1).strip()
            if not span or span in seen_spans:
                continue
            seen_spans.add(span)
            claims.append({"text": span, "claim_type": "symbol", "doc": doc_name, "line": lineno})

    stripped = CODE_SPAN_RE.sub(" ", text)
    for sentence in SENTENCE_SPLIT_RE.split(stripped.replace("\n", " ")):
        sentence = sentence.strip().lstrip("-*# ").rstrip()
        lower = sentence.lower()
        if len(sentence) >= 8 and any(v in lower for v in CAPABILITY_VERBS):
            claims.append({"text": sentence, "claim_type": "capability", "doc": doc_name, "line": 0})
    return claims


def extract_claims_llm(text: str, doc_name: str) -> list[dict]:
    """Best-effort augmentation via the local Ollama cascade. Never touches
    the network beyond 127.0.0.1 — on any failure (server down, bad JSON)
    this returns [] and the regex pass alone still stands."""
    prompt = (
        "Extract a JSON array of short capability claims (things the doc "
        "asserts the software DOES) from this documentation excerpt. Each "
        "item: {\"text\": \"<claim in a few words>\"}. Only real claims, no "
        "commentary, output JSON array only.\n\n" + text[:4000]
    )
    body = json.dumps({"model": OLLAMA_MODEL, "prompt": prompt, "stream": False}).encode()
    try:
        req = urllib.request.Request(
            OLLAMA_URL, data=body, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode())
        raw = payload.get("response", "")
        parsed = json.loads(re.search(r"\[.*\]", raw, re.DOTALL).group(0))
        return [
            {"text": item["text"].strip(), "claim_type": "capability", "doc": doc_name, "line": 0}
            for item in parsed
            if isinstance(item, dict) and item.get("text")
        ]
    except Exception:
        return []


def _tokens(text: str) -> list[str]:
    words = re.findall(r"[A-Za-z][A-Za-z0-9_\-]{3,}", text.lower())
    return [w for w in words if w not in STOPWORDS]


def ground_symbol(claim_text: str, files: list[str], symbols: list[tuple]) -> dict:
    """A `code span` claim: look for an exact/substring symbol-name match,
    then a file basename match. Multi-word spans (e.g. a CLI invocation) are
    matched by first token."""
    tokens = re.findall(r"[A-Za-z_][A-Za-z0-9_.\-]*", claim_text)
    candidates = [claim_text] + tokens[:2]

    for cand in candidates:
        for name, path, start_line in symbols:
            if name == cand:
                return {"verdict": "grounded", "citation": f"{path}:{start_line}"}
    for cand in candidates:
        low = cand.lower()
        for name, path, start_line in symbols:
            if low and low in name.lower():
                return {"verdict": "grounded", "citation": f"{path}:{start_line}"}
    for cand in candidates:
        low = cand.lower()
        for path in files:
            base = Path(path).stem.lower()
            if low and (low == base or low in base):
                return {"verdict": "grounded", "citation": f"{path}:1"}
    return {"verdict": "ungrounded", "citation": None}


def ground_capability(claim_text: str, files: list[str], symbols: list[tuple]) -> dict:
    """An "X works"-shaped sentence: is there a symbol/file whose name
    references the claim's key terms, and — separately — one that looks like
    a test for it? grounded (impl + test evidence), unverifiable (impl
    exists, no test evidence), ungrounded (no evidence at all)."""
    tokens = _tokens(claim_text)
    if not tokens:
        return {"verdict": "unverifiable", "citation": None}

    impl_hit = None
    test_hit = None
    for tok in tokens:
        for name, path, start_line in symbols:
            hay_name = name.lower()
            hay_path = path.lower()
            if tok in hay_name or tok in hay_path:
                is_test = "test" in hay_path or hay_name.startswith("test_") or hay_name.endswith("_test")
                if is_test and test_hit is None:
                    test_hit = f"{path}:{start_line}"
                elif not is_test and impl_hit is None:
                    impl_hit = f"{path}:{start_line}"
        if impl_hit and test_hit:
            break

    if impl_hit and test_hit:
        return {"verdict": "grounded", "citation": test_hit}
    if impl_hit:
        return {"verdict": "unverifiable", "citation": impl_hit}
    return {"verdict": "ungrounded", "citation": None}


def audit(repo: str, index_dir: Path, doc_globs: list[str], use_llm: bool) -> dict:
    db_path = resolve_index_db(repo, index_dir)
    if db_path is None:
        return {
            "repo": repo,
            "error": f"no Almanac index found for '{repo}' under {index_dir} "
            "(index it first, or pass --index-dir)",
            "claims": [],
        }

    repo_root, files, symbols = load_index(db_path)
    docs = find_docs(repo_root, doc_globs)
    if not docs:
        return {
            "repo": repo,
            "repo_root": repo_root,
            "index_db": str(db_path),
            "error": f"none of {doc_globs} found under {repo_root or '(unknown repo_root)'}",
            "claims": [],
        }

    results = []
    for doc in docs:
        text = doc.read_text(errors="ignore")
        doc_name = str(doc)
        claims = extract_claims_regex(text, doc_name)
        if use_llm:
            claims += extract_claims_llm(text, doc_name)

        for claim in claims:
            if claim["claim_type"] == "symbol":
                verdict = ground_symbol(claim["text"], files, symbols)
            else:
                verdict = ground_capability(claim["text"], files, symbols)
            results.append({**claim, **verdict})

    return {
        "repo": repo,
        "repo_root": repo_root,
        "index_db": str(db_path),
        "claims": results,
        "summary": {
            "total": len(results),
            "grounded": sum(1 for r in results if r["verdict"] == "grounded"),
            "ungrounded": sum(1 for r in results if r["verdict"] == "ungrounded"),
            "unverifiable": sum(1 for r in results if r["verdict"] == "unverifiable"),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("repo", help="checkout path, or a bare name resolved against --index-dir")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--docs", default=",".join(DEFAULT_DOCS), help="comma-separated doc paths, relative to repo_root")
    parser.add_argument("--index-dir", default=str(DEFAULT_INDEX_DIR))
    parser.add_argument("--llm", action="store_true", help="augment claim extraction via the local Ollama cascade")
    args = parser.parse_args()

    result = audit(args.repo, Path(args.index_dir), args.docs.split(","), args.llm)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        if "error" in result and result["error"]:
            print(f"[almanac-audit] {result['repo']}: {result['error']}")
            return 0
        s = result["summary"]
        print(f"[almanac-audit] {result['repo']}: {s['total']} claim(s) — "
              f"{s['grounded']} grounded, {s['ungrounded']} ungrounded, {s['unverifiable']} unverifiable")
        for c in result["claims"]:
            marker = {"grounded": "OK", "ungrounded": "XX", "unverifiable": "??"}[c["verdict"]]
            cite = f" ({c['citation']})" if c["citation"] else ""
            print(f"  [{marker}] {c['claim_type']:10s} {c['text'][:70]}{cite}")

    return 0  # signal, not a gate — MISSION-045


if __name__ == "__main__":
    sys.exit(main())
