#!/usr/bin/env bash
# score-closed-eval-gaps.sh — INFRA-091
#
# Score every closed EVAL-* / RESEARCH-* gap against the methodology table
# in docs/process/RESEARCH_INTEGRITY.md. Pre-commit guards (INFRA-079,
# INFRA-113) catch violations at close time, but they only enforce going
# forward. This script provides retroactive coverage so Cold Water's
# Reality Check lens can drop its hand-checking and the team can see
# methodology drift across the whole closed-gap corpus at a glance.
#
# Usage:
#   scripts/eval/score-closed-eval-gaps.sh                    # all closed EVAL+RESEARCH
#   scripts/eval/score-closed-eval-gaps.sh --since 2026-04-01 # only gaps closed after date
#   scripts/eval/score-closed-eval-gaps.sh --gap EVAL-095     # one gap
#   scripts/eval/score-closed-eval-gaps.sh --json             # machine-readable JSONL
#
# Output: markdown report to stdout (default) or JSONL with --json.
# Each row scores against the five RESEARCH_INTEGRITY methodology criteria:
#   1. Sample size n>=50 (≥100 for ship-or-cut decisions)
#   2. Judge diversity (cross-judge audit OR waiver OR single-judge prereg)
#   3. A/A baseline run referenced
#   4. Mechanism analysis when |delta| > 0.05
#   5. No prohibited claims in the result doc
#
# Cold Water consumption: writes also to .chump/eval-methodology-scores.md
# so the lens can read it directly.
#
# Exit codes:
#   0  — script ran (regardless of how many gaps failed scoring)
#   1  — script error (bad args, missing files)

set -euo pipefail

SINCE_DATE=""
GAP_FILTER=""
JSON_OUTPUT=0
WRITE_COLD_WATER=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) SINCE_DATE="$2"; shift 2 ;;
        --gap)   GAP_FILTER="$2"; shift 2 ;;
        --json)  JSON_OUTPUT=1; shift ;;
        --no-cold-water) WRITE_COLD_WATER=0; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

INTEGRITY_DOC="docs/process/RESEARCH_INTEGRITY.md"
GAPS_DIR="docs/gaps"
EVAL_DOCS_DIR="docs/eval"
COLD_WATER_OUT="$REPO_ROOT/.chump/eval-methodology-scores.md"

[[ -f "$INTEGRITY_DOC" ]] || { echo "missing $INTEGRITY_DOC" >&2; exit 1; }
[[ -d "$GAPS_DIR" ]]      || { echo "missing $GAPS_DIR (per-file gap registry; INFRA-188)" >&2; exit 1; }

# Pre-extract the prohibited-claims phrases so python doesn't re-parse the
# whole integrity doc per gap. Pull from the markdown table; one phrase per
# line, lowercased for case-insensitive match.
PROHIBITED_FILE="$(mktemp -t prohibited-claims.XXXXXX)"
trap 'rm -f "$PROHIBITED_FILE"' EXIT
awk '
    /^## Prohibited Claims/ { in_section=1; next }
    in_section && /^## / && !/^## Prohibited/ { in_section=0 }
    in_section && /^\| "/ {
        # extract text between first quotes
        match($0, /"[^"]+"/)
        if (RSTART > 0) {
            phrase = substr($0, RSTART+1, RLENGTH-2)
            print tolower(phrase)
        }
    }
' "$INTEGRITY_DOC" > "$PROHIBITED_FILE"

python3 - "$GAPS_DIR" "$EVAL_DOCS_DIR" "$SINCE_DATE" "$GAP_FILTER" "$JSON_OUTPUT" "$PROHIBITED_FILE" "$COLD_WATER_OUT" "$WRITE_COLD_WATER" <<'PYEOF'
import os, sys, re, glob, json, datetime

gaps_dir, docs_dir, since_date, gap_filter, json_out_s, prohibited_file, cold_water_out, write_cold_water_s = sys.argv[1:9]
json_out = json_out_s == "1"
write_cold_water = write_cold_water_s == "1"

with open(prohibited_file) as f:
    prohibited = [line.strip() for line in f if line.strip()]

