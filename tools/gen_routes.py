#!/usr/bin/env python3
"""Generate every boat and zeppelin route, with its timetable, for the pinned Forever client (stdlib only).

Routes are the client's own taxi paths with stops (TaxiPathNode Flags 2, a Delay in seconds). Their
timetable is the server's: CMaNGOS mangos-classic TransportMgr::GenerateWaypoints, reproduced here
(Catmull-Rom splines per map segment, three samples per spline segment, 30 yd/s with 1 yd/s² acceleration
and braking, the stop's delay at each stop). Checked against the sniffed periods of the eight classic routes.
"""

import argparse
import csv
import io
import math
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path

BUILD = "1.60.1.69913"
ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "tools" / ".cache"
OUTPUT = ROOT / "Data" / "Routes.lua"
# gameobject_template type 15 data1/data2 in CMaNGOS classic-db 22b5146: every passenger transport.
SPEED, ACCEL = 30.0, 1.0
# CMaNGOS classic-db 22b5146 `transports.period` (ms), sniffed from the original servers.
REFERENCE_PERIODS = {
    241: 350818,
    285: 303463,
    292: 329313,
    293: 316251,
    295: 295579,
    301: 333044,
    302: 356284,
    303: 317038,
}
TOLERANCE = 0.005
# 11398 is the Dalaran-Valanaar skyship and 11457 the Thunder Bluff-Zephras Isle zeppelin (Forever, Skyborne only).
ZEPPELINS = {285, 301, 302, 11398, 11457}
# Routes between one faction's towns, whose docks stand among that faction's guards. The rest (Ratchet-Booty
# Bay, and the Forever crossings until their towns are known to belong to a side) are neutral.
FACTIONS = {
    285: "Horde",
    301: "Horde",
    302: "Horde",
    292: "Alliance",
    293: "Alliance",
    295: "Alliance",
    303: "Alliance",
    11167: "Alliance",
    11616: "Alliance",
    11398: "Alliance",
    11457: "Horde",
}
EXCLUDED = {436}  # Naxxramas, a raid's floating citadel rather than a passenger route
STOP = 2
TELEPORT = 1
# Stops of different routes this close share one dock (the same pier).
SAME_DOCK = 30.0
CATMULL_ROM = ((-0.5, 1.5, -1.5, 0.5), (1.0, -2.5, 2.0, -0.5), (-0.5, 0.0, 0.5, 0.0), (0.0, 1.0, 0.0, 0.0))


