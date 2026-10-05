#!/usr/bin/env bash
# test-curator-agent-productization.sh — INFRA-1917: smoke test for the
# 7-role curator productization triplet (.claude/agents/<role>.md +
# .claude/skills/<role>/SKILL.md + scripts/coord/<role>-loop.sh).
#
# Since a real Agent(subagent_type=<role>) spawn and a live /<role> slash
# invocation aren't reproducible in a headless CI shell, this test asserts
# the structural wiring that makes both possible: the agent doc exists with
# a matching `name:` frontmatter field, the skill doc exists and points at
# the loop script, and the loop script is executable and its `heartbeat`
# subcommand actually runs and emits to ambient (the same code path an
# Agent/slash invocation would exercise).

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROLES=(shepherd ci-audit target decompose handoff md-links)
# orchestrator uses a non-role-name loop script; handled separately below.

_pass=0
_fail=0
_ok()  { echo "  ✓ $*"; _pass=$((_pass + 1)); }
_bad() { echo "  ✗ FAIL: $*" >&2; _fail=$((_fail + 1)); }

_check_role() {
    local role="$1"
    local agent_doc="$REPO_ROOT/.claude/agents/${role}.md"
    local skill_doc="$REPO_ROOT/.claude/skills/${role}/SKILL.md"
    local loop_script="$REPO_ROOT/scripts/coord/${role}-loop.sh"

    echo "Role: $role"

    if [[ -f "$agent_doc" ]]; then
        _ok "$role: agent doc exists at .claude/agents/${role}.md"
    else
        _bad "$role: missing .claude/agents/${role}.md"
        return
    fi

    if grep -q "^name: ${role}$" "$agent_doc"; then
        _ok "$role: agent doc frontmatter name matches (dispatchable via Agent(subagent_type=${role}))"
    else
        _bad "$role: agent doc frontmatter 'name:' does not match '${role}'"
    fi

    if [[ -f "$skill_doc" ]]; then
        _ok "$role: skill doc exists at .claude/skills/${role}/SKILL.md"
    else
        _bad "$role: missing .claude/skills/${role}/SKILL.md"
    fi

    if [[ -f "$skill_doc" ]] && grep -q "${role}-loop.sh" "$skill_doc"; then
        _ok "$role: skill doc references its loop script (no logic duplication)"
    else
        _bad "$role: skill doc does not reference ${role}-loop.sh"
    fi

    if [[ -x "$loop_script" ]]; then
        _ok "$role: loop script exists and is executable"
    else
        _bad "$role: missing or non-executable scripts/coord/${role}-loop.sh"
        return
    fi

    if bash -n "$loop_script" 2>/dev/null; then
        _ok "$role: loop script passes bash -n syntax check"
    else
        _bad "$role: loop script has a syntax error"
    fi

    # Exercise the heartbeat subcommand — the same executable surface an
    # Agent(subagent_type=<role>) or /<role> slash invocation would hit,
    # and assert stdout + the ambient emission both surface to the caller.
    local dir amb rc out
    dir="$(mktemp -d)"
    amb="$dir/ambient.jsonl"
    rc=0
    out="$(CHUMP_AMBIENT_LOG="$amb" CHUMP_SESSION_ID="test-${role}-productization" \
        "$loop_script" heartbeat 2>&1)" || rc=$?
    if (( rc == 0 )); then
        _ok "$role: loop script 'heartbeat' subcommand exits 0"
    else
        _bad "$role: loop script 'heartbeat' should exit 0, got $rc"
    fi
    if [[ -n "$out" ]]; then
        _ok "$role: loop script surfaces stdout to the caller"
    else
        _bad "$role: loop script produced no stdout"
    fi
    if [[ -f "$amb" ]] && grep -q "heartbeat" "$amb"; then
        _ok "$role: heartbeat subcommand emits a heartbeat kind to ambient"
    else
        _bad "$role: heartbeat subcommand did not emit to ambient"
    fi
    rm -rf "$dir"
    echo
}

for role in "${ROLES[@]}"; do
    _check_role "$role"
done

# ── orchestrator: agent + skill exist; loop script is orchestrator-loop.sh ──
echo "Role: orchestrator"
if [[ -f "$REPO_ROOT/.claude/agents/orchestrator.md" ]]; then
    _ok "orchestrator: agent doc exists at .claude/agents/orchestrator.md"
else
    _bad "orchestrator: missing .claude/agents/orchestrator.md"
fi
if grep -q "^name: orchestrator$" "$REPO_ROOT/.claude/agents/orchestrator.md" 2>/dev/null; then
    _ok "orchestrator: agent doc frontmatter name matches"
else
    _bad "orchestrator: agent doc frontmatter 'name:' mismatch"
fi
if [[ -f "$REPO_ROOT/.claude/skills/orchestrator/SKILL.md" ]]; then
    _ok "orchestrator: skill doc exists at .claude/skills/orchestrator/SKILL.md"
else
    _bad "orchestrator: missing .claude/skills/orchestrator/SKILL.md"
fi
_orch_loop="$REPO_ROOT/scripts/coord/orchestrator-loop.sh"
if [[ -x "$_orch_loop" ]]; then
    _ok "orchestrator: loop script exists and is executable"
else
    _bad "orchestrator: missing or non-executable scripts/coord/orchestrator-loop.sh"
fi
if bash -n "$_orch_loop" 2>/dev/null; then
    _ok "orchestrator: loop script passes bash -n syntax check"
else
    _bad "orchestrator: loop script has a syntax error"
fi
_dir_o="$(mktemp -d)"
_amb_o="$_dir_o/ambient.jsonl"
_rc_o=0
_out_o="$(CHUMP_AMBIENT_LOG="$_amb_o" CHUMP_SESSION_ID="test-orchestrator-productization" \
    "$_orch_loop" heartbeat 2>&1)" || _rc_o=$?
if (( _rc_o == 0 )); then
    _ok "orchestrator: loop script 'heartbeat' subcommand exits 0"
else
    _bad "orchestrator: loop script 'heartbeat' should exit 0, got $_rc_o"
fi
if [[ -n "$_out_o" ]]; then
    _ok "orchestrator: loop script surfaces stdout to the caller"
else
    _bad "orchestrator: loop script produced no stdout"
fi
if [[ -f "$_amb_o" ]] && grep -q "heartbeat" "$_amb_o"; then
    _ok "orchestrator: heartbeat subcommand emits a heartbeat kind to ambient"
else
    _bad "orchestrator: heartbeat subcommand did not emit to ambient"
fi
rm -rf "$_dir_o"
echo

# ── TEAM_OF_AGENTS.md roster references all 7 roles ────────────────────────
echo "TEAM_OF_AGENTS.md roster coverage:"
_team_doc="$REPO_ROOT/docs/architecture/TEAM_OF_AGENTS.md"
if [[ -f "$_team_doc" ]]; then
    for role in shepherd ci-audit target decompose handoff md-links orchestrator; do
        if grep -q "$role" "$_team_doc"; then
            _ok "TEAM_OF_AGENTS.md references '$role'"
        else
            _bad "TEAM_OF_AGENTS.md does not mention '$role'"
        fi
    done
else
    _bad "docs/architecture/TEAM_OF_AGENTS.md not found"
fi

# ── Summary ──────────────────────────────────────────────────────────────
echo
echo "Results: ${_pass} passed, ${_fail} failed"
if (( _fail > 0 )); then
    exit 1
fi
echo "✓ All curator-agent-productization tests passed"
