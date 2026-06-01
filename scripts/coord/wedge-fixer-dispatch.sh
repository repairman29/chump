#!/usr/bin/env bash
# wedge-fixer-dispatch.sh — INFRA-2069
#
# Operator-facing manual dispatcher for the wedge-fixer template library.
# Renders a prompt template from wedge-fixer-templates.yaml and prints
# the rendered prompt that the operator can paste into the Agent tool
# (or that INFRA-2068 will auto-feed once that gap ships).
#
# Usage:
#   wedge-fixer-dispatch.sh --gap <ID> --template <name> [OPTIONS]
#
# Options:
#   --gap <ID>           Gap identifier (e.g. INFRA-2069)
#   --template <name>    Template name: fmt-drift | orphan-event | printf-grep
#   --dry-run            Print rendered prompt only, do NOT emit ambient event (default)
#   --execute            Emit ambient event kind=wedge_fixer_template_rendered
#   --event-kind <kind>  For orphan-event template: the event kind name
#   --violation-file <f> For printf-grep template: the file with violations
#   --worktree <path>    Override worktree path (default: auto-detected from chump claim)
#   --template-file <f>  Override template library path (default: scripts/coord/wedge-fixer-templates.yaml)
#   --help               Show this help
#
# Status: AC #2 / INFRA-2069. Manual dispatcher only.
# Auto-dispatch (consume kind=wedge_class_detected → auto-render-and-dispatch) is
# deferred to the follow-up PR that ships once INFRA-2068 lands.
#
# ambient event: kind=wedge_fixer_template_rendered (--execute only)
#   fields: template_name, gap_id, dry_run

set -euo pipefail

# ── locate repo root ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR/../..")"

# ── defaults ──────────────────────────────────────────────────────────────────
GAP_ID=""
TEMPLATE_NAME=""
DRY_RUN=true
EVENT_KIND=""
VIOLATION_FILE=""
WORKTREE_OVERRIDE=""
TEMPLATE_FILE="${REPO_ROOT}/scripts/coord/wedge-fixer-templates.yaml"
SHOW_HELP=false

# ── arg parse ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gap)        GAP_ID="$2";          shift 2 ;;
    --template)   TEMPLATE_NAME="$2";   shift 2 ;;
    --dry-run)    DRY_RUN=true;         shift   ;;
    --execute)    DRY_RUN=false;        shift   ;;
    --event-kind) EVENT_KIND="$2";      shift 2 ;;
    --violation-file) VIOLATION_FILE="$2"; shift 2 ;;
    --worktree)   WORKTREE_OVERRIDE="$2"; shift 2 ;;
    --template-file) TEMPLATE_FILE="$2"; shift 2 ;;
    --help|-h)    SHOW_HELP=true;       shift   ;;
    *) echo "[wedge-fixer-dispatch] unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── help ─────────────────────────────────────────────────────────────────────
if [[ "$SHOW_HELP" == "true" ]]; then
  grep '^#' "$0" | sed 's/^# \?//' | head -30
  exit 0
fi

# ── validation ───────────────────────────────────────────────────────────────
if [[ -z "$GAP_ID" ]]; then
  echo "[wedge-fixer-dispatch] ERROR: --gap <ID> is required" >&2
  exit 1
fi

if [[ -z "$TEMPLATE_NAME" ]]; then
  echo "[wedge-fixer-dispatch] ERROR: --template <name> is required" >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "[wedge-fixer-dispatch] ERROR: template file not found: $TEMPLATE_FILE" >&2
  exit 1
fi

# ── resolve worktree path ─────────────────────────────────────────────────────
if [[ -n "$WORKTREE_OVERRIDE" ]]; then
  WORKTREE_PATH="$WORKTREE_OVERRIDE"
else
  # Try to detect from active claim lease
  GAP_LOWER="${GAP_ID,,}"            # e.g. INFRA-2069 → infra-2069
  GAP_HYPHEN="${GAP_LOWER//_/-}"    # normalize underscores to hyphens
  CANDIDATE="/tmp/chump-${GAP_HYPHEN}"
  if [[ -d "$CANDIDATE" ]]; then
    WORKTREE_PATH="$CANDIDATE"
  else
    # Fall back to repo root (for --dry-run use cases)
    WORKTREE_PATH="$REPO_ROOT"
  fi
