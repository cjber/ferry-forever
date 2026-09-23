#!/usr/bin/env python3
"""Reproduce Shortest Path Forever with Pillow and the pinned client's own art.

    python3 tools/screenshots.py
    python3 tools/screenshots.py --scenes tracker boats
    python3 tools/screenshots.py --verify --refs /path/to/refs

WOWMOCK overrides ~/.claude/skills/wow-mock-screenshots. First use downloads assets
from wago.tools; subsequent runs use its build-specific cache. Never reads the game
installation or SavedVariables. See docs/screenshots.md for source and scene notes.
"""

import argparse
import csv
import hashlib
import io
import json
import math
import os
import subprocess
import sys
from functools import cache, lru_cache
from pathlib import Path

from PIL import Image, ImageDraw

WOWMOCK = Path(os.environ.get("WOWMOCK", Path.home() / ".claude/skills/wow-mock-screenshots"))
if not (WOWMOCK / "wowmock.py").is_file():
    sys.exit(f"wowmock.py not found in {WOWMOCK}; set WOWMOCK to its directory")
sys.path.insert(0, str(WOWMOCK))

from wowmock import (
    BUILD,
    FONTS,
    NORMAL,
    WHITE,
    TooltipLine,
    TrackerBlock,
    TrackerModule,
    Ui,
    backdrop,
    colored,
    draw_overlay,
    map_art,
    map_overlays,
    minimap_art,
    objective_tracker,
    rgba255,
    scene,
    tooltip,
    tooltip_backdrop,
    world_map_frame,
)

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs/screenshots"
# A chosen offline character state, not a recorded or predicted live timetable.
START = {"map": 1, "x": 6341.38, "y": 557.68, "z": 16.29}
GOAL = {"map": 0, "x": -3263.0, "y": -1353.0}
DARKSHORE_GOAL = {"map": 1, "x": 4990.0, "y": 170.0}
BOAT_COLOR = (0, 0.75, 1)


class Art(Ui):
    """Reuse atlas crops across animation frames and the generator's already pinned DB2 CSVs."""

    @cache
    def atlas(self, name):
        return super().atlas(name)

    def table(self, name, key="ID"):
        local = ROOT / "tools/.cache" / f"{name}-{BUILD}.csv"
        if name not in self._tables and local.is_file():
            with local.open() as source:
                self._tables[name] = {row[key]: row for row in csv.DictReader(source)}
        return super().table(name, key)


@lru_cache(maxsize=1)
def data():
    """Use the real Lua 5.1 path implementation; table serialization is the only adapter."""
    program = r"""
local ns = {}
for _, name in ipairs({ "Data/Routes", "Data/Transports", "Data/Portals", "Data/Taxi", "Model", "Path", "Planner" }) do
	assert(loadfile(name .. ".lua"))("ShortestPathForever", ns)
end
assert(loadfile("tools/load_nav.lua"))(0)
assert(loadfile("tools/load_nav.lua"))(1)
local function walk(map, a, b)
	local points, why = ns.Path.FindSync(map, a, b)
	assert(points, tostring(why))
	return points
end
local start = { map = 1, x = 6341.38, y = 557.68, z = 16.29 }
local goal = { map = 0, x = -3263, y = -1353 }
local darkshore = { map = 1, x = 4990, y = 170 }
local routeID, boarding, alighting = 295
for _, stop in ipairs(ns.Routes[routeID].stops) do
	if stop.dock == 10 then boarding = stop end
	if stop.dock == 9 then alighting = stop end
end
assert(boarding and alighting, "Auberdine to Menethil crossing disappeared")
local boat = ns.Planner.LegPoints({ mode = "boat", route = routeID,
	from = ns.Docks[10], to = ns.Docks[9], boarding = boarding, alighting = alighting }, ns.Routes)
local crossing = ns.Routes[292]
local theramore = ns.Planner.LegPoints({ mode = "boat", route = 292,
	from = ns.Docks[5], to = ns.Docks[6], boarding = crossing.stops[1], alighting = crossing.stops[2] }, ns.Routes)
local hovered = {}
for _, id in ipairs({ 293, 295, 11167, 11616 }) do
	local route = ns.Routes[id]
	for i, stop in ipairs(route.stops) do
		local onward = route.stops[i % #route.stops + 1]
		hovered[#hovered + 1] = ns.Planner.LegPoints({ mode = "boat", route = id,
			from = ns.Docks[stop.dock], to = ns.Docks[onward.dock], boarding = stop, alighting = onward }, ns.Routes)
	end
end
local function json(value)
	if type(value) == "string" then return string.format("%q", value) end
	if type(value) ~= "table" then return tostring(value) end
	local keys, parts = {}, {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	for _, key in ipairs(keys) do
		parts[#parts + 1] = string.format("%q", tostring(key)) .. ":" .. json(value[key])
	end
	return "{" .. table.concat(parts, ",") .. "}"
end
print(json({ portals = ns.Portals, docks = ns.Docks, taxis = ns.TaxiNodes, routes = ns.Routes, hovered = hovered,
	walk = walk(1, start, ns.Docks[10]), boat = boat,
	theramore = theramore, silithus = walk(1, ns.Docks[6], ns.TaxiNodes[73]),
	wetlands = walk(0, ns.Docks[9], goal), darkshore = walk(1, start, darkshore) }))
"""
    result = subprocess.run(["luajit", "-"], input=program, text=True, cwd=ROOT, capture_output=True, check=True)
    return json.loads(result.stdout)


