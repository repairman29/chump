# chump-gh-app

GitHub App JWT generation and installation-token fetching for Chump's
multi-lane GitHub quota isolation ([INFRA-1076](https://github.com/repairman29/chump/issues/INFRA-1076)).

## Purpose

Chump splits GitHub API calls into **critical** and **background** lanes,
each backed by a separate GitHub App installation, so background polling
can't exhaust the quota that ship-blocking mutations need (INFRA-1076).

This crate handles the credential layer:

1. **`generate_jwt`** — RS256-signed JWT for authenticating as the App itself.
2. **`fetch_installation_token`** — exchange the JWT for a short-lived
   `ghs_…` installation access token via the GitHub Apps REST API.
3. **`load_apps_config`** — read `~/.chump/github_apps.toml` to get the
   `app_id`, `private_key_path`, and `installation_id` for each lane.

## Config format

```toml
# ~/.chump/github_apps.toml

[critical]
app_id           = 123456
private_key_path = "~/.chump/critical-app-key.pem"
installation_id  = 78901234

[background]
app_id           = 123457
private_key_path = "~/.chump/background-app-key.pem"
installation_id  = 78901235
```

## Token rotation

The companion gap **INFRA-1361** adds a `chump gh-token rotate` subcommand
that calls this crate on a 50-minute launchd/cron cadence and writes fresh
tokens to `~/.chump/oauth-token-<lane>.json`.

## Setup

Operator steps (one-time, documented in INFRA-1362 runbook):
1. Create two GitHub Apps under your org/account.
2. Install each on the target repository.
3. Download each App's PEM private key.
4. Populate `~/.chump/github_apps.toml` as shown above.
5. Run `chump gh-token rotate` to verify the round-trip.
