#!/usr/bin/env python3.12
"""
RESEARCH-018 — Length-matched null-prose generator.

Produces a markdown-structured block of deterministic random prose
matched to a target character count. Used as Cell C in RESEARCH-018's
length-matched scaffolding-as-noise control: if Cell C (null prose of
equal length) produces a delta comparable to Cell A (real lessons
block), the effect is "prompt length/ceremony," not "lessons content."

Design requirements (from docs/eval/preregistered/RESEARCH-018.md §11):
  1. Match the target character count within ±2%.
  2. Preserve the same markdown skeleton as the real lessons block
     (H2 heading + bulleted list).
  3. Use frequency-matched English word sampling.
  4. Do NOT emit load-bearing rubric tokens. Banned word list blocks
     'lesson', 'always', 'never', 'important', 'must', 'should',
     'correct', 'wrong', 'hallucinat*', 'tool', 'function', 'avoid'.
  5. Deterministic given (target_chars, seed). Two runs with the
     same args produce byte-identical output.

Preregistration: docs/eval/preregistered/RESEARCH-018.md
Usage:
    # Stand-alone generator
    python3.12 scripts/ab-harness/gen-null-prose.py --target-chars 2000 --seed 42

    # Against a real lessons block to get an exactly-length-matched placebo:
    python3.12 scripts/ab-harness/gen-null-prose.py \\
        --match-file path/to/lessons_block.txt --seed 42 --out placebo.md

    # Self-test
    python3.12 scripts/ab-harness/gen-null-prose.py --self-test
"""

from __future__ import annotations

import argparse
import random
import re
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Word list — high-frequency English, domain-neutral
# ---------------------------------------------------------------------------
# Drawn from the top ~300 most-common English words, filtered to remove
# second-person pronouns and imperative verbs that could trigger agent
# behavior shifts independent of prompt length. Static, embedded so the
# generator has no external-file dependency.

_COMMON_WORDS = """
the be to of and a in that have it for on with as but at by from this or
an one some any all each every many much few more less most least another
other both either neither none same such which who what when where why how
time day year week month hour minute second morning evening night today tomorrow
person people thing place way name word part piece item kind sort type case
number amount rate level stage point area side end front back top bottom center
house room door window floor wall table chair book page line paragraph chapter
water food tree flower leaf branch river mountain cloud sun moon star sky earth
city town village road path street park garden forest field beach lake ocean
walk run sit stand wait rest sleep wake come go arrive leave enter exit return
think know hear see watch look read write draw paint sing dance laugh smile
blue red green yellow white black brown grey pink orange purple bright dark
soft hard warm cold fresh old new young small large huge tiny long short wide
quiet loud quick slow early late happy glad calm simple plain steady common
over under above below inside outside beyond between among toward past through
during after before until since while whenever although though because unless
song story picture map letter number page chapter shelf drawer cabinet window
river valley hill forest meadow island shore bay cove stream path trail route
machine engine wheel bridge tower gate fence post sign lamp clock chain rope
"""

_WORD_BANK: list[str] = sorted({w for w in _COMMON_WORDS.split() if w})


# Banned tokens — must not appear anywhere in the generated output, even
# as substrings of longer words. Protects against "ceremony without content"
# being contaminated by directive-sounding substrings.
_BANNED_SUBSTRINGS: set[str] = {
    "lesson", "always", "never", "important", "must", "should",
    "correct", "wrong", "hallucinat", "tool", "function", "avoid",
    "rule", "require", "ensure", "verify", "validate", "error",
    "fail", "succeed", "pass", "try", "attempt", "prohibit", "allow",
}


def _safe_word(word: str) -> bool:
    lo = word.lower()
    return not any(banned in lo for banned in _BANNED_SUBSTRINGS)


# Filter the word bank once at import
_WORD_BANK = [w for w in _WORD_BANK if _safe_word(w)]


# ---------------------------------------------------------------------------
# Generator
# ---------------------------------------------------------------------------


def _random_sentence(rng: random.Random, min_words: int = 6, max_words: int = 14) -> str:
    """Produce a single sentence of random words ending in a period."""
    n = rng.randint(min_words, max_words)
    words = [rng.choice(_WORD_BANK) for _ in range(n)]
    words[0] = words[0].capitalize()
    return " ".join(words) + "."


def _random_bullet(rng: random.Random, target_chars: int) -> str:
    """Produce one markdown bullet line of approximately target_chars
    characters, composed of 1–3 safe sentences."""
    sentences: list[str] = []
    current = 0
    # "- " prefix + one space between sentences + newline
    overhead = 3
    while current < target_chars - overhead:
        s = _random_sentence(rng)
        sentences.append(s)
        current += len(s) + 1
        if current > target_chars * 0.8 and rng.random() < 0.5:
            break
    return "- " + " ".join(sentences) + "\n"


