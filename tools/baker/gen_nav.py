"""Build a map's walking-route data (HPA* graph + per-cluster 8 yd grids) as an addon Lua file.

usage: gen_nav.py <out.lua> --map <id> [--name "<title>"] [--rows r0 r1 --cols c0 c1] [--jobs n]

Reads our own bake of the local client (Mappster, TrinityCore mmtile layout <mm>/MMMM_RR_CC.mmtile, one Detour tile
per ADT) from NAV_MM. The tile bounding box comes from the .mmtile files present (optionally cut to --rows/--cols).
Every tile with walkable data becomes a cluster; poly components under MIN_COMPONENT polys (rooftops, treetops,
props) are dropped over the whole map.

Streamed so a continent fits in memory: pass 1 finds the poly components over the whole map with a compact
union-find; pass 2 rasterizes each tile from the 3x3 tiles around it (in parallel); pass 3 builds the HPA graph over
the assembled grid. All iteration is in a canonical (tile, poly) order, so the output is deterministic and a tile's
cells do not depend on which window computed them.

Detour stores vertices as (worldY, worldZ, worldX). Output is in UnitPosition's frame: x grows north (world X),
y grows west (world Y).
"""

import glob
import heapq
import math
import os
import re
import struct
import sys
from array import array
from collections import defaultdict
import multiprocessing

MM = os.environ.get("NAV_MM", "mm")
T = 1600 / 3
CELLS = 67
CS = T / CELLS
SWIM = 7 / 4.7  # running 7 yd/s, swimming 4.7 yd/s
ENTRANCE_RUN = 20  # longest border run (cells) served by one entrance
PRUNE = 1.02  # drop an intra edge when a two-hop path is within 2%
MIN_COMPONENT = 500
MARGIN = 1.0  # a step between cells may use navmesh this far outside the two cells (yd)
CLIMB = 3.0  # two surfaces at one point are the same layer within this height (yd)
AREA_GROUND, AREA_WATER, AREA_OCEAN = 11, 9, 6
FLAG_UNDER_HAZARD = 0x80  # Mappster: ground under magma or slime
SOURCE = os.environ.get("NAV_SOURCE", "own bake of the World of Warcraft client (wow_classic_beta), Mappster/DotRecast")
B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

# Set by configure(): the map, its tiles and the global grid.
MAP = 0
TILES = {}  # (rr, cc) -> path
ROWS = COLS = range(0)
CX0 = CY0 = NX = NY = GW = GH = 0
X0 = Y0 = 0.0
ORD = {}  # (rr, cc) -> canonical tile ordinal (rows outer, cols inner)
BASE = {}  # (rr, cc) -> first dense poly id of the tile
SIZE = array("i")  # dense poly id -> poly count of its navmesh component; kept when >= MIN_COMPONENT


def configure(map_id, rows=None, cols=None):
    global MAP, TILES, ROWS, COLS, CX0, CY0, NX, NY, GW, GH, X0, Y0, ORD
    MAP = map_id
    TILES = {}
    for path in glob.glob(os.path.join(MM, f"{map_id:04d}_??_??.mmtile")):
        rr, cc = map(int, re.findall(r"_(\d\d)_(\d\d)\.mmtile$", path)[0])
        if (rows is None or rows[0] <= rr <= rows[1]) and (cols is None or cols[0] <= cc <= cols[1]):
            TILES[(rr, cc)] = path
    if not TILES:
        sys.exit(f"no {map_id:04d}_RR_CC.mmtile files in {MM}")
    ROWS = range(min(r for r, _ in TILES), max(r for r, _ in TILES) + 1)
    COLS = range(min(c for _, c in TILES), max(c for _, c in TILES) + 1)
    CX0, CY0 = 31 - max(ROWS), 31 - max(COLS)
    NX, NY = len(ROWS), len(COLS)
    X0, Y0 = CX0 * T, CY0 * T
    GW, GH = NX * CELLS, NY * CELLS
    ORD = {rc: i for i, rc in enumerate(sorted(TILES))}