def ordered(mapping):
    # Path.FindSync attaches wet-yard metadata to the Lua array.
    return [mapping[key] for key in sorted((k for k in mapping if k.isdigit()), key=int)]


def projection(ui, point, map_id):
    rows = [
        r
        for r in ui.table("UiMapAssignment").values()
        if int(r["UiMapID"]) == map_id and int(r["MapID"]) == point["map"] and r["WMODoodadPlacementID"] == "0"
    ]
    if not rows:
        return None
    r = min(rows, key=lambda row: (int(row["OrderIndex"]), int(row["ID"])))
    # UiMapAssignment uses world x north/y west, with min at the southeast corner.
    x = (float(r["Region_4"]) - point["y"]) / (float(r["Region_4"]) - float(r["Region_1"]))
    y = (float(r["Region_3"]) - point["x"]) / (float(r["Region_3"]) - float(r["Region_0"]))
    return tuple(
        float(r[f"UiMin_{i}"]) + n * (float(r[f"UiMax_{i}"]) - float(r[f"UiMin_{i}"])) for i, n in enumerate((x, y))
    )


def dock_name(dock_id):
    d = data()["docks"][str(dock_id)]
    near = sorted(
        (math.hypot(t["x"] - d["x"], t["y"] - d["y"]), int(key), t)
        for key, t in data()["taxis"].items()
        if t["map"] == d["map"]
    )
    assert near[0][0] < 1000
    return near[0][2]["name"].split(",")[0]


def pier_direction(east, north):
    index = math.floor(math.atan2(north, east) / (2 * math.pi) * 8 + 0.5) % 8
    return ("east", "northeast", "north", "northwest", "west", "southwest", "south", "southeast")[index] + " pier"


def dock_title(dock_id):
    dock = data()["docks"][str(dock_id)]
    boats = {str(s["dock"]) for r in data()["routes"].values() if r["kind"] == "boat" for s in r["stops"].values()}
    near = [
        d
        for key, d in data()["docks"].items()
        if key in boats and d["map"] == dock["map"] and (d["x"] - dock["x"]) ** 2 + (d["y"] - dock["y"]) ** 2 < 800**2
    ]
    # Map.lua's DockPierName uses all nearby boat piers, independent of zoom or discovered routes.
    landing = (
        pier_direction(
            sum(d["y"] for d in near) / len(near) - dock["y"], dock["x"] - sum(d["x"] for d in near) / len(near)
        )
        if len(near) > 1
        else "dock"
    )
    return dock_name(dock_id) + " " + landing


def segment(canvas, a, b, color, dashed=False, alpha=1):
    """Route.lua Segment/Stroke: lengths in UI units at an effective scale of 1, whatever the frame's own scale."""
    ax, ay = (n * canvas.ui.scale for n in a)
    bx, by = (n * canvas.ui.scale for n in b)
    dx, dy = bx - ax, by - ay
    length = math.hypot(dx, dy)
    if length == 0:
        return
    # Route.lua's DASH and GAP, in the same units as the thickness.
    dash, gap = round(6 * canvas.ui.scale), round(5 * canvas.ui.scale)
    intervals = (
        [(d / length, min(d + dash, length) / length) for d in range(0, math.ceil(length), dash + gap)]
        if dashed
        else [(0, 1)]
    )
    if not hasattr(canvas, "strokes"):
        canvas.strokes = []
    for low, high in intervals:
        canvas.strokes.append(((ax + dx * low, ay + dy * low, ax + dx * high, ay + dy * high), color, alpha))


