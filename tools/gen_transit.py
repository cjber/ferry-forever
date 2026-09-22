#!/usr/bin/env python3
"""Generate lifts, trams, flights and public passages for the pinned Forever client (stdlib only)."""

import argparse
import csv
import gzip
import json
import math
import re
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from itertools import pairwise

from gen_routes import BUILD, CACHE, ROOT, db2, download

DB_REV = "22b51464f1625f6ef6275771de1f5466c6f5d19e"
DB_URL = f"https://github.com/cmangos/classic-db/raw/{DB_REV}/Full_DB/ClassicDB_1_12_1_z2815.sql.gz"
INFLIGHT_REV = "310f5fa167c6171ec2858561077ec441989541ae"
INFLIGHT_URL = f"https://raw.githubusercontent.com/LudiusMaximus/InFlight/{INFLIGHT_REV}"
# CMaNGOS mangos-classic src/game/MotionGenerators/PathMovementGenerator.cpp: TAXI_FLIGHT_SPEED.
TAXI_SPEED = 32.0
TAXI_POINT_ERROR = 20.0  # World yards; retain bends, without shipping every spline control point.
LIFTS = {11898, 11899, 4170, 4171, 47296, 47297, 20649, 20652, 20655}
TRAMS = {176080, 176081, 176082, 176083, 176084, 176085}
# Nighthaven is druid-only; Plaguewood tower flights depend on PvP control. Neither restriction can be
# expressed by the planner's faction/known-node contract. Mount IDs alone also admit quest/test nodes.
RESTRICTED_NODES = {62, 63, 84, 85, 86, 87}
PORTAL_NAMES = {
    527: ("Portal to Rut'theran Village", "portal"),
    542: ("Portal to Darnassus", "portal"),
    2166: ("Passage to Ironforge", "passage"),
    2171: ("Passage to Stormwind", "passage"),
    2173: ("Passage to Deeprun Tram (Stormwind)", "passage"),
    2175: ("Passage to Deeprun Tram (Ironforge)", "passage"),
}


def classicdb(refresh=False, offline=False):
    path = CACHE / f"classicdb-{DB_REV[:8]}.sql.gz"
    if refresh or not path.exists():
        if offline:
            raise ValueError(f"Missing cached source: {path}")
        request = urllib.request.Request(DB_URL, headers={"User-Agent": "FerryForever/1.0"})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
        gzip.decompress(data)  # Do not cache an HTTP error page.
        CACHE.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".tmp")
        temporary.write_bytes(data)
        temporary.replace(path)
    spawns, teleports = defaultdict(list), {}
    # These two tables have one INSERT per line; quoted SQL strings may contain commas and parentheses.
    tuples = re.compile(r"\(((?:'(?:\\.|[^'\\])*'|[^()'])*)\)")
    with gzip.open(path, "rt", encoding="utf-8") as stream:
        for line in stream:
            if line.startswith("INSERT INTO `gameobject` VALUES "):
                for match in tuples.finditer(line):
                    row = match[1].split(",")
                    template, map_id = int(row[1]), int(row[2])
                    if template in LIFTS | TRAMS and map_id in (0, 1, 369):
                        spawns[template].append(
                            {
                                "guid": int(row[0]),
                                "map": map_id,
                                "pos": tuple(map(float, row[4:7])),
                                "orientation": float(row[7]),
                            }
                        )
            elif line.startswith("INSERT INTO `areatrigger_teleport` VALUES "):
                for match in tuples.finditer(line):
                    row = next(csv.reader([match[1]], quotechar="'", escapechar="\\"))
                    if int(row[0]) in PORTAL_NAMES:
                        teleports[int(row[0])] = location(int(row[6]), map(float, row[7:10]))
    if set(spawns) != LIFTS | TRAMS or set(teleports) != set(PORTAL_NAMES):
        raise ValueError("classic-db: missing expected transport spawn or public passage")
    return spawns, teleports


def location(map_id, pos):
    return dict(zip(("map", "x", "y", "z"), (map_id, *pos)))


def point(row, prefix="Pos_"):
    return tuple(float(row[f"{prefix}{i}"]) for i in range(3))


def animation_tracks(rows, spawns):
    tracks = defaultdict(list)
    for row in rows:
        if int(row["TransportID"]) in spawns:
            tracks[int(row["TransportID"])].append((int(row["TimeIndex"]), point(row)))
    for template, track in tracks.items():
        track.sort()
        if len({t for t, _ in track}) != len(track) or math.dist(track[0][1], track[-1][1]) > 0.01:
            raise ValueError(f"animation {template}: timestamps overlap or loop does not close")
    return tracks


