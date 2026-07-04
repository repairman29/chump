# CSS Token Discipline (INFRA-1590)

A pre-commit lint gate that rejects design token violations in staged
`web/**/*.{js,html,css}` files before they reach `main`.

## Canonical token list

Defined in `web/v2/index.html` `:root {}`:

| Token | Purpose |
|---|---|
| `--bg` | Page background (darkest) |
| `--bg-surface` | Card / panel background |
| `--bg-elevated` | Elevated / overlay background |
| `--text` | Primary text |
| `--text-secondary` | Muted / secondary text |
| `--accent` | Brand blue (#0a84ff) |
| `--accent-dim` | Translucent accent for fills |
| `--success` | Green status |
| `--warn` | Amber warning |
| `--error` | Red error |
| `--border` | Border color |
| `--radius` | Standard border-radius |
| `--radius-sm` | Small border-radius |

Light and high-contrast theme overrides live in `html[data-theme="light"]`
and `html[data-theme="high-contrast"]` blocks in the same file.

## Rules enforced

### Rule 1 — No raw hex/rgb/hsl in CSS property values

Color literals must always be consumed through `var(--token)`. Raw hex
or `rgb()`/`rgba()`/`hsl()` values in `color`, `background`, `border`,
etc. properties are rejected.

```css
/* BAD */
.component { color: #7c83fd; }

/* GOOD */
.component { color: var(--accent); }
```

Token definitions inside `:root {}` or `html[data-theme="..."] {}` blocks
are allowed (that is how the tokens are declared).

### Rule 2 — No non-canonical `--*-primary` or `--*-secondary` definitions

New CSS variable definitions whose names end in `-primary` or `-secondary`
are rejected, with one exception: `--text-secondary` is canonical.

```css
/* BAD */
:root { --bg-primary: #0a0a0a; }   /* use --bg instead */
:root { --bg-secondary: #1a1a1c; } /* use --bg-surface instead */
:root { --text-primary: #f0f0f0; } /* use --text instead */

/* GOOD */
:root { --text-secondary: #8a8a8e; } /* the one canonical *-secondary */
```

### Rule 3 — `var(--token, FALLBACK)` must match `:root`

When a canonical token is given a hard-coded fallback, that fallback must
exactly match the token's `:root` value (case-insensitive, spaces stripped).

```css
/* BAD — --border is rgba(255,255,255,0.08), not #2a2a2e */
border: 1px solid var(--border, #2a2a2e);

/* GOOD */
border: 1px solid var(--border);
/* or if a fallback is needed for older browsers: */
border: 1px solid var(--border, rgba(255,255,255,0.08));
```

### Rule 4 — Drift detector (non-canonical hex in >3 files)

A non-canonical hex value (one not defined in `:root`) that appears in
more than three web files is treated as a spreading hardcode. Fix by
adding a named token for the value and using `var(--new-token)`.

## Using the bypass

When a violation is intentional (e.g., a one-off print stylesheet or a
genuine browser-compat fallback the team has agreed on), add a trailer to
the commit message body:

```
Token-Discipline-Bypass: <one-sentence reason>
```

Every bypass is logged as `kind=token_discipline_bypass` in
`.chump-locks/ambient.jsonl` with `{commit_sha, reason, files}` for audit.

## Env bypass

```bash
CHUMP_CSS_TOKEN_CHECK=0 git commit ...
```

Reserve for extraordinary circumstances (e.g., the linter itself has a
bug). File a follow-up gap if you use it.

## Baseline (pre-existing violations)

Files listed in `.css-discipline-baseline.txt` are exempt from all rules.
They contain violations that predate the gate. The goal is to shrink this
list over time via dedicated cleanup gaps.

To check whether a file is still correctly baselined after cleanup, remove
it from the baseline, stage a change to that file, and run:

```bash
bash scripts/lint/css-token-discipline.sh
```

## Linter location

`scripts/lint/css-token-discipline.sh` — wired into `scripts/git-hooks/pre-commit`
(check 19). Runs only when staged files match `web/**/*.{js,html,css}`.

## CI smoke test

```bash
bash scripts/ci/test-css-token-discipline.sh
```

Asserts that `tests/fixtures/css-token-clean.html` passes and
`tests/fixtures/css-token-violation.html` fails.
