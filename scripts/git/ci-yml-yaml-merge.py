#!/usr/bin/env python3
"""ci-yml-yaml-merge.py — INFRA-1482

YAML-structure-aware 3-way merge for `.github/workflows/ci.yml` `steps:`
arrays. Used as a fallback layer by merge-driver-ci-yml-add-row.sh when the
line-diff heuristics (pure-append / patch-fuzz / union) refuse an
interleaved-addition rebase (e.g. main added two steps and our branch added
one step in between them — textually a conflict, semantically two safe
additions).

Identity for a step is its `name:` value (or, for name-less steps such as
`- uses: actions/checkout@v4`, the stripped text of the step's first line).
Steps are located only inside a job's `steps:` array (lines at exactly
steps-indent+2 starting with "- "), so nested `- ` list items inside a
step body (e.g. a `strategy.matrix.include` list) are never mistaken for
step boundaries.

Algorithm (per file: ancestor / ours / theirs):
  1. Locate every `steps:` block and the step-blocks inside it (raw text,
     not re-serialized — avoids reformatting the rest of the file).
  2. Replace each step-block with a placeholder in a "skeleton" copy of the
     file. If skeleton(ancestor) != skeleton(ours) or != skeleton(theirs)
     (ignoring which placeholder ids are used, only whether the SHAPE outside
     step bodies changed) — bail (exit 2): something outside the steps
     arrays changed, too risky for this driver.
  3. Do a base-anchored 3-way merge of the step-identity sequences. If either
     side deleted or renamed an existing step (a non-additive diff) — bail
     (exit 2): let the existing line-based fallback / conflict markers
     handle it.
  4. If a step present in ancestor was modified by BOTH ours and theirs with
     DIFFERENT content — bail (exit 2, real conflict). If modified by only
     one side, take that side's content.
  5. Reconstruct the merged file by walking ancestor's skeleton and
     splicing in the merged step blocks in the resolved order.

Exit codes:
  0 — merged successfully; merged content written to OURS (in place)
  1 — reserved (unused; the caller only checks 0 vs non-zero)
  2 — not applicable / unsafe; caller should fall back to other heuristics
"""
import re
import sys

STEP_RE = re.compile(r"^( *)- +")
STEPS_KEY_RE = re.compile(r"^( *)steps:\s*$")
NAME_RE = re.compile(r"^\s*- +name:\s*(.*?)\s*$")

NOT_APPLICABLE = 2
BODY_RE = re.compile(r"^\s+(run|uses):", re.MULTILINE)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def find_step_blocks(text):
    """Return list of (start_idx, end_idx, indent, identity) over lines(text)."""
    lines = text.splitlines(keepends=True)
    blocks = []
    i = 0
    n = len(lines)
    while i < n:
        m = STEPS_KEY_RE.match(lines[i])
        if not m:
            i += 1
            continue
        steps_indent = len(m.group(1))
        item_indent = steps_indent + 2
        j = i + 1
        while j < n:
            line = lines[j]
            if line.strip() == "":
                j += 1
                continue
            stripped_len = len(line) - len(line.lstrip(" "))
            if stripped_len < item_indent:
                break
            if stripped_len == item_indent and line[item_indent:].startswith("- "):
                start = j
                j += 1
                while j < n:
                    line2 = lines[j]
                    if line2.strip() == "":
                        j += 1
                        continue
                    sl2 = len(line2) - len(line2.lstrip(" "))
                    if sl2 <= item_indent:
                        break
                    j += 1
                end = j
                block_text = "".join(lines[start:end])
                nm = NAME_RE.match(lines[start])
                if nm and nm.group(1):
                    identity = "name:" + nm.group(1)
                else:
                    identity = "raw:" + lines[start].strip()
                blocks.append((start, end, item_indent, identity, block_text))
                continue
            break
        i = j
    return blocks, lines


def skeleton(text, blocks):
    """Text with every step-block replaced by a constant placeholder token."""
    lines = text.splitlines(keepends=True)
    out = []
    covered = set()
    for start, end, _indent, _identity, _block in blocks:
        for k in range(start, end):
            covered.add(k)
    i = 0
    n = len(lines)
    while i < n:
        if i in covered:
            out.append("\x00STEP\x00\n")
            while i in covered:
                i += 1
        else:
            out.append(lines[i])
            i += 1
    return "".join(out)


def insertions_after_base(base_ids, seq_ids):
    """Map base_index -> [inserted identities immediately before that index].

    Returns None if seq_ids is not a pure superset-via-insertion of base_ids
    (i.e. any delete or replace vs. base — unsafe to auto-merge)."""
    import difflib

    sm = difflib.SequenceMatcher(None, base_ids, seq_ids, autojunk=False)
    result = {}
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        if tag == "insert":
            result.setdefault(i1, []).extend(seq_ids[j1:j2])
        else:
            return None
    return result


