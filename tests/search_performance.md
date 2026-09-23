# Journey display and retained memory

Baseline: `6c75d965d1acf259504e1e666848c1a2719a6bb4`, copied with `git archive` to
`/tmp/spf-search-before`. All measurements use LuaJIT and the offline
UI fixture; no game client or saved-variable files were accessed.

## Display contract

`search_spec.lua` checks hidden candidates, the three-second grace period, atomic settlement,
both inclusive switch thresholds, comparison against measured costs of the original legs,
invalid-route replacement, one final swap, silent background searches, cache eviction and clear.
`search_ui.lua` checks actual map/minimap layers, destination pins, the grey loading row,
the stock spinner, idle Guide/compass, committed totals and releasing closed-map pin geometry.
Geometry for a grace preview does not take budget from the ongoing cost proof.

The tracker spinner is SharedXML's `SpinnerTemplate`, Group Finder's 16 px ring and sparks.
While a grace-period route is on screen, its stroke layer pulses through a native alpha
animation, 1.2 seconds eased at both ends. Half-second walked-leg trimming and minimap
arrival fading retain their existing harness coverage.

## Memory

`memory_bench.lua` preloads all three maps, drives the complete stubbed UI at 60 Hz, measures
`collectgarbage("count")` before and after a full collection, then releases cache owners in a
disposable process to attribute retained memory. Figures below are KB, excluding the 17,500 KB
packed maps and the initialized fixture/addon (1,438 before / 1,446 after).

| Route | Retained route/cache state before | After |
| --- | ---: | ---: |
| Auberdine → Tanaris | 3,435 | 1,525 |
| Auberdine → Eastern Plaguelands | 3,309 | 2,240 |
| Crossroads → Thunder Bluff | 4,961 | 1,486 |
| Ironforge → Menethil | 4,109 | 1,872 |
| Felwood `(6341.38, 557.68)` → `(5000, -2000)` | 6,802 | 3,209 |

The long Felwood run's whole Lua heap was **60,511 before collection / 25,740 retained** on the
baseline, and **57,981 / 22,155** afterward. Thus 34,771 / 35,826 KB was uncollected garbage.
The owner's exact 69,869.9 KB addon reading cannot be reconstructed from these different runtimes;
these measurements distinguish live state from garbage rather than treating that reading as a leak.
Frame boundaries and the existing CPU-based probe threshold affect retained baseline frontiers.

With the world map open, Felwood retained 8,738 → 5,512 KB above maps/base. Sequential release
attribution for that run was:

| Owner | Before KB | After KB |
| --- | ---: | ---: |
| FindMany coroutine frontiers/scratch | 1,180 | 0 |
| startCosts/goalCosts, batch results/probes | 39 | 23 |
| walkCache entries, excluding shared drawing points | <1 | <1 |
| Single planner topology | 682 | 682 |
| Path endpoint trees/connections/abstract paths | 1,881 | 21 |
| Remaining decoded graph/grid metadata | 2,345 | 2,363 |
| Transport geometry | 74 | 74 |
| Pooled strokes' Lua bookkeeping | 2,232 | 2,052 |

Shared geometry is charged to its last owner, not counted twice. Remaining memory includes
fixture frames and display state; fixture region tables do not measure native client region storage.
In a separate, non-destructive cross-continent clear test, retained state above maps/base fell
from **3,276 to 111 KB**. Packed maps remain loaded.

The walk cache is bounded to 64 entries. Endpoint results retain only the latest start and goal;
their suspended stacks/callbacks are released after settlement and rebuild only if another bound
is needed. Path retains at most 256 endpoint vectors and 16 abstract paths per map, releases local
trees at idle, and keeps its existing 24 MB active-grid / 4 MB graph accounting budgets. The planner
has one topology. Transport geometry is bounded by current route IDs and invalidates with data
replacement. Each line pool is capped at 4,096 paired strokes. Clear releases journey caches,
Path state and pooled journey geometry. `/path perf` explicitly collects before addon accounting.

## Settle speed and checks

Three fresh serial before/after pairs of `luajit -joff tests/journey_bench.lua`, pinned to one CPU
to reduce scheduling noise, gave these median frames at the unchanged 3 ms search budget:

| Route | Before | After |
| --- | ---: | ---: |
| Auberdine → Tanaris | 19 | 19 |
| Auberdine → Eastern Plaguelands | 24 | 26 |
| Crossroads → Thunder Bluff | 20 | 19 |
| Ironforge → Menethil | 16 | 16 |

Search/probe/planner-call counts are identical; every route settles once with zero straight resets.
Cross-continent's two-frame median difference is within the reproduced baseline's 24–26 frame
range, but exact historical wall-clock frame counts are not deterministic on this host.
The four complete walking simulations finish with zero route flips and retain both tram transfers.

Required checks: `luacheck . -q`, `stylua --check .`, every `tests/*_spec.lua`, and `sh tests/ui.sh`.
The release/resume test verifies exact frontier bounds after dropping a coroutine, and the optimality
spec still compares 30 seeded journeys plus eight fixed-place/water-mode cases against full searches.

```sh
luajit -joff tests/journey_bench.lua /tmp/spf-search-before
luajit -joff tests/journey_bench.lua
luajit -joff tests/memory_bench.lua felwood
luajit -joff tests/memory_bench.lua felwood open
luajit -joff tests/memory_bench.lua cross clear
# Run the same memory script by absolute path from the baseline directory for before readings.
```

Actual client animation appearance, native region memory and client GC/profiler accounting remain
unverified offline.
