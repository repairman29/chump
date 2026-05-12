# CLI Aliases (EFFECTIVE-011)

Short aliases for frequent chump commands. All aliases are expanded before routing, so they work identically to the full command.

## Alias table

| Alias | Full command | Example |
|-------|-------------|---------|
| `g`   | `gap`       | `chump g list` → `chump gap list` |
| `c`   | `claim`     | `chump c INFRA-123` → `chump claim INFRA-123` |
| `s`   | `gap ship`  | `chump s INFRA-123` → `chump gap ship INFRA-123` |
| `f`   | `fleet`     | `chump f status` → `chump fleet status` |
| `d`   | `dispatch`  | `chump d route` → `chump dispatch route` |
| `h`   | `health`    | `chump h` → `chump health` |
| `cs`  | `cost-watch`| `chump cs` → `chump cost-watch` |

## Notes

- Aliases are expanded at the top of `main()` before any command routing.
- `s` is a compound alias: it replaces `args[1]` with `gap` and inserts `ship` at `args[2]`.
- All other aliases are simple single-word substitutions.
- `chump --help` and `chump help` list aliases next to each command.