def flush_strokes(canvas):
    # ARTWORK sublevel -1 puts every outline beneath every core, including at bends and crossings.
    # THICKNESS / scale UI units draws at THICKNESS units' worth of pixels at every UI scale, so it widens with the
    # render scale like everything else.
    for width in (4, 2):
        layer = Image.new("RGBA", canvas.image.size)
        draw = ImageDraw.Draw(layer)
        for line, color, alpha in getattr(canvas, "strokes", []):
            rgba = (0.04, 0.04, 0.04, alpha * 0.5) if width == 4 else (*color, alpha)
            draw.line(line, fill=rgba255(rgba), width=round(width * canvas.ui.scale))
        canvas.image.alpha_composite(layer)
    canvas.strokes = []


def icon(canvas, name, x, y, size=None, alpha=1):
    art = canvas.ui.atlas(name)
    factor = size / max(art.width, art.height) if size else 1
    w, h = art.width * factor, art.height * factor
    canvas.draw(art, x - w / 2, y - h / 2, w, h, (1, 1, 1, alpha))


def map_docks(ui, map_id, width, height):
    """Map.lua's sorted, transitive clusters; a running centroid misses chains of overlapping pins."""
    kinds = {
        int(stop["dock"]): route["kind"] for route in data()["routes"].values() for stop in route["stops"].values()
    }
    docks = []
    for key, dock in sorted(data()["docks"].items(), key=lambda item: int(item[0])):
        p = projection(ui, dock.get("pin", dock), map_id)
        if p and all(0 <= n <= 1 for n in p):
            docks.append((int(key), max(0.015, min(0.985, p[0])) * width, max(0.015, min(0.985, p[1])) * height))
    roots = list(range(len(docks)))

    def root(i):
        while roots[i] != i:
            i = roots[i]
        return i

    for i, a in enumerate(docks):
        for j in range(i + 1, len(docks)):
            b = docks[j]
            if abs(a[1] - b[1]) < 16 and abs(a[2] - b[2]) < 16:
                roots[root(j)] = root(i)
    groups = {}
    for i, dock in enumerate(docks):
        groups.setdefault(root(i), []).append(dock)
    return [
        (
            sum(d[1] for d in group) / len(group),
            sum(d[2] for d in group) / len(group),
            [d[0] for d in group],
            kinds[group[0][0]],
        )
        for group in groups.values()
    ]


def map_landmarks(canvas, map_id, rect):
    """The default addon filters, with undiscovered Alliance flight points as in the captures."""
    ui = canvas.ui
    mx, my, mw, mh = rect

    def point(p):
        n = projection(ui, p, map_id)
        return (mx + n[0] * mw, my + n[1] * mh) if n and all(0 <= v <= 1 for v in n) else None

    for _, taxi in sorted(data()["taxis"].items(), key=lambda item: int(item[0])):
        p = point(taxi)
        # A zone's art also contains adjacent terrain; Map.lua only includes that zone's flight masters.
        if map_id == 1439 and taxi["name"].split(", ")[-1] != "Darkshore":
            continue
        if p and taxi.get("faction") != "Horde":
            icon(canvas, "taxinode_undiscovered", *p)
    for portal in ordered(data()["portals"]):
        p = point(portal["from"])
        if p and portal["kind"] == "portal" and portal.get("faction", "Alliance") == "Alliance":
            icon(canvas, "map-icon-suramardoor.tga", *p, 20)


@cache
def map_base(ui, map_id):
    art = map_art(ui, map_id)
    for overlay in map_overlays(ui, map_id):
        draw_overlay(ui, art, overlay.offset_x, overlay.offset_y, overlay.width, overlay.height, overlay.tiles)
    names = {947: ("World",), 1414: ("World", "Kalimdor"), 1439: ("World", "Kalimdor", "Darkshore")}
    return world_map_frame(ui, art, names[map_id], arrows=names[map_id][1:])


