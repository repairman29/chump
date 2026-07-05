# CSS Token Discipline (INFRA-1590)

Enforces the PWA's design-token system at commit time so new components cannot
introduce raw color literals or non-canonical variable names.

## The rules

| Rule | What is rejected |
|------|-----------------|
| **rule1-hex / rule1-fn** | Raw hex (`#rrggbb`), `rgb()`, `rgba()`, `hsl()` literals **outside** `:root { }` or `[data-theme]` blocks. Colors belong only in token definitions — uses must go through `var(--token)`. |
| **rule2-alias** | New `--*-primary` or `--*-secondary` CSS variable definitions. These are non-canonical aliases that diverge from the system. |
| **rule3-fallback** | `var(--token, FALLBACK)` where `FALLBACK` does not match the token's value in `:root`. Mismatched fallbacks silently break theming. |
| **rule4-drift** | A single color literal appearing in more than 3 different files. The first repeat is caught before it becomes an established pattern. |

## Canonical token names

Only these tokens are part of the design system:

```
--bg           --bg-surface     --bg-elevated
--text         --text-secondary
--accent       --accent-dim
--success      --warn           --error
--border
--radius       --radius-sm
```

Canonical values are defined in `web/v2/index.html` inside `:root { }` (dark mode
default) and overridden per theme in `html[data-theme="light"]` and
`html[data-theme="high-contrast"]` blocks.

## Adding a new color

1. Add a `--my-token: <value>;` line to `:root { }` in `web/v2/index.html`.
2. Add the corresponding overrides to the light and high-contrast blocks.
3. Use `var(--my-token)` everywhere. Never use the hex literal directly in component code.

Do **not** name the token `--*-primary` or `--*-secondary` — use descriptive
names like `--sidebar-bg` or `--badge-error`.

## Bypass mechanic

When a violation is intentional (e.g. a one-time data-visualization palette),
add this trailer to the commit body:

```
Token-Discipline-Bypass: <one-sentence reason>
```

The bypass is logged to `.chump-locks/ambient.jsonl` as `kind=token_discipline_bypass`
with `{commit_sha, reason, files}` for audit. It mirrors the `Rust-First-Bypass:`
pattern from `scripts/git-hooks/pre-commit-rust-first.sh` (META-064).

Env bypass (rare, CI override): `CHUMP_CSS_TOKEN_CHECK=0 git commit ...`

## Pre-existing violations

Existing violations at install time are whitelisted in `.css-discipline-baseline.txt`.
The baseline shrinks as files are cleaned up — do not add new entries to it.

## Scripts

| Path | Purpose |
|------|---------|
| `scripts/lint/css-token-discipline.sh` | Core linter (called by the hook and CI) |
| `scripts/git-hooks/pre-commit-css-token-discipline.sh` | Pre-commit hook wrapper |
| `scripts/ci/test-css-token-discipline.sh` | CI smoke test |
| `.css-discipline-baseline.txt` | Whitelisted pre-existing violations |
| `tests/fixtures/css-token-violation.html` | Dirty fixture (must fail linter) |
| `tests/fixtures/css-token-clean.html` | Clean fixture (must pass linter) |

## Manual invocation

```bash
# Staged files only (same as pre-commit):
bash scripts/lint/css-token-discipline.sh

# Full web/ tree:
bash scripts/lint/css-token-discipline.sh --all

# Custom index.html (token source):
bash scripts/lint/css-token-discipline.sh --index path/to/index.html
```
