---
doc_tag: reference
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Internal Maintainer & Fleet Engineering Notes

Files outside the curated public allowlist in [`mkdocs.yml`](../../mkdocs.yml) (`docs/design/`, `docs/strategy/`, `docs/eval/`, `docs/audits/`, `docs/syntheses/`, `docs/gaps/`, and internal `docs/process/` runbooks) are **maintainer engineering history** from Chump's self-hosting fleet.

- **Public user & operator documentation:** Published from the strict 22-page allowlist in [`mkdocs.yml`](../../mkdocs.yml) at `https://repairman29.github.io/chump/reference/` (paired with the Warm-Stone quickstart at `https://repairman29.github.io/chump/docs/`).
- **Privacy & hygiene guardrail:** [`scripts/ci/test-public-doc-privacy.sh`](../../scripts/ci/test-public-doc-privacy.sh) blocks `awesome-pages`, enforces the default-deny `exclude_docs` allowlist in `mkdocs.yml`, and rejects private hostnames, Tailscale CGNAT IPs, personal user paths, and retired pre-v1.0 scripts on all public surfaces.
