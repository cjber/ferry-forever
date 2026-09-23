# Bounded journey verification

All measurements use `luajit -joff`, a 3 ms shared search budget and simulated 60 Hz frames. Numbers are medians of three serial runs on this host; each benchmark process starts fresh. No client or SavedVariables access was used.

| Journey | 2e4753a | af9b9d4 | Working tree |
| --- | ---: | ---: | ---: |
| Auberdine → Tanaris | 20 | 161 | 20 |
| Auberdine → Eastern Plaguelands | 85 | 215 | 31 |
| Crossroads → Thunder Bluff | 38 | 134 | 25 |
| Ironforge → Menethil | 220 | 124 | 37 |

| Harness Felwood goal (map 1, x north / y west) | 2e4753a | af9b9d4 | Working tree |
| --- | ---: | ---: | ---: |
| 5068.4, −337.22 | 38 | 177 | 26 |
| 6205.88, −1949.63 | 46 | 115 | 16 |
| 5000, −2000 | 1269 | 169 | 61 |
| 5500, −1500 (off mesh) | 191 | 39 | 1 |
| 4800, −1200 (off mesh) | 187 | 37 | 1 |

Every median is at or below both reproduced baselines. Auberdine → Tanaris remains one frame above the supplied 19-frame target: the final three runs were 20/22/20, versus 20/19/20 on 2e4753a. The other journey runs were 30/34/31, 22/25/25 and 36/37/37. Felwood runs were 24/26/26, 15/17/16, 59/63/61, 1/1/1 and 1/1/1; all stay below both reproduced baselines and the supplied 90-frame hard-case ceiling. This host did not reproduce the supplied 887 → 90 counts; the table uses the same no-JIT harness loop for all three versions. CPU frequency, collection and slice boundaries affect frame counts.

## Causes and changes

- af9b9d4 waited for two complete endpoint searches, including all distant target connections, before planning. `luajit -joff tests/journey_bench.lua /tmp/spf-af9` reports 92/32 batch slices (303.2/108.5 ms) for Auberdine → Tanaris in the first recorded run; the working tree reports 1/1 slices (2.3/3.8 ms) before its two candidate probes. Targets now connect lazily, settle in cost order and publish exact costs plus a frontier lower bound. Paused searches retain their state.
- Short cost-only A* probes avoid a broad Dijkstra for easy candidate walks. After 60 ms of cumulative probe CPU, unfinished alternatives use the shared endpoint searches; an active probe finishes so its work is not discarded. This is a work-selection threshold, not a spatial or optimality cap.
- Plans use `max(frontier, geometric lower bound)` for unsettled endpoint walks, in running yards divided by walk speed. The geometric bound uses eight-direction grid distance, subtracts the maximum snapping/ledge displacement and discounts edge rounding; height and extra swimming penalties cannot increase it. Once the relaxed optimum uses only exact endpoint walks, it is feasible at that same cost, proving equality with the fully measured optimum.
- The seeded comparison exposed a planner dominance bug: an earlier arrival could have visited a stop needed later, while a later arrival had not. Labels now preserve both until visited-set inclusion proves dominance. `planner_spec.lua` includes a minimal regression: the same options return `unreachable` with bounded walks but arrival `10000` with full costs under af9b9d4; the working tree returns `10000` in both cases. A relaxed reverse-time heuristic limits the extra label work.
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
