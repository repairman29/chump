# scripts/release/

| Script | Purpose | Owner |
|---|---|---|
| `publish-crates.sh` | Orchestrate `cargo publish` across the workspace in dependency order. Default is dry-run; `--execute` actually publishes (irreversible). Requires `cargo login` / `CARGO_REGISTRY_TOKEN`. | Manual-run only — not wired into CI/CD. Run by whoever is cutting the crates.io release (operator, Jeff Adkins, as of 2026-08-27); no automated trigger exists.