def parse_gap(path):
    """Minimal YAML reader — enough for our flat gap files."""
    fields = {}
    cur_key = None
    cur_block = []
    with open(path) as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith("- id:"):
                fields["id"] = line.split(":", 1)[1].strip()
                cur_key = None
                continue
            if not line.startswith("  ") or line.startswith("    "):
                # block continuation OR sub-list item — flush block when we leave
                if cur_key and line.startswith("    "):
                    cur_block.append(line.strip())
                    continue
            if cur_key and cur_block:
                fields[cur_key] = "\n".join(cur_block).strip()
                cur_key = None
                cur_block = []
            m = re.match(r"^  ([a-z_][a-z_0-9]*):\s*(.*)$", line)
            if not m:
                continue
            k, v = m.group(1), m.group(2)
            if v in ("|", ">", "|-", ">-"):
                cur_key = k
                cur_block = []
            elif v == "":
                fields[k] = ""
            else:
                # strip surrounding quotes if any
                fields[k] = v.strip().strip("'").strip('"')
    if cur_key and cur_block:
        fields[cur_key] = "\n".join(cur_block).strip()
    return fields

def find_result_doc(gap_id):
    """Try canonical patterns for result doc."""
    candidates = sorted(glob.glob(f"{docs_dir}/{gap_id}-*.md")) + sorted(glob.glob(f"{docs_dir}/{gap_id}.md"))
    for c in candidates:
        if os.path.isfile(c):
            return c
    return None

def find_prereg(gap_id):
    p = f"{docs_dir}/preregistered/{gap_id}.md"
    return p if os.path.isfile(p) else None

# Load all closed EVAL-* / RESEARCH-* gaps from per-file registry
all_gaps = []
for path in sorted(glob.glob(f"{gaps_dir}/EVAL-*.yaml") + glob.glob(f"{gaps_dir}/RESEARCH-*.yaml")):
    g = parse_gap(path)
    if not g.get("id"):
        continue
    if gap_filter and g["id"] != gap_filter:
        continue
    if g.get("status") != "done":
        continue
    if since_date and g.get("closed_date","") < since_date:
        continue
    all_gaps.append(g)

def score_gap(g):
    """Return dict of per-criterion verdicts: ok | fail | n/a (+ note)."""
    gid = g["id"]
    res_doc = find_result_doc(gid)
    prereg = find_prereg(gid)
    res_text = open(res_doc).read() if res_doc else ""
    prereg_text = open(prereg).read() if prereg else ""
    haystack = (g.get("description","") + "\n" + g.get("notes","") + "\n" + res_text + "\n" + prereg_text).lower()

    out = {"id": gid, "closed_pr": g.get("closed_pr","-"), "closed_date": g.get("closed_date","-")}

    # 1) sample size n>=50 (>=100 for ship-or-cut)
    n_matches = re.findall(r"n[ =/]?(?:per[ -]?cell\s*[:=]?\s*)?(\d{1,4})", haystack)
    n_max = max((int(n) for n in n_matches if int(n) <= 5000), default=0)
    if n_max >= 100:
        out["sample_size"] = ("ok", f"n_max={n_max}")
    elif n_max >= 50:
        out["sample_size"] = ("ok", f"n_max={n_max} (directional bar)")
    elif n_max > 0:
        out["sample_size"] = ("fail", f"n_max={n_max} below 50")
    else:
        out["sample_size"] = ("n/a", "no n= found in artifacts")

    # 2) judge diversity
    has_cross = "cross_judge_audit" in haystack or re.search(r"cross[- ]judge", haystack)
    waived = "single_judge_waived" in haystack and "true" in haystack
    single_prereg = bool(prereg_text) and re.search(
        r"single[- ]judge\s+(scope|design|run|preregistration|study)", prereg_text.lower())
    if has_cross:
        out["judge_diversity"] = ("ok", "cross_judge_audit referenced")
    elif waived:
        out["judge_diversity"] = ("ok", "single_judge_waived (acknowledged)")
    elif single_prereg:
        out["judge_diversity"] = ("ok", "single-judge prereg declared")
    else:
        out["judge_diversity"] = ("fail", "no cross-judge / waiver / prereg declaration")

    # 3) A/A baseline
    if re.search(r"\baa[- ]?baseline|\ba/a\s+(baseline|run|delta)|aa[- ]?calibrate", haystack):
        out["aa_baseline"] = ("ok", "referenced")
    else:
        out["aa_baseline"] = ("fail", "no A/A reference")

    # 4) mechanism analysis if |delta| > 0.05
    deltas = re.findall(r"(?:delta|Δ)\s*=?\s*([+-]?\d*\.\d+)", haystack)
    delta_max = max((abs(float(d)) for d in deltas), default=0.0)
    if delta_max > 0.05:
        if re.search(r"mechanism|hypothesis|why\s+it\s+appears|explanation", haystack):
            out["mechanism"] = ("ok", f"|Δ|max={delta_max:.3f}, mechanism discussed")
        else:
            out["mechanism"] = ("fail", f"|Δ|max={delta_max:.3f} > 0.05 but no mechanism text")
    else:
        out["mechanism"] = ("n/a", f"|Δ|max={delta_max:.3f} ≤ 0.05")

    # 5) prohibited claims
    hits = [p for p in prohibited if p and p in haystack]
    if hits:
        out["prohibited_claims"] = ("fail", f"hits: {', '.join(hits[:3])}")
    else:
        out["prohibited_claims"] = ("ok", f"no hits ({len(prohibited)} phrases checked)")

    # Aggregate verdict
    fails = sum(1 for k, v in out.items() if isinstance(v, tuple) and v[0] == "fail")
    out["fails"] = fails
    out["overall"] = "PASS" if fails == 0 else f"FAIL ({fails})"
    out["result_doc"] = res_doc or "(missing)"
    return out

