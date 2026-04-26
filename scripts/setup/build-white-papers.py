#!/usr/bin/env python3
"""
Build PDF white paper(s) from docs listed in docs/white-paper-manifest.json.

Requires Pandoc plus one of: XeLaTeX/pdfLaTeX, Docker (pandoc/ubuntu-latex),
or **Chrome/Chromium** with `--chrome-pdf` (HTML → headless print; no LaTeX).

Cross-links to Markdown files **not** included in the same volume are rewritten to
plain text so shared PDFs do not imply the reader has the rest of the repo.

Usage:
  ./scripts/setup/build-white-papers.py
  ./scripts/setup/build-white-papers.py --docker
  ./scripts/setup/build-white-papers.py --chrome-pdf
  ./scripts/setup/build-white-papers.py --volume volume-1-showcase
  ./scripts/setup/build-white-papers.py --html-only
  ./scripts/setup/build-white-papers.py --profile academic
  ./scripts/setup/build-white-papers.py --merge
  ./scripts/setup/build-white-papers.py --dry-run

Override Docker image: CHUMP_WHITE_PAPER_IMAGE=pandoc/ubuntu-latex:3.6
Pin digest (recommended in CI): CHUMP_WHITE_PAPER_IMAGE=pandoc/ubuntu-latex@sha256:...
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def load_manifest(root: Path) -> dict:
    p = root / "docs" / "white-paper-manifest.json"
    return json.loads(p.read_text(encoding="utf-8"))


def load_profiles(root: Path) -> dict:
    p = root / "docs" / "white-paper-profiles.json"
    if not p.is_file():
        return {}
    return json.loads(p.read_text(encoding="utf-8"))


def have_cmd(name: str) -> bool:
    return shutil.which(name) is not None


def pick_pdf_engine() -> str | None:
    if have_cmd("xelatex"):
        return "xelatex"
    if have_cmd("pdflatex"):
        return "pdflatex"
    return None


def git_revision(root: Path) -> str:
    try:
        r = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
        return r.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return "unknown"


def changelog_excerpt(root: Path, max_lines: int) -> str:
    p = root / "CHANGELOG.md"
    if not p.is_file():
        return "_No CHANGELOG.md found._\n"
    lines = p.read_text(encoding="utf-8").splitlines()
    body = "\n".join(lines[: max(0, max_lines)])
    return body + ("\n" if body and not body.endswith("\n") else "")


def make_roadmap_excerpt(root: Path, max_lines: int) -> str:
    p = root / "docs" / "ROADMAP.md"
    lines = p.read_text(encoding="utf-8").splitlines()
    head = "\n".join(lines[:max_lines])
    return (
        "# Roadmap (PDF excerpt)\n\n"
        + head
        + "\n\n---\n\n"
        + "*Truncated for PDF. Full checklist: `docs/ROADMAP.md` in the repository.*\n"
    )


def volume_with_profile(
    vol: dict,
    *,
    profile: str | None,
    profiles_doc: dict,
) -> dict:
    v = copy.deepcopy(vol)
    if not profile or profile in ("default", "none"):
        return v
    pdata = profiles_doc.get("profiles", {}).get(profile)
    if pdata is None:
        print(f"Unknown profile {profile!r}", file=sys.stderr)
        raise SystemExit(1)
    tweak = pdata.get("volumes", {}).get(v["id"])
    if not tweak:
        return v
    prep = tweak.get("prepend", [])
    app = tweak.get("append", [])
    merged = prep + v["sources"] + app
    seen: set[str] = set()
    out: list[str] = []
    for s in merged:
        if s not in seen:
            seen.add(s)
            out.append(s)
    v["sources"] = out
    return v


def volume_meta_yaml(
    title: str,
    subtitle: str,
    *,
    date_s: str,
    git_sha: str,
    profile: str,
) -> str:
    def esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')

    return f"""---
