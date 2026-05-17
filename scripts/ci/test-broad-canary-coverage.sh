#!/usr/bin/env bash
# test-broad-canary-coverage.sh — INFRA-1568
#
# Coverage smoke: asserts the broad canary script
# (scripts/setup/test-runner-lane-broad-canary.sh) exercises every external
# CLI that any self-hosted-targeted workflow step depends on.
#
# Why this exists (CREDIBLE pillar):
#   When a contributor adds a workflow step that calls a new external CLI
#   (e.g. `gh`, `jq`, `python3`, a new homebrew tool) on a self-hosted job,
#   the runner lane may pass the previous canary while the new CLI is
#   missing from the runner's PATH and the production step silently fails.
#   This smoke closes the "canary too narrow" regression hole structurally:
#   any new external CLI invoked in a self-hosted-targeted workflow step
#   MUST be exercised somewhere in the canary script's command surface, or
#   this gate exits 1.
#
# Discovery (auto-discoverable per AC #5):
#   1. Find every workflow job whose `runs-on:` references self-hosted
#      routing (`self-hosted`, `CHUMP_SELF_HOSTED_ENABLED`, or `RUNNER_*`).
#   2. Within those jobs, parse every `run:` block and extract the leading
#      command tokens — these are the external CLIs the step invokes.
#   3. Compare against the canary script's text. A CLI is "covered" if it
#      appears either in the canary's text or in the explicit allowlist
#      (system binaries like `bash`, `cd`, etc.).
#
# Exit codes:
#   0 = every external CLI in a self-hosted-targeted step is covered
#   1 = at least one CLI is missing; the offending CLIs are listed
#   2 = arg/usage error
#
# Rust-First-Bypass: linter shell over `grep|awk|python3` parsing of YAML;
# pure glue, no canonical-state mutation. Per META-064 shell-OK criteria.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

WORKFLOWS_DIR=".github/workflows"
CANARY="scripts/setup/test-runner-lane-broad-canary.sh"

if [ ! -f "$CANARY" ]; then
  echo "FAIL: broad canary script missing: $CANARY" >&2
  exit 1
fi
if [ ! -d "$WORKFLOWS_DIR" ]; then
  echo "FAIL: workflows dir missing: $WORKFLOWS_DIR" >&2
  exit 1
fi

# Allowlist of universally-available CLIs / shell builtins / control words
# that don't need explicit canary coverage. Anything NOT in here that appears
# as a leading run-step token gets compared to the canary surface.
ALLOWLIST=(
  # Shell builtins / control flow
  bash sh set source export cd test if then else elif fi for while do done
  echo printf true false exit return read eval source case esac in
  let local declare shift trap unset shopt umask wait time exec
  break continue function getopts mapfile readarray pushd popd dirs
  # Coreutils (always present on any UNIX runner)
  ls cat head tail grep sed awk cut tr sort uniq wc find xargs mkdir rmdir
  mv cp rm touch chmod chown ln readlink dirname basename realpath
  date env which command type pwd df du tee diff cmp
  sleep kill killall seq stat file md5sum sha256sum md5 shasum
  # CI primitives present on every runner image
  sudo apt-get apt brew curl wget tar gzip gunzip unzip
  # Allowlist for guard scripts written in pure bash — the canary doesn't
  # need to reimplement each guard; it just needs to invoke the binaries.
  npm node yarn npx pnpm
  # Python-heredoc keywords / common identifiers that leak through CLI
  # extraction when a step embeds inline Python via `python3 - <<'PY'`.
  # These are NOT external CLIs; they're language tokens.
  import from as try except finally raise with class def return pass
  yield lambda global nonlocal assert del is not and or None True False
  print type str int float list dict set tuple bool open input range
  len abs min max sum any all sorted enumerate zip map filter
  # Tauri/Linux-only build deps — only invoked on the apt-get install line,
  # which is itself gated by `if: runner.os == 'Linux'`. They never run on
  # the self-hosted macOS lane (INFRA-1542 cross-platform gating).
  build-essential pkg-config libssl-dev libgtk-3-dev librsvg2-dev
  libwebkit2gtk-4.1-dev libayatana-appindicator3-dev webkit2gtk-4.1
  webkit2gtk-driver util-linux xvfb xvfb-run
)

