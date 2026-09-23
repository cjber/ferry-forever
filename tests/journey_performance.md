# Runtime verification — 2026-09-23

Baseline: `9921ef4` on `cb/ferry`; after: the uncommitted runtime changes. All work and verification were offline. No client or SavedVariables access was used.

## Frame time, allocation and retained memory

`tests/runtime_bench.lua` uses the UI stubs from `~/drive/proj/wow-handoff/scratch/harness2.lua`, `luajit -joff` and simulated 60 Hz frames. Each version/scenario runs in three fresh processes, serially, alternating before/after. Means, allocations and resident sizes below are medians; **worst is the largest frame across all three runs**. Times cover addon Lua and stub calls, not client rendering. CPU frequency and slice boundaries affect timings.

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
luajit ~/drive/proj/wow-handoff/scratch/harness2.lua
luajit -joff ~/drive/proj/wow-handoff/scratch/harness2.lua
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
from pathlib import Path
source = Path.home() / "drive/proj/wow-handoff/scratch/harness2.lua"
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
luajit ~/drive/proj/wow-handoff/scratch/harness2.lua
luajit -joff ~/drive/proj/wow-handoff/scratch/harness2.lua
```

`journey_optimal_spec.lua` compares 30 seeded EK/Kalimdor pairs against full forward/reverse `FindMany`, with a frozen timetable, both water modes, speeds 7/14 and flight-knowledge variations; ten pairs disable probes to exercise pure bounded Dijkstra. It also checks repeated-goal geometry and cache invalidation. `path_many_spec.lua` checks 452 forward/reverse costs and geometric bounds, shipped graph symmetry, every published frontier, pause/resume and concurrent geometry with a four-cluster cache. The four walking simulations finish without route flips. Real client frame pacing and visual appearance remain unverified offline.