title: "{esc(title)}"
subtitle: "{esc(subtitle)}"
date: "{esc(date_s)}"
documentclass: article
fontsize: 11pt
geometry: margin=1in
colorlinks: true
linkcolor: blue
urlcolor: blue
keywords: ["chump", "white-paper", "{esc(profile)}"]
---
"""


# Inline Markdown links: [label](url) or [label](url "title")
_MD_LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
# Reference-style [text][id]
_REF_LINK_RE = re.compile(r"\[([^\]]+)\]\[([^\]]+)\]")
_REF_DEF_RE = re.compile(r"^[ \t]*\[([^\]]+)\]:\s+(\S+)")


def _parse_reference_definitions(text: str) -> dict[str, str]:
    defs: dict[str, str] = {}
    for line in text.splitlines():
        m = _REF_DEF_RE.match(line)
        if m:
            defs[m.group(1).strip().lower()] = m.group(2).strip()
    return defs


def expand_reference_links(text: str) -> str:
    """Turn [label][id] into [label](url) when [id]: url definitions exist."""
    defs = _parse_reference_definitions(text)

    def repl(m: re.Match[str]) -> str:
        label, rid = m.group(1), m.group(2).strip()
        url = defs.get(rid.lower())
        if url:
            return f"[{label}]({url})"
        return m.group(0)

    return _REF_LINK_RE.sub(repl, text)


def _resolve_local_md(href: str, current_file: Path, root: Path) -> Path | None:
    """If href points to a local .md file, return its resolved path; else None."""
    if href.startswith(("#", "http://", "https://", "mailto:", "ftp://")):
        return None
    path_part = href.split("#", 1)[0].split("?", 1)[0].strip()
    if not path_part.lower().endswith((".md", ".markdown")):
        return None
    p = Path(path_part)
    candidates = []
    if p.is_absolute():
        candidates.append(p.resolve())
    else:
        candidates.append((current_file.parent / path_part).resolve())
        candidates.append((root / path_part).resolve())
    for c in candidates:
        try:
            c.relative_to(root.resolve())
        except ValueError:
            continue
        if c.is_file():
            return c
    return None


def rewrite_md_links_for_bundle(
    text: str,
    *,
    current_file: Path,
    root: Path,
    included: set[Path],
) -> str:
    """Drop hyperlinks to .md files: in-bundle → label only; out-of-bundle → label + short note."""

    def repl(m: re.Match[str]) -> str:
        label, href = m.group(1), m.group(2).strip()
        target = _resolve_local_md(href, current_file, root)
        if target is None:
            return m.group(0)
        target = target.resolve()
        if target in included:
            return label
        return f"{label} *(full document not included in this PDF edition)*"

    return _MD_LINK_RE.sub(repl, text)


def build_edition_notice(
    *,
    git_sha: str,
    date_s: str,
    profile: str,
    changelog_lines: str,
) -> str:
    return f"""# About this PDF edition

This file bundles **only** the chapters listed in the white-paper manifest (and any profile appendices). Cross-references to other Markdown files in the repository have been **unlinked**: if a document was not included in this volume, the link text is kept and a short note is shown instead, so this PDF stands alone when you are not sharing the rest of the repo.

External **HTTP/HTTPS** links are unchanged.

## Build provenance

| Field | Value |
|-------|-------|
| Git revision | `{git_sha}` |
| Build date | {date_s} |
| Profile | `{profile}` |

## Changelog excerpt (repository)

