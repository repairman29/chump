# Repo Sentinel

## Overview
Repo Sentinel is a tool for scanning repositories for security vulnerabilities and compliance issues.

## Threat Model
- `.env.bak` files
- `*service*account*.json` files
- `clawdbot.json` files
- High-signal redacted API tokens
- `.gitignore` blindspots
- Tracked bloat

## CLI Usage Examples
- `repo-sentinel scan`
- `repo-sentinel portfolio`
- `repo-sentinel harden`

## Pre-commit Hook Setup
```bash
repo-sentinel --staged
```

## Exit Codes
- `0`: Success
- `1`: Error
- `2`: Findings detected