def enc(v, width):
    assert 0 <= v < 64**width, (v, width)
    return "".join(B64[(v >> (6 * (width - 1 - i))) & 63] for i in range(width))


def load_tile(path):
    """Detour tile -> (verts, [(vertex ids, neighbour refs, flags, area, type)])."""
    b = open(path, "rb").read()
    o = 20
    h = struct.unpack_from("<4s14i3f3ff", b, o)
    assert h[0] == b"VAND", path
    poly_count, vert_count = h[6], h[7]
    o += 100
    verts = struct.unpack_from("<%df" % (vert_count * 3), b, o)
    o += vert_count * 12
    polys = []
    for _ in range(poly_count):
        _, *rest = struct.unpack_from("<I6H6HHBB", b, o)
        o += 32
        pv, pn, flags, nv, at = rest[0:6], rest[6:12], rest[12], rest[13], rest[14]
        polys.append((pv[:nv], pn[:nv], flags, at & 0x3F, at >> 6))
    return verts, polys


def plane(pts, c):
    """(cx, cy, cz, gx, gy): height at (x, y) is cz + gx (x - cx) + gy (y - cy), from the Newell normal."""
    nx = ny = nz = 0.0
    for i in range(len(pts)):
        (x1, y1, z1), (x2, y2, z2) = pts[i], pts[(i + 1) % len(pts)]
        nx += (y1 - y2) * (z1 + z2)
        ny += (z1 - z2) * (x1 + x2)
        nz += (x1 - x2) * (y1 + y2)
    if abs(nz) < 1e-9:
        return (*c, 0.0, 0.0)
    return (*c, -nx / nz, -ny / nz)


def height(p, x, y):
    cx, cy, cz, gx, gy = p["plane"]
    return cz + gx * (x - cx) + gy * (y - cy)


def cluster_of_tile(rr, cc):
    return ((31 - rr) - CX0) * NY + ((31 - cc) - CY0)


def walkable(pts, flags, area, typ):
    return typ == 0 and area in (AREA_GROUND, AREA_WATER, AREA_OCEAN) and not flags & FLAG_UNDER_HAZARD and pts


def read_tile(rc):
    """One tile's walkable polys as (local index, pts (X, Y, Z), water) plus its intra-tile links and border edges."""
    verts, tile_polys = load_tile(TILES[rc])
    pts_of = [[(verts[v * 3 + 2], verts[v * 3], verts[v * 3 + 1]) for v in pv] for pv, *_ in tile_polys]  # (X, Y, Z)
    ok = [bool(walkable(pts_of[i], flags, area, typ)) for i, (_, _, flags, area, typ) in enumerate(tile_polys)]
    polys, links, border = [], [], []
    for i, (pv, pn, flags, area, typ) in enumerate(tile_polys):
        if not ok[i]:
            continue
        pts = pts_of[i]
        polys.append((i, pts, area != AREA_GROUND))
        n = len(pts)
        for e, nb in enumerate(pn):
            if nb == 0:
                continue
            p1, p2 = pts[e], pts[(e + 1) % n]
            if nb & 0x8000:  # tile-border edge; detour side 0/4 is an x (= world Y) border
                side = nb & 0xFF
                if side in (0, 4):
                    key, lo, hi = ("y", round(p1[1], 1)), *sorted((p1[0], p2[0]))
                else:
                    key, lo, hi = ("x", round(p1[0], 1)), *sorted((p1[1], p2[1]))
                border.append((key, i, lo, hi, (p1[2] + p2[2]) / 2))
            elif ok[nb - 1]:
                links.append((i, nb - 1, p1[:2], p2[:2]))
    return polys, links, border


def match_borders(border):
    """Cross-tile links from border edges keyed by line: [(a, b, ends)] for overlapping edges of different tiles."""
    out = []
    for key, es in border.items():
        es.sort(key=lambda t: (t[1], t[0]))
        for i in range(len(es)):
            for j in range(i + 1, len(es)):
                if es[j][1] >= es[i][2] - 0.01:
                    break
                a, b = es[i][0], es[j][0]
                if a >> 16 == b >> 16:
                    continue
                lo, hi = max(es[i][1], es[j][1]), min(es[i][2], es[j][2])
                if hi - lo > 0.05 and abs(es[i][3] - es[j][3]) < 4:
                    axis, at = key
                    out.append((a, b, ((lo, at), (hi, at)) if axis == "y" else ((at, lo), (at, hi))))
    return out


