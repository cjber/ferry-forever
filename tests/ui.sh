#!/bin/sh
# The UI checks: stubbed client frames plus Blizzard's own map, tracker and menu code, fetched pinned.
set -e
tools/fetch_blizzard_ui.sh
for t in tests/*_ui.lua; do luajit "$t"; done
echo "ui checks ok"
