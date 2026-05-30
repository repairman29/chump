# Rotate sccache R2 Token — Operator Procedure

**Filed under:** `docs/process/PROCEDURES/` — META-205 (Quartermaster seed procedure)
**Source scripts:** `scripts/ops/rotate-sccache-r2-gh-only.sh` (INFRA-2240) and `scripts/ops/rotate-sccache-r2-token.sh` (INFRA-2237)

---

## When to use

Run this procedure when Rust CI jobs start failing with:
```
S3Error code: Unauthorized
```
or when the `sccache` layer shows zero cache hits across multiple PRs for > 30 min.

Root cause: the R2 token pair (`R2_ACCESS_KEY_ID` + `R2_SECRET_ACCESS_KEY` in GitHub Actions secrets) has become stale or was **half-rotated** — one secret updated, the other left behind. The pair must match as a unit.

**Which path to take:**

| Situation | Use |
|---|---|
| You have both new key values from CF dashboard | `rotate-sccache-r2-gh-only.sh` (**primary path**) |
| You want to automate the CF token regen step too | `rotate-sccache-r2-token.sh` (**backup path**, requires CF API token) |

The GH-only path is the primary path because the CF dashboard token regen is already a one-click flow, and having a long-lived `CHUMP_CF_API_TOKEN` env var with privileged scope is a security trade-off most operators don't want for routine use.

---

## Path A: GH-Only (primary) — `rotate-sccache-r2-gh-only.sh`

### Prerequisites

- `gh` CLI installed and authenticated: `gh auth status`
- You have write access to the `repairman29/chump` repo secrets: `gh secret list -R repairman29/chump`
- A Cloudflare account with the R2 bucket `chump-sccache` (access via the CF dashboard at `https://dash.cloudflare.com`)

### Steps

**1. Regen the R2 token in the Cloudflare dashboard (~30 sec)**

   a. Go to `https://dash.cloudflare.com` → your account → **R2** → **Manage R2 API Tokens**
   b. Find the token named `chump-sccache-ci` → click **Roll token** (or delete + create new with same permissions: Object Read & Write on bucket `chump-sccache`)
   c. Copy both the new **Access Key ID** (32 hex chars) and **Secret Access Key** (64 hex chars)

**2. Save to the input file**

```bash
cat > ~/.chump/r2-new-token.txt <<'EOF'
ACCESS_KEY_ID=<paste 32-char hex here>
SECRET_ACCESS_KEY=<paste 64-char hex here>
EOF
chmod 600 ~/.chump/r2-new-token.txt
```

**3. Dry-run to verify the script reads correctly**

```bash
bash scripts/ops/rotate-sccache-r2-gh-only.sh
# Expected output: shows [DRY-RUN] lines + fingerprints like abc1...xyz9
# Verify the fingerprints match the beginning/end of your pasted keys
```

**4. Execute the rotation**

```bash
bash scripts/ops/rotate-sccache-r2-gh-only.sh --execute
```

Expected output:
```
[rotate-r2-gh-only] writing R2_ACCESS_KEY_ID in repairman29/chump …
  PASS
[rotate-r2-gh-only] writing R2_SECRET_ACCESS_KEY in repairman29/chump …
  PASS
[rotate-r2-gh-only] verifying secret timestamps …
R2_ACCESS_KEY_ID    2026-05-30
R2_SECRET_ACCESS_KEY 2026-05-30
[rotate-r2-gh-only] both secrets timestamped; pair-mismatch class avoided.
[rotate-r2-gh-only] securely deleting ~/.chump/r2-new-token.txt …
  PASS (file removed)
[rotate-r2-gh-only] DONE.
```

### Verification

```bash
# Trigger a CI run on main to confirm sccache hits:
gh workflow run ci.yml --ref main -R repairman29/chump
# Then watch the Rust build jobs — look for "sccache stats" lines with
# cache_hits > 0 instead of "S3Error Unauthorized".

# Check the ambient event was emitted:
grep sccache_r2_gh_rotated .chump-locks/ambient.jsonl | tail -1
```

### Recovery if half-failed

**Scenario:** the script failed after updating `R2_ACCESS_KEY_ID` but before updating `R2_SECRET_ACCESS_KEY`. GH is now half-rotated (pair mismatch).

1. **Don't panic.** The input file may still have both values if the script didn't get to the secure-delete step.
2. Check: `ls ~/.chump/r2-new-token.txt` — if present, re-run `--execute` immediately. The script is idempotent for the GH secret-write step.
3. If the input file was deleted: go back to the CF dashboard, regen again (step 1), repaste, re-run.
4. Check ambient for the partial event: `grep sccache_r2_gh_rotation_partial .chump-locks/ambient.jsonl`

---

## Path B: CF-API-Automated — `rotate-sccache-r2-token.sh`

Use this when you want to automate the CF dashboard step (step 1 above) via the CF API. Requires a Cloudflare API token with **Account → Workers R2 Storage → Edit** scope — a different, more privileged token than the R2-S3-compat token being rotated.

### Prerequisites

- All prerequisites from Path A, plus:
- A CF API token with `Account → Workers R2 Storage → Edit` scope:
  - Create at `https://dash.cloudflare.com/profile/api-tokens` → **Create Token** → **Custom token**
  - Permissions: **Account → Workers R2 Storage → Edit**
- Your 32-char hex Cloudflare Account ID (visible in CF dashboard URL after `/`)

### Steps

**1. Set required env vars**

```bash
export CHUMP_CF_API_TOKEN="<your CF API token>"
export CHUMP_R2_ACCOUNT_ID="<32-char hex account ID>"
```

**2. Dry-run**

```bash
bash scripts/ops/rotate-sccache-r2-token.sh
# Expected: [DRY-RUN] lines showing what would happen
```

**3. Execute**

```bash
bash scripts/ops/rotate-sccache-r2-token.sh --execute
```

Expected output walks through: CF API ping → list existing token → create new token → update GH secrets → delete old token → emit `kind=sccache_r2_token_rotated`.

### Verification

Same as Path A — trigger a CI run and watch for `sccache stats` with cache hits.

### Recovery if half-failed

The script sets a `trap` on EXIT: if it fails after creating the new CF token but before persisting it (i.e., before the GH secret update succeeds), it attempts to **delete the orphan new token** so it doesn't leak. The script emits `kind=sccache_r2_token_rotation_partial` with the failure step.

Check ambient: `grep sccache_r2_token_rotation_partial .chump-locks/ambient.jsonl | tail -1`

If the GH secrets were half-updated (one written, one failed):
- The input values are NOT in a file (unlike Path A). They were in the CF API response.
- Operator must **re-run the script** from scratch — it will create a new CF token, which is fine (the old one may be orphaned; clean it up in the CF dashboard if needed).

---

## Ambient events emitted

| Kind | When |
|---|---|
| `sccache_r2_gh_rotated` | Path A success |
| `sccache_r2_gh_rotation_partial` | Path A partial failure |
| `sccache_r2_gh_rotation_failed` | Path A hard failure |
| `sccache_r2_token_rotated` | Path B success |
| `sccache_r2_token_rotation_partial` | Path B partial failure (orphan CF token) |
| `sccache_r2_token_rotation_failed` | Path B hard failure |