def world_track(track, spawn):
    # Vanilla animation Y is reversed (CMaNGOS ElevatorTransport::Update). Do not apply spawn facing:
    # the tram's +/-Y track must join map 369's stations at Y=10/2491; a 90-degree rotation cannot.
    # Lifts have only vertical displacement, so their spawn facing does not affect their track.
    frames = []
    for time, (x, y, z) in track:
        pos = (spawn["pos"][0] + x, spawn["pos"][1] - y, spawn["pos"][2] + z)
        if frames and math.dist(frames[-1]["pos"], pos) < 0.001:
            frames[-1]["depart"] = time
        else:
            frames.append({"arrive": time, "depart": time, "pos": pos, "map": spawn["map"]})
    return frames


def transports(animation, spawns, triggers):
    tracks = animation_tracks(animation, spawns)
    docks, routes = {}, {}
    # Explicit site/car identities keep IDs stable if the source gains more spawns.
    sites = [
        (118981, "The Great Lift", [(11898, 16874), (11899, 16876)]),
        (118982, "Freewind Post", [(11898, 16875), (11899, 16877)]),
        (41701, "Thunder Bluff, west lift", [(4170, 18298), (4171, 18435)]),
        (472961, "Thunder Bluff, north lift", [(47296, 20639), (47297, 20640)]),
        (206491, "Undercity, west lift", [(20649, 44892)]),
        (206521, "Undercity, east lift", [(20652, 44962)]),
        (206551, "Undercity, south lift", [(20655, 44901)]),
    ]
    for index, (route_id, site, cars) in enumerate(sites):
        car_frames = []
        for template, guid in cars:
            spawn = next(s for s in spawns[template] if s["guid"] == guid)
            frames = world_track(tracks[template], spawn)
            car_frames.append((template, frames))
        landings = [f for _, frames in car_frames for f in frames if f["depart"] > f["arrive"]]
        middle = (min(f["pos"][2] for f in landings) + max(f["pos"][2] for f in landings)) / 2
        for top, name in ((True, "Top"), (False, "Bottom")):
            members = [f for f in landings if (f["pos"][2] > middle) == top]
            dock_id = 1001 + index * 2 + (0 if top else 1)
            pos = tuple(sum(f["pos"][axis] for f in members) / len(members) for axis in range(3))
            docks[dock_id] = {**location(members[0]["map"], pos), "site": site, "name": name}
            for frame in members:
                frame["dock"] = dock_id
        periods = {tracks[template][-1][0] for template, _ in car_frames}
        # TB pairs differ by 33 ms per cycle: separate cars preserve each period and fitted epoch.
        groups = [[car] for car in car_frames] if len(periods) > 1 else [car_frames]
        for group in groups:
            template = group[0][0]
            key = template * 10 + 1 if len(groups) > 1 else route_id
            frames = []
            for _, car in group:
                car[-1]["jump"] = 1
                frames.extend(car)
            # UC's entire ride is 3.5 s; TB is slower than the Great Lift during its cruise.
            fit = (
                {"samples": 3, "span": 2000, "speed": 8}
                if template in (20649, 20652, 20655)
                else {"samples": 5, "span": 4000, "speed": 6 if template in (4170, 4171, 47296, 47297) else 8}
            )
            routes[key] = {
                "kind": "lift",
                "site": site,
                "period": tracks[template][-1][0],
                "fit": fit,
                "stops": stops_of(frames, tracks[template][-1][0]),
                "frames": frames,
            }
    for dock_id, station, trigger in ((1101, "Ironforge", 2175), (1102, "Stormwind", 2173)):
        ends = []
        for template in (176080, 176082):
            for frame in world_track(tracks[template], spawns[template][0]):
                if frame["depart"] > frame["arrive"] and (frame["pos"][1] < 1200) == (station == "Ironforge"):
                    ends.append(frame["pos"])
                    break
        pos = tuple(sum(p[axis] for p in ends) / len(ends) for axis in range(3))
        docks[dock_id] = {
            **location(369, pos),
            "site": "Deeprun Tram",
            "name": station,
            "pin": location(0, point(triggers[trigger])),
        }
    # 176081/176085 follow 176080; 176083/176084 follow 176082. One timetable per train.
    for template in (176080, 176082):
        frames = world_track(tracks[template], spawns[template][0])
        for frame in frames:
            if frame["depart"] > frame["arrive"]:
                frame["dock"] = 1101 if frame["pos"][1] < 1200 else 1102
                entrance = triggers[2166 if frame["dock"] == 1101 else 2171]
                if math.dist(frame["pos"][:2], point(entrance)[:2]) > 150:
                    raise ValueError(f"tram {template}: transformed track misses its station")
        routes[template] = {
            "kind": "tram",
            "site": "Deeprun Tram",
            "period": tracks[template][-1][0],
            "stops": stops_of(frames, tracks[template][-1][0]),
            "frames": frames,
        }
    for route in routes.values():
        route["frames"] = [
            [f["arrive"], f["depart"], f["map"], *f["pos"][:2], f.get("jump"), f["pos"][2]] for f in route["frames"]
        ]
    return docks, routes


