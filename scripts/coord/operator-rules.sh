#!/usr/bin/env bash
# scripts/coord/operator-rules.sh — INFRA-1300
#
# Operator-defined filter rules that the reach-classifier (INFRA-1299)
# evaluates at send-time. Replaces the hardcoded urgency-default mapping
# with declarative YAML — operator can say "notify me on FEEDBACK
# kind=defect with subject prefix INFRA-1*" without touching code.
#
# Rule schema (.chump/operator-rules.yaml):
#   rules:
#     - match:
#         event: STUCK            # exact event type (optional)
#         kind: defect            # event sub-kind (optional)
#         subject_pattern: "INFRA-1*"  # glob (optional)
#         min_urgency: hours      # only match if urgency >= this (optional)
#       action: notify | silent | digest_only | force_now
#
# Action semantics (composed by reach-classifier):
#   notify       → use default urgency / channel mapping
#   silent       → drop to ['inbox'] only (no toast, no push, no digest)
#   digest_only  → ['inbox','digest'] regardless of urgency
#   force_now    → ['inbox','toast','push'] regardless of urgency
#
# Rules evaluated in order; first match wins. No match = default behavior.
#
# Commands:
#   operator-rules.sh list                       — print current rules
#   operator-rules.sh add <action> <key=value>...— append a rule
#       Example: add notify event=FEEDBACK kind=defect
#   operator-rules.sh remove <index>             — delete rule N
#   operator-rules.sh test <event-json>          — show what would match

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
RULES_FILE="${CHUMP_OPERATOR_RULES_FILE:-$REPO_ROOT/.chump/operator-rules.yaml}"

ensure_rules_file() {
    if [ ! -f "$RULES_FILE" ]; then
        mkdir -p "$(dirname "$RULES_FILE")"
        cat > "$RULES_FILE" <<'EOF'
# operator-rules.yaml — INFRA-1300
# Rules evaluated in order by reach-classifier.sh; first match wins.
# Default ships with sensible notify rules; operator tunes.
rules:
  - match:
      event: STUCK
    action: notify
  - match:
      event: ALERT
      kind: fleet_wedge
    action: force_now
  - match:
      event: FEEDBACK
      kind: defect
    action: notify
EOF
    fi
}

cmd="${1:-list}"
shift || true

case "$cmd" in
    list)
        ensure_rules_file
        echo "Rules at $RULES_FILE:"
        python3 -c "
import yaml, sys
try: data = yaml.safe_load(open(sys.argv[1])) or {}
except Exception as e: print(f'parse error: {e}'); sys.exit(1)
rules = data.get('rules', [])
if not rules: print('  (none)'); sys.exit(0)
for i, r in enumerate(rules):
    m = r.get('match', {})
    parts = [f'{k}={v}' for k, v in m.items()]
    print(f'  [{i}] {r.get(\"action\",\"?\")} when ' + (' and '.join(parts) if parts else '<any>'))
" "$RULES_FILE"
        ;;
    add)
        action="${1:-}"; shift || true
        [ -z "$action" ] && { echo "Usage: add <notify|silent|digest_only|force_now> <key=value>..." >&2; exit 2; }
        case "$action" in notify|silent|digest_only|force_now) : ;;
            *) echo "action must be notify | silent | digest_only | force_now" >&2; exit 2 ;;
        esac
        ensure_rules_file
        python3 -c "
import yaml, sys
file, action = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
match = {}
for p in pairs:
    if '=' not in p: print(f'bad kv: {p}', file=sys.stderr); sys.exit(2)
    k, v = p.split('=', 1)
    match[k] = v
data = yaml.safe_load(open(file)) or {}
data.setdefault('rules', []).append({'match': match, 'action': action})
with open(file, 'w') as fh: yaml.safe_dump(data, fh, default_flow_style=False, sort_keys=False)
print(f'added rule: {action} when ' + (' and '.join(pairs) if pairs else '<any>'))
" "$RULES_FILE" "$action" "$@"
        ;;
    remove)
        idx="${1:-}"
        [ -z "$idx" ] && { echo "Usage: remove <index>" >&2; exit 2; }
        ensure_rules_file
        python3 -c "
import yaml, sys
file, idx = sys.argv[1], int(sys.argv[2])
data = yaml.safe_load(open(file)) or {}
rules = data.get('rules', [])
if idx < 0 or idx >= len(rules): print(f'index out of range: {idx}', file=sys.stderr); sys.exit(2)
removed = rules.pop(idx)
data['rules'] = rules
with open(file, 'w') as fh: yaml.safe_dump(data, fh, default_flow_style=False, sort_keys=False)
print(f'removed [{idx}]: {removed}')
" "$RULES_FILE" "$idx"
        ;;
    test)
        event_json="${1:-}"
        [ -z "$event_json" ] && { echo "Usage: test '<event-json>'" >&2; exit 2; }
        ensure_rules_file
        python3 -c "
import json, sys, yaml, fnmatch
file, raw = sys.argv[1], sys.argv[2]
try: event = json.loads(raw)
except Exception as e: print(f'invalid event JSON: {e}', file=sys.stderr); sys.exit(2)
data = yaml.safe_load(open(file)) or {}
rules = data.get('rules', [])
URGENCY_ORDER = {'digest': 0, 'hours': 1, 'now': 2}
for i, r in enumerate(rules):
    m = r.get('match', {})
    ok = True
    for k, v in m.items():
        if k == 'subject_pattern':
            subj = event.get('subject') or event.get('gap') or event.get('corr_id') or ''
            if not fnmatch.fnmatchcase(subj, v): ok = False; break
        elif k == 'min_urgency':
            evurg = event.get('urgency', '')
            if URGENCY_ORDER.get(evurg, -1) < URGENCY_ORDER.get(v, 99): ok = False; break
        else:
            if str(event.get(k, '')) != str(v): ok = False; break
    if ok:
        print(json.dumps({'matched_rule_index': i, 'action': r.get('action', 'notify'), 'rule': r}))
        sys.exit(0)
print(json.dumps({'matched_rule_index': None, 'action': 'notify', 'rule': None}))
" "$RULES_FILE" "$event_json"
        ;;
    -h|--help|"")
        sed -n '2,30p' "$0" | sed 's/^# \?//'
        ;;
    *)
        echo "unknown command: $cmd" >&2
        echo "valid: list / add / remove / test" >&2
        exit 2
        ;;
esac