def generate(target_chars: int, seed: int = 42, heading: str = "## Notes") -> str:
    """Generate a markdown block matched to target_chars character length
    (±2%). Deterministic given (target_chars, seed)."""
    rng = random.Random(seed)

    # The skeleton consumes some budget. Estimate:
    #   heading + 2 newlines = len(heading) + 2
    # Then bullet-lines fill the remainder. Each bullet ~100-140 chars
    # on average. Keep adding until we're within ±2% of target.

    header = heading + "\n\n"
    budget = target_chars - len(header)
    bullets: list[str] = []

    # Approximate char budget per bullet
    per_bullet_target = rng.randint(90, 140)

    while True:
        current_total = len(header) + sum(len(b) for b in bullets)
        remaining = target_chars - current_total
        if remaining <= 0:
            break
        if remaining < per_bullet_target * 0.5:
            # Running out of budget — append a short bullet and stop
            bullets.append(_random_bullet(rng, max(remaining, 10)))
            break
        bullets.append(_random_bullet(rng, min(per_bullet_target, remaining)))

    body = header + "".join(bullets)

    # Trim / pad to ±2%, iterating until we're inside the tolerance band.
    tolerance_chars = max(5, int(0.02 * target_chars))
    for _ in range(32):  # cap iterations to avoid pathological bounce
        if abs(len(body) - target_chars) <= tolerance_chars:
            break
        if len(body) > target_chars + tolerance_chars:
            # Trim the last bullet; snap to last newline so we don't leave
            # a half-word at the tail.
            last_nl = body.rfind("\n", 0, target_chars + tolerance_chars)
            if last_nl > len(header):
                body = body[: last_nl + 1]
            else:
                # Should never happen for reasonable targets, but bail safely.
                body = body[: target_chars + tolerance_chars]
                break
        elif len(body) < target_chars - tolerance_chars:
            pad_target = max(30, (target_chars - len(body)))
            body = body + _random_bullet(rng, pad_target)

    return body


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------


def run_self_test() -> int:
    print("=== gen-null-prose self-test ===")
    failures: list[str] = []

    # Test 1: length accuracy across a range of targets
    for target in [500, 1000, 2000, 4000]:
        out = generate(target, seed=42)
        got = len(out)
        tol = max(1, int(0.02 * target))
        if abs(got - target) > tol:
            failures.append(f"target={target}: got {got}, tolerance ±{tol}")
        else:
            print(f"  PASS: target={target}  actual={got}  Δ={got - target:+d}")

    # Test 2: determinism — same args produce same output
    a = generate(1500, seed=7)
    b = generate(1500, seed=7)
    if a != b:
        failures.append("determinism: two runs with same (1500, 7) produced different output")
    else:
        print("  PASS: deterministic (target=1500, seed=7)")

    # Test 3: different seeds produce different output
    c = generate(1500, seed=8)
    if a == c:
        failures.append("different-seed: (1500, 7) matched (1500, 8) — not randomizing")
    else:
        print("  PASS: different seeds yield different output")

    # Test 4: no banned substrings in a battery of runs
    battery = [generate(2000, seed=s) for s in range(1, 21)]
    for s, out in enumerate(battery, 1):
        lo = out.lower()
        hit = next((b for b in _BANNED_SUBSTRINGS if b in lo), None)
        if hit:
            failures.append(f"seed={s}: banned substring '{hit}' appeared in output")
    if not any("seed=" in f for f in failures):
        print("  PASS: 20-seed battery — no banned substrings")

    # Test 5: markdown skeleton preserved
    out = generate(2000, seed=100)
    if not out.startswith("## "):
        failures.append("skeleton: output does not start with H2 heading")
    if "\n- " not in out:
        failures.append("skeleton: output contains no bullet lines")
    if not any(f.startswith("skeleton:") for f in failures):
        print("  PASS: markdown skeleton preserved (H2 + bullets)")

    # Summary
    if failures:
        print(f"\nSELF-TEST FAILED ({len(failures)}):")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("\nSELF-TEST PASSED — length ±2%, deterministic, banned-substring-clean, skeleton preserved.")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--target-chars", type=int, help="Target character count")
    ap.add_argument("--match-file", type=Path, help="Read target char count from this file's length")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--heading", default="## Notes", help="Markdown heading (default: '## Notes')")
    ap.add_argument("--out", type=Path, help="Write output here (default: stdout)")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return run_self_test()

    if args.match_file:
        target = len(args.match_file.read_text())
    elif args.target_chars:
        target = args.target_chars
    else:
        ap.error("--target-chars, --match-file, or --self-test required")

    output = generate(target, seed=args.seed, heading=args.heading)

    if args.out:
        args.out.write_text(output)
        print(f"Wrote {len(output)} chars to {args.out} (target {target}, Δ={len(output) - target:+d})", file=sys.stderr)
    else:
        sys.stdout.write(output)

    return 0


if __name__ == "__main__":
    sys.exit(main())
