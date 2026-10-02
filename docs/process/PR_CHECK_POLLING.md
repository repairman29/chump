# PR check polling discipline (DOC-020)

Moved out of `AGENTS.md` by ZERO-WASTE-125 (rulebook line-budget cut).

`gh pr checks <N>` polling burns output tokens fast (~200/poll for the diff
+ your reasoning). Cap at **3 attempts** per session, then back off:

1. **Hand off to `pr-watch-shepherd`** — already running on launchd, will
   auto-rebase + re-arm DIRTY/BEHIND PRs. Don't do its job.
2. **Use `ScheduleWakeup` (~1200s) or `Bash run_in_background`** for "check
   back later" — the runtime notifies you when something completes.
3. **Move on to the next gap.** PRs are async; treat them that way.

Never poll a check loop in a tight `while`. If you find yourself doing
"let me just check one more time," stop.
