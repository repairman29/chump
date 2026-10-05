#!/usr/bin/env bash
# gate-fixtures.sh — INFRA-4537 (INFRA-1861 slice)
#
# Sourceable library: synthetic fixture preparers for scripts/ci/gate-manifest.yaml
# entries. Extracted from test-all-gates-force-fire.sh (CREDIBLE-050) so a
# second consumer — test-bypass-line-output-audit.sh (INFRA-4537) — can
# force-fire the same gates without duplicating fixture logic.
#
# Usage:
#   source "$(dirname "$0")/lib/gate-fixtures.sh"
#   fixture_root="$(prepare_fixture "$fixture_kind")"

fixture_pr_title_vs_diff() {
    # check-pr-scope.sh needs: real main branch + feature branch on top so
    # git merge-base resolves; PR title (from first commit OR gh pr view).
    # Without these, the script short-circuits with "skipping scope check"
    # which exits 0 and looks like a non-firing gate.
    local tmp; tmp="$(mktemp -d -t gate-fixture-scope.XXXXXX)"
    cd "$tmp"
    git init -q -b main
    git config user.email t@t.t
    git config user.name t
    mkdir -p docs/gaps src
    echo "- id: TEST-000" > docs/gaps/TEST-000.yaml
    echo "// initial" > src/lib.rs
    git add . && git commit -q -m "initial"
    # Pretend origin/main exists so MERGE_BASE resolves.
    git update-ref refs/remotes/origin/main HEAD
    # Feature branch with the violating change: chore(gaps): title + src touched.
    git checkout -q -b feature
    echo "- id: TEST-001" > docs/gaps/TEST-001.yaml
    echo "// scope violation: touching src under chore(gaps): title" >> src/lib.rs
    git add . && git commit -q -m "chore(gaps): file TEST-001 + bonus src change"
    echo "$tmp"
}

fixture_scratch_commits_or_mass_delete() {
    local tmp; tmp="$(mktemp -d -t gate-fixture-scratch.XXXXXX)"
    cd "$tmp"
    git init -q -b main
    git config user.email t@t.t
    git config user.name t
    mkdir -p src docs/gaps
    for i in $(seq 1 50); do echo "line $i" >> src/lib.rs; done
    echo "feature one" > docs/feature.md
    git add . && git commit -q -m "initial seed"
    git checkout -q -b scratch-disaster
    : > src/lib.rs
    git add . && git commit -q -m "first"
    rm docs/feature.md
    git add . && git commit -q -m "unrelated change"
    echo "$tmp"
}

fixture_state_db_with_ghost_closed_pr() {
    # Args like --strict come from the manifest's `fixture_args` field —
    # not from `export` here (the fixture preparer runs in a $(...)
    # subshell, so exports never reach the runner's main shell).
    local tmp; tmp="$(mktemp -d -t gate-fixture-premature.XXXXXX)"
    mkdir -p "$tmp/.chump"
    sqlite3 "$tmp/.chump/state.db" <<'SQL'
CREATE TABLE gaps (
    id TEXT PRIMARY KEY, domain TEXT, title TEXT, description TEXT,
    priority TEXT, effort TEXT, status TEXT, acceptance_criteria TEXT,
    depends_on TEXT, notes TEXT, source_doc TEXT,
    created_at INTEGER NOT NULL DEFAULT 0, closed_at INTEGER,
    opened_date TEXT NOT NULL DEFAULT '', closed_date TEXT NOT NULL DEFAULT '',
    closed_pr INTEGER, skills_required TEXT NOT NULL DEFAULT '',
    preferred_backend TEXT NOT NULL DEFAULT '', preferred_machine TEXT NOT NULL DEFAULT '',
    estimated_minutes TEXT NOT NULL DEFAULT '', required_model TEXT NOT NULL DEFAULT ''
);
INSERT INTO gaps(id, domain, title, status, priority, effort, closed_pr)
VALUES ('TEST-001', 'TEST', 't', 'done', 'P1', 's', 999999);
SQL
    cd "$tmp"
    git init -q && git config user.email t@t.t && git config user.name t
    git commit --allow-empty -q -m "init"
    echo "$tmp"
}

fixture_in_script_self_test() {
    echo "$REPO_ROOT"
}

fixture_cognition_src_change_without_prereg() {
    # test-prereg-required-for-cognition.sh checks git diff against
    # origin/main for cognition src changes. Need both branches + the
    # update-ref trick so origin/main resolves locally.
    local tmp; tmp="$(mktemp -d -t gate-fixture-prereg.XXXXXX)"
    cd "$tmp"
    git init -q -b main
    git config user.email t@t.t
    git config user.name t
    mkdir -p src docs/eval/preregistered
    echo "// reflection" > src/reflection_db.rs
    echo "// neuromod" > src/neuromod.rs
    git add . && git commit -q -m "initial"
    git update-ref refs/remotes/origin/main HEAD
    git checkout -q -b cognition-feature
    echo "// added neuromod tuning" >> src/reflection_db.rs
    echo "fn new_thing() {}" >> src/neuromod.rs
    git add . && git commit -q -m "feat(COG-XXX): tune neuromod kappa (no prereg doc)"
    echo "$tmp"
}

prepare_fixture() {
    local kind="$1"
    case "$kind" in
        pr-title-vs-diff) fixture_pr_title_vs_diff ;;
        scratch-commits-or-mass-delete) fixture_scratch_commits_or_mass_delete ;;
        state.db-with-ghost-closed-pr) fixture_state_db_with_ghost_closed_pr ;;
        in-script-self-test) fixture_in_script_self_test ;;
        cognition-src-change-without-prereg) fixture_cognition_src_change_without_prereg ;;
        *) echo ""; return 1 ;;
    esac
}
