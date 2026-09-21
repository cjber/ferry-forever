#!/usr/bin/env python3
"""Print one version's section of CHANGELOG.md (stdlib only).

The release workflow hands what this prints to the packager, so GitHub, CurseForge and Wago show the same
words as the changelog in the repository. A tag with no entry, or an empty one, fails here rather than
publishing notes nobody wrote.

    python3 tools/changelog.py 0.2.0
"""

import re
import sys
from pathlib import Path

CHANGELOG = Path(__file__).resolve().parent.parent / "CHANGELOG.md"
HEADING = re.compile(r"^## \[?(?P<version>\d+\.\d+\.\d+)\]? - \d{4}-\d{2}-\d{2}\s*$", re.MULTILINE)


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


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: changelog.py VERSION")
    print(section(CHANGELOG.read_text(encoding="utf-8"), sys.argv[1].removeprefix("v")))
