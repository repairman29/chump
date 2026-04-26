---
name: Bug report
about: Report a defect (include minimal repro for fastest triage)
title: "[bug] "
labels: []
---

## Summary

What went wrong (one or two sentences)?

## Environment

- OS (macOS / Linux / WSL / other):
- Rust (`rustc --version`):
- Inference (Ollama version, or `OPENAI_API_BASE` host):
- Followed `docs/process/EXTERNAL_GOLDEN_PATH.md`? yes / no / partial

## Minimal repro

1. Steps to reproduce (commands from a fresh clone if possible):
2. Expected behavior:
3. Actual behavior (paste logs or `curl` output; redact tokens):

## Optional

Output of `./scripts/ci/verify-external-golden-path.sh` (pass/fail).

See `CONTRIBUTING.md` for PR expectations.
