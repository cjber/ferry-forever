"""Make every LuaLS diagnostic actionable, independent of its process exit status."""

import json
import sys
from collections import Counter
from pathlib import Path
from urllib.parse import unquote, urlparse


def main():
    report = Path(sys.argv[1])
    if not report.exists():
        print(f"LuaLS did not write its diagnostic report: {report}", file=sys.stderr)
        return 1
    counts = Counter()
    # LuaLS serializes an empty Lua table as [] rather than {} on a clean run.
    diagnostics_by_file = json.loads(report.read_text()) or {}
    for uri, diagnostics in sorted(diagnostics_by_file.items()):
        path = Path(unquote(urlparse(uri).path))
        if path.is_relative_to(Path.cwd()):
            path = path.relative_to(Path.cwd())
        for diagnostic in sorted(diagnostics, key=lambda item: item["range"]["start"]["line"]):
            line = diagnostic["range"]["start"]["line"] + 1
            code = diagnostic["code"]
            message = " ".join(diagnostic["message"].splitlines())
            print(f"{path}:{line}: {code}: {message}")
            counts[code] += 1
    if counts:
        print("Diagnostics:", ", ".join(f"{code}={count}" for code, count in sorted(counts.items())))
    return int(bool(counts))


if __name__ == "__main__":
    sys.exit(main())
