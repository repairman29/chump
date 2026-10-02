# Reading code economically (DOC-019)

Moved out of `AGENTS.md` by ZERO-WASTE-125 (rulebook line-budget cut).

Token cost discipline. Every full file read of a 1500-line file costs
~5-8K input tokens. After context compaction the same agent often re-reads
the same file. At fleet scale this is real budget.

- **Files >500 lines: default to `grep -n <symbol>` + `Read offset/limit`.**
  Read the full file only when the change touches structure (cross-cutting
  refactor, file-level rename).
- **`Read` supports `offset` + `limit`.** Use them. The line-number output
  from `grep -n` is the offset.
- **`cat` is forbidden via the Bash tool.** Use `Read` instead.

When in doubt: grep first, ask what region is relevant, then read it.
