# Idle and event audit — 2026-09-23

Baseline: `a29b6a7` on `cb/ferry`; after: this uncommitted working tree. All tests are offline. No client,
windows, input or SavedVariables were accessed. The earlier search report is retained below.

## What the audit proved

- The suspected unconditional tracker relayout was **already prevented**: `Tracker.lua` compared
  structure, edited countdown lines in place and dirtied only structure/wrapping changes. Baseline
  `activity_bench.lua idle` recorded **189 timer callbacks, 177 position reads, zero MarkDirty calls**
  in 60 seconds. Rebuilding the empty block list still allocated 0.061 KB/s. A scalar signature now
  exits before formatting/allocating; the dormant travel clock eliminates those callbacks altogether.
- Observer, tracker, alerts and dock requests had independent permanent tickers. One shared 1 s clock
  now runs only while moving, within 200 yards of a landing, observing a ride, following a journey or
  tracing debug samples. Movement, world/zone changes, regained control and player vehicle exit wake
  it. Two samples after waking detect passive movement even after a mid-crossing reload. A ride keeps
  sampling until its existing 30 s gap expires. All dock consumers share one proximity lookup.
- A sighting called `RefreshMap`, rebuilding portal/flight/transport pins despite unchanged geometry.
  Sightings now refresh only an owned tooltip and tracker data. Dock filtering reads cached static
  visits instead of constructing/sorting live departures. Taxi event bursts coalesce while the map
  is visible. External pin-pool release invalidates retained dock pins before reacquisition.
- Journey, arrow and compass frames were already hidden when unused; minimap updates were already
  removed on clear. Their idle OnUpdates were **not** a root cause. The waypoint-provider hook remains
  a constant-time Guide guard; the minimap hook exits before any lookup unless Shift-left-clicked.
  Arrow/compass distance text now changes only when the displayed yard value changes.
- The 510 shared terrain-link masks were built at file load; they now materialize on first use,
  preserving the nil representation of an empty mask. Walking-map strings remain load-on-demand.
  Combat pauses the search queue until `PLAYER_REGEN_ENABLED`, hides the journey driver, and defers
  tracker work and quadratic ride fitting. Necessary ride samples continue; arrival alerts and dock
  queries are suppressed during combat.

## Paired measurements

`luajit -joff tests/activity_bench.lua <scenario>`: three fresh processes per version/scenario, alternating
before/after, simulated 60 Hz, 40 s warm-up then 60 s measured. GC is stopped during allocation measurement.
CPU below times only invoked addon callbacks (including the forced tracker layout in `panel`); the
harness also prints dispatcher-inclusive time, about 0.03–0.07 ms/s, dominated by stub iteration/noise.
KB/s is heap growth, **not** retained memory. Panel churn forces 20 tracker layouts/s plus profession,
bag and unrelated-unit events; it measures this module's contribution, not Blizzard's whole tracker.

| Scenario | Addon ms/s before → after | Allocated KB/s before → after |
| --- | ---: | ---: |
| Idle, away from docks | 0.0031 → 0.0000 | 0.061 → 0.000 |
| Near Ratchet dock, timed boat | 0.0082 → 0.0033 | 2.318 → 1.735 |
| Walking, no journey | 0.0065 → 0.0052 | 0.061 → 0.017 |
| Passive route 241 ride | 0.0248 → 0.0245 | 0.956 → 0.797 |
| Panel-like tracker churn | 0.0065 → 0.0036 | 0.061 → 0.000 |
| Stationary combat, away from docks | 0.0029 → 0.0000 | 0.061 → 0.000 |

After warm-up, idle has **zero timer/frame callbacks, position reads and MarkDirty calls**. Dock/walk/ride
scenarios use 59 shared timer callbacks instead of 189 independent callbacks. The ride benchmark asserts
route 241 is actually recognized, so sleeping through a ride cannot produce a false gain.