def main():
    if len(sys.argv) != 4:
        sys.exit(NOT_APPLICABLE)
    ancestor_path, ours_path, theirs_path = sys.argv[1:4]

    try:
        import yaml  # noqa: F401  (validate availability + parseability)
    except ImportError:
        sys.exit(NOT_APPLICABLE)

    try:
        ancestor_text = read(ancestor_path)
        ours_text = read(ours_path)
        theirs_text = read(theirs_path)
    except OSError:
        sys.exit(NOT_APPLICABLE)

    try:
        yaml.safe_load(ancestor_text)
        yaml.safe_load(ours_text)
        yaml.safe_load(theirs_text)
    except yaml.YAMLError:
        sys.exit(NOT_APPLICABLE)

    a_blocks, _ = find_step_blocks(ancestor_text)
    o_blocks, o_lines = find_step_blocks(ours_text)
    t_blocks, t_lines = find_step_blocks(theirs_text)

    if not a_blocks:
        sys.exit(NOT_APPLICABLE)

    a_skel = skeleton(ancestor_text, a_blocks)
    o_skel = skeleton(ours_text, o_blocks)
    t_skel = skeleton(theirs_text, t_blocks)
    if a_skel != o_skel or a_skel != t_skel:
        # Non-step content diverged (job scaffolding, path filters, etc.) —
        # too risky for this driver to touch.
        sys.exit(NOT_APPLICABLE)

    a_ids = [b[3] for b in a_blocks]
    o_ids = [b[3] for b in o_blocks]
    t_ids = [b[3] for b in t_blocks]

    ins_ours = insertions_after_base(a_ids, o_ids)
    ins_theirs = insertions_after_base(a_ids, t_ids)
    if ins_ours is None or ins_theirs is None:
        # Someone deleted or renamed an existing step — real conflict.
        sys.exit(NOT_APPLICABLE)

    a_content = {b[3]: b[4] for b in a_blocks}
    o_content = {b[3]: b[4] for b in o_blocks}
    t_content = {b[3]: b[4] for b in t_blocks}

    # INFRA-1199 parity: a newly-inserted step with a 'name:' but no 'run:'/
    # 'uses:' body is rejected by GitHub Actions outright. Don't auto-merge
    # one in — bail and let the line-diff validate_step_bodies() path (or a
    # human) handle it.
    for idents, content in ((o_ids, o_content), (t_ids, t_content)):
        for ident in idents:
            if ident in a_content:
                continue
            if ident.startswith("name:") and not BODY_RE.search(content[ident]):
                sys.exit(NOT_APPLICABLE)

    # Resolve content for identities that exist in ancestor: if both sides
    # changed the body differently, that's a real conflict.
    resolved_content = {}
    for ident in a_ids:
        base_body = a_content[ident]
        ours_body = o_content.get(ident, base_body)
        theirs_body = t_content.get(ident, base_body)
        if ours_body != base_body and theirs_body != base_body and ours_body != theirs_body:
            sys.exit(NOT_APPLICABLE)
        resolved_content[ident] = ours_body if ours_body != base_body else theirs_body
    for ident in o_ids:
        if ident not in resolved_content:
            resolved_content[ident] = o_content[ident]
    for ident in t_ids:
        if ident not in resolved_content:
            resolved_content[ident] = t_content[ident]

    # Build the merged identity order: walk base anchors 0..len(a_ids),
    # emitting insertions from both sides (ours first, then any of theirs'
    # insertions not already present) before each base element.
    merged_ids = []
    for idx in range(len(a_ids) + 1):
        for ident in ins_ours.get(idx, []):
            if ident not in merged_ids:
                merged_ids.append(ident)
        for ident in ins_theirs.get(idx, []):
            if ident not in merged_ids:
                merged_ids.append(ident)
        if idx < len(a_ids):
            merged_ids.append(a_ids[idx])

    if len(merged_ids) == len(a_ids):
        # Nothing was actually added by either side (pure equal); no-op.
        sys.exit(NOT_APPLICABLE)

    # Reconstruct: replace each ancestor step-block span with the merged
    # block sequence anchored at that span; insertions before the first
    # block go before it, insertions after the last go after it.
    lines = ancestor_text.splitlines(keepends=True)
    out = []
    covered = set()
    for start, end, _indent, _identity, _block in a_blocks:
        for k in range(start, end):
            covered.add(k)

    span_for_anchor = {}
    for pos, (start, end, _indent, identity, _block) in enumerate(a_blocks):
        span_for_anchor[pos] = (start, end)

    # Pre-compute, for each base anchor idx, the ordered list of merged
    # identities to emit immediately before it (its own pre-insertions),
    # and a trailing list for after the very last base element.
    pre = {idx: [] for idx in range(len(a_ids) + 1)}
    for idx in range(len(a_ids) + 1):
        for ident in ins_ours.get(idx, []):
            if ident not in pre[idx]:
                pre[idx].append(ident)
        for ident in ins_theirs.get(idx, []):
            if ident not in pre[idx]:
                pre[idx].append(ident)

    i = 0
    n = len(lines)
    anchor_pos = 0
    while i < n:
        if i in covered:
            # Emit pre-insertions for this anchor, then the (possibly
            # updated) base content itself.
            for ident in pre.get(anchor_pos, []):
                out.append(resolved_content[ident])
            start, end = span_for_anchor[anchor_pos]
            out.append(resolved_content[a_ids[anchor_pos]])
            anchor_pos += 1
            i = end
        else:
            out.append(lines[i])
            i += 1
    # Trailing insertions anchored after the last base step.
    for ident in pre.get(len(a_ids), []):
        out.append(resolved_content[ident])

    merged_text = "".join(out)
    try:
        yaml.safe_load(merged_text)
    except yaml.YAMLError:
        sys.exit(NOT_APPLICABLE)

    with open(ours_path, "w", encoding="utf-8") as f:
        f.write(merged_text)
    sys.exit(0)


if __name__ == "__main__":
    main()
