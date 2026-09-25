#!/usr/bin/env python3
"""Print every phrase the addon translates, as a translation file to copy (stdlib only).

The phrases are the `L["..."]` keys in the Lua files the TOC loads, English text being its own key. The output
is committed as Locales/phrases.txt, and tests/locales_spec.lua fails when the two differ, so after changing a
phrase run

    python3 tools/phrases.py > Locales/phrases.txt

A translator copies it to Locales/<locale>.lua and translates the right-hand sides (Locales/README.md).
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOC = ROOT / "ShortestPathForever.toc"
PHRASE = re.compile(r'\bL\["((?:\\.|[^"\\])*)"\]')
HEADER = """\
-- Copy this file to Locales/deDE.lua (or your language's code), set that code below, translate the text on the
-- right of each line and delete any line you leave in English. Then add the file to ShortestPathForever.toc after
-- Locales\\enUS.lua. See Locales/README.md.
local _, ns = ...
if GetLocale() ~= "deDE" then
	return
end
local L = ns.L
"""


def shipped_lua():
    for line in TOC.read_text().splitlines():
        line = line.strip()
        # Translations use the same keys; the English in the code is what counts.
        if line.endswith(".lua") and not line.startswith(("#", "Locales")):
            yield ROOT / line.replace("\\", "/")


def phrases():
    found = set()
    for path in shipped_lua():
        found.update(PHRASE.findall(path.read_text()))
    return sorted(found)


if __name__ == "__main__":
    print(HEADER, end="")
    for phrase in phrases():
        print(f'L["{phrase}"] = "{phrase}"')