Login medians across those 18 processes per version (TOC Lua parsing/execution, then ADDON_LOADED and
PLAYER_ENTERING_WORLD, with nav unloaded): **5.415 → 5.316 ms load; 0.084 → 0.084 ms init**. Allocations:
**2,831.4 → 2,770.0 KB load; 38.1 → 40.9 KB init**. Post-GC addon load/init growth: **1,295.5 → 1,224.6 KB**.
These include stub frame/settings creation, not engine XML work, rendering or disk cold-cache guarantees.
Static route/taxi/walk tables still parse at login; no nav decode or planner graph is built there. The
normal one-time 15 s guild/group timing request is excluded from steady-state measurements.

`runtime_bench.lua` uses the same paired three-process method. The table retains full-frame timings;
max is the largest frame in all three runs. Active journeys remain within their previous performance range.

| Scenario | Mean ms/frame before → after | Max ms before → after | KB/frame before → after |
| --- | ---: | ---: | ---: |
| Walking, map closed, minimap disabled | 0.0059 → 0.0059 | 1.185 → 1.273 | 0.591 → 0.582 |
| Walking, world map + minimap | 0.0094 → 0.0099 | 1.518 → 1.291 | 1.563 → 1.554 |
| Stationary journey + minimap | 0.0061 → 0.0061 | 1.651 → 1.731 | 0.612 → 0.599 |
| Aboard journey + minimap | 0.0032 → 0.0034 | 0.467 → 0.439 | 0.589 → 0.585 |
| Tanaris search | 2.9273 → 2.9934 | 3.311 → 3.339 | 453.988 → 458.487 |
| Cross-continent search | 2.9568 → 3.0158 | 3.272 → 3.197 | 447.109 → 468.819 |
| Unchanged map refresh (per call) | 0.2078 → 0.1117 | 0.430 → 0.221 | 104.573 → 71.448 |

Search work is unchanged; per-frame allocation varies with how much work fits the slice. Deferred masks
shift some allocations from login to the first search. Runtime harness/addon base falls 1,509.6 → 1,438.7 KB;
including that base, retained Tanaris state is 13,914.8 → 13,911.3 KB and walking with the map open is
16,927.9 → 16,937.6 KB. Dock caches add about 13 KB once all pins have been used. No collector tuning or
forced collection was added to the addon.

`journey_bench.lua` before/after: 7/6/12/8 searches, 3/3/7/3 planner calls, one settling round and zero
straight resets for Tanaris/Eastern Plaguelands/Thunder Bluff/Menethil. Example frame counts were
19/23/19/15 → 18/24/19/15; CPU-dependent slice boundaries vary. `walk_sim.lua` keeps zero route flips.

## API evidence and prior art

Client source was read from `Interface/AddOns/` of [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source/tree/forever), branch `forever`:

- `Blizzard_ObjectiveTrackerModule.lua:86,126` and `Blizzard_ObjectiveTrackerContainer.lua:65`:
  MarkDirty propagates to the container; clean complete modules can skip dirty-only layouts, while
  full layouts replay contents. `Blizzard_ProfessionsRecipeTracker.lua:11` subscribes to currency,
  recipe and delayed bag changes. Hence cached rendered blocks, unchanged-text checks and no hooks on
  the tracker update path. Offline tests cannot prove absence of client taint or native layout cost.
- `Blizzard_MapCanvas/MapCanvas_DataProviderBase.lua:34,84` requires refreshes to tolerate a blank map;
  OnMapChanged refreshes the provider. `Blizzard_MapCanvas.lua:357,673,699` releases pools and fans out
  refreshes. Hence no blind "same map" early return after pins are released, and no full refresh on a sighting.
- Generated `MapDocumentation.lua:437` returns a Vector2DMixin value from GetPlayerMapPosition;
  `UnitDocumentation.lua:2714` returns four numbers from UnitPosition. The travel loop uses the latter.
  `SimpleFrameAPIDocumentation.lua:1063` supports unit-filtered registration. `GlobalCallbackRegistry.lua`
  reference-counts frame events and `CallbackRegistry.lua` dispatches owned callbacks; direct narrow
  registrations suffice here. AREA_POIS changes map POIs, not fixed transport proximity, so it is not registered.
