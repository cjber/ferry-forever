# Lua type checking

Run `tools/typecheck.sh` with LuaLS **3.19.1**, Python 3.10+, and git. The first run fetches
[Ketho's WoW API annotations](https://github.com/Ketho/vscode-wow-api/tree/d0b5b51fac4c52c493371b9b18e66ce604ea4326)
into `.types/vscode-wow-api`; later runs reuse that clean, pinned checkout. CI verifies the LuaLS
release archive's SHA-256 and runs the same command.

LuaLS checks all runtime Lua, including the generated data and all three walking-map addons.
The coverage check rejects excluded or oversized TOC files and follows XML file references.
LuaLS has a hard 10 MiB file limit; `tools/pack_nav.py` splits larger walking maps into
TOC-ordered parts. The gate tests inject errors into both parts of the Kalimdor map to
verify that neither is silently skipped.
Tests and generators are outside the game sandbox and excluded from LuaLS. The multi-value
checker also scans those files. No type files ship in the addon.

`Addon.lua` describes the shared data; each module reopens `SPFNamespace` so its exports are
checked across files. Custom frames and mixins extend the WoW frame types. Generated namespace
annotations come from their generators, never manual data edits.

The pinned annotation repository's FrameXML directory is empty. `Forever.lua` declares the
missing interfaces used here, checked against Gethe/wow-ui-source's `forever` branch. It does
not replace the annotated Core API. Two call-site suppressions in Journey.lua describe actual
client differences: `IsPlayerSpell` remains available, and `GetQuestUiMapID` accepts two arguments.

The tokenizer/parser rejects bare `select(...)` at the end of call arguments, table constructors,
or returns. Use `(select(...))` for one value. An intentional expansion needs a trailing
`-- multi-value: explain why` on the final line of that expression list. Regression tests verify
both the parser and the required LuaLS diagnostics, including GetClassColor's extra-argument error.