results = [score_gap(g) for g in all_gaps]

if json_out:
    for r in results:
        # Flatten tuples for JSON
        flat = {}
        for k, v in r.items():
            flat[k] = list(v) if isinstance(v, tuple) else v
        print(json.dumps(flat))
else:
    def emit(out_stream):
        out_stream.write(f"# Closed EVAL/RESEARCH methodology scorecard\n\n")
        out_stream.write(f"_Generated by scripts/eval/score-closed-eval-gaps.sh on {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}_\n\n")
        out_stream.write(f"Scored {len(results)} closed gap(s) against `docs/process/RESEARCH_INTEGRITY.md` "
                         f"§Required Methodology Standards.\n\n")
        n_pass = sum(1 for r in results if r["fails"] == 0)
        n_fail = len(results) - n_pass
        out_stream.write(f"**Summary:** {n_pass} pass / {n_fail} fail / {len(results)} total\n\n")
        out_stream.write("| Gap | Closed PR | n | Judge | A/A | Mech | Prohibited | Overall |\n")
        out_stream.write("|---|---|---|---|---|---|---|---|\n")
        emoji = {"ok": "✅", "fail": "❌", "n/a": "—"}
        for r in results:
            row = [
                r["id"],
                str(r.get("closed_pr","-")),
                emoji[r["sample_size"][0]],
                emoji[r["judge_diversity"][0]],
                emoji[r["aa_baseline"][0]],
                emoji[r["mechanism"][0]],
                emoji[r["prohibited_claims"][0]],
                r["overall"],
            ]
            out_stream.write("| " + " | ".join(row) + " |\n")
        out_stream.write("\n## Per-gap detail (failures + non-trivial passes)\n\n")
        for r in results:
            if r["fails"] == 0 and r["mechanism"][0] == "n/a":
                continue  # skip trivial pass + no-delta cases to keep readable
            out_stream.write(f"### {r['id']}  closed_pr={r.get('closed_pr','-')}  ({r['overall']})\n")
            out_stream.write(f"  - result doc: `{r['result_doc']}`\n")
            for crit in ("sample_size", "judge_diversity", "aa_baseline", "mechanism", "prohibited_claims"):
                verdict, note = r[crit]
                out_stream.write(f"  - **{crit}:** {emoji[verdict]} {verdict} — {note}\n")
            out_stream.write("\n")

    emit(sys.stdout)
    if write_cold_water:
        os.makedirs(os.path.dirname(cold_water_out), exist_ok=True)
        with open(cold_water_out, "w") as f:
            emit(f)
        print(f"\n_Cold Water sink: {cold_water_out}_", file=sys.stderr)
PYEOF