def map_canvas(ui, map_id=947, alpha=1, hover=False):
    base, rects = map_base(ui, map_id)
    canvas = ui.canvas(base.width, base.height)
    canvas.image = base.image.copy()
    mx, my, mw, mh = rects["map"]
    route = ui.canvas(mw, mh)

    def point(p):
        normal = projection(ui, p, map_id)
        return (normal[0] * mw, normal[1] * mh) if normal else None

    def curve(a, b, control, color, fade=False):
        previous = (a[0] * mw, a[1] * mh)
        for step in range(1, 13):
            t = step / 12
            p = tuple(
                ((1 - t) ** 2 * a[i] + 2 * (1 - t) * t * control[i] + t * t * b[i]) * size
                for i, size in enumerate((mw, mh))
            )
            segment(route, previous, p, color, alpha=alpha * (1 - (step - 0.5) / 12 if fade else 1))
            previous = p

    def crossing(a, b, color, previous=None):
        dx, dy = b[0] - a[0], b[1] - a[1]
        control = ((a[0] + b[0]) / 2 - dy * 0.25, (a[1] + b[1]) / 2 + dx * 0.25)
        if previous:
            tx, ty = a[0] - previous[0], a[1] - previous[1]
            length = math.hypot(tx, ty)
            if length > 0:
                reach = math.hypot(dx, dy) * 0.6 / length
                control = (a[0] + tx * reach, a[1] + ty * reach)
        else:
            side = -1 if dx < 0 else 1
            control = ((a[0] + b[0]) / 2 + dy * side * 0.6, (a[1] + b[1]) / 2 - dx * side * 0.6)
        if abs((control[0] - a[0]) * dy - (control[1] - a[1]) * dx) < (dx * dx + dy * dy) * 0.1:
            control = ((a[0] + b[0]) / 2 - dy * 0.25, (a[1] + b[1]) / 2 + dx * 0.25)
        curve(a, b, control, color)

    def path(points, color, dashed):
        for index, (a, b) in enumerate(zip(points, points[1:], strict=False)):
            if a["map"] == b["map"] and not a.get("jump"):
                pa, pb = point(a), point(b)
                if pa and pb:
                    segment(route, pa, pb, color, dashed, alpha)
            elif not dashed:
                pa, pb = projection(ui, a, map_id), projection(ui, b, map_id)
                before = points[index - 1] if index else points[-2]
                if pa and pb:
                    # Same-continent teleports retain both ends; only a hidden end fades to the map edge.
                    crossing(pa, pb, color, projection(ui, before, map_id) if before["map"] == a["map"] else None)
                    continue
                # Route.lua EdgeCurve carries a loading-screen crossing out to sea, fading at the edge.
                for end, neighbor in ((a, before), (b, points[index + 2] if index + 2 < len(points) else points[1])):
                    p, n = projection(ui, end, map_id), projection(ui, neighbor, map_id)
                    if not p or not n or end["map"] != neighbor["map"]:
                        continue
                    dx, dy = p[0] - n[0], p[1] - n[1]
                    length = math.hypot(dx, dy)
                    if length < 0.000001:
                        continue
                    dx, dy = dx / length, dy / length
                    ex, ey = dx - dy * 0.3, dy + dx * 0.3
                    distance = min(
                        ((1 if delta > 0 else 0) - origin) / delta
                        for origin, delta in ((p[0], ex), (p[1], ey))
                        if delta
                    )
                    if distance > 0:
                        end = (p[0] + ex * distance, p[1] + ey * distance)
                        control = (p[0] + dx * distance * 0.55, p[1] + dy * distance * 0.55)
                        curve(p, end, control, color, fade=True)

    if not hover:
        for name in (
            ("darkshore",) if map_id == 1439 else ("walk", "silithus") if map_id == 1414 else ("walk", "wetlands")
        ):
            path(ordered(data()[name]), NORMAL, True)
    boats = ordered(data()["hovered"]) if hover else [data()["boat"]]
    if map_id == 1414:
        boats.append(data()["theramore"])
    for boat_data in boats if map_id != 1439 else []:
        boat = ordered(boat_data)
        if map_id == 947 and boat[0]["map"] != boat[-1]["map"]:
            crossing(projection(ui, boat[0], map_id), projection(ui, boat[-1], map_id), BOAT_COLOR)
        else:
            path(boat, BOAT_COLOR, False)
    flush_strokes(route)
    canvas.paste(route, mx, my)
    map_landmarks(canvas, map_id, rects["map"])
    clusters = map_docks(ui, map_id, mw, mh)
    hover_point = None
    for x, y, ids, kind in clusters:
        x, y = x + mx, y + my
        if hover and set(ids) & {7, 9, 17, 25}:
            canvas.draw(ui.atlas("UI-QuestPoi-OuterGlow"), x - 28, y - 28, 56, 56)
        if kind == "zeppelin":
            canvas.draw(Image.open(ROOT / "media/zeppelin.tga").convert("RGBA"), x - 10, y - 10, 20, 20)
        else:
            size = 15 if kind in ("lift", "tram") else 20
            atlas = {"boat": "flightmasterferry", "lift": "poi-door-arrow-up", "tram": "poi-door-arrow-down"}[kind]
            canvas.draw(ui.atlas(atlas), x - size / 2, y - size / 2, size, size)
            if hover and 10 in ids:
                canvas.draw(ui.atlas(atlas), x - 10, y - 10, 20, 20, blend="ADD")
        if 10 in ids:
            hover_point = (x, y)
    if not hover:
        goal = DARKSHORE_GOAL if map_id == 1439 else data()["taxis"]["73"] if map_id == 1414 else GOAL
        gp = point(goal)
        if gp and 0 <= gp[0] <= mw and 0 <= gp[1] <= mh:
            art = ui.atlas("Waypoint-MapPin-Tracked")
            canvas.draw(
                art, mx + gp[0] - art.width * 0.4, my + gp[1] - art.height * 0.4, art.width * 0.8, art.height * 0.8
            )
        points = ordered(data()["darkshore" if map_id == 1439 else "walk"])
        bend = next(p for p in points[1:] if math.hypot(p["x"] - START["x"], p["y"] - START["y"]) > 25)
        bp = point(bend)
        if bp:
            # Journey.lua places Guide's native 30-unit waypoint beneath the player's map arrow.
            icon(canvas, "Waypoint-MapPin-Tracked", mx + bp[0], my + bp[1], 30)
    sp = point(START)
    if sp:
        icon(canvas, "UI-WorldMapArrow", mx + sp[0], my + sp[1], 27)
    return canvas, hover_point