def gid(rc, i):
    return ORD[rc] << 16 | i


def components():
    """Pass 1: union-find over every walkable poly of the map; SIZE records each poly's component size."""
    global SIZE
    parent = array("i")
    border = defaultdict(list)
    dense = {}  # gid -> dense id, only while matching borders

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for rc in sorted(TILES):
        polys, links, edges = read_tile(rc)
        BASE[rc] = base = len(parent)
        loc = {i: base + n for n, (i, _, _) in enumerate(polys)}
        parent.extend(range(base, base + len(polys)))
        for i, j, _, _ in links:
            parent[find(loc[i])] = find(loc[j])
        for key, i, lo, hi, z in edges:
            g = gid(rc, i)
            dense[g] = loc[i]
            border[key].append((g, lo, hi, z))
    for a, b, _ in match_borders(border):
        parent[find(dense[a])] = find(dense[b])
    size = defaultdict(int)
    for x in range(len(parent)):
        size[find(x)] += 1
    SIZE = array("i", (size[find(x)] for x in range(len(parent))))
    big = sorted((s for s in size.values() if s >= MIN_COMPONENT), reverse=True)
    print(f"tiles {len(TILES)}, polys {len(parent)}, components {len(size)}, kept {len(big)} "
          f"({sum(big)} polys): {big[:12]}{' ...' if len(big) > 12 else ''}", flush=True)


def load_window(tiles):
    """Kept polys of some tiles keyed by gid, with their adjacency and portals (world coordinates)."""
    polys, adj, portal, border = {}, defaultdict(set), {}, defaultdict(list)
    for rc in sorted(tiles, key=ORD.get):
        tp, links, edges = read_tile(rc)
        base, k = BASE[rc], cluster_of_tile(*rc)
        kept = set()
        for n, (i, pts, water) in enumerate(tp):
            if SIZE[base + n] < MIN_COMPONENT:
                continue
            kept.add(i)
            nv = len(pts)
            c = tuple(sum(p[a] for p in pts) / nv for a in range(3))
            polys[gid(rc, i)] = dict(c=c, water=water, k=k, size=SIZE[base + n], pts=[(p[0], p[1]) for p in pts], plane=plane(pts, c))
        for i, j, p1, p2 in links:
            if i in kept and j in kept:
                adj[gid(rc, i)].add(gid(rc, j))
                portal[(gid(rc, i), gid(rc, j))] = (p1, p2)
        for key, i, lo, hi, z in edges:
            if i in kept:
                border[key].append((gid(rc, i), lo, hi, z))
    for a, b, ends in match_borders(border):
        adj[a].add(b)
        adj[b].add(a)
        portal[(a, b)] = portal[(b, a)] = ends
    return polys, adj, portal


def triarea2(a, b, c):
    return (c[0] - a[0]) * (b[1] - a[1]) - (b[0] - a[0]) * (c[1] - a[1])


def point_in_convex(px, py, pts):
    sign = 0
    n = len(pts)
    for i in range(n):
        (x1, y1), (x2, y2) = pts[i], pts[(i + 1) % n]
        c = (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)
        if abs(c) < 1e-9:
            continue
        s = 1 if c > 0 else -1
        if sign == 0:
            sign = s
        elif s != sign:
            return False
    return True


def seg_in_box(a, b, box):
    """Does segment a-b touch the axis-aligned box (x0, x1, y0, y1)? (Liang-Barsky clip.)"""
    x0, x1, y0, y1 = box
    t0, t1 = 0.0, 1.0
    dx, dy = b[0] - a[0], b[1] - a[1]
    for p, q in ((-dx, a[0] - x0), (dx, x1 - a[0]), (-dy, a[1] - y0), (dy, y1 - a[1])):
        if p == 0:
            if q < 0:
                return False
            continue
        r = q / p
        if p < 0:
            t0 = max(t0, r)
        else:
            t1 = min(t1, r)
        if t0 > t1:
            return False
    return True