def stops_of(frames, period):
    stops = []
    for frame in frames:
        if "dock" not in frame:
            continue
        stop = {"dock": frame["dock"], "arrive": frame["arrive"], "depart": frame["depart"]}
        # Join a dwell straddling phase zero, without joining the tracks of separate cars.
        previous = next((s for s in stops if s["dock"] == stop["dock"] and s["arrive"] == 0), None)
        if stop["depart"] == period and previous:
            previous["arrive"] = stop["arrive"]
        else:
            stops.append(stop)
    return sorted(stops, key=lambda s: (s["arrive"], s["dock"]))


def inflight(content):
    section = content.split("local global_classic = {", 1)[1].split("local global_tbc = {", 1)[0]
    durations, source = {}, None
    for line in section.splitlines():
        node = re.fullmatch(r"    \[(\d+)\] = \{", line)
        duration = re.fullmatch(r"      \[(\d+)\] = (\d+),", line)
        if node:
            source = int(node[1])
        elif duration and source is not None:
            key, seconds = (source, int(duration[1])), int(duration[2])
            # Shared neutral endpoints occasionally have faction-specific observations.
            durations[key] = min(seconds, durations.get(key, seconds))
    if not durations:
        raise ValueError("InFlight classic section has no duration pairs")
    return durations


def taxi_points(track):
    coords = [point(row, "Loc_")[:2] for row in track]
    keep = {0, len(track) - 1}
    pending = [(0, len(track) - 1)]
    while pending:
        start, end = pending.pop()
        ax, ay = coords[start]
        bx, by = coords[end]
        dx, dy = bx - ax, by - ay
        length = dx * dx + dy * dy
        farthest, error = None, TAXI_POINT_ERROR**2
        for index in range(start + 1, end):
            x, y = coords[index]
            t = max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / length)) if length else 0
            distance = (x - ax - t * dx) ** 2 + (y - ay - t * dy) ** 2
            if distance > error:
                farthest, error = index, distance
        if farthest is not None:
            keep.add(farthest)
            pending.extend(((start, farthest), (farthest, end)))
    return [v for i in sorted(keep) for v in (int(track[i]["ContinentID"]), *[round(c, 1) for c in coords[i]])]


def taxis(node_rows, path_rows, geometry, durations):
    nodes, by_path = {}, defaultdict(list)
    for row in node_rows:
        node_id, flags = int(row["ID"]), int(row["Flags"])
        # Bits 1/2 advertise ordinary Alliance/Horde flight-map nodes. This drops transport endpoints,
        # quest/test/obsolete paths, battleground taxis and nodes with unmodelled visibility conditions.
        # Powderfuse's new Alliance node 3275 lacks the UI bits, but has ordinary paid paths 11582/11583.
        if (
            node_id in RESTRICTED_NODES
            or (not flags & 3 and node_id != 3275)
            or int(row["ContinentID"]) not in (0, 1, 2991)
            or row["Name_lang"].startswith(("zzOLD", "Quest "))
            or int(row["ConditionID"])
            or int(row["VisibilityConditionID"])
        ):
            continue
        horde, alliance = int(row["MountCreatureID_0"]), int(row["MountCreatureID_1"])
        if not horde and not alliance:
            continue
        node = {**location(int(row["ContinentID"]), point(row)), "name": row["Name_lang"]}
        if not (horde and alliance):
            node["faction"] = "Horde" if horde else "Alliance"
        nodes[node_id] = node
    for row in geometry:
        by_path[int(row["PathID"])].append(row)
    paths, used, seen = [], set(), set()
    for row in sorted(path_rows, key=lambda r: int(r["ID"])):
        start, end = int(row["FromTaxiNode"]), int(row["ToTaxiNode"])
        track = sorted(by_path[int(row["ID"])], key=lambda r: int(r["NodeIndex"]))
        # Missing/zero endpoints, geometry-less path 472 and stopped passenger transports are not flights.
        if start not in nodes or end not in nodes or len(track) < 2 or any(int(r["Flags"]) & 2 for r in track):
            continue
        if (start, end) in seen:
            continue
        if len({r["ContinentID"] for r in track}) != 1:
            raise ValueError(f"flight {row['ID']}: cross-map geometry needs an explicit duration")
        seconds = durations.get((start, end))
        path = {"from": start, "to": end}
        if seconds is None:
            seconds = sum(math.dist(point(a, "Loc_"), point(b, "Loc_")) for a, b in pairwise(track)) / TAXI_SPEED
            path["estimated"] = True
        path["seconds"] = round(seconds, 1)
        path["points"] = taxi_points(track)
        paths.append(path)
        used.update((start, end))
        seen.add((start, end))
    return {key: nodes[key] for key in sorted(used)}, paths