def render_map(ui, map_id=947):
    canvas, _ = map_canvas(ui, map_id)
    return scene(ui, [(canvas, 0, 0)])


def render_docks(ui):
    canvas, pin = map_canvas(ui, hover=True)
    assert pin
    _, _, width, height = map_base(ui, 947)[1]["map"]
    x, y, ids, _ = next(c for c in map_docks(ui, 947, width, height) if 10 in c[2])
    labels = {}
    for dock_id in ids:
        px, py = projection(ui, data()["docks"][str(dock_id)], 947)
        labels[dock_id] = "Darkshore, " + pier_direction(px - x / width, y / height - py)
    tip = tooltip(
        ui,
        [
            TooltipLine("Boats"),
            TooltipLine(labels[8]),
            TooltipLine("to Teldrassil", NORMAL, "no sighting yet", (0.5, 0.5, 0.5)),
            TooltipLine(labels[10]),
            TooltipLine("to Wetlands", NORMAL, "arrives 3:23 · leaves 4:23"),
            TooltipLine("to Wetlands, then Hillsbrad Foothills", NORMAL, "no sighting yet", (0.5, 0.5, 0.5)),
            TooltipLine(labels[24]),
            TooltipLine("to Stormwind City", NORMAL, "no sighting yet", (0.5, 0.5, 0.5)),
            TooltipLine("Last seen 2 min ago by you", (0.5, 0.5, 0.5)),
        ],
    )
    # GameTooltip ANCHOR_RIGHT: tooltip bottom-left just past the owner's top-right.
    return scene(ui, [(canvas, 0, 0), (tip, pin[0] + 10, pin[1] - 10 - tip.height)])


def tracker_canvas(ui, seconds=0, boats=False, settling=False):
    if boats:
        module = TrackerModule(
            "Boats",
            [
                TrackerBlock(
                    dock_title(8),
                    [
                        f"Teldrassil   arrives {countdown(203 - seconds)} · leaves {countdown(263 - seconds)}",
                    ],
                )
            ],
        )
    else:
        # Reference 21 is a captured itinerary, not a new optimality claim for these timings.
        rows = [
            colored(f"1. Walk to {dock_title(10)}   {countdown(120 - seconds)}", WHITE),
            "2. Boat to Wetlands (no sighting yet)   wait 2:28 · 1:20",
            f"3. Walk to {dock_title(5)}   1:31",
            "4. Boat to Dustwallow Marsh (no sighting yet)   wait 2:45 · 1:44",
            "5. Walk to Silithus   33:02",
        ]
        title = "Journey to Silithus" + (" · finding the fastest way..." if settling else "")
        module = TrackerModule(f"Journey  {countdown(2687 - seconds)} · 9.2k yd", [TrackerBlock(title, rows)])
    return objective_tracker(ui, [module], container=False)[0]


def countdown(seconds):
    return f"{max(0, seconds) // 60}:{max(0, seconds) % 60:02d}"


def render_tracker(ui, boats=False):
    return scene(ui, [(tracker_canvas(ui, boats=boats), 0, 0)])


