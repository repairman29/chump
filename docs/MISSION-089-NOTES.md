# MISSION-089 — closed as superseded by already-shipped parse_backlog_file

MISSION-089 ("Parse defined backlog file into structured items", MISSION-055
slice) asks for a public `parse_backlog_file` function in `src/briefing.rs`
that reads a backlog file, detects JSON-vs-plain-text format by extension,
parses into `Vec<Task>`, and returns `Result<Vec<Task>, BacklogParseError>`
with a descriptive error for malformed JSON, plus `#[cfg(test)]` coverage for
valid JSON, valid plain text, and malformed-JSON rejection.

`src/briefing.rs` on `main` already has every piece of this, shipped by
**MISSION-089 itself** via PR #5235 (commit `fd5a8908c`, same gap ID — the
gap was never closed in `state.db` even though the branch merged):

1. **`Task` struct + `BacklogParseError` enum** (`Io` / `MalformedJson`
   variants) — present verbatim, with a `Display`/`Error` impl on the error
   type.
2. **`pub fn parse_backlog_file(path: &Path) -> Result<Vec<Task>,
   BacklogParseError>`** — detects `.json` by extension, parses a JSON array
   or `{"tasks": [...]}` wrapper for JSON, falls back to one-task-per-line
   for plain text, and returns `MalformedJson` (message containing
   "malformed") on bad JSON.
3. **Test coverage** — `parse_backlog_file_valid_beast_mode_json`,
   `parse_backlog_file_valid_plain_text`, and
   `parse_backlog_file_malformed_json_rejected` cover all three ACs.
4. **Public, no extra imports needed** — the function and its types are
   `pub` at the top level of `briefing.rs`, callable as
   `briefing::parse_backlog_file`.

Closing MISSION-089 rather than re-landing a second copy of the same
function in the same file — the registry record (`state.db`) just hadn't
been marked closed after PR #5235 merged.

## Re-closure (third time, 2026-10-10)

The gap resurfaced again as a fresh claim-and-dispatch (`chump gap preflight`
reported it as "open and unclaimed" after re-syncing from `state.sql`), even
though it had already been closed twice before (PR #5235's own close, then
PR #5237's duplicate-closure note above). `src/briefing.rs` is unchanged
since the last closure — `parse_backlog_file`, `Task`, `BacklogParseError`,
and all three required tests are still present verbatim at the lines cited
above. No code change needed; closing again with the same rationale.
