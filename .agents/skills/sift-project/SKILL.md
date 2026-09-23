---
name: sift-project
description: "Project profile for sift in Shortest Path Forever: the exact quality-gate and evidence commands, live roots that must never be deleted as dead code, exclusions, conventions and risk order. Load before running sift or any code-quality, cleanup or dead-code work in this repository."
---

# sift project profile — Shortest Path Forever

<!-- Written by `sift setup`. Keep it factual: every command here has been run and works.
     Update it whenever an audit learns something (a live root, a false-positive source). -->

A World of Warcraft: Forever (Classic, `## Interface: 16001`) addon that plans journeys (walking, flights,
boats, lifts, tram, portals) and draws them on the map. Runtime is the WoW client's Lua 5.1 sandbox; files
load in `.toc` order and share one namespace table (`local addonName, ns = ...`). It ships through
BigWigs packager (`.pkgmeta`) to CurseForge/Wago/GitHub as one zip that also carries three load-on-demand
walking-map addons. The specs run headless under LuaJIT with stubbed WoW APIs. Python, one shell script and
C# under `tools/` generate the data offline; `.pkgmeta` keeps `tools/` and `tests/` out of the zip.

## Gate

Run in order from the repository root. All must pass before and after any audit slice.

| Step | Command | Pass means |
|---|---|---|
| Format (Lua) | `stylua --check .` | exit 0 (StyLua 2.5.2) |
| Format (Python) | `ruff format --check .` | exit 0 (ruff 0.16.8, `ruff.toml`) |
| Format (shell) | `shfmt -d tools/baker/bake.sh` | no diff |
| Lint (Lua) | `luacheck .` | `0 warnings / 0 errors` |
| Lint (Python) | `ruff check .` | `All checks passed!` |
| Lint (shell) | `shellcheck tools/baker/bake.sh` | exit 0 |
| Types (Lua) | `lua-language-server --check=. --checklevel=Error --logpath=.sift/runs/luals` | `no problems found`, exit 0 |
| Tests | `for s in tests/*_spec.lua; do luajit "$s" \|\| exit 1; done` | every spec prints `…: ok`; ~25 s total |
| Workflows | `actionlint && zizmor --offline .github` | exit 0 / "No findings" |
| Secrets | `gitleaks git --redact --no-banner .` | `no leaks found` |

Not in the gate but worth running after touching the planner: `luajit -joff tests/journey_bench.lua`,
`luajit tests/walk_sim.lua` (README lists both).

## Evidence

On-demand tools for audits. Output is candidates, never verdicts.

| Concern | Command | Known false positives |
|---|---|---|
| Dead code (Lua) | `luacheck .` (unused locals/values; clean today) | none so far |
| Diagnostics (Lua) | `lua-language-server --check=. --checklevel=Warning --logpath=.sift/runs/luals` (results print to stdout, not the log dir) | `duplicate-set-field` / `unbalanced-assignments` in tests are deliberate stub monkeypatching |
| Dead code (Python) | `uvx vulture tools --min-confidence 60` | clean today |
| Types (Python) | `uvx --with pillow ty check --extra-search-path tools --python-version 3.10 tools` | 5 inference errors in `gen_nav.py` (tuple unpacking, `dict.get` keys) + Pillow `Image.LANCZOS` — not bugs |
| Duplication | `npx --yes jscpd@4 --silent --reporters json --output .sift/runs/jscpd --ignore '**/ShortestPathForever_Nav*/**,**/Data/**,**/.sift/**,**/media/**,LICENSE' .` | the test harness preambles (`walk_sim`, `journey_bench`, `journey_optimal_spec`) repeat stub setup |
| Live roots (Lua) | `rg -n 'RegisterEvent\|SetScript\|hooksecurefunc\|SLASH_\|SlashCmdList\|LoadAddOn\|SendAddonMessage' -g '*.lua'` | — |

## Live roots

Things reached indirectly. The dead-code lens must treat these as referenced.

- `ShortestPathForever.toc` file list — load order; every listed file runs at login.
- `Map.xml` templates name the global mixins (`ShortestPathForever*PinMixin`); Blizzard's map canvas calls
  their `OnLoad`, `OnAcquired`, `OnReleased`, `OnMouseEnter`/`OnMouseLeave`, `OnClick`,
  `OnCanvasScaleChanged`, `OnCanvasSizeChanged` by name. Data-provider mixins' `RefreshAllData`,
  `RemoveAllData`, `OnAdded`, `OnRemoved`, `OnMapChanged` likewise.
- ObjectiveTracker module methods (Tracker.lua) are called by `ObjectiveTrackerManager`.
- `ns.X` / `function ns.X` exports are the cross-file API; a symbol defined in one file is used in another
  (and by specs via `loadfile(...)("ShortestPathForever", ns)`). Search every `.lua`, not just the file.