def compass_canvas(ui, facing=math.pi - 0.2, distance=780):
    canvas = ui.canvas(360, 65)
    tooltip_backdrop(canvas, 0, 0, 360, 60, background=(0.06, 0.06, 0.06, 0.7), border=(0.55, 0.52, 0.46, 0.65))

    def offset(angle):
        return -((angle - facing + math.pi) % (2 * math.pi) - math.pi) * 360 / math.pi

    for index in range(24):
        x = offset(index * math.pi / 12)
        if abs(x) > 180:
            continue
        alpha = min(1, (180 - abs(x)) / 18)
        height = 5 if index % 6 == 0 else 3
        canvas.fill(180 + x - 0.5, 6, 1, height, (0.72, 0.67, 0.55, 0.7 * alpha))
        if index % 6 == 0:
            canvas.text(
                180 + x - 10,
                12,
                ("N", "W", "S", "E")[index // 6],
                FONTS["GameFontNormalSmall"],
                (*NORMAL, alpha),
                justify="CENTER",
                width=20,
            )
    canvas.fill(179.5, 3, 1, 6, (1, 0.82, 0, 0.85))
    # Chosen bearings reproduce reference 20, using the current proportion-preserving atlas sizes.
    for angle, name, size, alpha, bend in (
        (math.pi + 0.9, "Waypoint-MapPin-Tracked", 18, 0.85, False),
        (math.pi, "Navigation-Tracked-Icon", 18, 1, True),
        (math.pi + 0.15, "Navigation-Tracked-Icon", 12, 0.45, False),
    ):
        x = 180 + max(-180, min(180, offset(angle)))
        icon(canvas, name, x, 36, size, alpha)
        if bend:
            art = ui.atlas(name)
            h = size * art.height / max(art.width, art.height)
            canvas.text(
                x - 40, 36 + h / 2 + 2, f"{distance} yd", FONTS["GameFontHighlightSmall"], justify="CENTER", width=80
            )
    return canvas


def render_compass(ui):
    return scene(ui, [(compass_canvas(ui), 0, 0)])


def render_minimap(ui):
    canvas = ui.canvas(300, 285)
    cx, cy, size, radius = 150, 155, 198, 233 + 1 / 3
    terrain = minimap_art(ui, START["map"], START["x"], START["y"], radius)
    face = ui.canvas(size, size)
    face.draw(terrain, 0, 0, size, size)
    points = ordered(data()["walk"])

    def project(p):
        return (
            size / 2 + (START["y"] - p["y"]) * size / (2 * radius),
            size / 2 - (p["x"] - START["x"]) * size / (2 * radius),
        )

    for a, b in zip(points, points[1:], strict=False):
        segment(face, project(a), project(b), NORMAL, True)
    flush_strokes(face)
    face.mask(ui.atlas("ui-hud-minimap-frame-generic-mask").image, 0, 0, size, size)
    canvas.paste(face, cx - size / 2, cy - size / 2)
    icon(canvas, "UI-HUD-Minimap-Frame", cx, cy)
    # Camelot Diel.lua: indicator is 63 right and 72 up from the cluster center.
    icon(canvas, "UI-HUD-Minimap-NightCycle", cx + 63, cy - 72)
    icon(canvas, "UI-HUD-Minimap-Frame-Cycle", cx + 63, cy - 72)
    icon(canvas, "MinimapArrow", cx, cy, 16)
    bend = next(p for p in points[1:] if math.hypot(p["x"] - START["x"], p["y"] - START["y"]) > 25)
    x, y = project(bend)
    icon(canvas, "Waypoint-MapPin-Minimap-Tracked", cx - size / 2 + x, cy - size / 2 + y, 16)
    canvas.text(0, 13, dock_name(10), FONTS["GameFontNormal"], justify="CENTER", width=300)
    return scene(ui, [(canvas, 0, 0)])


def render_demo(ui):
    # Route.lua fixes stroke widths in physical pixels; render at the GIF's final size.
    ui = Art(scale=1)
    frames = []
    for index in range(80):
        t = index / 10
        canvas = backdrop(ui, 760, 555)
        if t < 3:
            alpha = 0.575 + 0.225 * math.cos(t * 2 * math.pi / 1.2) if t < 2.4 else 1
            map_frame, _ = map_canvas(ui, 1414, alpha=alpha)
            fit = min(734 / map_frame.width, 555 / map_frame.height)
            width, height = map_frame.width * fit, map_frame.height * fit
            canvas.draw(map_frame.image, (760 - width) / 2, 0, width, height)
        else:
            seconds = int(t - 3)
            tracker = tracker_canvas(ui, seconds)
            canvas.paste(tracker, 242, 165)
            # Compass.lua's exponential easing, fed a deterministic slow player turn.
            target = math.pi - 0.2 + 0.3 * math.sin((t - 3) * math.pi / 2.5)
            if index == 30:
                facing = target
            facing += (target - facing) * (1 - math.exp(-18 / 10))
            canvas.paste(compass_canvas(ui, facing, 780 - 7 * seconds), 200, 75)
        frames.append(canvas.image.convert("RGB").resize((760, 555), Image.Resampling.LANCZOS))
    # One shared palette avoids colour shimmer and makes repeated encodes byte-identical.
    palette_source = Image.new("RGB", (760, 555 * 2))
    palette_source.paste(frames[0], (0, 0))
    # Give the small tracker/compass as much palette weight as the parchment, preserving text colours.
    palette_source.paste(frames[40].crop((200, 75, 580, 390)).resize((760, 555)), (0, 555))
    palette = palette_source.quantize(colors=240, method=Image.Quantize.MEDIANCUT)
    reserved = [(255, 255, 255), (204, 204, 204), (191, 156, 0), (255, 210, 0), (0, 191, 255), (10, 10, 10)]
    palette.putpalette(
        palette.getpalette()[:720] + [channel for color in reserved + [(0, 0, 0)] * 10 for channel in color]
    )
    indexed = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]
    buffer = io.BytesIO()
    indexed[0].save(
        buffer, format="GIF", save_all=True, append_images=indexed[1:], duration=100, loop=0, optimize=True, disposal=1
    )
    assert len(buffer.getvalue()) <= 3_000_000, "demo exceeds 3 MB"
    return buffer.getvalue()