def landmasses(assignments, maps):
    result = []
    # Client zone bounds include Rut'theran. Zephras already has a separate world map (2991).
    for ui_map, name in ((1438, "Teldrassil"), (2521, maps[2991]["MapName_lang"])):
        row = next(r for r in assignments if int(r["UiMapID"]) == ui_map)
        result.append(
            {
                "map": int(row["MapID"]),
                "name": name,
                "minX": float(row["Region_0"]),
                "maxX": float(row["Region_3"]),
                "minY": float(row["Region_1"]),
                "maxY": float(row["Region_4"]),
            }
        )
    # Sardor (Feathermoon) and Isle of Dread share Feralas's UiMap, so use conservative coastal boxes.
    # Boat dock 15 and flight node 41 are on Sardor; dock 16 is on the mainland. Theramore has a bridge.
    result.extend(
        [
            {"map": 1, "name": "Sardor Isle", "minX": -4900, "maxX": -3900, "minY": 2900, "maxY": 3900},
            {"map": 1, "name": "Isle of Dread", "minX": -6300, "maxX": -4900, "minY": 2900, "maxY": 4300},
        ]
    )
    return result


def portals(triggers, teleports):
    return [
        (
            key,
            {
                "name": name,
                "kind": kind,
                "from": location(int(triggers[key]["ContinentID"]), point(triggers[key])),
                "to": teleports[key],
                "seconds": 5,
            },
        )
        for key, (name, kind) in PORTAL_NAMES.items()
    ]


def lua(value):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, float):
        return f"{value:.3f}".rstrip("0").rstrip(".")
    return str(value)


def render(value, depth=0):
    if not isinstance(value, (dict, list)):
        return lua(value)
    if isinstance(value, list) and value and len(value) % 3 == 0 and all(isinstance(v, (int, float)) for v in value):
        # Keep flattened geometry compact, wrapping only between complete map/x/y triples.
        lines, line = [], ""
        for offset in range(0, len(value), 3):
            triple = ", ".join(lua(v) for v in value[offset : offset + 3])
            if line and len(line) + len(triple) + (depth + 1) * 4 + 2 > 116:
                lines.append(line)
                line = ""
            line += (", " if line else "") + triple
        lines.append(line)
        return "{\n" + "\n".join("\t" * (depth + 1) + line + "," for line in lines) + "\n" + "\t" * depth + "}"
    items = (
        [((f"[{k}]" if isinstance(k, int) else k) + " = ", v) for k, v in value.items()]
        if isinstance(value, dict)
        else [("", v) for v in value]
    )
    flat = "{ " + ", ".join(k + render(v, depth + 1) for k, v in items) + " }"
    if "\n" not in flat and len(flat) + depth * 4 <= 100:
        return flat
    return (
        "{\n"
        + "\n".join("\t" * (depth + 1) + k + render(v, depth + 1) + "," for k, v in items)
        + "\n"
        + "\t" * depth
        + "}"
    )


def header(source):
    return [
        "-- Generated by tools/gen_transit.py — do not edit.",
        f"-- Source: {source}",
        f"-- DB2: https://wago.tools/db2 (CSV build {BUILD}).",
        f"-- DB: https://github.com/cmangos/classic-db/tree/{DB_REV}",
        "local _, ns = ...",
        "",
    ]


