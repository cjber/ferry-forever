#!/usr/bin/env python3
"""Deterministically join shipped base64 chunks without needing the original mmtile bake."""

import argparse
import re
from pathlib import Path

ENTRY = re.compile(r'\t\t\[(\d+)\] = \{\n((?:\t\t\t"[A-Za-z0-9+/]*",\n)+)\t\t\},')


def pack(source):
    return ENTRY.sub(lambda m: f'\t\t[{m[1]}] = "' + "".join(re.findall(r'"([^"]*)"', m[2])) + '",', source)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="*", type=Path)
    args = parser.parse_args()
    for path in args.files or sorted(Path(".").glob("ShortestPathForever_Nav*/Nav*.lua")):
        source = path.read_text()
        result = pack(source)
        assert pack(result) == result
        path.write_text(result)
        print(f"{path}: {len(source)} -> {len(result)} bytes")