SCENES = {
    "world-map": lambda ui: render_map(ui),
    "kalimdor": lambda ui: render_map(ui, 1414),
    "darkshore": lambda ui: render_map(ui, 1439),
    "docks": render_docks,
    "tracker": render_tracker,
    "boats": lambda ui: render_tracker(ui, boats=True),
    "minimap": render_minimap,
    "compass": render_compass,
}


def encode(ui, name):
    if name == "demo":
        return render_demo(ui), ".gif"
    buffer = io.BytesIO()
    SCENES[name](ui).image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue(), ".png"


def comparison_sheet(name, pairs):
    width = max(a.width + b.width for _, a, _, b in pairs) + 30
    height = sum(max(a.height, b.height) + 40 for _, a, _, b in pairs)
    sheet = Image.new("RGB", (width, height), (28, 29, 33))
    draw, y = ImageDraw.Draw(sheet), 0
    for left, a, right, b in pairs:
        draw.text((10, y + 6), left, fill="white")
        draw.text((a.width + 20, y + 6), right, fill="white")
        sheet.paste(a, (10, y + 27))
        sheet.paste(b, (a.width + 20, y + 27))
        y += max(a.height, b.height) + 40
    path = ROOT / "docs/verification" / (name + ".png")
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path, optimize=True)
    print(path.relative_to(ROOT), flush=True)


def enlarged(image, factor=2):
    return image.resize((round(image.width * factor), round(image.height * factor)), Image.Resampling.NEAREST)


