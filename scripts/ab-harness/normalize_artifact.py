#!/usr/bin/env python3.12
"""Normalize a ship/release artifact JSON into a LaunchContext object.

Usage:
    normalize_artifact.py <artifact.json>

Reads the artifact, validates required fields (title, primary URL) plus
platform-specific rules (Show HN needs a URL, Substack needs a body), and
prints the normalized LaunchContext {"title", "url", "platform"} to stdout.

On any validation failure, prints "error: <reason>" to stderr and exits 1.
"""
import json
import sys


def normalize(artifact):
    title = artifact.get("title")
    if not title:
        print("error: missing title", file=sys.stderr)
        sys.exit(1)

    url = artifact.get("url") or artifact.get("primary_url")
    platform = artifact.get("platform", "")
    platform_key = platform.strip().lower()

    if platform_key == "show hn" and not url:
        print("error: Show HN requires a URL", file=sys.stderr)
        sys.exit(1)

    if platform_key == "substack" and not artifact.get("body"):
        print("error: Substack requires a body", file=sys.stderr)
        sys.exit(1)

    if not url:
        print("error: missing url", file=sys.stderr)
        sys.exit(1)

    return {"title": title, "url": url, "platform": platform}


def main():
    if len(sys.argv) != 2:
        print("usage: normalize_artifact.py <artifact.json>", file=sys.stderr)
        sys.exit(2)

    path = sys.argv[1]
    try:
        with open(path) as f:
            artifact = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    launch_context = normalize(artifact)
    print(json.dumps(launch_context))
    sys.exit(0)


if __name__ == "__main__":
    main()
