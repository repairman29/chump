#!/usr/bin/env bash
# scripts/audit/audit-launchd-installers.sh — INFRA-2394
#
# Ranks every scripts/setup/install-*-launchd.sh by inbound reference count
# and buckets each into WIRED / DOCUMENTED / UNWIRED so the operator can see
# which installers are actually executed by something vs. dead-on-disk.
#
# Ref classes counted (per installer basename, matched against the rest of
# the repo, excluding the installer's own file):
#   bootstrap - referenced from scripts/setup/chump-fleet-bootstrap.sh
#   coord     - referenced from scripts/coord/**
#   workflow  - referenced from .github/workflows/**
#   sibling   - referenced from any other scripts/**
#   docs      - referenced from docs/** or CLAUDE.md / AGENTS.md
#
# Buckets:
#   WIRED       - (bootstrap + coord) total >= 2
#   DOCUMENTED  - not WIRED, but docs >= 1
#   UNWIRED     - zero refs across every class above
#
# UNWIRED installers are emitted as candidate-delete findings — this script
# never deletes anything, only reports. Deletion is a per-installer or
# batched follow-up gap (operator call; some may be intentional escape
# hatches).
#
# Usage:
#   scripts/audit/audit-launchd-installers.sh [--json] [--no-ambient]
#
# Output: human-readable report on stdout (or JSON with --json). Per-UNWIRED
# finding, also appends a kind=installer_audit_finding event to
# .chump-locks/ambient.jsonl unless --no-ambient is passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

JSON=0
EMIT_AMBIENT=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON=1; shift ;;
        --no-ambient) EMIT_AMBIENT=0; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

BOOTSTRAP_FILE="scripts/setup/chump-fleet-bootstrap.sh"
BOOTSTRAP_MANIFEST="scripts/setup/bootstrap-manifest.yaml"

# These three registry files (INFRA-1810 / INFRA-1926) TRACK installer
# wiring status in prose/list form — being named in one of them means
# "someone looked at this and wrote down an opinion", not "something
# executes this". Treat mentions here as DOCUMENTED-class signal, same as
# docs/**, never as an executor-class (sibling/coord/workflow) signal —
# otherwise every installer that's merely catalogued as "known unmapped"
# would incorrectly count as if a script were invoking it.
NON_EXECUTOR_REGISTRIES=(
    "scripts/setup/bootstrap-manifest-unmapped.txt"
    "scripts/setup/optional-installers-allowlist.txt"
    "scripts/setup/deprecated-installers-allowlist.txt"
)

