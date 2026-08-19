#!/usr/bin/env python3
"""ci-yml-yaml-merge.py — INFRA-1482

YAML-aware last-resort fallback for the ci.yml merge driver
(scripts/git/merge-driver-ci-yml-add-row.sh). Invoked only after the
line-diff heuristics in the shell driver have already failed (pure-append
check + INFRA-1490 patch/union fallback both gave up).

Algorithm: find every `jobs.<job>.steps` list in ancestor/ours/theirs by
indentation-aware structural scan (no full YAML re-serialization, which
would drop comments/formatting). For each job's steps array, take the
UNION of steps keyed by step "name" (or "uses" when a step has no name),
preserving order via each step's position in the base list, with new
steps from ours/theirs inserted immediately after the nearest preceding
base step they followed in their own branch. Steps present in both ours
and theirs that differ in content are left as a hard conflict (the shell
driver falls through to git's own 3-way markers). A base step dropped
from either side (rename or delete) is also left as a hard conflict
(ambiguous — plain-key matching can't tell rename from delete). Every
merged step must carry a `run:` or `uses:` body (INFRA-1199 guard) or the
whole merge is refused.

Output is built by splicing the original raw text blocks in place —
never by re-dumping parsed YAML — so comments/formatting outside the
touched steps arrays are untouched.
"""
import re
import sys

STEP_RE = re.compile(r"^(?P<indent>[ \t]*)-\s")
STEPS_HEADER_RE = re.compile(r"^(?P<indent>[ \t]*)steps:\s*$")


def read_lines(path):
    with open(path, encoding="utf-8") as f:
        return f.readlines()


def find_steps_blocks(lines):
    """Return list of (header_idx, indent, [step_dicts]) for every
    'steps:' list found in the file. Each step_dict has: key (name or uses
    or None), start, end (line indices, end exclusive), raw text.
    """
    blocks = []
    i = 0
    n = len(lines)
    while i < n:
        m = STEPS_HEADER_RE.match(lines[i])
        if not m:
            i += 1
            continue
        header_idx = i
        parent_indent = len(m.group("indent"))
        i += 1
        steps = []
        cur_start = None
        cur_indent = None
        while i < n:
            line = lines[i]
            stripped = line.rstrip("\n")
            if stripped.strip() == "":
                i += 1
                continue
            sm = STEP_RE.match(line)
            this_indent = len(line) - len(line.lstrip(" \t"))
            if sm and this_indent > parent_indent:
                if cur_start is not None and this_indent == cur_indent:
                    steps.append((cur_start, i))
                cur_start = i
                cur_indent = this_indent
                i += 1
                continue
            if cur_start is not None and this_indent <= parent_indent:
                steps.append((cur_start, i))
                cur_start = None
                break
            i += 1
        else:
            if cur_start is not None:
                steps.append((cur_start, i))
                cur_start = None
        step_dicts = []
        for (s, e) in steps:
            key = None
            has_body = False
            for j in range(s, e):
                stripped_line = lines[j].lstrip()
                if key is None and stripped_line.startswith("- name:"):
                    key = ("name", lines[j].split("name:", 1)[1].strip())
                elif key is None and stripped_line.startswith("- uses:"):
                    key = ("uses", lines[j].split("uses:", 1)[1].strip())
                if stripped_line.startswith("run:") or stripped_line.startswith("uses:") or stripped_line.startswith("- uses:"):
                    has_body = True
            step_dicts.append({
                "start": s, "end": e, "key": key, "has_body": has_body,
                "text": "".join(lines[s:e]),
            })
        blocks.append({"header_idx": header_idx, "indent": parent_indent, "steps": step_dicts, "end": i})
        i = max(i, header_idx + 1)
    return blocks


def key_id(step):
    return step["key"] if step["key"] is not None else ("raw", step["text"])


