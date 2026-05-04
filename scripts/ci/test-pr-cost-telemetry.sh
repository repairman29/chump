#!/bin/bash
# INFRA-405: per-PR cost telemetry test
# Verify that chump cost record-pr and chump dispatch cost-report work end-to-end.

set -e

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

cd "$TESTDIR"
git init --quiet
git config user.email "test@example.com"
git config user.name "Test User"
mkdir -p .chump

echo "Testing PR cost telemetry (INFRA-405)..."

# Find the chump binary
CHUMP="${OLDPWD}/target/debug/chump"
if [ ! -f "$CHUMP" ]; then
    CHUMP="${OLDPWD}/target/release/chump"
fi

# Record a synthetic PR cost
echo "Recording PR #123 cost..."
$CHUMP cost record-pr \
    --pr 123 \
    --gap INFRA-405 \
    --model claude-haiku \
    --tokens-in 1000 \
    --tokens-out 500 \
    --usd 0.02 \
    --duration-secs 120 \
    --backend claude \
    2>&1 | grep -q "recorded PR 123"

# Record a second PR
echo "Recording PR #124 cost..."
$CHUMP cost record-pr \
    --pr 124 \
    --gap INFRA-406 \
    --model claude-sonnet \
    --tokens-in 2000 \
    --tokens-out 1000 \
    --usd 0.05 \
    --duration-secs 180 \
    --backend claude \
    2>&1 | grep -q "recorded PR 124"

# Query all costs
echo "Querying all costs..."
REPORT=$($CHUMP dispatch cost-report)
echo "$REPORT" | grep -q "123"
echo "$REPORT" | grep -q "INFRA-405"

# Query by model
echo "Querying by model..."
BY_MODEL=$($CHUMP dispatch cost-report --per-model)
echo "$BY_MODEL" | grep -q "claude-haiku"
echo "$BY_MODEL" | grep -q "claude-sonnet"

# Query by domain
echo "Querying by domain..."
BY_DOMAIN=$($CHUMP dispatch cost-report --per-domain)
echo "$BY_DOMAIN" | grep -q "INFRA"

echo "✓ All tests passed"
