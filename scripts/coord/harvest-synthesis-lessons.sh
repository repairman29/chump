#!/usr/bin/env bash
# Extract operational lessons from a synthesis document and write them into
# chump_improvement_targets so prompt_assembler.rs surfaces them automatically.
#
# Usage: ./scripts/coord/harvest-synthesis-lessons.sh <synthesis.md> [CHUMP_HOME]
#   CHUMP_HARVEST_LESSONS=0  — skip silently (no-op).
#
# Reads:  docs/syntheses/YYYY-MM-DD.md  (section 3: Methodology lessons)
# Writes: chump_improvement_targets rows (priority=high, scope=NULL / universal)
#         chump_reflections parent row  (error_pattern='synthesis:<date>')
#
# Cap: 3 lessons per synthesis, matching the LESSONS_LIMIT=5 headroom in
# prompt_assembler.rs. Idempotent: skips if this synthesis date already harvested.
set -euo pipefail

SYNTH_FILE="${1:-}"
ROOT="${2:-${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}}"
DB="$ROOT/sessions/chump_memory.db"

if [[ "${CHUMP_HARVEST_LESSONS:-1}" == "0" ]]; then
  echo "[harvest-synthesis-lessons] disabled via CHUMP_HARVEST_LESSONS=0" >&2
  exit 0
fi

if [[ -z "$SYNTH_FILE" ]]; then
  echo "Usage: $0 <synthesis.md> [CHUMP_HOME]" >&2
  exit 1
fi
if [[ ! -f "$SYNTH_FILE" ]]; then
  echo "[harvest-synthesis-lessons] synthesis file not found: $SYNTH_FILE" >&2
  exit 1
fi
if [[ ! -f "$DB" ]]; then
  echo "[harvest-synthesis-lessons] DB not found: $DB" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[harvest-synthesis-lessons] python3 not found — skipping lesson harvest" >&2
  exit 0
fi

python3 - "$SYNTH_FILE" "$DB" <<'PYEOF'
import sys, re, sqlite3, os

synth_file = sys.argv[1]
db_path = sys.argv[2]

text = open(synth_file, encoding='utf-8', errors='replace').read()
stamp = os.path.basename(synth_file).replace('.md', '')

conn = sqlite3.connect(db_path)

# Idempotent: skip if already harvested for this date
existing = conn.execute(
    "SELECT COUNT(*) FROM chump_reflections WHERE error_pattern = ?",
    (f"synthesis:{stamp}",)
).fetchone()[0]
if existing > 0:
    print(f"[harvest-synthesis-lessons] {stamp} already harvested — skipping", file=sys.stderr)
    sys.exit(0)

# Extract any "## [N.] Methodology lessons" section (up to the next "## " heading)
m = re.search(
    r'##\s+(?:\d+\.\s+)?Methodology lessons[^\n]*\n+(.*?)(?=\n##\s+|\Z)',
    text, re.DOTALL | re.IGNORECASE
)
if not m:
    print(f"[harvest-synthesis-lessons] no '## 3. Methodology lessons' section found in {stamp}", file=sys.stderr)
    sys.exit(0)

lessons_text = m.group(1)

# Extract "### Title\n\nbody" pairs — these are the hard-won operational rules
entries = re.findall(
    r'###\s+(.+?)\n+(.*?)(?=\n###\s+|\Z)',
    lessons_text, re.DOTALL
)
# Also check for a "#### Operational rules" subsection and pull bullet items from it
ops_match = re.search(
    r'####\s+Operational rules[^\n]*\n+(.*?)(?=\n##|\n###|\Z)',
    lessons_text, re.DOTALL | re.IGNORECASE
)
op_rules = []
if ops_match:
    for line in ops_match.group(1).splitlines():
        line = line.strip().lstrip('-*•').strip()
        if len(line) > 10:
            op_rules.append(line)

if not entries and not op_rules:
    print(f"[harvest-synthesis-lessons] no lessons found to harvest from {stamp}", file=sys.stderr)
    sys.exit(0)

# Insert parent reflection so the NOT IN ab_seed filter keeps these rows visible
cur = conn.execute(
    "INSERT INTO chump_reflections "
    "(intended_goal, observed_outcome, outcome_class, error_pattern, hypothesis) "
    "VALUES (?, 'harvested', 'synthesis', ?, ?)",
    (
        f"Sprint synthesis {stamp}",
        f"synthesis:{stamp}",
        f"Operational lessons extracted from {stamp} synthesis",
    )
)
reflection_id = cur.lastrowid

count = 0

# Insert up to 3 named lessons (### headings) — cap keeps total within LESSONS_LIMIT=5
for title, body in entries[:3]:
    title = title.strip()
    clean = ' '.join(body.strip().split())[:280]
    directive = f"{title}: {clean}" if clean else title
    conn.execute(
        "INSERT INTO chump_improvement_targets "
        "(reflection_id, directive, priority, scope) VALUES (?, ?, 'high', NULL)",
        (reflection_id, directive[:300])
    )
    count += 1

# If fewer than 3 named lessons, fill from operational rules bullets
for rule in op_rules:
    if count >= 3:
        break
    conn.execute(
        "INSERT INTO chump_improvement_targets "
        "(reflection_id, directive, priority, scope) VALUES (?, ?, 'high', NULL)",
        (reflection_id, rule[:300])
    )
    count += 1

conn.commit()
print(f"[harvest-synthesis-lessons] harvested {count} lesson(s) from {stamp}", file=sys.stderr)
PYEOF
