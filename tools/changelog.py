#!/usr/bin/env python3
"""Print one version's section of CHANGELOG.md, or check that every release has one (stdlib only).

The release workflow hands what this prints to the packager, so GitHub, CurseForge and Wago show the same
words as the changelog in the repository. A tag with no entry, or an empty one, fails here rather than
publishing notes nobody wrote. CI runs `--check`, so a released version the changelog forgot fails on the
next push instead of going unnoticed.

    python3 tools/changelog.py 0.2.0           # that version's entry (a leading v is fine)
    python3 tools/changelog.py --check         # every v* tag has an entry, and Unreleased is there
    python3 tools/changelog.py --check 0.3.0   # that version has an entry, before it is tagged
"""

import argparse
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"
HEADING = re.compile(r"^## \[?(?P<version>\d+\.\d+\.\d+)\]? - \d{4}-\d{2}-\d{2}\s*$", re.MULTILINE)
UNRELEASED = re.compile(r"^## \[Unreleased\]\s*$", re.MULTILINE)


def section(text, version):
    matches = list(HEADING.finditer(text))
    for index, match in enumerate(matches):
        if match["version"] == version:
            end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
            body = text[match.end() : end].strip()
            if not body:
                raise SystemExit(f"CHANGELOG.md's section for {version} is empty")
            return body
    known = ", ".join(m["version"] for m in matches) or "none"
    raise SystemExit(f"CHANGELOG.md has no section for {version} (has: {known})")


def released():
    """Every released version, from the repository's v* tags (CI checks out with fetch-depth 0)."""
    tags = subprocess.run(
        ["git", "tag", "--list", "v*"], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout.split()
    return [tag.removeprefix("v") for tag in tags if re.fullmatch(r"v\d+\.\d+\.\d+", tag)]


def check(text, versions):
    if not UNRELEASED.search(text):
        raise SystemExit("CHANGELOG.md has no ## [Unreleased] heading")
    for version in versions:
        section(text, version)
    print(f"CHANGELOG.md documents {', '.join(versions) or 'no releases yet'}")


def main():
    parser = argparse.ArgumentParser(description="Print one version's changelog entry.")
    parser.add_argument("version", nargs="?", help="the version to print, e.g. 0.2.0")
    parser.add_argument(
        "--check", nargs="?", const="", metavar="VERSION", help="fail unless every tag (or VERSION) has an entry"
    )
    args = parser.parse_args()
    text = CHANGELOG.read_text(encoding="utf-8")
    if args.check is not None:
        check(text, [args.check.removeprefix("v")] if args.check else released())
        return
    if not args.version:
        parser.error("give a version or --check")
    print(section(text, args.version.removeprefix("v")))


if __name__ == "__main__":
    main()