- `C_AddOns.LoadAddOn("ShortestPathForever_Nav" .. map)` (Path.lua) loads the walking maps by built name.
- SavedVariables `ShortestPathForeverDB` / `ShortestPathForeverCharDB`: keys (settings in Core.lua
  `DEFAULTS`, `anchors`, debug trace) persist in players' saved files.
- Sync wire format (Sync.lua, prefix `ShortPath1`): other players run older versions; message fields are
  a compatibility contract.
- Slash commands `/path`, `/shortestpath` (`SLASH_SHORTESTPATHFOREVER*`, `SlashCmdList`).
- `tools/*.py` are run by hand (README) and `tools/changelog.py` by `.github/workflows/release.yml`;
  `tools/bake_walks.lua` writes `Data/Walks.lua`; `tools/baker/bake.sh` drives `gen_nav.py` and the C# baker.
- Test seams: `Path.after`, `Path.clock` and `Path.budget` are replaced by specs; Journey's `ns.Path == nil`
  branches serve specs that load Journey without Path. Guards around them are not dead.
- The `taxiLog` / debug trace in SavedVariables is read by a human after `/path debug`; a bounded,
  debug-gated write there is a live output, not residue.
- `tests/journey_driver.lua` is a helper loaded by the journey specs; `journey_bench.lua` and
  `walk_sim.lua` are run by hand (README).

## Zones

How each part of the tree is reviewed. Unlisted paths are `production`.

| Path | Zone | Reason |
|---|---|---|
| `Data/Routes.lua`, `Data/Taxi.lua`, `Data/Transports.lua`, `Data/Portals.lua` | generated | `tools/gen_*.py`, "do not edit" header |
| `Data/Walks.lua` | generated | `luajit tools/bake_walks.lua > Data/Walks.lua` |
| `ShortestPathForever_Nav*/` | generated | `tools/baker/gen_nav.py` + `bake.sh`; excluded from luacheck/stylua/gitleaks |
| `tools/` | script | offline data generators, never shipped |
| `tools/baker/mappster.patch` | vendor | patch against upstream Mappster |
| `tests/` | test | headless LuaJIT specs, harnesses and a bench |
| `tests/journey_performance.md`, `README.md`, `tools/baker/README.md` | docs | |
| `CHANGELOG.md` | docs (history) | each entry is a release note; kept verbatim by policy |
| `.github/`, `.pkgmeta`, `.luacheckrc`, `.luarc.json`, `stylua.toml`, `ruff.toml`, `.gitleaks.toml` | config | |
| `media/` | asset | |

## Conventions

- Tabs, 120 columns (StyLua, luacheck, ruff). Double quotes.
- Each file opens `local addonName, ns = ...` (or `local _, ns = ...`) and publishes modules as `ns.Name`
  tables; locals cache `ns.Model` etc. at file top. Globals only where WoW requires them (mixins,
  SavedVariables, slash commands) — all listed in `.luacheckrc`.
- Modules start via `ns.Init(fn)` after `ADDON_LOADED`, each under `xpcall` so one failure does not stop
  the rest (Core.lua `Start`).
- Comments explain why, in full sentences, often citing the Blizzard source file and line a behaviour
  depends on; they are the project's documentation style, not narration.
- Specs are plain LuaJIT scripts with `assert`, stubbing WoW APIs and loading production files by
  `loadfile`; they end by printing `<name>: ok`.
- Generated files carry a `-- Generated by … — do not edit.` header naming their generator.
- Any string a generator emits (headers, fit tables, messages) is generated data: changing it is a data
  diff, so such findings are reported, not applied during an audit.
- The BigWigs packager already drops dotfiles and git-ignored paths from the zip; `.pkgmeta` `ignore`
  only needs visible, tracked files (e.g. `ruff.toml`, `tools/`, `tests/`).

## Risk order

Audit slices from lowest to highest risk:

1. docs + config (`README.md`, `tools/baker/README.md`, `tests/journey_performance.md`, config files)
2. `tools/` — offline generators; output is checked in, so a change is visible as a data diff
3. `tests/`
4. UI leaves: `Alert.lua`, `Arrow.lua`, `Compass.lua`, `Settings.lua`, `Taxi.lua`, `Tracker.lua`
5. Map layers: `Map.lua`, `Map.xml`, `Route.lua`
6. State and wire: `Model.lua`, `Core.lua`, `Observer.lua`, `Sync.lua` (SavedVariables, wire format)
7. Planning core: `Planner.lua`, `Path.lua`, `Journey.lua` (performance-tuned, 3 ms frame budget)

## Project rules and lenses

- Rules: none yet.
- Lenses: none yet.
