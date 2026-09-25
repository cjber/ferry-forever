#!/usr/bin/env python3
"""Print every phrase the addon translates, as CurseForge's "Import localization" page takes Lua (stdlib only).

The phrases are the `L["..."]` keys in the Lua files the TOC loads, English text being its own key. The output
is committed as Locales/phrases.txt, and tests/locales_spec.lua fails when the two differ, so after changing a
phrase run

    python3 tools/phrases.py > Locales/phrases.txt

and paste the file into the CurseForge project's Localization > Import page (base language, English).
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOC = ROOT / "ShortestPathForever.toc"
PHRASE = re.compile(r'\bL\["((?:\\.|[^"\\])*)"\]')


def shipped_lua():
    for line in TOC.read_text().splitlines():
        line = line.strip()
        if line.endswith(".lua") and not line.startswith("#"):
            yield ROOT / line.replace("\\", "/")


def phrases():
    found = set()
    for path in shipped_lua():
        found.update(PHRASE.findall(path.read_text()))
    return sorted(found)


if __name__ == "__main__":
    for phrase in phrases():
        print(f'L["{phrase}"] = true')