# CLIs the canary script needs to exercise. These get extracted from the
# canary text (or matched against allowlist). When a workflow step calls a
# CLI that isn't (allowlisted OR present in canary text), the smoke fails.
canary_text() {
  cat "$CANARY"
}

is_allowlisted() {
  local cli="$1"
  for a in "${ALLOWLIST[@]}"; do
    [ "$a" = "$cli" ] && return 0
  done
  return 1
}

canary_blob="$(canary_text)"

is_covered() {
  local cli="$1"
  # Exact word-boundary match in canary text.
  if echo "$canary_blob" | grep -qwE "$(printf '%s' "$cli" | sed -E 's/[][\.|$(){}?+*^]/\\&/g')"; then
    return 0
  fi
  return 1
}

# Extract every external CLI from self-hosted-targeted job `run:` blocks.
extract_cli_invocations() {
  python3 - <<'PY'
import os, re, sys

wf_dir = ".github/workflows"
selfhosted_indicators = ("self-hosted", "CHUMP_SELF_HOSTED_ENABLED", "RUNNER_")

def is_self_hosted_runs_on(line: str) -> bool:
    return any(tok in line for tok in selfhosted_indicators)

# Extract leading CLI tokens from a command line. Skips env-var-prefixes
# (FOO=bar baz → baz), pipes (a | b → both a and b), and subshell wrappers.
# Also: skips lines that are clearly shell-variable-assignment-only,
# heredoc-marker lines, and apt-get install argument lists.
def strip_quoted(s: str) -> str:
    """Replace contents of single- and double-quoted strings with spaces so
    embedded shell-metachars (especially `|` inside regex args) don't split
    a command line."""
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c in ("'", '"'):
            quote = c
            out.append(" ")
            i += 1
            while i < len(s) and s[i] != quote:
                out.append(" ")
                i += 1
            if i < len(s):
                out.append(" ")
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)

def clis_from_line(s: str):
    s = s.strip()
    if not s or s.startswith("#"):
        return
    # Skip pure variable assignment lines.
    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", s) and not re.search(r"\s\S", s.split("=", 1)[1] if "=" in s else ""):
        return
    # Skip lines that are obviously inside-an-apt-get-install argument list
    # (continuation lines). We can't see context here, so use a heuristic:
    # the line is a single bare word with optional trailing backslash.
    if re.match(r"^\\?\s*[a-zA-Z0-9._+-]+\s*\\?$", s) and "/" not in s:
        return
    # Skip heredoc end markers and known marker tokens.
    if re.match(r"^[A-Z]+$", s) and len(s) <= 8:
        return
    # Split on logical separators that introduce a new command — but only
    # when not inside a quoted string. Strip quoted regions first.
    s_for_split = strip_quoted(s)
    for chunk in re.split(r"[|;&]+|\$\(|\)|`", s_for_split):
        chunk = chunk.strip()
        if not chunk:
            continue
        tokens = chunk.split()
        # Drop leading env-var assignments (FOO=bar BAZ=qux cmd ...).
        while tokens and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
            tokens.pop(0)
        if not tokens:
            continue
        first = tokens[0]
        # Path-stripped binary name.
        if "/" in first:
            first = first.rsplit("/", 1)[-1]
        first = first.strip("\"'")
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_.+-]*$", first):
            continue
        # Skip tokens that look like shell variables ($foo), heredoc names,
        # or all-caps env vars (those are typically env-only).
        if first.startswith("$"):
            continue
        yield first

