#!/usr/bin/env python3
"""ci-yml-yaml-merge.py — INFRA-1482

YAML-aware last-resort fallback for the ci.yml merge driver
(scripts/git/merge-driver-ci-yml-add-row.sh). Invoked only after the
line-diff heuristics (pure-append, patch --fuzz=3, git merge-file --union)
have already given up.

Scope (deliberately narrow): jobs that exist in ancestor AND ours AND
theirs, where each side may have added/kept steps but the shared/base
steps are unmodified (or modified identically) on both sides. This is
the reported failure mode — concurrent PRs adding steps to the SAME
existing job, interleaved with each other's additions — not general
3-way YAML merge (new jobs, deleted jobs, and renamed steps are left to
the caller to fall back on).

Algorithm per shared job:
  1. Parse ancestor/ours/theirs with yaml.compose() to get Node trees
     with line-accurate marks (no re-dump -> no comment/formatting loss).
  2. Extract the job's `steps:` sequence as an ordered list of
     (step_name, raw_text) using the marks to slice the ORIGINAL text.
  3. Anchor every step that is new-in-ours / new-in-theirs to the
     nearest preceding base (ancestor) step name (or "<start>").
  4. Rebuild the steps block: walk the base order, and after emitting
     each base step, emit any ours-anchored then theirs-anchored new
     steps for that anchor (de-duplicated by name+raw).
  5. If any base step's body differs between ours and theirs (both
     sides modified it differently), refuse (exit 1) -- a real content
     conflict, not an additive one.
  6. Splice the rebuilt steps block back into `ours`'s raw text
     (bottom-up across jobs, to keep earlier line offsets valid) and
     write the result over OURS.

Exit codes: 0 = merged and wrote OURS. 1 = could not resolve
(caller should treat this as "give up", same as the existing rc=1 path).
"""
import sys

import re

try:
    import yaml
except ImportError:
    sys.exit(1)


_BODY_RE = re.compile(r"(?m)^\s*(run|uses):")


def has_body(raw_text):
    """INFRA-1199 guard: a step lacking 'run:'/'uses:' makes GitHub Actions
    reject the whole workflow file. Any step content this script introduces
    or changes must carry a body."""
    return bool(_BODY_RE.search(raw_text))


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    return text, text.splitlines(keepends=True)


def step_name(step_node):
    if not isinstance(step_node, yaml.MappingNode):
        return None
    for k, v in step_node.value:
        if (
            isinstance(k, yaml.ScalarNode)
            and k.value == "name"
            and isinstance(v, yaml.ScalarNode)
        ):
            return v.value
    return None


def extract_job_steps(text):
    """job_name -> {'steps': [(name, raw)...], 'start': int, 'end': int} (0-indexed line range)."""
    try:
        root = yaml.compose(text, Loader=yaml.SafeLoader)
    except yaml.YAMLError:
        return None
    if root is None or not isinstance(root, yaml.MappingNode):
        return {}
    lines = text.splitlines(keepends=True)
    jobs = {}
    for k, v in root.value:
        if not (isinstance(k, yaml.ScalarNode) and k.value == "jobs"):
            continue
        if not isinstance(v, yaml.MappingNode):
            continue
        for job_key, job_val in v.value:
            if not isinstance(job_val, yaml.MappingNode):
                continue
            steps_seq = None
            for jk, jv in job_val.value:
                if isinstance(jk, yaml.ScalarNode) and jk.value == "steps" and isinstance(
                    jv, yaml.SequenceNode
                ):
                    steps_seq = jv
            if steps_seq is None or not steps_seq.value:
                continue
            items = steps_seq.value
            steps = []
            for i, item in enumerate(items):
                start = item.start_mark.line
                end = (
                    items[i + 1].start_mark.line
                    if i + 1 < len(items)
                    else steps_seq.end_mark.line
                )
                raw = "".join(lines[start:end])
                steps.append((step_name(item), raw))
            jobs[job_key.value] = {
                "steps": steps,
                "start": items[0].start_mark.line,
                "end": steps_seq.end_mark.line,
            }
    return jobs


