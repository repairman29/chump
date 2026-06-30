# CSS Token Discipline (INFRA-1590)

Lint gate that rejects design-token drift in `web/**/*.{js,html,css}` at commit time.
Mirrors the [META-064 Rust-First-Bypass](../../CLAUDE.md) pattern.

## Canonical token list

Defined in `web/v2/index.html :root {}`:

| Token | Purpose |
|---|---|
| `--bg` | Page background |
| `--bg-surface` | Card / panel surface |
| `--bg-elevated` | Elevated layer (dropdown, modal) |
| `--text` | Primary text |
| `--text-secondary` | Muted / secondary text |
| `--accent` | Interactive accent (links, buttons) |
| `--accent-dim` | Translucent accent for badges/highlights |
| `--success` | Success indicator |
| `--warn` | Warning indicator |
| `--error` | Error / danger indicator |
| `--border` | Subtle divider / border |
| `--radius` | Default border-radius |
| `--radius-sm` | Small border-radius |

Theme overrides live in `[data-theme="light"]` and `[data-theme="high-contrast"]`
blocks in the same file.

## Rules

### Rule 1 — No raw color literals outside `:root` / `[data-theme]`

Raw hex, `rgb()`, `rgba()`, and `hsl()` values **outside** a token-definition
block are rejected. Uses must go through `var(--token)`.

```css
/* ❌ bad */
.my-component { background: #0a0a0a; }

/* ✓ good */
.my-component { background: var(--bg); }
```

Colors inside `/* CSS comments */` are ignored.

### Rule 2 — No `--*-primary` or `--*-secondary` definitions

Non-canonical variable names (`--bg-primary`, `--text-primary`, etc.) are
rejected. The system uses `--text`, `--bg`, `--accent`, etc. directly.

```css
/* ❌ bad */
:root { --bg-primary: #0a0a0a; }

/* ✓ good — use the canonical name or add a new token with a descriptive name */
:root { --bg-chat: #0f0f12; }  /* new semantic token */
```

### Rule 3 — `var()` fallback must match `:root` value

When a `var()` call includes a fallback, the fallback must exactly match the
token's value in `:root`. Mismatched fallbacks indicate the author used the
wrong token or the wrong fallback.

```css
/* ❌ bad — :root says --bg is #0a0a0a, not #0d0d0f */
.panel { background: var(--bg, #0d0d0f); }

/* ✓ good */
.panel { background: var(--bg, #0a0a0a); }

/* ✓ better — just use var() without a fallback */
.panel { background: var(--bg); }
```

### Rule 4 — Drift detector: same color literal in >3 files

When a raw color value (e.g. `#ff453a`) appears in more than 3 different
files, the lint rejects it. This catches repeated ad-hoc use of the same
value before it calcifies into an un-tracked de-facto token.

Fix: add the color to `web/v2/index.html :root {}` with a descriptive name,
then replace all uses with `var(--new-token)`.

## Bypass

Add to the commit body:

```
Token-Discipline-Bypass: <one-sentence reason>
```

Bypasses emit `kind=token_discipline_bypass` to `ambient.jsonl` with
`{commit_sha, reason, files}` for audit.

## Baseline (grandfathering)

Files with violations that existed before the lint was introduced are listed
in `.css-discipline-baseline.txt`. The linter skips those files entirely.

To add a new file to the baseline (e.g. while migrating incrementally):

```bash
echo 'web/v2/my-component.js' >> .css-discipline-baseline.txt
```

To clean up a baselined file, fix its violations and remove it from the baseline.

## Adding a new token

1. Add to `web/v2/index.html :root {}` with a value.
2. Add matching entries in `[data-theme="light"]` and `[data-theme="high-contrast"]`.
3. Use `var(--new-token)` everywhere.

## Environment controls

| Env var | Effect |
|---|---|
| `CHUMP_TOKEN_DISCIPLINE_CHECK=0` | Disable the linter entirely |
| `CSS_DISCIPLINE_BASELINE_OVERRIDE=<path>` | Use alternate baseline file |
| `CHUMP_AMBIENT_LOG=<path>` | Override ambient log path |

## Files

- Linter: `scripts/lint/css-token-discipline.sh`
- CI test: `scripts/ci/test-css-token-discipline.sh`
- Baseline: `.css-discipline-baseline.txt`
- Clean fixture: `tests/fixtures/css-token-clean.html`
- Dirty fixture: `tests/fixtures/css-token-violation.html`
- Event kind: `token_discipline_bypass` (see `docs/observability/EVENT_REGISTRY.yaml`)