```text
{changelog_lines.strip()}
```
"""


def build_included_set(
    root: Path,
    sources: list[str],
    *,
    roadmap_was_excerpt: bool,
) -> set[Path]:
    root = root.resolve()
    inc: set[Path] = set()
    for rel in sources:
        if rel == "docs/_generated_roadmap_excerpt.md" and roadmap_was_excerpt:
            inc.add((root / "docs" / "ROADMAP.md").resolve())
            continue
        inc.add((root / rel).resolve())
    return inc


def prepare_volume_workdir(
    root: Path,
    out_dir: Path,
    vol: dict,
    manifest: dict,
    *,
    git_sha: str,
    date_s: str,
    profile: str,
    changelog_excerpt_text: str,
) -> tuple[Path | None, list[str]]:
    """
    Write preprocessed sources under out_dir/._pre_<id>/ (mirrors repo paths).
    Returns (work dir, effective source paths relative to work) or (None, []) if missing.
    """
    vid = vol["id"]
    work = out_dir / f"._pre_{vid}"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)

    root = root.resolve()
    excerpt_lines = manifest.get("roadmap_excerpt_lines")
    roadmap_was_excerpt = False
    sources_eff: list[str] = []
    for rel in vol["sources"]:
        if rel == "docs/ROADMAP.md" and excerpt_lines:
            gen = "docs/_generated_roadmap_excerpt.md"
            gp = work / gen
            gp.parent.mkdir(parents=True, exist_ok=True)
            gp.write_text(make_roadmap_excerpt(root, int(excerpt_lines)), encoding="utf-8")
            sources_eff.append(gen)
            roadmap_was_excerpt = True
        else:
            sources_eff.append(rel)

    included = build_included_set(root, sources_eff, roadmap_was_excerpt=roadmap_was_excerpt)

    for rel in sources_eff:
        dest = work / rel
        if dest.is_file() and rel == "docs/_generated_roadmap_excerpt.md":
            raw = dest.read_text(encoding="utf-8")
            cur_file = (root / "docs" / "ROADMAP.md").resolve()
        else:
            src = root / rel
            if not src.is_file():
                shutil.rmtree(work, ignore_errors=True)
                return None, []
            raw = src.read_text(encoding="utf-8")
            cur_file = src.resolve()
        raw = expand_reference_links(raw)
        new = rewrite_md_links_for_bundle(
            raw, current_file=cur_file, root=root, included=included
        )
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(new, encoding="utf-8")

    (work / "_volume_meta.yaml").write_text(
        volume_meta_yaml(
            vol["title"],
            vol.get("subtitle", ""),
            date_s=date_s,
            git_sha=git_sha,
            profile=profile,
        ),
        encoding="utf-8",
    )
    (work / "_00_edition_notice.md").write_text(
        build_edition_notice(
            git_sha=git_sha,
            date_s=date_s,
            profile=profile,
            changelog_lines=changelog_excerpt_text,
        ),
        encoding="utf-8",
    )
    return work, sources_eff


def pandoc_input_order(sources_eff: list[str]) -> list[str]:
    return ["_volume_meta.yaml", "_00_edition_notice.md", *sources_eff]


def shlex_join(args: list[str]) -> str:
    return " ".join(shlex.quote(a) for a in args)


def find_chrome() -> Path | None:
    """Headless print-to-PDF needs a Chromium-based browser."""
    if sys.platform == "darwin":
        for p in (
            Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            Path("/Applications/Chromium.app/Contents/MacOS/Chromium"),
            Path.home()
            / "Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            Path.home() / "Applications/Chromium.app/Contents/MacOS/Chromium",
        ):
            if p.is_file():
                return p
    for name in ("google-chrome", "chromium", "chromium-browser", "chrome"):
        w = shutil.which(name)
        if w:
            return Path(w)
    return None


def output_html_path(out_dir: Path, vol: dict) -> Path:
    base = Path(vol["output"])
    return out_dir / (base.stem + ".html")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_checksums(out_dir: Path) -> None:
    for pat in ("*.pdf", "*.html"):
        for f in sorted(out_dir.glob(pat)):
            if f.name.startswith("._"):
                continue
            sum_path = f.with_suffix(f.suffix + ".sha256")
            hx = sha256_file(f)
            sum_path.write_text(f"{hx}  {f.name}\n", encoding="utf-8")


def write_dist_readme(
    out_dir: Path,
    *,
    git_sha: str,
    date_s: str,
    profile: str,
    volumes: list[dict],
) -> None:
    names: list[str] = []
    for v in volumes:
        pdf = out_dir / v["output"]
        if pdf.is_file():
            names.append(pdf.name)
        html = out_dir / (Path(v["output"]).stem + ".html")
        if html.is_file():
            names.append(html.name)
    lines = [
        "Chump white papers — distribution kit",
        "",
        "Chump is an autonomous agent stack (Rust core, optional Discord / web PWA, SQLite state,",
        "heartbeat rounds, and tool integrations). These PDFs are generated from the repository",
        "Markdown sources; the live documentation tree is the source of truth.",
        "",
        f"Build: {date_s}  git: {git_sha}  profile: {profile}",
        "",
        "Artifacts in this directory:",
        *(f"  - {n}" for n in names),
        *(("  (none — build may have failed)",) if not names else ()),
        "",
        "Verify integrity:",
        "  shasum -a 256 -c *.sha256",
        "",
        "Regenerate: ./scripts/setup/build-white-papers.py --docker",
        "",
    ]
    (out_dir / "README.txt").write_text("\n".join(lines), encoding="utf-8")


def try_merge_pdfs(out_dir: Path, pdf_paths: list[Path]) -> Path | None:
    exe = shutil.which("pdfunite")
    if not exe or len(pdf_paths) < 2:
        return None
    merged = out_dir / "chump-white-paper-merged.pdf"
    cmd = [exe, *[str(p) for p in pdf_paths], str(merged)]
    subprocess.run(cmd, check=True)
    print(f"Wrote {merged}")
    return merged


def build_one_volume_chrome(
    *,
    root: Path,
    out_dir: Path,
    vol: dict,
    manifest: dict,
    dry_run: bool,
    html_only: bool,
    git_sha: str,
    date_s: str,
    profile: str,
    changelog_excerpt_text: str,
) -> int:
    """Pandoc → standalone HTML → Chrome headless --print-to-pdf (no LaTeX)."""
    vid = vol["id"]
    out_pdf = out_dir / vol["output"]
    out_html = output_html_path(out_dir, vol)

    chrome = find_chrome()
    if not html_only and not chrome:
        print(
            "No Google Chrome or Chromium found for --chrome-pdf.",
            file=sys.stderr,
        )
        return 1

    out_dir.mkdir(parents=True, exist_ok=True)
    work: Path | None = None
    html_abs: Path | None = None
    sources_eff: list[str] = []

    try:
        if dry_run:
            work = out_dir / f"._pre_{vid}"
            target = out_html if html_only else out_pdf
            print(
                shlex_join(
                    [
                        "(preprocess →)",
                        str(work),
                        "then pandoc … -o",
                        str(target.with_suffix(".html") if not html_only else target),
                    ]
                )
            )
            return 0

        work, sources_eff = prepare_volume_workdir(
            root,
            out_dir,
            vol,
            manifest,
            git_sha=git_sha,
            date_s=date_s,
            profile=profile,
            changelog_excerpt_text=changelog_excerpt_text,
        )
        if work is None:
            print(f"Missing source file for volume {vid}", file=sys.stderr)
            return 1

        inputs = pandoc_input_order(sources_eff)
        html_name = f"._wp_build_{vid}.html"
        html_abs = out_dir / html_name
        out_pdf = out_pdf.resolve()
        out_html = out_html.resolve()
        out_html_rel = os.path.relpath(html_abs.resolve(), work.resolve())
        out_pdf_rel = os.path.relpath(out_pdf, work.resolve())

        pandoc_cmd = [
            "pandoc",
            "--from",
            "markdown+yaml_metadata_block+raw_tex+pipe_tables+fenced_divs+backtick_code_blocks",
            "--toc",
            "--toc-depth=3",
            "--number-sections",
            "--standalone",
            "--resource-path",
            f"{work}:{root}:{root / 'docs'}",
            "-o",
            out_html_rel,
            *inputs,
        ]

        print(
            f"Building {out_html.relative_to(root)} (HTML) …"
            if html_only
            else f"Building {out_pdf.relative_to(root)} (via HTML + Chrome) …"
        )
        subprocess.run(pandoc_cmd, cwd=str(work), check=True)
        if html_only:
            shutil.move(str(html_abs), str(out_html))
            print(f"Wrote {out_html}")
            return 0

        chrome_cmd = [
            str(chrome),
            "--headless=new",
            "--disable-gpu",
            "--no-pdf-header-footer",
            f"--print-to-pdf={out_pdf}",
            html_abs.resolve().as_uri(),
        ]
        subprocess.run(chrome_cmd, check=True)
        print(f"Wrote {out_pdf}")
        return 0
    except subprocess.CalledProcessError as e:
        print(f"build failed with exit {e.returncode}", file=sys.stderr)
        return e.returncode or 1
    finally:
        if html_only and html_abs and html_abs.exists():
            try:
                html_abs.unlink()
            except OSError:
                pass
        elif html_abs and html_abs.exists():
            try:
                html_abs.unlink()
            except OSError:
                pass
        if work and work.exists() and not dry_run:
            shutil.rmtree(work, ignore_errors=True)


def build_one_volume(
    *,
    root: Path,
    out_dir: Path,
    vol: dict,
    manifest: dict,
    docker: bool,
    pdf_engine: str,
    dry_run: bool,
    html_only: bool,
    git_sha: str,
    date_s: str,
    profile: str,
    changelog_excerpt_text: str,
) -> int:
    vid = vol["id"]
    out_pdf = out_dir / vol["output"]
    out_html = output_html_path(out_dir, vol)

    out_dir.mkdir(parents=True, exist_ok=True)
    work: Path | None = None
    sources_eff: list[str] = []

    try:
        if dry_run:
            work = out_dir / f"._pre_{vid}"
            target = out_html if html_only else out_pdf
            pandoc_cmd = [
                "pandoc",
                "…",
                "-o",
                str(target.relative_to(root)),
                "(inputs from",
                str(work),
                ")",
            ]
            cmd = pandoc_cmd
            if docker:
                cmd = ["docker", "run", "…", *pandoc_cmd]
            print(shlex_join(cmd))
            return 0

        work, sources_eff = prepare_volume_workdir(
            root,
            out_dir,
            vol,
            manifest,
            git_sha=git_sha,
            date_s=date_s,
            profile=profile,
            changelog_excerpt_text=changelog_excerpt_text,
        )
        if work is None:
            print(f"Missing source file for volume {vid}", file=sys.stderr)
            return 1

        inputs = pandoc_input_order(sources_eff)
        out_pdf = out_pdf.resolve()
        out_html = out_html.resolve()
        out_rel = os.path.relpath(out_pdf, work.resolve())
        out_html_rel = os.path.relpath(out_html, work.resolve())

        pandoc_from = (
            "markdown+yaml_metadata_block+raw_tex+pipe_tables+fenced_divs+backtick_code_blocks"
        )
        base_pandoc = [
            "pandoc",
            "--from",
            pandoc_from,
            "--toc",
            "--toc-depth=3",
            "--number-sections",
            "--resource-path",
            f"{work}:{root}:{root / 'docs'}",
        ]

        if html_only:
            pandoc_cmd = [
                *base_pandoc,
                "--standalone",
                "-o",
                out_html_rel,
                *inputs,
            ]
        else:
            pandoc_cmd = [
                *base_pandoc,
                "--pdf-engine",
                pdf_engine,
                "-o",
                out_rel,
                *inputs,
            ]

        if docker:
            image = os.environ.get("CHUMP_WHITE_PAPER_IMAGE", "pandoc/ubuntu-latex:3.6")
            # `pandoc/latex:*` images set ENTRYPOINT=pandoc, so passing
            # "pandoc" as the first arg makes pandoc try to open a file
            # NAMED "pandoc" (INFRA-WHITE-PAPERS-PANDOC root cause —
            # produces "pandoc: pandoc: withBinaryFile: does not exist").
            # Override entrypoint to empty so we control it as a normal arg.
            # `pandoc/ubuntu-latex` historically didn't have entrypoint;
            # the override is harmless when entrypoint is already empty.
            cmd = [
                "docker",
                "run",
                "--rm",
                "--entrypoint",
                "",
                "-v",
                f"{root}:/data",
                "-w",
                "/data",
                image,
            ]
            work_rel = work.relative_to(root)
            out_rel_docker = os.path.relpath(
                out_html if html_only else out_pdf, root
            )
            pandoc_docker = [
                "pandoc",
                "--from",
                pandoc_from,
                "--toc",
                "--toc-depth=3",
                "--number-sections",
                "--resource-path",
                f"/data/{work_rel}:/data:/data/docs",
            ]
            if html_only:
                pandoc_docker += [
                    "--standalone",
                    "-o",
                    out_rel_docker,
                    *[str(Path(work_rel) / p) for p in inputs],
                ]
            else:
                pandoc_docker += [
                    "--pdf-engine",
                    pdf_engine,
                    "-o",
                    out_rel_docker,
                    *[str(Path(work_rel) / p) for p in inputs],
                ]
            cmd = [*cmd, *pandoc_docker]
            cwd = None
        else:
            cmd = pandoc_cmd
            cwd = str(work)

        label = (
            out_html.relative_to(root) if html_only else out_pdf.relative_to(root)
        )
        print(f"Building {label} …")
        subprocess.run(cmd, cwd=cwd, check=True)
        print(f"Wrote {out_dir / (out_html.name if html_only else Path(out_pdf).name)}")
        return 0
    except subprocess.CalledProcessError as e:
        print(f"pandoc failed with exit {e.returncode}", file=sys.stderr)
        return e.returncode or 1
    finally:
        if work and work.exists() and not dry_run:
            shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description="Build Chump white paper PDFs from Markdown.")
    ap.add_argument(
        "--docker",
        action="store_true",
        help="Run pandoc inside pandoc/ubuntu-latex (no local TeX install).",
    )
    ap.add_argument(
        "--chrome-pdf",
        action="store_true",
        help="Use Pandoc → HTML then Chrome/Chromium headless print-to-PDF (good on Mac without LaTeX).",
    )
    ap.add_argument(
        "--volume",
        metavar="ID",
        help="Build only this volume id (e.g. volume-1-showcase).",
    )
    ap.add_argument(
        "--html-only",
        action="store_true",
        help="Emit standalone HTML per volume (no PDF engine / no Chrome print).",
    )
    ap.add_argument(
        "--profile",
        metavar="NAME",
        help="Merge optional sources from docs/white-paper-profiles.json (e.g. academic, defense, operator).",
    )
    ap.add_argument(
        "--merge",
        action="store_true",
        help="After PDF builds, merge volume PDFs into chump-white-paper-merged.pdf (requires pdfunite).",
    )
    ap.add_argument("--dry-run", action="store_true", help="Print commands only.")
    args = ap.parse_args()

    root = repo_root()
    manifest = load_manifest(root)
    profiles_doc = load_profiles(root)
    out_dir = root / manifest.get("output_dir", "dist/white-papers")

    if args.docker and args.chrome_pdf:
        print("Use only one of --docker or --chrome-pdf.", file=sys.stderr)
        return 1
    if args.merge and args.html_only:
        print("--merge is not available with --html-only.", file=sys.stderr)
        return 1

    use_docker = args.docker
    use_chrome = args.chrome_pdf
    html_only = args.html_only

    if args.dry_run:
        engine = "xelatex"
    elif use_chrome:
        if not have_cmd("pandoc"):
            print("pandoc not found. Install: brew install pandoc", file=sys.stderr)
            return 1
        engine = "xelatex"
    elif not use_docker:
        if not have_cmd("pandoc"):
            print("pandoc not found. Install: brew install pandoc", file=sys.stderr)
            print("Or run with --docker (requires Docker).", file=sys.stderr)
            return 1
        engine = pick_pdf_engine()
        if engine is None and not html_only:
            print(
                "No PDF engine (xelatex/pdflatex) on PATH. Install BasicTeX or MacTeX:",
                file=sys.stderr,
            )
            print("  brew install --cask basictex", file=sys.stderr)
            print("Then add TeX to PATH (often /Library/TeX/texbin).", file=sys.stderr)
            print("Or: ./scripts/setup/build-white-papers.py --docker", file=sys.stderr)
            print("Or: ./scripts/setup/build-white-papers.py --chrome-pdf", file=sys.stderr)
            print("Or: ./scripts/setup/build-white-papers.py --html-only", file=sys.stderr)
            return 1
    else:
        if not have_cmd("docker"):
            print("docker not found.", file=sys.stderr)
            return 1
        engine = "xelatex"

    git_sha = git_revision(root)
    date_s = date.today().isoformat()
    ch_lines = manifest.get("changelog_excerpt_lines", 40)
    changelog_excerpt_text = changelog_excerpt(root, int(ch_lines))
    profile = args.profile or "default"

    volumes_raw = manifest["volumes"]
    if args.volume:
        volumes_raw = [v for v in volumes_raw if v["id"] == args.volume]
        if not volumes_raw:
            print(f"No volume with id {args.volume!r}", file=sys.stderr)
            return 1

    volumes = [volume_with_profile(v, profile=profile, profiles_doc=profiles_doc) for v in volumes_raw]

    rc = 0
    for vol in volumes:
        if use_chrome:
            r = build_one_volume_chrome(
                root=root,
                out_dir=out_dir,
                vol=vol,
                manifest=manifest,
                dry_run=args.dry_run,
                html_only=html_only,
                git_sha=git_sha,
                date_s=date_s,
                profile=profile,
                changelog_excerpt_text=changelog_excerpt_text,
            )
        else:
            r = build_one_volume(
                root=root,
                out_dir=out_dir,
                vol=vol,
                manifest=manifest,
                docker=use_docker,
                pdf_engine=engine,
                dry_run=args.dry_run,
                html_only=html_only,
                git_sha=git_sha,
                date_s=date_s,
                profile=profile,
                changelog_excerpt_text=changelog_excerpt_text,
            )
        if r != 0:
            rc = r

    if rc == 0 and not args.dry_run:
        write_dist_readme(
            out_dir,
            git_sha=git_sha,
            date_s=date_s,
            profile=profile,
            volumes=volumes,
        )
        write_checksums(out_dir)
        if args.merge and not html_only:
            pdfs = [out_dir / v["output"] for v in volumes]
            if all(p.is_file() for p in pdfs):
                try_merge_pdfs(out_dir, pdfs)
                write_checksums(out_dir)
            else:
                print("--merge skipped: not all PDFs present.", file=sys.stderr)

    return rc


if __name__ == "__main__":
    raise SystemExit(main())