mapfile -t INSTALLERS < <(ls scripts/setup/install-*-launchd.sh 2>/dev/null | sort)
TOTAL=${#INSTALLERS[@]}

if [[ "$TOTAL" -eq 0 ]]; then
    echo "no scripts/setup/install-*-launchd.sh found" >&2
    exit 1
fi

# rows: name\tbootstrap\tcoord\tworkflow\tsibling\tdocs\ttotal\tbucket\tintroducing_pr\tintroducing_gap
ROWS=()

for path in "${INSTALLERS[@]}"; do
    name="$(basename "$path")"

    bootstrap_refs=0
    if [[ -f "$BOOTSTRAP_FILE" ]] && grep -q -- "$name" "$BOOTSTRAP_FILE"; then
        bootstrap_refs=$(grep -c -- "$name" "$BOOTSTRAP_FILE" || true)
    fi
    # bootstrap-manifest.yaml is read by chump-fleet-bootstrap.sh (see
    # `MANIFEST=` there) — a manifest `install:` entry means bootstrap
    # actually runs this installer, so it counts as a bootstrap-class ref
    # even though it isn't a literal grep hit inside chump-fleet-bootstrap.sh.
    if [[ -f "$BOOTSTRAP_MANIFEST" ]] && grep -q -- "$name" "$BOOTSTRAP_MANIFEST"; then
        bootstrap_refs=$((bootstrap_refs + 1))
    fi

    coord_refs=$( { { grep -rl -- "$name" scripts/coord/ 2>/dev/null || true; } | grep -v -- "/$name\$" | wc -l | tr -d ' '; } || true)

    workflow_refs=0
    if [[ -d .github/workflows ]]; then
        workflow_refs=$( { { grep -rl -- "$name" .github/workflows/ 2>/dev/null || true; } | wc -l | tr -d ' '; } || true)
    fi

    sibling_refs=$( { { grep -rl -- "$name" scripts/ 2>/dev/null || true; } \
        | grep -v -- "/$name\$" \
        | grep -v '^scripts/coord/' \
        | grep -vxF -- "$BOOTSTRAP_MANIFEST" \
        | grep -vxF -- "${NON_EXECUTOR_REGISTRIES[0]}" \
        | grep -vxF -- "${NON_EXECUTOR_REGISTRIES[1]}" \
        | grep -vxF -- "${NON_EXECUTOR_REGISTRIES[2]}" \
        | wc -l | tr -d ' '; } || true)

    # Real documentation: docs/**, CLAUDE.md, AGENTS.md — prose that explains
    # what the installer is for. Deliberately excludes the three
    # NON_EXECUTOR_REGISTRIES: those are status-tracking lists (INFRA-1810 /
    # INFRA-1926), not documentation, and folding them in here would mean
    # every installer counts as "documented" purely because it was seeded
    # into a triage list — masking the exact orphans this audit exists to
    # find.
    docs_refs=0
    if [[ -d docs ]]; then
        docs_refs=$( { { grep -rl -- "$name" docs/ 2>/dev/null || true; } | wc -l | tr -d ' '; } || true)
    fi
    for extra_doc in CLAUDE.md AGENTS.md; do
        if [[ -f "$extra_doc" ]] && grep -q -- "$name" "$extra_doc"; then
            docs_refs=$((docs_refs + 1))
        fi
    done

    # Informational only (not counted toward any bucket): does an existing
    # INFRA-1810/1926 tracking list already know about this installer?
    registry_tracked="no"
    for reg in "${NON_EXECUTOR_REGISTRIES[@]}"; do
        if [[ -f "$reg" ]] && grep -q -- "$name" "$reg"; then
            registry_tracked="yes"
            break
        fi
    done

    executor_total=$((bootstrap_refs + coord_refs + workflow_refs + sibling_refs))
    total_refs=$((executor_total + docs_refs))

    bucket="UNWIRED"
    if [[ $((bootstrap_refs + coord_refs)) -ge 2 ]]; then
        bucket="WIRED"
    elif [[ "$docs_refs" -ge 1 ]]; then
        bucket="DOCUMENTED"
    elif [[ "$executor_total" -gt 0 ]]; then
        # some executor reference exists (workflow/sibling) but below the
        # WIRED bar of bootstrap+coord>=2 — still not a dead installer, but
        # not confidently WIRED either. Treat as DOCUMENTED-tier so it isn't
        # miscategorized as a pure candidate-delete.
        bucket="DOCUMENTED"
    fi

    introducing_pr=""
    introducing_gap=""
    intro_line="$( { git log --diff-filter=A --format='%s' -- "$path" 2>/dev/null | tail -1; } || true)"
    if [[ -n "$intro_line" ]]; then
        introducing_pr="$( { grep -oE '#[0-9]+' <<<"$intro_line" | head -1 | tr -d '#'; } || true)"
        introducing_gap="$( { grep -oE '[A-Z]+-[0-9]+' <<<"$intro_line" | head -1; } || true)"
    fi

    ROWS+=("$name"$'\t'"$bootstrap_refs"$'\t'"$coord_refs"$'\t'"$workflow_refs"$'\t'"$sibling_refs"$'\t'"$docs_refs"$'\t'"$total_refs"$'\t'"$bucket"$'\t'"$introducing_pr"$'\t'"$introducing_gap"$'\t'"$registry_tracked")
done

# sort by total_refs desc (field 7), stable on name
IFS=$'\n' SORTED=($(printf '%s\n' "${ROWS[@]}" | sort -t$'\t' -k7,7nr -k1,1))
unset IFS

wired_count=0
documented_count=0
unwired_count=0
for row in "${SORTED[@]}"; do
    bucket="$(cut -f8 <<<"$row")"
    case "$bucket" in
        WIRED) wired_count=$((wired_count + 1)) ;;
        DOCUMENTED) documented_count=$((documented_count + 1)) ;;
        UNWIRED) unwired_count=$((unwired_count + 1)) ;;
    esac
done

