---
doc_tag: canonical
owner_gap: CREDIBLE-017
last_audited: 2026-11-27
---

# CLI Exit Codes

All `chump` CLI commands follow a deterministic Unix exit-code contract so shell scripts, git hooks, and CI pipelines can distinguish runtime failures from invalid CLI invocations:

| Exit Code | Meaning | Typical Causes |
|:---------:|---------|----------------|
| `0` | **Success** | Command completed cleanly; validation or preflight passed |
| `1` | **Runtime / Gate Failure** | Lease collision detected, secret pattern blocked, model/server unreachable, or validation failed |
| `2` | **Usage Error** | Unknown subcommand, missing required flag, or invalid argument syntax |

---

## Scripting Example

```bash
chump config validate
case $? in
  0) echo "Configuration valid" ;;
  1) echo "Configuration schema or credential check failed" >&2; exit 1 ;;
  2) echo "CLI invocation syntax error" >&2; exit 2 ;;
esac
```

---

## Related Guides

- [CLI Flags](CLI_FLAGS.md)
- [File Leases & Worktrees](process/AGENT_COORDINATION.md)
