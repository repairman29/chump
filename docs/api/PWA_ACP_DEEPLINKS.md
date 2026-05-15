---
doc_tag: canonical
owner_gap: PRODUCT-110
last_audited: 2026-05-14
---

# PWA ACP deeplinks

Chump's PWA renders `chump://acp/open?...` deeplinks on every gap row and
PR card. These links are intercepted by a registered ACP client on the
operator's machine — Zed, JetBrains, or any other editor that has the
`chump-acp` integration installed — and open the relevant context inside
that editor.

This is the **competitive-differentiation surface** vs Claude Code. CC
structurally can't ship deeplinks into arbitrary editors because it's
locked to its own REPL.

## URL schema

Base: `chump://acp/open`

Query parameters (all optional, all additive):

| Param | Type | Meaning |
|-------|------|---------|
| `gap` | string | Gap ID (e.g. `INFRA-1197`). When present, the editor should open the gap's worktree and surface the gap's AC in a side panel. |
| `pr` | int | PR number. When present, the editor should check out the PR branch and present the diff. |
| `branch` | string | Branch name. When present, the editor should switch to that branch. |
| `worktree` | string | Absolute path to a worktree directory. When present, takes precedence over `gap`-derived worktree resolution. |
| `file` | string | Relative file path within the worktree. When present, the editor should open that file at the top. |
| `line` | int | Line number. Pairs with `file` to position the cursor. |

Examples:

```
chump://acp/open?gap=INFRA-1197
chump://acp/open?pr=1934
chump://acp/open?branch=chump/infra-1197-claim
chump://acp/open?gap=INFRA-1197&file=src/web_server.rs&line=3053
chump://acp/open?worktree=/private/tmp/chump-infra-1197&file=docs/api/WEB_API_REFERENCE.md
```

## Where the PWA surfaces them

- Every gap card in the queue view (`<chump-view-agent>` row template)
  carries an **Open in editor ↗** link with `?gap=<id>` and a **Copy link**
  button.
- Every PR row (via `<chump-pr-card>`) carries an **Open PR in editor** link
  with `?pr=<n>` (future — when INFRA-1011 PR card is updated to consume
  this contract; currently the queue-row coverage is the primary surface).
- The status footer (PRODUCT-107) does not link to ACP today; future
  per-slot drill-ins may.

## JS API

```js
// window.ChumpAcpDeeplink — IIFE helper.
window.ChumpAcpDeeplink.gap('INFRA-1197')
  // → "chump://acp/open?gap=INFRA-1197"

window.ChumpAcpDeeplink.pr(1934, { file: 'src/foo.rs', line: 42 })
  // → "chump://acp/open?pr=1934&file=src/foo.rs&line=42"

window.ChumpAcpDeeplink.branch('chump/infra-1275-claim')
  // → "chump://acp/open?branch=chump/infra-1275-claim"

window.ChumpAcpDeeplink.open({ worktree: '/tmp/foo', file: 'README.md' })
  // → "chump://acp/open?worktree=%2Ftmp%2Ffoo&file=README.md"
```

All four return strings; the caller decides whether to render as an `<a>`,
put on the clipboard, or post-message to a peer tab.

## Behavior when no ACP client is registered

The `chump://` URL scheme is registered by the editor at install time. If
no editor has claimed the handler, clicking the link is a no-op in most
browsers (Safari may pop a warning dialog, Chrome silently does nothing).

For that case, the PWA always offers a **Copy link** button next to the
**Open in editor ↗** link. Operators can copy the URL and:

- Paste into a peer's chat to share a debugging context
- Paste into a terminal to invoke `chump-acp-handler "<url>"` manually
- Bookmark for later (the URL embeds gap/PR/branch state)

In a future enhancement, `/api/acp/health` will expose registered-client
state and the PWA will tooltip-warn before the operator's first click on
an unregistered system. That endpoint is filed as a follow-up.

## Telemetry

Every click on a `.gap-acp-link` or `.gap-acp-copy` button emits an
ambient event via `navigator.sendBeacon`:

```json
{
  "kind": "acp_deeplink_emitted",
  "target_kind": "gap" | "pr" | "branch" | "copy",
  "target_id": "<gap_id | pr_num | branch_name>",
  "client_detected": "unknown" | true | false,
  "ts": "2026-05-14T22:30:00Z"
}
```

The `client_detected` field is `"unknown"` for the link click (the browser
doesn't tell us whether a handler matched), `true | false` for the copy
button (based on `navigator.clipboard` availability).

Use the leaderboard at `scripts/dev/api-cost-leaderboard.sh` or grep
`ambient.jsonl` to measure adoption.

## Security

- `chump://acp/open` is a custom URL scheme. The operating system routes
  it to the registered handler. There is no automatic execution path:
  the editor must explicitly process the params before any action.
- The PWA URL-encodes all query values via `URLSearchParams`, so no
  injection risk from gap IDs or branch names that contain `&` / `=` / `#`.
- Worktree paths in `worktree=` are passed through as opaque strings. The
  editor must sanity-check them (e.g. inside `/tmp/chump-*` or
  `~/.chump/worktrees/*`) before acting.

## Future work

- `/api/acp/health` endpoint reporting registered clients
- PR card (`<chump-pr-card>`) gains a deeplink row
- Workflow timeline can include deeplinks to the worktree at each phase
- Status footer click can deeplink the model slot to provider settings in
  the editor