def assignment(name, value):
    return ["-- stylua: ignore", name + " = " + render(value), ""]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--refresh", action="store_true", help="redownload pinned sources")
    mode.add_argument("--offline", action="store_true", help="use cached sources only")
    args = parser.parse_args()
    tables = {
        name: db2(name, args.refresh, args.offline)
        for name in (
            "TransportAnimation",
            "TaxiNodes",
            "TaxiPath",
            "TaxiPathNode",
            "AreaTrigger",
            "Map",
            "UiMapAssignment",
        )
    }
    spawns, teleports = classicdb(args.refresh, args.offline)
    triggers = {int(r["ID"]): r for r in tables["AreaTrigger"]}
    docks, routes = transports(tables["TransportAnimation"], spawns, triggers)
    durations = inflight(download(f"{INFLIGHT_URL}/Defaults.lua", "InFlight-Defaults.lua", args.refresh, args.offline))
    license_text = download(f"{INFLIGHT_URL}/LICENSE", "InFlight-LICENSE", args.refresh, args.offline)
    nodes, paths = taxis(tables["TaxiNodes"], tables["TaxiPath"], tables["TaxiPathNode"], durations)
    islands = landmasses(tables["UiMapAssignment"], {int(r["ID"]): r for r in tables["Map"]})
    passages = portals(triggers, teleports)
    transport_lines = header("TransportAnimation + classic-db gameobject spawns; milliseconds, world yards.")
    transport_lines += [
        "-- TB pairs have 30000/30033 ms periods: each car is a separate route.",
        "-- UC 20650/51/53/54/56/57 are upperLdoor/lowerLdoor (display 462), not riding platforms.",
        "-- Tram offsets use (x, -y, z), without rotating by spawn facing, to join station ends.",
        "-- 176080 leads 176081/176085; 176082 leads 176083/176084. Each train uses its lead track.",
        "",
    ]
    for key, dock in sorted(docks.items()):
        transport_lines += assignment(f"ns.Docks[{key}]", dock)
    for key, route in sorted(routes.items()):
        transport_lines += assignment(f"ns.Routes[{key}]", route)
    covered = sum(not p.get("estimated") for p in paths)
    taxi_lines = header("TaxiNodes/TaxiPath/TaxiPathNode; InFlight classic directed durations (seconds).")
    taxi_lines += (
        [
            f"-- InFlight: https://github.com/LudiusMaximus/InFlight/tree/{INFLIGHT_REV}",
            f"-- Measured durations: {covered}/{len(paths)} ({covered / len(paths):.1%}); remaining paths estimated at 32 yd/s.",
            "-- Speed: cmangos/mangos-classic src/game/MotionGenerators/PathMovementGenerator.cpp, TAXI_FLIGHT_SPEED.",
            "-- Only ordinary, unrestricted flight-map nodes; quest/test/transport/PvP/druid-only paths excluded.",
            "-- Path points: flattened map/x/y triples, simplified within 20 yd in XY, rounded to 0.1 yd.",
            "-- InFlight duration data license:",
        ]
        + ["-- " + line if line else "--" for line in license_text.splitlines()]
        + [""]
    )
    taxi_lines += assignment("ns.TaxiNodes", nodes) + assignment("ns.TaxiPaths", paths)
    taxi_lines += [
        "-- Teldrassil/Zephras: UiMapAssignment 1438/2521. Feralas islands: conservative coastal bounds.",
        "-- Zephras (map 2991) has two ferry docks and no ordinary flight nodes in this build.",
    ]
    taxi_lines += assignment("ns.Landmasses", islands)
    portal_lines = header("AreaTrigger source positions + classic-db areatrigger_teleport destinations.")
    portal_lines += [
        "-- Loading-screen allowance: 5 s. Only these public transitions are included.",
        "-- Excludes GM/test 1103/1104 and dungeon/raid triggers.",
        "-- Skyborne Dalaran <-> Stormwind omitted: eligibility is documented, exact endpoints are not sourced.",
        "-- https://benjamh681.github.io/wow-forever-atlas/guide.html (Alliance Skyborne only).",
        "",
        "-- stylua: ignore",
        "ns.Portals = {",
    ]
    for trigger, portal in passages:
        portal_lines += [
            f"\t-- Source: AreaTrigger {trigger} -> classic-db areatrigger_teleport {trigger}.",
            "\t" + render(portal, 1) + ",",
        ]
    portal_lines += ["}", ""]
    for name, lines in (("Transports", transport_lines), ("Taxi", taxi_lines), ("Portals", portal_lines)):
        (ROOT / "Data" / f"{name}.lua").write_text("\n".join(lines), encoding="utf-8")
    print(
        f"Transports: {len(routes)} routes, {len(docks)} docks; Taxi: {len(nodes)} nodes, {len(paths)} paths, "
        f"{covered / len(paths):.1%} measured; {len(islands)} landmasses; Portals: {len(passages)} directed entries"
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, urllib.error.URLError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