emit_ambient_finding() {
    local name="$1" bootstrap="$2" coord="$3" workflow="$4" sibling="$5" docs="$6" pr="$7" gap="$8"
    [[ "$EMIT_AMBIENT" -eq 1 ]] || return 0
    local emit_bin="scripts/dev/ambient-emit.sh"
    [[ -x "$emit_bin" ]] || return 0
    local ref_count_by_class
    ref_count_by_class="$(printf 'bootstrap=%s,coord=%s,workflow=%s,sibling=%s,docs=%s' "$bootstrap" "$coord" "$workflow" "$sibling" "$docs")"
    # scanner-anchor: "kind":"installer_audit_finding"
    "$emit_bin" installer_audit_finding \
        path="scripts/setup/${name}" \
        introducing_pr="${pr:-unknown}" \
        introducing_gap="${gap:-unknown}" \
        ref_count_by_class="$ref_count_by_class" \
        >/dev/null 2>&1 || true
}

if [[ "$JSON" -eq 1 ]]; then
    printf '{"total":%d,"wired":%d,"documented":%d,"unwired":%d,"installers":[' "$TOTAL" "$wired_count" "$documented_count" "$unwired_count"
    first=1
    for row in "${SORTED[@]}"; do
        IFS=$'\t' read -r name bootstrap coord workflow sibling docs total bucket pr gap registry_tracked <<<"$row"
        [[ "$first" -eq 1 ]] || printf ','
        first=0
        printf '{"name":"%s","bootstrap_refs":%d,"coord_refs":%d,"workflow_refs":%d,"sibling_refs":%d,"docs_refs":%d,"total_refs":%d,"bucket":"%s","introducing_pr":"%s","introducing_gap":"%s","registry_tracked":"%s"}' \
            "$name" "$bootstrap" "$coord" "$workflow" "$sibling" "$docs" "$total" "$bucket" "$pr" "$gap" "$registry_tracked"
        if [[ "$bucket" == "UNWIRED" ]]; then
            emit_ambient_finding "$name" "$bootstrap" "$coord" "$workflow" "$sibling" "$docs" "$pr" "$gap"
        fi
    done
    printf ']}\n'
else
    printf 'installer-launchd audit — %d scripts scanned\n' "$TOTAL"
    printf '  WIRED:      %d (bootstrap [chump-fleet-bootstrap.sh + bootstrap-manifest.yaml] + scripts/coord/ refs >= 2)\n' "$wired_count"
    printf '  DOCUMENTED: %d (real docs/CLAUDE.md/AGENTS.md ref, or a non-qualifying executor ref)\n' "$documented_count"
    printf '  UNWIRED:    %d (zero refs from any executor or real doc — candidate-delete)\n\n' "$unwired_count"
    printf 'Note: "registry" column = already catalogued in bootstrap-manifest-unmapped.txt\n'
    printf '/ optional-installers-allowlist.txt / deprecated-installers-allowlist.txt (INFRA-1810,\n'
    printf 'INFRA-1926). Those lists are prior tracking, not execution — they do NOT count toward\n'
    printf 'WIRED or DOCUMENTED here, so a "yes" alongside UNWIRED means: known-about but still dead.\n\n'

    printf '%-55s %-5s %-5s %-5s %-5s %-5s %-6s %-11s %-8s\n' "installer" "boot" "coord" "wf" "sib" "docs" "total" "bucket" "registry"
    for row in "${SORTED[@]}"; do
        IFS=$'\t' read -r name bootstrap coord workflow sibling docs total bucket pr gap registry_tracked <<<"$row"
        printf '%-55s %-5s %-5s %-5s %-5s %-5s %-6s %-11s %-8s\n' "$name" "$bootstrap" "$coord" "$workflow" "$sibling" "$docs" "$total" "$bucket" "$registry_tracked"
    done

    if [[ "$unwired_count" -gt 0 ]]; then
        printf '\nUNWIRED (candidate-delete, operator decides per-installer):\n'
        for row in "${SORTED[@]}"; do
            IFS=$'\t' read -r name bootstrap coord workflow sibling docs total bucket pr gap registry_tracked <<<"$row"
            [[ "$bucket" == "UNWIRED" ]] || continue
            printf '  - %s (introduced in %s%s; registry-tracked: %s)\n' "$name" "${pr:+#$pr }" "${gap:-unknown gap}" "$registry_tracked"
            emit_ambient_finding "$name" "$bootstrap" "$coord" "$workflow" "$sibling" "$docs" "$pr" "$gap"
        done
    fi
fi