out = set()
for fname in sorted(os.listdir(wf_dir)):
    if not fname.endswith(".yml"):
        continue
    path = os.path.join(wf_dir, fname)
    with open(path) as f:
        lines = f.readlines()
    current_job = None
    job_is_selfhosted = False
    current_step_name = "(unnamed)"
    in_run_block = False
    run_block_indent = None
    # Track heredoc state within a run block — we don't want to extract CLIs
    # from inline python/perl/awk bodies like `python3 - <<'PY'`.
    heredoc_marker = None
    # Track apt-get install continuation lines (lines that are pure package
    # names inside an `apt-get install -y \` continuation).
    in_apt_install = False
    for i, raw in enumerate(lines):
        line = raw.rstrip("\n")
        m = re.match(r"^(  )([a-zA-Z0-9_-]+):\s*$", line)
        if m:
            current_job = m.group(2)
            job_is_selfhosted = False
            current_step_name = "(unnamed)"
            in_run_block = False
            continue
        if current_job and re.match(r"^\s*runs-on:", line):
            if is_self_hosted_runs_on(line):
                job_is_selfhosted = True
        if not (current_job and job_is_selfhosted):
            continue
        m = re.match(r"^\s*-\s*name:\s*(.+?)\s*$", line)
        if m:
            current_step_name = m.group(1).strip().strip('"').strip("'")
            in_run_block = False
            continue
        m = re.match(r"^(\s*)run:\s*\|?\s*(.*)$", line)
        if m:
            run_block_indent = len(m.group(1))
            inline = m.group(2)
            if inline.strip():
                for cli in clis_from_line(inline):
                    out.add((fname, current_job, current_step_name, cli))
                in_run_block = False
            else:
                in_run_block = True
            continue
        if in_run_block:
            indent = len(line) - len(line.lstrip())
            if line.strip() and indent <= run_block_indent:
                in_run_block = False
                heredoc_marker = None
                in_apt_install = False
                continue
            stripped = line.strip()
            # Heredoc tracking: when we see `<<'MARKER'` or `<<MARKER` or
            # `<<-MARKER`, skip lines until we see the closing MARKER.
            if heredoc_marker is not None:
                if stripped == heredoc_marker:
                    heredoc_marker = None
                continue
            hm = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", stripped)
            if hm:
                heredoc_marker = hm.group(1)
                # Still process the launching line itself (it contains the CLI).
                for cli in clis_from_line(stripped):
                    out.add((fname, current_job, current_step_name, cli))
                continue
            # apt-get install continuation tracking: when a previous line
            # ended with backslash and started with `apt-get install`, skip
            # subsequent bare-word continuation lines.
            if in_apt_install:
                if not stripped.endswith("\\"):
                    in_apt_install = False
                continue
            if re.search(r"\bapt(-get)?\s+install\b", stripped) and stripped.endswith("\\"):
                in_apt_install = True
                for cli in clis_from_line(stripped):
                    out.add((fname, current_job, current_step_name, cli))
                continue
            for cli in clis_from_line(line):
                out.add((fname, current_job, current_step_name, cli))

for wf, job, step, cli in sorted(out):
    print(f"{wf}\t{job}\t{step}\t{cli}")
PY
}

MISSING_FILE="$(mktemp -t broad-canary-missing.XXXXXX)"
trap 'rm -f "$MISSING_FILE"' EXIT
SEEN_FILE="$(mktemp -t broad-canary-seen.XXXXXX)"
trap 'rm -f "$MISSING_FILE" "$SEEN_FILE"' EXIT

while IFS=$'\t' read -r wf job step cli; do
  [ -z "${cli:-}" ] && continue
  if is_allowlisted "$cli"; then continue; fi
  if is_covered "$cli"; then continue; fi
  if grep -Fxq "$cli" "$SEEN_FILE" 2>/dev/null; then continue; fi
  echo "$cli" >> "$SEEN_FILE"
  printf '%s\t%s::%s::%s\n' "$cli" "$wf" "$job" "$step" >> "$MISSING_FILE"
done < <(extract_cli_invocations)

MISSING_COUNT=$(wc -l < "$MISSING_FILE" | tr -d ' ')

if [ "$MISSING_COUNT" -gt 0 ]; then
  echo "FAIL: broad-canary coverage gap — $MISSING_COUNT external CLI(s) invoked by self-hosted-targeted workflow steps are not exercised by $CANARY:" >&2
  while IFS=$'\t' read -r cli src; do
    printf "  - %s  (first seen in %s)\n" "$cli" "$src" >&2
  done < "$MISSING_FILE"
  echo "" >&2
  echo "Fix one of:" >&2
  echo "  (a) Add a register_step line to $CANARY that exercises the CLI on the lane, OR" >&2
  echo "  (b) If the CLI is universally-available, add it to the ALLOWLIST in $0." >&2
  echo "" >&2
  echo "Rationale: a new external CLI on a self-hosted lane is a runner-env regression" >&2
  echo "risk (INFRA-1556 chump-PATH pattern). The canary catches it upfront." >&2
  exit 1
fi

echo "OK: every external CLI invoked by self-hosted-targeted workflow steps is exercised by the broad canary."
exit 0