def rasterize_tile(rc):
    """Pass 2 for one tile: its cells' top surfaces (0 blocked, 1 ground, 2 water) and the step codes it owns.

    Where layers overlap, the surface of the larger navmesh component decides and, within one component, the highest:
    a bridge is ground and a lake (a water surface over a walkable lake bed) is water, while a city under a walkable
    roof (Ironforge under its mountain top, Undercity under the Lordaeron ruins' rooftops) stays the city. A step between neighbouring cells is cut unless a 2D ray along the navmesh surface from one
    cell's anchor reaches the other's surface poly, so the grid cannot climb a cliff, pass a fence or wall, or drop off
    a bridge. Surfaces are computed two cells beyond the tile and orthogonal cuts one cell beyond, which is all the
    tile's own steps and diagonals read; everything comes from the 3x3 tiles around it.
    """
    rr, cc = rc
    window = [(rr + dr, cc + dc) for dr in (-1, 0, 1) for dc in (-1, 0, 1) if (rr + dr, cc + dc) in TILES]
    polys, adj, portal = load_window(window)
    k = cluster_of_tile(rr, cc)
    kx, ky = divmod(k, NY)
    tx0, tx1, ty0, ty1 = kx * CELLS, kx * CELLS + CELLS - 1, ky * CELLS, ky * CELLS + CELLS - 1
    ax0, ax1, ay0, ay1 = max(0, tx0 - 2), min(GW - 1, tx1 + 2), max(0, ty0 - 2), min(GH - 1, ty1 + 2)
    grid, top, anchor = {}, {}, {}  # cell -> value / (component size, height) / (poly, point on it)

    def mark(i, v, z, pid, pt):
        key = (polys[pid]["size"], z)
        if key > top.get(i, (0, -1e9)):
            grid[i], top[i], anchor[i] = v, key, (pid, pt)

    def at(x, y):
        gx, gy = int((x - X0) // CS), int((y - Y0) // CS)
        return gx * GH + gy if ax0 <= gx <= ax1 and ay0 <= gy <= ay1 else -1

    for pid in sorted(polys):
        p = polys[pid]
        v = 2 if p["water"] else 1
        xs, ys = [q[0] for q in p["pts"]], [q[1] for q in p["pts"]]
        for gx in range(max(ax0, int((min(xs) - X0) // CS)), min(ax1 + 1, int((max(xs) - X0) // CS) + 1)):
            for gy in range(max(ay0, int((min(ys) - Y0) // CS)), min(ay1 + 1, int((max(ys) - Y0) // CS) + 1)):
                c = (X0 + (gx + 0.5) * CS, Y0 + (gy + 0.5) * CS)
                if point_in_convex(c[0], c[1], p["pts"]):
                    mark(gx * GH + gy, v, height(p, *c), pid, c)
    # Passages narrower than a cell: centroid -> shared edge midpoint -> centroid stays inside the two convex polygons.
    # These cells anchor on the poly centroid, since their centre may lie off the mesh.
    for u in sorted(adj):
        for w in sorted(adj[u]):
            if w <= u:
                continue
            pu, pw = polys[u], polys[w]
            e1, e2 = portal[(u, w)]
            mid = ((e1[0] + e2[0]) / 2, (e1[1] + e2[1]) / 2)
            for a, b, p, pid in ((pu["c"], mid, pu, u), (mid, pw["c"], pw, w)):
                steps = int(math.dist(a[:2], b[:2]) / (CS / 4)) + 1
                for t in range(steps + 1):
                    i = at(a[0] + (b[0] - a[0]) * t / steps, a[1] + (b[1] - a[1]) * t / steps)
                    if i >= 0 and i not in anchor:
                        mark(i, 2 if p["water"] else 1, p["c"][2], pid, p["c"][:2])

    def linked(i, j):
        """Is there a navmesh path from cell i's surface to cell j's that stays inside the two cells (+ MARGIN)?"""
        (pa, _), (pb, b) = anchor[i], anchor[j]
        if pa == pb or pb in adj.get(pa, ()):
            return True
        (xi, yi), (xj, yj) = divmod(i, GH), divmod(j, GH)
        box = (X0 + min(xi, xj) * CS - MARGIN, X0 + (max(xi, xj) + 1) * CS + MARGIN,
               Y0 + min(yi, yj) * CS - MARGIN, Y0 + (max(yi, yj) + 1) * CS + MARGIN)
        hb = height(polys[pb], *b)
        seen, stack = {pa}, [pa]
        while stack:
            u = stack.pop()
            for v in adj.get(u, ()):
                if v in seen or not seg_in_box(*portal[(u, v)], box):
                    continue
                if v == pb or (point_in_convex(b[0], b[1], polys[v]["pts"]) and abs(height(polys[v], *b) - hb) < CLIMB):
                    return True
                seen.add(v)
                stack.append(v)
        return False

    g = lambda gx, gy: grid.get(gx * GH + gy, 0)  # noqa: E731
    cuts = set()
    for gx in range(max(0, tx0 - 1), min(GW, tx1 + 2)):
        for gy in range(max(0, ty0 - 1), min(GH, ty1 + 2)):
            i = gx * GH + gy
            if not g(gx, gy):
                continue
            for d, jx, jy in ((0, gx + 1, gy), (1, gx, gy + 1)):
                if jx >= GW or jy >= GH or not g(jx, jy):
                    continue
                j = jx * GH + jy
                if not linked(i, j) and not linked(j, i):
                    cuts.add(i * 4 + d)
    # Diagonal walkways narrower than a cell: open the diagonal step explicitly where both L-shaped detours are closed.
    own = set()
    for gx in range(tx0, min(tx1 + 1, GW - 1)):
        for gy in range(ty0, ty1 + 1):
            i = gx * GH + gy
            if not g(gx, gy):
                continue
            for d, dy in ((2, 1), (3, -1)):
                if not 0 <= gy + dy < GH:
                    continue
                j = i + GH + dy
                if g(gx + 1, gy + dy) and not diag_ok(g, cuts, gx, gy, gx + 1, gy + dy) and (linked(i, j) or linked(j, i)):
                    own.add(i * 4 + d)
    own |= {c for c in cuts if tx0 <= c // 4 // GH <= tx1 and ty0 <= c // 4 % GH <= ty1}
    vals = bytes(g(gx, gy) for gx in range(tx0, tx1 + 1) for gy in range(ty0, ty1 + 1))
    return rc, vals, sorted(own), len(polys)


def step_ok(grid, cuts, ux, uy, vx, vy):
    """Orthogonal step into a walkable cell. `cuts` holds codes cell * 4 + d on the lower-x (else lower-y) cell:
    d = 0 closes the +x step, 1 closes the +y step, 2 opens the +x+y diagonal, 3 opens the +x-y diagonal.
    `grid(gx, gy)` is the cell value."""
    if not grid(vx, vy):
        return False
    if vx != ux:
        return (min(ux, vx) * GH + uy) * 4 not in cuts
    return (ux * GH + min(uy, vy)) * 4 + 1 not in cuts


def diag_ok(grid, cuts, ux, uy, vx, vy):
    """Diagonal step: either L-shaped detour open (so it never adds connectivity), or an explicit diagonal link."""
    if not grid(vx, vy):
        return False
    if (step_ok(grid, cuts, ux, uy, vx, uy) and step_ok(grid, cuts, vx, uy, vx, vy)) or (
            step_ok(grid, cuts, ux, uy, ux, vy) and step_ok(grid, cuts, ux, vy, vx, vy)):
        return True
    ax, ay, by = (ux, uy, vy) if vx > ux else (vx, vy, uy)
    return (ax * GH + ay) * 4 + (2 if by > ay else 3) in cuts


MOVES = ((1, 0, 1.0), (-1, 0, 1.0), (0, 1, 1.0), (0, -1, 1.0),
         (1, 1, math.sqrt(2)), (1, -1, math.sqrt(2)), (-1, 1, math.sqrt(2)), (-1, -1, math.sqrt(2)))


def moves(g, grid, cuts, u, box):
    """(v, cost in yards) for the 8-neighbour moves out of u; entering water costs SWIM. Path.lua implements the
    same rule."""
    gx0, gx1, gy0, gy1 = box
    ux, uy = divmod(u, GH)
    for dx, dy, length in MOVES:
        vx, vy = ux + dx, uy + dy
        if not (gx0 <= vx <= gx1 and gy0 <= vy <= gy1):
            continue
        if dx and dy:
            ok = diag_ok(g, cuts, ux, uy, vx, vy)
        else:
            ok = step_ok(g, cuts, ux, uy, vx, vy)
        if ok:
            v = vx * GH + vy
            yield v, length * CS * (SWIM if grid[v] == 2 else 1)


def cluster_box(k):
    kx, ky = divmod(k, NY)
    return (kx * CELLS, kx * CELLS + CELLS - 1, ky * CELLS, ky * CELLS + CELLS - 1)


def cluster_of_cell(c):
    gx, gy = divmod(c, GH)
    return (gx // CELLS) * NY + gy // CELLS


def grid_hpa(grid, cuts):
    """HPA* over the grid. Every border crossing (orthogonal or diagonal) is grouped by the in-cluster regions it
    joins; each group gets an entrance every ENTRANCE_RUN cells. Intra-cluster edges come from Dijkstra, pruned when a
    two-hop path is within PRUNE."""
    g = lambda gx, gy: grid[gx * GH + gy]  # noqa: E731
    region = array("i", [-1]) * (GW * GH)
    for k in range(NX * NY):
        box = cluster_box(k)
        for gx in range(box[0], box[1] + 1):
            for gy in range(box[2], box[3] + 1):
                c = gx * GH + gy
                if not grid[c] or region[c] >= 0:
                    continue
                region[c] = c
                stack = [c]
                while stack:
                    u = stack.pop()
                    for v, _ in moves(g, grid, cuts, u, box):
                        if region[v] < 0:
                            region[v] = c
                            stack.append(v)
    edges = {}  # (a, b) cells -> cost
    nodes = defaultdict(set)  # cluster -> cells
    for k in range(NX * NY):
        kx, ky = divmod(k, NY)
        for axis in (0, 1):
            if (axis == 0 and kx + 1 >= NX) or (axis == 1 and ky + 1 >= NY):
                continue
            groups = defaultdict(list)
            for t in range(CELLS):
                if axis == 0:
                    ux, uy, vx, vy = kx * CELLS + CELLS - 1, ky * CELLS + t, (kx + 1) * CELLS, ky * CELLS + t
                else:
                    ux, uy, vx, vy = kx * CELLS + t, ky * CELLS + CELLS - 1, kx * CELLS + t, (ky + 1) * CELLS
                u = ux * GH + uy
                if not grid[u]:
                    continue
                for s in (0, -1, 1):
                    wx, wy = (vx, vy + s) if axis == 0 else (vx + s, vy)
                    if not 0 <= t + s < CELLS:
                        continue
                    ok = step_ok(g, cuts, ux, uy, wx, wy) if s == 0 else diag_ok(g, cuts, ux, uy, wx, wy)
                    if ok:
                        w = wx * GH + wy
                        groups[(region[u], region[w])].append((t, abs(s), u, w))
            for crossings in groups.values():
                crossings.sort()
                for i in range(0, len(crossings), ENTRANCE_RUN):
                    chunk = crossings[i : i + ENTRANCE_RUN]
                    mid = chunk[len(chunk) // 2][0]
                    _, diagonal, u, v = min(chunk, key=lambda c: (c[1], abs(c[0] - mid)))  # prefer orthogonal
                    edges[(u, v)] = CS * (math.sqrt(2) if diagonal else 1) * (
                        1 + (SWIM - 1) * ((grid[u] == 2) + (grid[v] == 2)) / 2)
                    nodes[cluster_of_cell(u)].add(u)
                    nodes[cluster_of_cell(v)].add(v)
    inter = len(edges)
    for k in sorted(nodes):
        cells = nodes[k]
        box = cluster_box(k)
        dist = {}
        for s in cells:
            gd, pq, left = {s: 0.0}, [(0.0, s)], len(cells) - 1
            while pq and left:
                du, u = heapq.heappop(pq)
                if du > gd[u]:
                    continue
                if u != s and u in cells:
                    left -= 1
                    dist[(s, u)] = du
                for v, c in moves(g, grid, cuts, u, box):
                    if du + c < gd.get(v, 1e18):
                        gd[v] = du + c
                        heapq.heappush(pq, (du + c, v))
        el = sorted(cells)
        for i, a in enumerate(el):
            for b in el[i + 1 :]:
                d = dist.get((a, b))
                if d is None:
                    continue
                if any(dist.get((a, x), 1e18) + dist.get((x, b), 1e18) <= d * PRUNE for x in el if x not in (a, b)):
                    continue
                edges[(a, b)] = d
    print(f"grid HPA: nodes {sum(map(len, nodes.values()))}, edges {len(edges)} (inter {inter})", flush=True)
    return nodes, edges


def lua_lines(s, indent, width=96):
    return [indent + '"' + s[i : i + width] + '",' for i in range(0, len(s), width)] or [indent + '"",']


def emit(nodes, edges, grid, cuts, out, name):
    cells = sorted(c for cs in nodes.values() for c in cs)
    parent = {c: c for c in cells}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for a, b in sorted(edges):
        parent[find(a)] = find(b)
    roots = {}
    comp = {c: roots.setdefault(find(c), len(roots)) for c in cells}
    local = {}
    order = {k: sorted(cs) for k, cs in nodes.items()}
    for k, cs in order.items():
        for i, c in enumerate(cs):
            local[c] = i
    nbrs = defaultdict(list)
    for (a, b), d in edges.items():
        nbrs[a].append((b, d))
        nbrs[b].append((a, d))
    flags = defaultdict(int)
    for code in cuts:
        i, d = divmod(code, 4)
        flags[i] |= 1 << d

    def lcell(c):
        gx, gy = divmod(c, GH)
        return (gx % CELLS) * CELLS + gy % CELLS

    graph, grids = {}, {}
    for k in range(NX * NY):
        kx, ky = divmod(k, NY)
        cs = order.get(k, [])
        if cs:
            rec, erec = [enc(len(cs), 2)], []
            for c in cs:
                rec.append(enc(lcell(c), 3) + enc(comp[c], 2) + enc(len(nbrs[c]), 1))
                for m, d in sorted(nbrs[c]):
                    km = cluster_of_cell(m)
                    dx, dy = km // NY - kx, km % NY - ky
                    assert abs(dx) <= 1 and abs(dy) <= 1
                    erec.append(enc((dx + 1) * 3 + dy + 1, 1) + enc(local[m], 2) + enc(round(d), 2))
            graph[k] = "".join(rec) + "".join(erec)
        vals = [grid[(kx * CELLS + i) * GH + ky * CELLS + j] * 16 + flags.get((kx * CELLS + i) * GH + ky * CELLS + j, 0)
                for i in range(CELLS) for j in range(CELLS)]
        if any(vals):
            syms, i = [], 0
            while i < len(vals):
                j = i + 1
                while j < len(vals) and vals[j] == vals[i]:
                    j += 1
                syms.append(B64[vals[i]])
                repeat = j - i - 1
                while repeat > 0:
                    n = min(repeat, 16)
                    syms.append(B64[48 + n - 1])
                    repeat -= n
                i = j
            grids[k] = "".join(syms)
    lines = [
        "-- Generated by tools/baker/gen_nav.py — do not edit.",
        f"-- Source: {SOURCE}.",
        f"-- Map {MAP} ({name}), mmtile rows {ROWS.start}-{ROWS.stop - 1} x cols {COLS.start}-{COLS.stop - 1}.",
        "-- UnitPosition's frame (x north, y west). Cluster k (0-based) is the ADT tile x in [(cx0 + k // ny) T, +T),",
        "-- y in [(cy0 + k % ny) T, +T), T = 1600 / 3, cut into cells x cells cells, x-major. Base64 (A-Za-z0-9+/).",
        "-- graph[k + 1]: n(2) | n x [cell(3) component(2) degree(1)] | edges in node order [cluster offset(1):",
        "--   (dx + 1) * 3 + dy + 1, node(2), cost(2) yards]. grid[k + 1]: per cell value * 16 + flags, where value",
        "--   0 blocked, 1 ground, 2 water; flags 1/2 close the step to the +x/+y neighbour, 4/8 open the +x+y/+x-y",
        "--   diagonal (otherwise a diagonal is open when either L-shaped detour is). A symbol >= 48 repeats the",
        "--   previous cell (symbol - 47) more times.",
        "ShortestPathForeverPathData = ShortestPathForeverPathData or {}",
        "",
        "-- stylua: ignore",
        f"ShortestPathForeverPathData[{MAP}] = {{",
        f"\tcx0 = {CX0},",
        f"\tcy0 = {CY0},",
        f"\tnx = {NX},",
        f"\tny = {NY},",
        f"\tcells = {CELLS},",
        f"\tswim = {SWIM:.6f},",
    ]
    for key, table in (("graph", graph), ("grid", grids)):
        lines.append(f"\t{key} = {{")
        for k in sorted(table):
            lines.append(f"\t\t[{k + 1}] = {{")
            lines += lua_lines(table[k], "\t\t\t")
            lines.append("\t\t},")
        lines.append("\t},")
    lines.append("}")
    src = "\n".join(lines) + "\n"
    with open(out, "w") as f:
        f.write(src)
    gb, rb = sum(map(len, graph.values())), sum(map(len, grids.values()))
    print(f"emit: components {len(roots)}, graph {gb / 1e3:.1f} KB, grids+cuts {rb / 1e3:.1f} KB "
          f"({len(grids)} clusters, cuts {len(cuts)}), file {len(src) / 1e3:.1f} KB", flush=True)


def opt(args, name, n):
    if name not in args:
        return None
    i = args.index(name)
    vals = args[i + 1 : i + 1 + n]
    del args[i : i + 1 + n]
    return vals


def main():
    args = sys.argv[1:]
    map_id = int((opt(args, "--map", 1) or [os.environ.get("NAV_MAP", "0")])[0])
    name = (opt(args, "--name", 1) or [f"map {map_id}"])[0]
    rows, cols = opt(args, "--rows", 2), opt(args, "--cols", 2)
    jobs = int((opt(args, "--jobs", 1) or [os.environ.get("NAV_JOBS", "6")])[0])
    out = args[0] if args else f"Nav{map_id}.lua"
    configure(map_id, rows and tuple(map(int, rows)), cols and tuple(map(int, cols)))
    print(f"map {map_id}: {len(TILES)} tiles, rows {ROWS.start}-{ROWS.stop - 1}, cols {COLS.start}-{COLS.stop - 1}, "
          f"grid {GW}x{GH}", flush=True)
    components()
    grid, cuts, polys = bytearray(GW * GH), set(), 0
    order = sorted(TILES, key=ORD.get)
    with multiprocessing.get_context("fork").Pool(jobs) as pool:  # workers inherit the pass-1 globals
        for n, (rc, vals, own, np_) in enumerate(pool.imap(rasterize_tile, order, chunksize=2)):
            kx, ky = divmod(cluster_of_tile(*rc), NY)
            for i in range(CELLS):
                row = (kx * CELLS + i) * GH + ky * CELLS
                grid[row : row + CELLS] = vals[i * CELLS : (i + 1) * CELLS]
            cuts.update(own)
            polys += np_
            if (n + 1) % 100 == 0:
                print(f"  rasterized {n + 1}/{len(order)} tiles", flush=True)
    print(f"grid {GW}x{GH}: ground {grid.count(1)}, water {grid.count(2)}, cut steps {len(cuts)}", flush=True)
    nodes, edges = grid_hpa(grid, cuts)
    emit(nodes, edges, grid, cuts, out, name)


if __name__ == "__main__":
    main()
