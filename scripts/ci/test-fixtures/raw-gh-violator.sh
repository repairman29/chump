#!/usr/bin/env bash
# INFRA-1274 test fixture: this file intentionally calls gh api directly.
# Used by test-no-raw-gh-in-hot-paths.sh to verify the linter rejects violations.
# DO NOT use as a template — use scripts/coord/lib/github_cache.sh instead.

gh api repos/owner/repo/pulls/1 --jq '.number'