- Generated `AddOnProfilerDocumentation.lua` and `AddOnProfilerConstantsDocumentation.lua`: GetAddOnMetric
  time metrics are milliseconds, RecentAverageTime covers 60 ticks, PeakTime covers the session, and
  CountTimeOver5Ms is a count. `/path perf` uses these enums with API guards; memory refresh is explicit only
  and includes the three nav addons. It does not enable scriptProfile or reset global measurements.
- [Questie's compiler](https://github.com/Questie/Questie/blob/master/Database/compiler.lua) batches/yields
  compilation and pauses in combat; its [map queues](https://github.com/Questie/Questie/blob/master/Modules/Map/QuestieMap.lua)
  throttle drawing and batch minimap work. This supports lazy masks and event-resumed search work, while
  retaining the existing budgeted/nav-on-demand architecture.
- [WeakAuras](https://github.com/WeakAuras/WeakAuras2/blob/main/WeakAuras/GenericTrigger.lua) removes OnUpdate
  when its last consumer unregisters and filters unit events; [Plater](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)
  throttles plate work with per-frame limits. Hence demand-driven travel polling, narrow events and retained
  search budgets. [Details](https://github.com/Tercioo/Details-Damage-Meter/blob/master/functions/profiles.lua)
  also separates display refresh with an update interval; it does not justify polling inactive features.
- [HandyNotes](https://github.com/Nevcairiel/HandyNotes/blob/master/HandyNotes.lua) refreshes the affected
  plugin's pins on notification. [TomTom's arrow](https://github.com/MURPHYENGINEERING/tomtom/blob/master/TomTom_CrazyArrow.lua)
  (public mirror) hides when unused, keeps a title dirty flag and throttles ETA. These informed scoped map
  invalidation and preserving active arrow motion while avoiding unchanged distance text writes.

## Verification and reproduction

The UI fixture gained cancellable tickers, unit-filtered events, movement/combat/height stubs and proper
ADDON_LOADED dispatch. `activity_ui.lua` asserts sleep/wake, unrelated events, countdown line reuse,
wrapping, combat recovery, passive boat/lift sync, external pin release, sighting scope, suspended search
recovery, and profiler present/absent behavior. `nav_compare.lua` can compare both old and packed link formats.

```sh
luacheck . -q
stylua --check .
for spec in tests/*_spec.lua; do luajit "$spec" || exit; done
luajit tests/walk_sim.lua
luajit tests/nav_compare.lua /tmp/spf-a29b6a7
luajit -joff tests/journey_bench.lua /tmp/spf-a29b6a7
luajit -joff tests/journey_bench.lua
luajit "$SPF_HARNESS"
luajit -joff "$SPF_HARNESS"
for s in idle dock walking ride panel combat; do luajit -joff tests/activity_bench.lua "$s"; done
```

The baseline is a plain source copy captured before editing, without changing git state. Run the current
benchmark script by absolute path with that copy as cwd for the before result; use the same updated fixture
for both. Real profession-panel latency, transport event timing, rendering, taint and profiler readings
still require owner testing in game with `/path perf`; the offline results do not claim to explain all
client hitches.

---

# Runtime verification — 2026-09-23

Baseline: `9921ef4` on `cb/ferry`; after: the uncommitted runtime changes. All work and verification were offline. No client or SavedVariables access was used.

## Frame time, allocation and retained memory

`tests/runtime_bench.lua` uses the UI stubs from the offline harness (`$SPF_HARNESS`, kept outside the repo; see `tests/ui.sh`), `luajit -joff` and simulated 60 Hz frames. Each version/scenario runs in three fresh processes, serially, alternating before/after. Means, allocations and resident sizes below are medians; **worst is the largest frame across all three runs**. Times cover addon Lua and stub calls, not client rendering. CPU frequency and slice boundaries affect timings.

Allocation runs stop GC during the measured interval. KB/frame is the resulting heap growth, not live memory. Resident KB is the post-full-GC increase above the initialized harness/addon, including loaded nav strings, retained endpoint searches and UI geometry. The excluded harness/addon base is approximately 1,407 KB before and 1,506 KB after (including shared link masks). Zero means no additional retained scenario state.

| Scenario | Mean ms, before → after | Worst ms, before → after | KB/frame, before → after | Resident KB, before → after |
| --- | ---: | ---: | ---: | ---: |
| Idle | 0.0007 → 0.0006 | 0.010 → 0.007 | 0.006 → 0.002 | 0 → 0 |
| Walking, map closed, minimap line disabled | 0.0096 → 0.0058 | 2.340 → 1.138 | 3.281 → 0.591 | 28,888 → 13,556 |
| Walking, world map open + minimap | 0.0132 → 0.0103 | 2.654 → 1.613 | 4.255 → 1.563 | 30,727 → 15,414 |
| Walking, minimap only | 0.0124 → 0.0085 | 2.709 → 1.231 | 3.991 → 1.303 | 28,894 → 13,568 |
| Settled, stationary, minimap | 0.0131 → 0.0061 | 3.276 → 1.962 | 4.337 → 0.612 | 22,418 → 12,405 |
| Search, Auberdine → Tanaris | 3.3158 → 2.9772 | 7.955 → 3.103 | 759.508 → 454.007 | 22,418 → 12,404 |
| Search, Auberdine → Eastern Plaguelands | 3.5902 → 2.9736 | 6.533 → 3.284 | 879.339 → 447.121 | 41,080 → 20,259 |
| Boat, active route 241 journey + minimap | 0.0063 → 0.0031 | 2.462 → 0.555 | 2.448 → 0.589 | 26,953 → 18,167 |
| Boat, route 241 observation only | 0.0011 → 0.0010 | 0.046 → 0.042 | 0.034 → 0.007 | 2.6 → 2.5 |

Walking follows the measured Felwood path from `(6341.38, 557.68)` to `(5068.4, -337.22)` at 7 yd/s for 30 seconds, including timed replans. Stationary follows a settled Auberdine→Tanaris journey for 30 seconds, with six replans. Boat measures 30 seconds along route 241. The active case starts with a settled Ratchet→Booty Bay journey, supplies a known ride/anchor and checks that the journey stays aboard through six replans; observation-only omits the journey. `walk_sim.lua` separately checks complete boat/tram journeys. Search rows preload their continents and include the complete UI frame, callbacks and planning; the click is measured separately.

With default GC enabled, Tanaris mean/worst was **3.285/4.043 → 2.888/3.161 ms**; cross-continent was **3.667/7.968 → 2.990/3.236 ms**. No forced collections or collector tuning were applied. All recorded warm search maxima, with or without GC, stay below 3.3 ms.

## Attribution and tradeoffs

- **Unbudgeted decoding and callbacks:** grid/height/floor loops previously ran to completion and planning ran after a search slice. Decode checkpoints now preserve private, incomplete grids across yields; planning callbacks run as prioritized coroutines under the same deadline. `runtime_spec.lua` forces tiny budgets and checks suspension, cancellation and released coroutine state. Compact/shared floor links, lazy entrance/edge decoding, scratch reuse and avoiding repeated connectivity scans reduce search allocation by 40–49% per frame in the table.
- **Nav strings and decoded state:** the four per-cluster concatenations are gone. Kalimdor packed resident memory falls **14,563.1 → 9,930.4 KB (31.8%)**. No baker inputs were present under `tools/baker/work`; `tools/pack_nav.py` deterministically converted the shipped data instead. The baker now emits the same single-string format. All **6,379 fields** equal the concatenation of the old fields; conversion is idempotent. `nav_compare.lua` checks all **1,746 clusters** for identical surfaces, moves, heights, floors and directed link sets.
- **Cache retention:** decoded grids have a conservative global 24 MB accounting budget, a 64-cluster per-map ceiling and a four-grid minimum; active coroutine locals are additional. Graph metadata/edges use a 4 MB target and decode lazily. Idle queues release decoded grids and spare scratch while preserving reusable endpoint frontiers, cost vectors and eight endpoint connections per map. Retained state excluding packed nav falls **7,854.8 → 2,474.0 KB** after Tanaris and **15,334.7 → 2,990.2 KB** after cross-continent. Both versions decode 13/20 grids respectively. An experimental 2–8 MB active grid cache decoded 34 grids for Tanaris and nearly doubled frames; it was discarded. Releasing grids at idle preserves that reuse during a search without retaining whole grids afterwards.
- **Settled planning:** six `Planner.Plan` calls average **2.728 → 1.397 ms**, allocate **1,034.4 → 139.6 KB/call**, and have a recorded worst **3.167 → 1.870 ms**. Fixed topology and baked edges are cached; endpoint costs, taxi discovery, ride/timetable inputs and labels update each plan. Data identity, faction, water mode, speed or an explicit revision invalidate the topology. Only winning labels become leg tables. Cached/fresh planner equivalence covers those inputs and retained endpoint objects.
- **Drawing:** stationary minimap lines reuse their geometry until position, facing, radius, dimensions, scale, shape or route geometry changes; pulse alpha continues independently. Transport geometry survives map refreshes, including pin-pool anchor resets. An unchanged full refresh (100 calls) falls **0.7129/1.068 → 0.2137/0.367 ms mean/worst**, **563.675 → 104.573 KB/call**; retained UI state is **1,557.9 → 1,562.1 KB**. The small residency tradeoff avoids rebuilding transport paths and strokes.
- **Polling and observation:** Guide ownership uses the already registered waypoint/tracking events. Observer skips speed-ineligible routes and reuses position/empty-phase tables. Isolated walking observation falls **0.029 → 0.002 KB/frame** (1.74 → 0.12 KB per one-second sample); mean remains 0.0007 ms, recorded worst 0.012 → 0.030 ms. Its retained memory is unchanged; the gain is allocation reduction. Harness assertions exercise manual waypoint replacement/removal, tracking handoff and stationary minimap invalidation.

Cold loading remains a separate limit: `C_AddOns.LoadAddOn` is atomic. It now runs after the click and separately from first decode. The stubbed cold click falls **29.191 → 1.277 ms**; subsequent frame mean/worst is **4.6389/34.220 → 3.4039/14.614 ms**, allocation **1,468.565 → 1,114.808 KB/frame**, resident **35,156 → 20,303 KB**. Thus the 3.5 ms target is met for warm search work, **not** for first-use addon loading. The stub uses `loadfile`; actual client loader, GC pauses, rendering and visual appearance remain unverified.

## Journey completion and correctness

`luajit -joff tests/journey_bench.lua`, three fresh serial before/after pairs, retains or improves every median frame count:

| Journey | Before frames (runs) | After frames (runs) | Median before → after |
| --- | --- | --- | ---: |
| Auberdine → Tanaris | 17 / 20 / 19 | 19 / 19 / 18 | 19 → 19 |
| Auberdine → Eastern Plaguelands | 25 / 29 / 28 | 24 / 25 / 24 | 28 → 24 |
| Crossroads → Thunder Bluff | 23 / 24 / 23 | 18 / 18 / 21 | 23 → 18 |
| Ironforge → Menethil | 33 / 39 / 34 | 16 / 16 / 16 | 34 → 16 |

Each settles once with zero straight-line resets. This driver preloads all three maps and differs from the full UI frame scenarios above. Fixed-place endpoints can strengthen their lower bound with the rounded baked cost minus 0.5 yards, only after confirming the same snapped nav surface. This removes unnecessary probes (cross-continent 3→2, Crossroads 10→8, Ironforge 11→2); winning endpoint walks still require exact search costs. Eight additional full-search comparisons cover these four journeys in both water modes.

All required checks pass, plus `runtime_spec.lua`, `path_many_spec.lua`, `journey_spec.lua`, `sync_spec.lua`, the expanded no-JIT optimality spec and the UI harness with JIT both on and off. The four walking simulations finish with zero route flips; Ironforge→Menethil retains both tram transfers. The harness additions cover stationary redraw invalidation, Guide event ownership and pooled map-pin anchors.

## Reproduction

Run from the repo root. `SPF_HARNESS` can override the external stub harness path. The archive command only reads git state.

```sh
mkdir -p /tmp/spf-runtime-before
git archive 9921ef4 | tar -x -C /tmp/spf-runtime-before
runtime_bench="$PWD/tests/runtime_bench.lua"
for scenario in idle closed open minimap stationary tanaris cross boat aboard observer refresh cold; do
  for run in 1 2 3; do
    (cd /tmp/spf-runtime-before && luajit -joff "$runtime_bench" "$scenario")
    luajit -joff "$runtime_bench" "$scenario"
  done
done
# Repeat tanaris/cross with the final argument gc for collector-enabled measurements.
luajit -joff tests/runtime_bench.lua cross gc
luajit -joff tests/journey_bench.lua /tmp/spf-runtime-before
luajit -joff tests/journey_bench.lua
luajit tests/nav_compare.lua /tmp/spf-runtime-before
luacheck . -q
stylua --check .
for spec in tests/*_spec.lua; do luajit "$spec" || exit; done
luajit -joff tests/journey_optimal_spec.lua
luajit tests/walk_sim.lua
luajit "$SPF_HARNESS"
luajit -joff "$SPF_HARNESS"
```

The measured baseline also had a single `Path.decodes` counter added to `decodeGrid` for the cache-tradeoff audit; it does not change search decisions. Absolute results differ from the supplied audit because these scenarios drive the complete stubbed frame and report the maximum across three runs.

---

The following records the earlier bounded-search stage; its numbers and “working tree” commands refer to 9921ef4, not the runtime changes above.

# Prior bounded journey verification (9921ef4)

All measurements use `luajit -joff`, a 3 ms shared search budget and simulated 60 Hz frames. Numbers are medians of three serial runs on this host; each benchmark process starts fresh. No client or SavedVariables access was used.

| Journey | 2e4753a | af9b9d4 | 9921ef4 |
| --- | ---: | ---: | ---: |
| Auberdine → Tanaris | 20 | 161 | 20 |
| Auberdine → Eastern Plaguelands | 85 | 215 | 31 |
| Crossroads → Thunder Bluff | 38 | 134 | 25 |
| Ironforge → Menethil | 220 | 124 | 37 |

| Harness Felwood goal (map 1, x north / y west) | 2e4753a | af9b9d4 | 9921ef4 |
| --- | ---: | ---: | ---: |
| 5068.4, −337.22 | 38 | 177 | 26 |
| 6205.88, −1949.63 | 46 | 115 | 16 |
| 5000, −2000 | 1269 | 169 | 61 |
| 5500, −1500 (off mesh) | 191 | 39 | 1 |
| 4800, −1200 (off mesh) | 187 | 37 | 1 |

Every median is at or below both reproduced baselines. Auberdine → Tanaris remains one frame above the supplied 19-frame target: the final three runs were 20/22/20, versus 20/19/20 on 2e4753a. The other journey runs were 30/34/31, 22/25/25 and 36/37/37. Felwood runs were 24/26/26, 15/17/16, 59/63/61, 1/1/1 and 1/1/1; all stay below both reproduced baselines and the supplied 90-frame hard-case ceiling. This host did not reproduce the supplied 887 → 90 counts; the table uses the same no-JIT harness loop for all three versions. CPU frequency, collection and slice boundaries affect frame counts.

## Causes and changes

- af9b9d4 waited for two complete endpoint searches, including all distant target connections, before planning. `luajit -joff tests/journey_bench.lua /tmp/spf-af9` reports 92/32 batch slices (303.2/108.5 ms) for Auberdine → Tanaris in the first recorded run; the 9921ef4 reports 1/1 slices (2.3/3.8 ms) before its two candidate probes. Targets now connect lazily, settle in cost order and publish exact costs plus a frontier lower bound. Paused searches retain their state.
- Short cost-only A* probes avoid a broad Dijkstra for easy candidate walks. After 60 ms of cumulative probe CPU, unfinished alternatives use the shared endpoint searches; an active probe finishes so its work is not discarded. This is a work-selection threshold, not a spatial or optimality cap.
- Plans use `max(frontier, geometric lower bound)` for unsettled endpoint walks, in running yards divided by walk speed. The geometric bound uses eight-direction grid distance, subtracts the maximum snapping/ledge displacement and discounts edge rounding; height and extra swimming penalties cannot increase it. Once the relaxed optimum uses only exact endpoint walks, it is feasible at that same cost, proving equality with the fully measured optimum.
- The seeded comparison exposed a planner dominance bug: an earlier arrival could have visited a stop needed later, while a later arrival had not. Labels now preserve both until visited-set inclusion proves dominance. `planner_spec.lua` includes a minimal regression: the same options return `unreachable` with bounded walks but arrival `10000` with full costs under af9b9d4; the 9921ef4 returns `10000` in both cases. A relaxed reverse-time heuristic limits the extra label work.
- Goal and stationary/same-cell start searches survive replans and repeated destinations. Drawn geometry remains until a proved replacement is ready. Timed replans resume any unresolved candidate instead of committing it directly.
- Endpoint trees, abstract paths and decoded grids are reused. The decoded-grid cache grew from 12 to 64 clusters per map (roughly 16 MB per populated map at the existing estimate). Decoder and smoothing constants were reduced. An offline comparison of all 1,746 shipped grids against af9b9d4 found identical surfaces, moves, heights, floors and links.

Planner work is measured separately in `journey_bench.lua`; it is smaller than search work on these cases. The initial bounded preview also selects the first probes, avoiding a redundant plan after validation. Bounds trigger planning when settlements change, otherwise at most once per 16 slices. Only one route is committed per initial journey; geometry callbacks never replan it.

## Reproduction

From the repository root, create read-only source snapshots without changing the checkout:

```sh
mkdir -p /tmp/spf-before /tmp/spf-af9
git archive 2e4753a | tar -x -C /tmp/spf-before
git archive af9b9d4 | tar -x -C /tmp/spf-af9
luajit -joff tests/journey_bench.lua /tmp/spf-before
luajit -joff tests/journey_bench.lua /tmp/spf-af9
luajit -joff tests/journey_bench.lua
```

The external harness contains newer UI assertions that old revisions fail before reaching Felwood. For the comparison only, make an identical reduced harness for all three versions, preserving its actual five-case Felwood loop:

```sh
python3 - <<'PYCODE'
import os
from pathlib import Path
source = Path(os.environ["SPF_HARNESS"])
s = source.read_text()
s = s[:s.index("-- Round 6:")] + s[s.index("-- Real Kalimdor searches"):]
s = s[:s.index("-- Search state chooses a pooled layer")]
Path("/tmp/spf-felwood-baseline.lua").write_text(s)
PYCODE
(cd /tmp/spf-before && luajit -joff /tmp/spf-felwood-baseline.lua)
(cd /tmp/spf-af9 && luajit -joff /tmp/spf-felwood-baseline.lua)
luajit -joff /tmp/spf-felwood-baseline.lua
```

The full, unmodified current harness also passes with and without JIT. Its final no-JIT Felwood counts are 26/16/60/1/1.

```sh
luacheck . -q
stylua --check .
for spec in tests/*_spec.lua; do luajit "$spec" || exit; done
luajit tests/walk_sim.lua
luajit -joff tests/journey_optimal_spec.lua
luajit "$SPF_HARNESS"
luajit -joff "$SPF_HARNESS"
```

`journey_optimal_spec.lua` compares 30 seeded EK/Kalimdor pairs against full forward/reverse `FindMany`, with a frozen timetable, both water modes, speeds 7/14 and flight-knowledge variations; ten pairs disable probes to exercise pure bounded Dijkstra. It also checks repeated-goal geometry and cache invalidation. `path_many_spec.lua` checks 452 forward/reverse costs and geometric bounds, shipped graph symmetry, every published frontier, pause/resume and concurrent geometry with a four-cluster cache. The four walking simulations finish without route flips. Real client frame pacing and visual appearance remain unverified offline.
