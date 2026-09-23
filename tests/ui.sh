#!/bin/sh
# UI checks that need the local client-UI harness (stubs + Blizzard UI source), which cannot ship here.
# Set SPF_HARNESS to harness2.lua if it is not at the default path. CI runs only tests/*_spec.lua.
set -e
harness=${SPF_HARNESS:-$HOME/drive/proj/wow-handoff/scratch/harness2.lua}
luajit "$harness" >/dev/null
for t in tests/*_ui.lua; do luajit "$t"; done
echo "ui checks ok"