def download(url, filename, refresh=False, offline=False):
    path = CACHE / filename
    if path.exists() and not refresh:
        return path.read_text(encoding="utf-8-sig")
    if offline:
        raise ValueError(f"Missing cached source: {path}")
    request = urllib.request.Request(url, headers={"User-Agent": "ShortestPathForever/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    content = data.decode("utf-8-sig")
    if content.lstrip().startswith("<"):
        raise ValueError(f"Expected data, received HTML from {url}")
    CACHE.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(path)
    return content


def db2(name, refresh=False, offline=False):
    content = download(f"https://wago.tools/db2/{name}/csv?build={BUILD}", f"{name}-{BUILD}.csv", refresh, offline)
    rows = list(csv.DictReader(io.StringIO(content)))
    if not rows:
        raise ValueError(f"{name}: empty DB2 export for {BUILD}")
    return rows


def evaluate(points, t):
    powers = (t * t * t, t * t, t, 1.0)
    weights = [sum(powers[r] * CATMULL_ROM[r][c] for r in range(4)) for c in range(4)]
    return tuple(sum(weights[k] * points[k][d] for k in range(4)) for d in range(3))


def segment_lengths(controls):
    """Length of each spline segment between consecutive controls, as the server measures it."""
    first = tuple(2 * a - b for a, b in zip(controls[0], controls[1]))
    points = [first, *controls, controls[-1]]
    lengths = []
    for i in range(1, len(controls)):
        window, previous, length = points[i - 1 : i + 3], controls[i - 1], 0.0
        for step in (1, 2, 3):
            current = evaluate(window, step / 3)
            length += math.dist(current, previous)
            previous = current
        lengths.append(length)
    return lengths


def keyframes(nodes):
    """The server's keyframes: interior nodes, each teleport marked on the frame before it."""
    frames, skip = [], False
    for i in range(1, len(nodes) - 1):
        if skip:
            skip = False
            continue
        node = nodes[i]
        if int(node["Flags"]) & TELEPORT or node["ContinentID"] != nodes[i + 1]["ContinentID"]:
            frames[-1]["teleport"] = True
            skip = True
            continue
        frames.append(
            {
                "map": int(node["ContinentID"]),
                "pos": (float(node["Loc_0"]), float(node["Loc_1"]), float(node["Loc_2"])),
                "stop": int(node["Flags"]) == STOP,
                "delay": float(node["Delay"]),
                "teleport": False,
                "dist": 0.0,
            }
        )
    frames[-1]["teleport"] = True
    start = 0
    for i in range(1, len(frames)):
        if frames[i - 1]["teleport"] or i + 1 == len(frames):
            end = i + (0 if frames[i - 1]["teleport"] else 1)
            for j, length in enumerate(segment_lengths([f["pos"] for f in frames[start:end]]), start + 1):
                frames[j]["dist"] = length
            start = i
    return frames


def move_time(since, until):
    """Seconds from a frame to the next stop, `since` past the last stop and `until` before the next."""
    accel_dist = 0.5 * SPEED * SPEED / ACCEL
    if since + until < 2 * accel_dist:
        if since < until:
            return 2 * math.sqrt((since + until) / ACCEL) - math.sqrt(2 * since / ACCEL)
        return math.sqrt(2 * until / ACCEL)
    if since < accel_dist:
        return (since + until) / SPEED + SPEED / ACCEL - math.sqrt(2 * since / ACCEL)
    if until < accel_dist:
        return math.sqrt(2 * until / ACCEL)
    return until / SPEED + 0.5 * SPEED / ACCEL


def timetable(nodes):
    """Frames with arrival/departure seconds, and the period."""
    frames = keyframes(nodes)
    count = len(frames)
    stops = [i for i, f in enumerate(frames) if f["stop"]] or [0]
    first, last = stops[0], stops[-1]
    distance = 0.0
    for k in range(count):
        j = (k + last) % count
        distance = 0.0 if frames[j]["stop"] or j == last else distance + frames[j]["dist"]
        frames[j]["since"] = distance
    distance = 0.0
    for k in range(count - 1, -1, -1):
        j = (k + first) % count
        distance += frames[(j + 1) % count]["dist"]
        frames[j]["until"] = distance
        if frames[j]["stop"] or j == first:
            distance = 0.0
    for frame in frames:
        frame["to"] = move_time(frame["since"], frame["until"])
    clock = frames[0]["delay"] if frames[0]["stop"] else 0.0
    frames[0]["arrive"], frames[0]["depart"] = 0.0, clock
    for i in range(1, count):
        clock += frames[i - 1]["to"]
        if frames[i]["stop"]:
            frames[i]["arrive"] = clock
            clock += frames[i]["delay"]
            frames[i]["depart"] = clock
        else:
            clock -= frames[i]["to"]
            frames[i]["arrive"] = frames[i]["depart"] = clock
    return frames, clock


def transport_paths(nodes):
    by_path = defaultdict(list)
    for node in nodes:
        by_path[int(node["PathID"])].append(node)
    return {
        path: sorted(rows, key=lambda r: int(r["NodeIndex"]))
        for path, rows in by_path.items()
        if path not in EXCLUDED and any(int(r["Flags"]) == STOP for r in rows)
    }


def generate(nodes):
    routes, docks = {}, []

    def dock_of(frame):
        for index, (map_id, x, y) in enumerate(docks):
            if map_id == frame["map"] and math.dist((x, y), frame["pos"][:2]) <= SAME_DOCK:
                return index
        docks.append((frame["map"], *frame["pos"][:2]))
        return len(docks) - 1

    tables = {path: timetable(rows) for path, rows in sorted(transport_paths(nodes).items())}
    for path, reference in REFERENCE_PERIODS.items():
        period = tables[path][1] * 1000
        if abs(period - reference) / reference > TOLERANCE:
            raise ValueError(f"path {path}: generated period {period:.0f} ms vs reference {reference} ms")
    # The model runs a steady ~0.05% fast against every sniffed period (the server's own spline sampling);
    # stretch each route onto its sniffed period, or the mean correction where none was sniffed, so a
    # sighting stays accurate for hours instead of drifting a few seconds per hour.
    ratios = [reference / (tables[path][1] * 1000) for path, reference in REFERENCE_PERIODS.items()]
    mean_ratio = sum(ratios) / len(ratios)
    for path, (frames, period) in tables.items():
        reference = REFERENCE_PERIODS.get(path)
        scale = reference / (period * 1000) if reference else mean_ratio
        for frame in frames:
            frame["arrive"] *= scale
            frame["depart"] *= scale
        period *= scale
        stops = [{"dock": dock_of(f), "arrive": f["arrive"], "depart": f["depart"]} for f in frames if f["stop"]]
        # A stop split by the loop's start (arrive at the end, leave at the beginning) is one visit.
        if len(stops) > 1 and stops[0]["dock"] == stops[-1]["dock"] and stops[0]["arrive"] == 0:
            stops[0]["arrive"] = stops.pop()["arrive"]
        routes[path] = {
            "kind": "zeppelin" if path in ZEPPELINS else "boat",
            "period": period,
            "stops": stops,
            "frames": frames,
        }
    if len({s["dock"] for r in routes.values() for s in r["stops"]}) != len(docks):
        raise ValueError("a dock was created without a stop")
    return routes, docks


def ms(seconds):
    return round(seconds * 1000)


def render(routes, docks):
    lines = [
        "-- Generated by tools/gen_routes.py — do not edit.",
        f"-- Source: wago.tools TaxiPathNode, wow_classic_beta {BUILD}: taxi paths with stops. Timetable: the",
        "-- CMaNGOS mangos-classic transport model (TransportMgr::GenerateWaypoints) at 30 yd/s, 1 yd/s².",
        "-- Periods stretched onto the sniffed CMaNGOS classic-db periods (the new routes by the mean correction).",
    ]
    lines += [
        "local _, ns = ...",
        "",
        "-- [dock] = { map = continent, x = world x (north), y = world y (west) }",
        "-- stylua: ignore",
        "ns.Docks = {",
    ]
    lines += [f"\t{{ map = {m}, x = {x:.1f}, y = {y:.1f} }}," for m, x, y in docks]
    lines += [
        "}",
        "",
        "-- [taxi path] = { kind, faction (absent when neutral), period (ms), stops = { { dock, arrive, depart } }",
        "--   (ms into the loop; a stop whose depart is below its arrive spans the loop's start), frames = { { arrive,",
        "--   depart, continent, x, y, jump (1 when the next frame is reached by teleport) } } }",
        "-- stylua: ignore",
        "ns.Routes = {",
    ]
    for path, route in routes.items():
        lines += [f"\t[{path}] = {{", f'\t\tkind = "{route["kind"]}",']
        if path in FACTIONS:
            lines.append(f'\t\tfaction = "{FACTIONS[path]}",')
        lines.append(f"\t\tperiod = {ms(route['period'])},")
        lines += ["\t\tstops = {"]
        lines += [
            f"\t\t\t{{ dock = {s['dock'] + 1}, arrive = {ms(s['arrive'])}, depart = {ms(s['depart'])} }},"
            for s in route["stops"]
        ]
        lines += ["\t\t},", "\t\tframes = {"]
        lines += [
            f"\t\t\t{{ {ms(f['arrive'])}, {ms(f['depart'])}, {f['map']}, {f['pos'][0]:.1f}, {f['pos'][1]:.1f}"
            + (", 1 }," if f["teleport"] else " },")
            for f in route["frames"]
        ]
        lines += ["\t\t},", "\t},"]
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--refresh", action="store_true", help="redownload the pinned sources")
    mode.add_argument("--offline", action="store_true", help="use cached sources only")
    args = parser.parse_args()
    routes, docks = generate(db2("TaxiPathNode", args.refresh, args.offline))
    OUTPUT.parent.mkdir(exist_ok=True)
    OUTPUT.write_text(render(routes, docks), encoding="utf-8")
    print(f"Wrote {OUTPUT.relative_to(ROOT)}: {len(routes)} routes, {len(docks)} docks")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, urllib.error.URLError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