def merge_steps(base_steps, ours_steps, theirs_steps):
    """Union base/ours/theirs step lists keyed by (kind, value). Returns
    merged list of step dicts (order preserved: base order first, with
    ours-only / theirs-only insertions placed right after the base step
    they immediately followed in their own branch). Returns None on any
    unresolvable conflict (same key, different text on both non-base
    sides; or a base step renamed differently on both sides).
    """
    base_keys = [key_id(s) for s in base_steps]
    ours_keys = [key_id(s) for s in ours_steps]
    theirs_keys = [key_id(s) for s in theirs_steps]
    base_set = set(base_keys)

    ours_by_key = {key_id(s): s for s in ours_steps}
    theirs_by_key = {key_id(s): s for s in theirs_steps}

    # Conflict: a base step's key vanished from BOTH ours and theirs but
    # via different replacement content at the same position — treat any
    # base step dropped from either side as unsafe (can't distinguish a
    # deletion from a rename with plain-key matching).
    for bk in base_keys:
        in_ours = bk in ours_by_key
        in_theirs = bk in theirs_by_key
        if not in_ours or not in_theirs:
            return None

    # Conflict: a key present in both ours and theirs (including base
    # keys) with differing raw text.
    common_new = (set(ours_keys) & set(theirs_keys)) - base_set
    for k in common_new:
        if ours_by_key[k]["text"] != theirs_by_key[k]["text"]:
            return None
    for bk in base_keys:
        if ours_by_key[bk]["text"] != theirs_by_key[bk]["text"]:
            return None

    def new_steps_after(steps, keys, base_set_local):
        """map: base_key (or None for 'before any base key') -> list of
        newly-added step dicts that appeared right after it in `steps`."""
        result = {}
        last_base = None
        for s, k in zip(steps, keys):
            if k in base_set_local:
                last_base = k
            else:
                result.setdefault(last_base, []).append(s)
        return result

    ours_new = new_steps_after(ours_steps, ours_keys, base_set)
    theirs_new = new_steps_after(theirs_steps, theirs_keys, base_set)

    merged = []
    seen = set()

    def emit_new_for(anchor):
        for s in ours_new.get(anchor, []):
            k = key_id(s)
            if k not in seen:
                merged.append(s)
                seen.add(k)
        for s in theirs_new.get(anchor, []):
            k = key_id(s)
            if k not in seen:
                merged.append(s)
                seen.add(k)

    emit_new_for(None)
    for bk in base_keys:
        base_step = next(s for s in base_steps if key_id(s) == bk)
        merged.append(ours_by_key[bk])
        seen.add(bk)
        emit_new_for(bk)

    return merged


def main():
    if len(sys.argv) != 4:
        print("usage: ci-yml-yaml-merge.py ANCESTOR OURS THEIRS", file=sys.stderr)
        return 2
    ancestor_path, ours_path, theirs_path = sys.argv[1:4]

    base_lines = read_lines(ancestor_path)
    ours_lines = read_lines(ours_path)
    theirs_lines = read_lines(theirs_path)

    base_blocks = find_steps_blocks(base_lines)
    ours_blocks = find_steps_blocks(ours_lines)
    theirs_blocks = find_steps_blocks(theirs_lines)

    if not (len(base_blocks) == len(ours_blocks) == len(theirs_blocks)):
        return 1
    if len(base_blocks) == 0:
        return 1

    # Blocks are matched positionally (Nth 'steps:' list in each file, in
    # document order) rather than by exact line number — an unrelated edit
    # outside any steps array (e.g. a comment tweak) can shift line numbers
    # without changing which steps list is which.
    out_lines = list(ours_lines)
    for bb, ob, tb in reversed(list(zip(base_blocks, ours_blocks, theirs_blocks))):
        merged = merge_steps(bb["steps"], ob["steps"], tb["steps"])
        if merged is None:
            return 1
        # INFRA-1199 guard: never write a step with no run:/uses: body.
        if any(not s["has_body"] for s in merged):
            return 1
        merged_text = "".join(s["text"] for s in merged)
        if ob["steps"]:
            start = ob["steps"][0]["start"]
            end = ob["steps"][-1]["end"]
        else:
            start = ob["header_idx"] + 1
            end = start
        out_lines[start:end] = [merged_text]

    with open(ours_path, "w", encoding="utf-8") as f:
        f.write("".join(out_lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