fi

# ── extract template from YAML ────────────────────────────────────────────────
# We use python3 (available on macOS dev machines) to parse the YAML safely.
RENDERED_PROMPT="$(python3 - "$TEMPLATE_FILE" "$TEMPLATE_NAME" <<'PYEOF'
import sys, yaml, re, os

template_file = sys.argv[1]
template_name = sys.argv[2]

with open(template_file) as f:
    data = yaml.safe_load(f)

templates = data.get("templates", [])
match = next((t for t in templates if t.get("template_name") == template_name), None)

if not match:
    known = [t.get("template_name", "?") for t in templates]
    print(f"ERROR: template '{template_name}' not found. Known templates: {known}", file=sys.stderr)
    sys.exit(1)

prompt = match.get("prompt_template", "")
print(prompt, end="")
PYEOF
)"

if [[ $? -ne 0 ]]; then
  echo "[wedge-fixer-dispatch] ERROR: failed to extract template '$TEMPLATE_NAME'" >&2
  exit 1
fi

# ── render placeholders ───────────────────────────────────────────────────────
# Replace well-known placeholders with resolved values
RENDERED_PROMPT="${RENDERED_PROMPT//\{\{GAP_ID\}\}/$GAP_ID}"
RENDERED_PROMPT="${RENDERED_PROMPT//\{\{WORKTREE_PATH\}\}/$WORKTREE_PATH}"

if [[ -n "$EVENT_KIND" ]]; then
  RENDERED_PROMPT="${RENDERED_PROMPT//\{\{EVENT_KIND\}\}/$EVENT_KIND}"
fi

if [[ -n "$VIOLATION_FILE" ]]; then
  RENDERED_PROMPT="${RENDERED_PROMPT//\{\{VIOLATION_FILE\}\}/$VIOLATION_FILE}"
fi

# ── check for unresolved placeholders ────────────────────────────────────────
UNRESOLVED="$(echo "$RENDERED_PROMPT" | grep -oE '\{\{[A-Z_]+\}\}' | sort -u || true)"
if [[ -n "$UNRESOLVED" ]]; then
  echo "[wedge-fixer-dispatch] ERROR: unresolved placeholders in rendered prompt:" >&2
  echo "$UNRESOLVED" >&2
  echo "" >&2
  echo "Hints:" >&2
  echo "  orphan-event template requires: --event-kind <kind>" >&2
  echo "  printf-grep template requires:  --violation-file <file>" >&2
  exit 1
fi

# ── output ────────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════════"
echo " wedge-fixer-dispatch — template: $TEMPLATE_NAME | gap: $GAP_ID"
if [[ "$DRY_RUN" == "true" ]]; then
  echo " mode: DRY-RUN (--execute to emit ambient event)"
else
  echo " mode: EXECUTE (will emit kind=wedge_fixer_template_rendered)"
fi
echo "═══════════════════════════════════════════════════════════════════════"
echo ""
echo "$RENDERED_PROMPT"
echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo " Paste the prompt above into a Sonnet Agent tool invocation."
echo " (Auto-dispatch deferred to follow-up PR after INFRA-2068 lands.)"
echo "═══════════════════════════════════════════════════════════════════════"

# ── emit ambient event (--execute only) ───────────────────────────────────────
if [[ "$DRY_RUN" == "false" ]]; then
  AMBIENT_LOG="${REPO_ROOT}/.chump-locks/ambient.jsonl"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # SCANNER-ANCHOR: kind=wedge_fixer_template_rendered
  printf '{"ts":"%s","kind":"wedge_fixer_template_rendered","template_name":"%s","gap_id":"%s","dry_run":false}\n' \
    "$TS" "$TEMPLATE_NAME" "$GAP_ID" >> "$AMBIENT_LOG"
  echo "[wedge-fixer-dispatch] emitted kind=wedge_fixer_template_rendered to ambient.jsonl"
fi