def compare_references(refs, tooltip_ref=None):
    """Keep reference pixels out of product media; this sheet is a review artifact only."""
    ui, art = Art(scale=1.2), Art(scale=2)
    # Reuse the cached 2x atlas at the capture's UI scale; never switch the art set for this comparison.
    ui.atlas = art.atlas
    panel = tracker_canvas(ui)
    ground = backdrop(ui, panel.width, panel.height)
    ground.paste(panel, 0, 0)
    reference = Image.open(refs / "21.png").convert("RGB").crop((5, 14, 325, 213))
    mock = ground.image.convert("RGB").crop((4, 8, 324, 207))
    comparison_sheet(
        "tracker",
        [("Owner 21 (2x)", enlarged(reference), "Current source: totals in section header (2x)", enlarged(mock))],
    )

    def map_image(map_id, hover=False):
        canvas, _ = map_canvas(ui, map_id, hover=hover)
        x, y, w, h = map_base(ui, map_id)[1]["map"]
        return canvas.image.convert("RGB").crop(tuple(round(n * ui.scale) for n in (x, y, x + w, y + h)))

    world = map_image(947)
    reference = Image.open(refs / "14.png").convert("RGB")
    comparison_sheet(
        "world-map",
        [
            ("Owner 14", reference, "Current overview curve / Wetlands goal", world),
            (
                "Owner: Auberdine (3x)",
                enlarged(reference.crop((115, 125, 220, 205)), 3),
                "Mock: Auberdine (3x)",
                enlarged(world.crop((115, 125, 220, 205)), 3),
            ),
        ],
    )
    for name, number, map_id, box in (
        ("kalimdor", "11", 1414, (249, 18, 633, 548)),
        ("darkshore", "13", 1439, (171, 171, 460, 553)),
    ):
        reference = Image.open(refs / (number + ".png")).convert("RGB")
        mock = map_image(map_id).crop(box)
        comparison_sheet(
            name,
            [
                (
                    f"Owner {number}: matched parchment crop (2x)",
                    enlarged(reference),
                    "Current route / selected destination (2x)",
                    enlarged(mock),
                )
            ],
        )
    hover = map_image(947, hover=True)
    comparison_sheet(
        "docks",
        [
            (
                "Owner 14: ferry beside Menethil (3x)",
                enlarged(Image.open(refs / "14.png").crop((590, 230, 674, 297)), 3),
                "Hover mock: same ferry, destination glow (3x)",
                enlarged(hover.crop((590, 230, 674, 297)), 3),
            ),
            (
                "Owner 14: Auberdine (3x)",
                enlarged(Image.open(refs / "14.png").crop((130, 135, 175, 175)), 3),
                "Hover mock: additive ferry highlight (3x)",
                enlarged(hover.crop((130, 135, 175, 175)), 3),
            ),
        ],
    )

    reference = Image.open(refs / "19.png").crop((94, 28, 422, 383))
    mock = render_minimap(art).image.crop((48, 82, 478, 538)).resize((323, 342), Image.Resampling.LANCZOS)
    comparison_sheet(
        "minimap",
        [
            (
                "Owner 19: Auberdine (2x)",
                enlarged(reference),
                "Mock: same tiles/frame; selected start and route (2x)",
                enlarged(mock),
            ),
            (
                "Owner 18: dashed route (3x)",
                enlarged(Image.open(refs / "18.png").crop((64, 34, 135, 156)), 3),
                "Mock: route and native waypoint (3x)",
                enlarged(render_minimap(art).image.crop((192, 280, 291, 354)), 3),
            ),
        ],
    )
    comparison_sheet(
        "compass",
        [
            (
                "Owner 20: previous compass (3x)",
                enlarged(Image.open(refs / "20.png").crop((0, 24, 313, 81)), 3),
                "Current source: 360x60, soft border, stock fonts (2x)",
                enlarged(compass_canvas(ui).image),
            )
        ],
    )
    if tooltip_ref:
        # The supplied captures contain no dock tooltip. Use the skill's real stock GameTooltip capture.
        tip = tooltip(
            ui,
            [
                TooltipLine("Boats"),
                TooltipLine("Darkshore, south pier"),
                TooltipLine("to Wetlands", NORMAL, "arrives 3:23 · leaves 4:23"),
            ],
        )
        ground = backdrop(ui, tip.width, tip.height)
        ground.paste(tip, 0, 0)
        comparison_sheet(
            "tooltip",
            [
                (
                    "Real stock GameTooltip: SkillUp be11638 (2x)",
                    enlarged(Image.open(tooltip_ref).crop((0, 0, 346, 50))),
                    "Same stock widget, dock content from Map.lua (2x)",
                    enlarged(ground.image),
                )
            ],
        )
    if (OUT / "demo.gif").exists():
        with Image.open(OUT / "demo.gif") as demo:
            samples = []
            for index in (0, 6, 26, 34, 48, 70):
                demo.seek(index)
                samples.append(demo.convert("RGB"))
            comparison_sheet(
                "demo",
                [
                    (f"Frame {a}", samples[i], f"Frame {b}", samples[i + 1])
                    for i, (a, b) in zip((0, 2, 4), ((0, 6), (26, 34), (48, 70)), strict=True)
                ],
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenes", nargs="+", choices=(*SCENES, "demo"), default=[*SCENES, "demo"])
    parser.add_argument("--verify", action="store_true", help="render twice and require identical bytes")
    parser.add_argument("--refs", type=Path, help="write enlarged comparisons against the owner's captures")
    parser.add_argument("--tooltip-ref", type=Path, help="optional real stock tooltip capture; absent from refs 11-21")
    args = parser.parse_args()
    ui = Art(scale=2)
    OUT.mkdir(parents=True, exist_ok=True)
    failed = []
    for name in args.scenes:
        try:
            content, suffix = encode(ui, name)
            if args.verify:
                assert content == encode(Art(scale=2), name)[0], f"{name}: nondeterministic bytes"
            path = OUT / (name + suffix)
            path.write_bytes(content)
            print(
                f"{path.relative_to(ROOT)}  {len(content):,} bytes  sha256:{hashlib.sha256(content).hexdigest()}",
                flush=True,
            )
        except Exception as error:
            failed.append(name)
            print(f"{name}: {type(error).__name__}: {error}", file=sys.stderr, flush=True)
    if args.refs:
        compare_references(args.refs, args.tooltip_ref)
    if failed:
        sys.exit("Not rendered: " + ", ".join(failed) + ". No placeholder art was substituted.")


if __name__ == "__main__":
    main()
