#!/usr/bin/env bash
# pre-commit-git-identity.sh — INFRA-787
#
# Refuses commits where the resolved git author identity is a test-fixture
# default. Today's PR #1369 (sibling-shipped INFRA-781 yaml) was attributed
# to a random 2011 GitHub account named `petros-double-test1` because:
#
#   1. A `scripts/ci/test-*.sh` fixture had previously run
#      `git -c user.email=t@t -c user.name=t commit ...` in or against the
#      MAIN repo (not an isolated tempdir). That mutated the local
#      .git/config to:
#          [user]
#              email = t@t.t
#              name = t
#   2. Linked worktrees inherit local .git/config; every fleet worker on
#      this machine then committed as `t <t@t.t>`.
#   3. GitHub's email-to-account mapping resolved `t@t.t` to whoever first
#      registered that email (an ancient anonymous account), and displayed
#      that account as the commit "author" everywhere.
#
# This guard prevents recurrence by refusing any commit whose effective
# (`git var GIT_AUTHOR_IDENT`) identity matches one of the well-known
# fixture sentinels.
#
# Detected sentinels
#   user.email exactly: t@t, t@t.t, test@test, test@test.test, fixture@x.x, ""
#   user.name exactly:  t, test, fixture, "" (empty)
#
# Bypass
#   CHUMP_GIT_IDENTITY_CHECK=0 git commit ...
#   For legitimate test-fixture commits in this repo (rare; the fixtures
#   should be using their own isolated repos). With this bypass, include
#   a `Git-Identity-Bypass: <reason>` trailer in the commit body.

set -uo pipefail

if [[ "${CHUMP_GIT_IDENTITY_CHECK:-1}" == "0" ]]; then
    exit 0
fi

# `git var GIT_AUTHOR_IDENT` returns the effective author identity in the
# format: `Name <email> timestamp tz`. We parse name + email out of that.
ident="$(git var GIT_AUTHOR_IDENT 2>/dev/null || true)"
if [[ -z "$ident" ]]; then
    # Identity unset entirely → block (git would refuse the commit anyway,
    # but this gives a more helpful message).
    name=""
    email=""
else
    # Strip trailing "<timestamp> <tz>" then extract name + email.
    name=$(echo "$ident" | sed -E 's/[[:space:]]*<[^>]*>[[:space:]]*[0-9].*$//')
    email=$(echo "$ident" | sed -nE 's/.*<([^>]*)>.*/\1/p')
fi

# Sentinel sets — case-insensitive on email, case-sensitive on name.
is_sentinel_email() {
    local lc
    lc=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$lc" in
        ""|t@t|t@t.t|test@test|test@test.test|fixture@*|user@example.com)
            return 0 ;;
    esac
    return 1
}

is_sentinel_name() {
    case "$1" in
        ""|t|test|fixture|Test)
            return 0 ;;
    esac
    return 1
}

bad=0
reasons=()

if is_sentinel_email "$email"; then
    bad=1
    reasons+=("user.email looks like a test-fixture sentinel: '${email:-<unset>}'")
fi
if is_sentinel_name "$name"; then
    bad=1
    reasons+=("user.name looks like a test-fixture sentinel: '${name:-<unset>}'")
fi

if [[ "$bad" -eq 0 ]]; then
    exit 0
fi

# Block.
echo "" >&2
echo "──────────────────────────────────────────────────────────────────────" >&2
echo "❌ INFRA-787 git-identity guard blocked this commit." >&2
echo "" >&2
echo "Effective author identity: ${name:-<unset>} <${email:-<unset>}>" >&2
echo "" >&2
for r in "${reasons[@]}"; do
    echo "  - $r" >&2
done
echo "" >&2
echo "Why this matters: GitHub maps commit author email to a GitHub" >&2
echo "account. A fixture email like 't@t.t' resolves to whoever first" >&2
echo "registered that address (a random 2011 account today), so commits" >&2
echo "look like they were authored by an unrelated user." >&2
echo "" >&2
echo "How to fix" >&2
echo "  1. If your local .git/config has overrides:" >&2
echo "       git config --unset user.email" >&2
echo "       git config --unset user.name" >&2
echo "     Re-run the commit; git will pick up your global ~/.gitconfig." >&2
echo "" >&2
echo "  2. Set a real identity for this repo:" >&2
echo "       git config user.email 'you@example.com'" >&2
echo "       git config user.name 'Your Name'" >&2
echo "" >&2
echo "  3. Bypass once (rare; legitimate test fixture only):" >&2
echo "       CHUMP_GIT_IDENTITY_CHECK=0 git commit ..." >&2
echo "     and add 'Git-Identity-Bypass: <reason>' to commit body." >&2
echo "──────────────────────────────────────────────────────────────────────" >&2

exit 1