def merge_job_steps(base_steps, ours_steps, theirs_steps):
    """Returns merged raw text for the job's steps block, or None on conflict."""
    base_by_name = {n: r for n, r in base_steps if n is not None}
    base_order = [n for n, _ in base_steps if n is not None]
    ours_by_name = {n: r for n, r in ours_steps if n is not None}
    theirs_by_name = {n: r for n, r in theirs_steps if n is not None}

    # Anything without a name (malformed step) makes this job unsafe to merge.
    if len(base_by_name) != len(base_steps):
        return None
    if len(ours_by_name) != len(ours_steps) or len(theirs_by_name) != len(theirs_steps):
        return None

    def anchor_new(step_list, base_names):
        """name -> anchor (preceding base step name, or None for <start>), in encounter order."""
        anchors = {}
        order = []
        current_anchor = None
        for name, raw in step_list:
            if name in base_names:
                current_anchor = name
                continue
            if name not in anchors:
                anchors[name] = (current_anchor, raw)
                order.append(name)
        return anchors, order

    base_name_set = set(base_order)
    ours_anchors, ours_new_order = anchor_new(ours_steps, base_name_set)
    theirs_anchors, theirs_new_order = anchor_new(theirs_steps, base_name_set)

    # A step added by BOTH sides with the same name: fine if identical text,
    # otherwise a genuine conflict (can't tell which is intended).
    for name in set(ours_new_order) & set(theirs_new_order):
        if ours_anchors[name][1] != theirs_anchors[name][1]:
            return None

    # INFRA-1199: refuse to write any added step that lacks a run:/uses: body
    # (an orphan '- name:' step is invalid GitHub Actions YAML).
    for name in ours_new_order:
        if not has_body(ours_anchors[name][1]):
            return None
    for name in theirs_new_order:
        if not has_body(theirs_anchors[name][1]):
            return None

    def emit_new_for_anchor(anchor, seen):
        out = []
        for name in ours_new_order:
            if ours_anchors[name][0] == anchor and name not in seen:
                out.append(ours_anchors[name][1])
                seen.add(name)
        for name in theirs_new_order:
            if theirs_anchors[name][0] == anchor and name not in seen:
                out.append(theirs_anchors[name][1])
                seen.add(name)
        return out

    result = []
    seen = set()
    result.extend(emit_new_for_anchor(None, seen))

    for name in base_order:
        base_raw = base_by_name[name]
        ours_has = name in ours_by_name
        theirs_has = name in theirs_by_name
        if not ours_has and not theirs_has:
            # Both sides made this base step disappear -- could be a genuine
            # shared deletion, could be both sides independently renaming it
            # (INFRA-1482 AC: "both rename -> keep conflict"). Ambiguous
            # either way; refuse rather than guess.
            return None
        if ours_has != theirs_has:
            # One side deleted/renamed it while the other kept or modified
            # it: a real deletion conflict, refuse.
            return None
        ours_raw = ours_by_name[name]
        theirs_raw = theirs_by_name[name]
        if ours_raw != theirs_raw:
            if ours_raw != base_raw and theirs_raw != base_raw:
                # Both sides modified the same base step differently: keep conflict.
                return None
            chosen = ours_raw if ours_raw != base_raw else theirs_raw
        else:
            chosen = ours_raw
        if chosen != base_raw and not has_body(chosen):
            return None  # INFRA-1199: modified step lost its run:/uses: body
        result.append(chosen)
        result.extend(emit_new_for_anchor(name, seen))

    return "".join(result)


def main():
    if len(sys.argv) != 4:
        sys.exit(1)
    ancestor_path, ours_path, theirs_path = sys.argv[1:4]

    ancestor_text, _ = read(ancestor_path)
    ours_text, ours_lines = read(ours_path)
    theirs_text, _ = read(theirs_path)

    ancestor_jobs = extract_job_steps(ancestor_text)
    ours_jobs = extract_job_steps(ours_text)
    theirs_jobs = extract_job_steps(theirs_text)
    if ancestor_jobs is None or ours_jobs is None or theirs_jobs is None:
        sys.exit(1)

    shared_jobs = [
        j for j in ancestor_jobs if j in ours_jobs and j in theirs_jobs
    ]
    if not shared_jobs:
        sys.exit(1)

    splices = []  # (start_line, end_line, replacement_text), computed against OURS
    any_merged = False
    for job in shared_jobs:
        base_steps = ancestor_jobs[job]["steps"]
        ours_steps = ours_jobs[job]["steps"]
        theirs_steps = theirs_jobs[job]["steps"]
        if ours_steps == theirs_steps:
            continue  # nothing to reconcile for this job
        merged = merge_job_steps(base_steps, ours_steps, theirs_steps)
        if merged is None:
            continue  # leave this job untouched; may still be an overall conflict
        splices.append((ours_jobs[job]["start"], ours_jobs[job]["end"], merged))
        any_merged = True

    if not any_merged:
        sys.exit(1)

    # Apply bottom-up so earlier splices' line numbers stay valid.
    splices.sort(key=lambda s: s[0], reverse=True)
    for start, end, replacement in splices:
        ours_lines[start:end] = [replacement]

    with open(ours_path, "w", encoding="utf-8") as f:
        f.write("".join(ours_lines))
    sys.exit(0)


if __name__ == "__main__":
    main()
