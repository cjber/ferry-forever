local _, ns = ...

-- Walking routes over a continent's collision map: HPA* between ADT-tile clusters, an 8 yd grid inside them,
-- then string-pulling so the drawn line is not jagged. Coordinates are UnitPosition's frame (x north, y west).
local Path = {}
ns.Path = Path

Path.budget = 3 -- milliseconds of CPU per frame for Find
Path.clusters = 12 -- decoded cluster grids kept in memory (at least 4)
Path.clock = debugprofilestop or function()
	return os.clock() * 1000
end

local TILE = 1600 / 3
local SNAP = 6 -- cells searched around an off-grid endpoint
local CHECK = 64 -- expansions between clock reads
local RETRIES = 8 -- other cells tried for an endpoint stuck in a pocket
local SQRT2 = math.sqrt(2)
local START, GOAL = -1, -2

local byte, floor, sqrt, huge, max = string.byte, math.floor, math.sqrt, math.huge, math.max
local concat, yield = table.concat, coroutine.yield

local B64 = {}
do
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, 64 do
		B64[byte(alphabet, i)] = i - 1
	end
end

local function num(s, i, width)
	local v = 0
	for j = i, i + width - 1 do
		v = v * 64 + B64[byte(s, j)]
	end
	return v
end

-- Slicing: tick() yields once the frame's deadline passes. Only one search runs at a time (see pump).
local deadline, ops, expansions = huge, 0, 0
local clock = function()
	return Path.clock()
end

local function tick()
	expansions = expansions + 1
	ops = ops + 1
	if ops >= CHECK then
		ops = 0
		if clock() > deadline then
			yield()
		end
	end
end

-- Binary min-heap on parallel arrays, reset per search.
local hk, hv, hn = {}, {}, 0

local function push(k, v)
	hn = hn + 1
	local i = hn
	while i > 1 do
		local p = floor(i / 2)
		if hk[p] <= k then
			break
		end
		hk[i], hv[i] = hk[p], hv[p]
		i = p
	end
	hk[i], hv[i] = k, v
end

local function pop()
	local top = hv[1]
	local k, v = hk[hn], hv[hn]
	hn = hn - 1
	local i = 1
	while true do
		local c = i * 2
		if c > hn then
			break
		end
		if c < hn and hk[c + 1] < hk[c] then
			c = c + 1
		end
		if hk[c] >= k then
			break
		end
		hk[i], hv[i] = hk[c], hv[c]
		i = c
	end
	hk[i], hv[i] = k, v
	return top
end

-- Collision maps ship as one load-on-demand addon per continent (ShortestPathForever_Nav<map>), so only players who
-- walk there pay for them. A separate addon cannot share `ns`, hence the global.
local tried = {}
local function Data(map)
	if not (ShortestPathForeverPathData and ShortestPathForeverPathData[map]) and not tried[map] and C_AddOns then
		tried[map] = true
		C_AddOns.LoadAddOn("ShortestPathForever_Nav" .. map)
	end
	return ShortestPathForeverPathData and ShortestPathForeverPathData[map]
end

-- Per-map state; clusters are decoded on first use.
local states = {}

local function State(map)
	local st = states[map]
	if st == nil then
		local D = Data(map)
		if not D then
			return nil
		end
		local C = D.cells
		st = {
			D = D,
			C = C,
			ny = D.ny,
			GX = D.nx * C,
			GY = D.ny * C,
			x0 = D.cx0 * TILE,
			y0 = D.cy0 * TILE,
			cs = TILE / C,
			swim = D.swim,
			used = {}, -- [k] = last use, for eviction
			decoded = 0,
			val = {}, -- [k] = cell values (1-based local index), false when the cluster has no data
			moves = {}, -- [k][lc + 1] = open moves inside the cluster + 16 * the data file's step flags
			nodes = {}, -- [k] = node ids (k * 4096 + i)
			ncell = {},
			ncomp = {},
			nadj = {},
		}
		states[map] = st
	end
	return st
end

local function decodeGrid(st, k)
	local chunks = st.D.grid[k + 1]
	if not chunks then
		st.val[k] = false
		return false
	end
	local s, C = concat(chunks), st.C
	local val, m = {}, {}
	local n, code = 0, 0
	for i = 1, #s do
		local sym = B64[byte(s, i)]
		if sym < 48 then
			code = sym
			n = n + 1
			val[n], m[n] = floor(code / 16), (code % 16) * 16
		else
			for _ = 48, sym do
				n = n + 1
				val[n], m[n] = floor(code / 16), (code % 16) * 16
			end
		end
	end
	-- m[i] packs the open moves (1 = +x, 2 = +y, 4 = +x+y, 8 = +x-y) over the data flags * 16.
	local N = C * C
	for a = 0, N - 1 do
		local i = a + 1
		local f = m[i] / 16
		if val[i] ~= 0 then
			if a + C < N and val[i + C] ~= 0 and f % 2 == 0 then
				m[i] = m[i] + 1
			end
			if a % C < C - 1 and val[i + 1] ~= 0 and f % 4 < 2 then
				m[i] = m[i] + 2
			end
		end
	end
	-- Diagonals: either L-shaped detour open, or an explicit link.
	local function X(j)
		return m[j] % 2 == 1
	end
	local function Y(j)
		return m[j] % 4 >= 2
	end
	for a = 0, N - 1 do
		local i, ly = a + 1, a % C
		if a + C < N and val[i] ~= 0 then
			local f = floor(m[i] / 16)
			if ly < C - 1 and val[i + C + 1] ~= 0 and ((X(i) and Y(i + C)) or (Y(i) and X(i + 1)) or f % 8 >= 4) then
				m[i] = m[i] + 4
			end
			if ly > 0 and val[i + C - 1] ~= 0 and ((X(i) and Y(i + C - 1)) or (Y(i - 1) and X(i - 1)) or f >= 8) then
				m[i] = m[i] + 8
			end
		end
	end
	st.val[k], st.moves[k] = val, m
	return val
end

-- Decoded clusters cost ~0.25 MB each under Lua 5.1, so only the Path.clusters most recently used stay decoded.
local useClock = 0

local function evict(st)
	local oldest, at = nil, huge
	for k, used in pairs(st.used) do
		if used < at then
			oldest, at = k, used
		end
	end
	st.used[oldest] = nil
	st.val[oldest], st.moves[oldest] = nil, nil
	st.decoded = st.decoded - 1
end

local function grid(st, k)
	local val = st.val[k]
	if val == nil then
		if st.decoded >= max(Path.clusters, 4) then
			evict(st)
		end
		val = decodeGrid(st, k)
		st.decoded = st.decoded + 1
	end
	useClock = useClock + 1
	st.used[k] = useClock
	return val
end

local function decodeGraph(st, k)
	local ids = {}
	st.nodes[k] = ids
	local chunks = st.D.graph[k + 1]
	if not chunks then
		return ids
	end
	local s = concat(chunks)
	local n, pos = num(s, 1, 2), 3
	local degree = {}
	for i = 0, n - 1 do
		local id = k * 4096 + i
		ids[i + 1] = id
		st.ncell[id] = num(s, pos, 3)
		st.ncomp[id] = num(s, pos + 3, 2)
		degree[i + 1] = B64[byte(s, pos + 5)]
		pos = pos + 6
	end
	local ny = st.ny
	for i = 1, n do
		local adj = {}
		for e = 1, degree[i] do
			local offset = B64[byte(s, pos)]
			local target = k + (floor(offset / 3) - 1) * ny + offset % 3 - 1
			adj[e * 2 - 1] = target * 4096 + num(s, pos + 1, 2)
			adj[e * 2] = num(s, pos + 3, 2)
			pos = pos + 5
		end
		st.nadj[ids[i]] = adj
	end
	return ids
end

local function nodesOf(st, k)
	return st.nodes[k] or decodeGraph(st, k)
end

-- Cluster k and local cell of a world point, or nil outside the data.
local function locate(st, x, y)
	local gx, gy = floor((x - st.x0) / st.cs), floor((y - st.y0) / st.cs)
	if gx < 0 or gy < 0 or gx >= st.GX or gy >= st.GY then
		return nil
	end
	local C = st.C
	return floor(gx / C) * st.ny + floor(gy / C), (gx % C) * C + gy % C
end

-- The nearest walkable cell within SNAP cells, by rings.
local function snap(st, k, lc)
	local val = grid(st, k)
	if not val then
		return nil
	end
	if val[lc + 1] ~= 0 then
		return lc
	end
	local C = st.C
	local lx, ly = floor(lc / C), lc % C
	for r = 1, SNAP do
		local best, bestD
		for dx = -r, r do
			for dy = -r, r do
				if dx == r or dx == -r or dy == r or dy == -r then
					local x, y = lx + dx, ly + dy
					if x >= 0 and y >= 0 and x < C and y < C and val[x * C + y + 1] ~= 0 then
						local d = dx * dx + dy * dy
						if not bestD or d < bestD then
							best, bestD = x * C + y, d
						end
					end
				end
			end
		end
		if best then
			return best
		end
	end
	return nil
end

-- Grid search inside one cluster. tree holds g/parent keyed by local cell + 1. With goal set it is A*, otherwise
-- Dijkstra that stops once every cell in targets (a set of local cells) is settled.
local function Tree()
	return { g = {}, par = {}, stamp = {}, closed = {}, gen = 0 }
end

local function search(st, k, source, tree, goal, targets, left)
	local val = grid(st, k)
	local m = st.moves[k]
	local C, cs, swim = st.C, st.cs, st.swim
	local g, par, stamp, closed = tree.g, tree.par, tree.stamp, tree.closed
	tree.gen = tree.gen + 1
	local gen = tree.gen
	tree.k = k
	local gx, gy = 0, 0
	if goal then
		gx, gy = floor(goal / C), goal % C
	end
	hn = 0
	g[source + 1], par[source + 1], stamp[source + 1] = 0, -1, gen
	push(0, source)

	local u, ux, uy, gu
	local function relax(v, length)
		local i = v + 1
		local gv = gu + length * cs * (val[i] == 2 and swim or 1)
		if stamp[i] ~= gen or gv < g[i] then
			g[i], par[i], stamp[i] = gv, u, gen
			local h = 0
			if goal then
				local ax, ay = floor(v / C) - gx, v % C - gy
				if ax < 0 then
					ax = -ax
				end
				if ay < 0 then
					ay = -ay
				end
				h = (ax > ay and ax + (SQRT2 - 1) * ay or ay + (SQRT2 - 1) * ax) * cs
			end
			push(gv + h, v)
		end
	end

	while hn > 0 do
		u = pop()
		local i = u + 1
		if closed[i] ~= gen then
			closed[i] = gen
			tick()
			if u == goal then
				return true
			end
			if targets and targets[u] then
				left = left - 1
				if left <= 0 then
					return true
				end
			end
			gu, ux, uy = g[i], floor(u / C), u % C
			local mi = m[i] % 16
			local px, mx, py, my = mi % 2 == 1, ux > 0 and m[i - C] % 2 == 1, mi % 4 >= 2, uy > 0 and m[i - 1] % 4 >= 2
			if px then
				relax(u + C, 1)
			end
			if mx then
				relax(u - C, 1)
			end
			if py then
				relax(u + 1, 1)
			end
			if my then
				relax(u - 1, 1)
			end
			if mi % 8 >= 4 then
				relax(u + C + 1, SQRT2)
			end
			if mi >= 8 then
				relax(u + C - 1, SQRT2)
			end
			if ux > 0 and uy > 0 and m[i - C - 1] % 8 >= 4 then
				relax(u - C - 1, SQRT2)
			end
			if ux > 0 and uy < C - 1 and m[i - C + 1] % 16 >= 8 then
				relax(u - C + 1, SQRT2)
			end
		end
	end
	return goal == nil
end

local function reached(tree, lc)
	return tree.stamp[lc + 1] == tree.gen and tree.closed[lc + 1] == tree.gen
end

-- Cell path in a tree from lc back to its source (local cells, lc first).
local function trace(tree, lc, out)
	local par = tree.par
	while lc >= 0 do
		out[#out + 1] = lc
		lc = par[lc + 1]
	end
	return out
end

-- Global grid helpers for smoothing across clusters.
local function value(st, gx, gy)
	if gx < 0 or gy < 0 or gx >= st.GX or gy >= st.GY then
		return 0
	end
	local C = st.C
	local val = grid(st, floor(gx / C) * st.ny + floor(gy / C))
	return val and val[(gx % C) * C + gy % C + 1] or 0
end

-- Is the step from (gx, gy) to (gx + dx, gy + dy) open, for an orthogonal unit step?
local function stepOpen(st, gx, gy, dx, dy, water)
	local ax, ay = gx, gy
	if dx < 0 or dy < 0 then
		ax, ay = gx + dx, gy + dy
	end
	local a, b = value(st, ax, ay), value(st, ax + (dx ~= 0 and 1 or 0), ay + (dy ~= 0 and 1 or 0))
	if a == 0 or b == 0 or (not water and (a == 2 or b == 2)) then
		return false
	end
	local C = st.C
	local f = floor(st.moves[floor(ax / C) * st.ny + floor(ay / C)][(ax % C) * C + ay % C + 1] / 16)
	if dx ~= 0 then
		return f % 2 == 0
	end
	return f % 4 < 2
end

-- Is the diagonal step from (gx, gy) by (sx, sy) open?
local function diagonalOpen(st, gx, gy, sx, sy, water)
	local b = value(st, gx + sx, gy + sy)
	if b == 0 or (not water and b == 2) then
		return false
	end
	if
		(stepOpen(st, gx, gy, sx, 0, water) and stepOpen(st, gx + sx, gy, 0, sy, water))
		or (stepOpen(st, gx, gy, 0, sy, water) and stepOpen(st, gx, gy + sy, sx, 0, water))
	then
		return true
	end
	local ax, ay, up = gx, gy, sy > 0 -- links are stored on the lower-x cell
	if sx < 0 then
		ax, ay, up = gx + sx, gy + sy, sy < 0
	end
	local a = value(st, ax, ay)
	if a == 0 or (not water and a == 2) then
		return false
	end
	local C = st.C
	local f = floor(st.moves[floor(ax / C) * st.ny + floor(ay / C)][(ax % C) * C + ay % C + 1] / 16)
	if up then
		return f % 8 >= 4
	end
	return f >= 8
end

-- Line of sight on the grid between cell centres, walking every cell the segment crosses.
local function sight(st, ax, ay, bx, by, water)
	local dx, dy = bx - ax, by - ay
	local sx, sy = dx > 0 and 1 or -1, dy > 0 and 1 or -1
	local nx, ny = dx * sx, dy * sy
	local x, y, ix, iy = ax, ay, 0, 0
	while ix < nx or iy < ny do
		tick()
		-- Compare the next x and y boundary crossings: (0.5 + ix) / nx against (0.5 + iy) / ny.
		local d = (1 + 2 * ix) * ny - (1 + 2 * iy) * nx
		if d == 0 then -- through a corner
			if not diagonalOpen(st, x, y, sx, sy, water) then
				return false
			end
			x, y, ix, iy = x + sx, y + sy, ix + 1, iy + 1
		elseif d < 0 then
			if not stepOpen(st, x, y, sx, 0, water) then
				return false
			end
			x, ix = x + sx, ix + 1
		else
			if not stepOpen(st, x, y, 0, sy, water) then
				return false
			end
			y, iy = y + sy, iy + 1
		end
	end
	return true
end

-- Collapse a cell path to its turns, then pull the string: from each anchor, jump to the furthest point in sight.
-- Water may only be crossed where the grid path itself swam.
local function smooth(st, PX, PY, PW)
	local n = #PX
	local keep = { 1 }
	for i = 2, n - 1 do
		if PX[i + 1] - PX[i] ~= PX[i] - PX[i - 1] or PY[i + 1] - PY[i] ~= PY[i] - PY[i - 1] or PW[i + 1] ~= PW[i] then
			keep[#keep + 1] = i
		end
	end
	if n > 1 then
		keep[#keep + 1] = n
	end
	local out, a = { keep[1] }, 1
	while a < #keep do
		local b = a + 1
		for j = a + 2, #keep do
			local p, q = keep[a], keep[j]
			if not sight(st, PX[p], PY[p], PX[q], PY[q], PW[q] - PW[p] > 0) then
				break
			end
			b = j
		end
		out[#out + 1] = keep[b]
		a = b
	end
	return out
end

local trees = { S = Tree(), G = Tree(), R = Tree() }

-- Abstract A* state.
local ag, apar, astamp, aclosed, agen = {}, {}, {}, {}, 0

local function run(map, fx, fy, tx, ty)
	local st = State(map)
	if not st then
		return nil, "nodata"
	end
	local sk, sc = locate(st, fx, fy)
	local gk, gc = locate(st, tx, ty)
	if not sk or not gk then
		return nil, "outside"
	end
	sc, gc = snap(st, sk, sc), snap(st, gk, gc)
	if not sc or not gc then
		return nil, "offmesh"
	end
	local C = st.C

	-- Endpoint searches: grid Dijkstra to the cluster's entrances (and the other endpoint when they share it).
	local function endpoint(tree, k, lc, other)
		local targets, left = {}, 0
		for _, id in ipairs(nodesOf(st, k)) do
			if not targets[st.ncell[id]] then
				targets[st.ncell[id]], left = true, left + 1
			end
		end
		if other and not targets[other] then
			targets[other], left = true, left + 1
		end
		search(st, k, lc, tree, nil, targets, left)
	end
	-- An endpoint on a rooftop or ledge the grid cannot leave moves to the nearest cell that reaches an entrance.
	local function settle(tree, k, lc, other)
		endpoint(tree, k, lc, other)
		local function connected()
			if other and reached(tree, other) then
				return true
			end
			for _, id in ipairs(nodesOf(st, k)) do
				if reached(tree, st.ncell[id]) then
					return true
				end
			end
			return false
		end
		local tries, val = 0, grid(st, k)
		local lx, ly = floor(lc / C), lc % C
		for r = 1, SNAP do
			for dx = -r, r do
				for dy = -r, r do
					if connected() or tries >= RETRIES then
						return lc
					end
					local x, y = lx + dx, ly + dy
					local ring = dx == r or dx == -r or dy == r or dy == -r
					if ring and x >= 0 and y >= 0 and x < C and y < C then
						local cell = x * C + y
						if val[cell + 1] ~= 0 and not reached(tree, cell) then
							tries, lc = tries + 1, cell
							endpoint(tree, k, lc, other)
						end
					end
				end
			end
		end
		return lc
	end
	local S, G = trees.S, trees.G
	local same = sk == gk
	gc = settle(G, gk, gc, nil)
	settle(S, sk, sc, same and gc)
	local direct = same and reached(S, gc) and S.g[gc + 1] or nil

	-- O(1)-ish reject: the endpoints' entrances must share a component.
	local comps, shared = {}, false
	for _, id in ipairs(nodesOf(st, sk)) do
		if reached(S, st.ncell[id]) then
			comps[st.ncomp[id]] = true
		end
	end
	for _, id in ipairs(nodesOf(st, gk)) do
		if reached(G, st.ncell[id]) and comps[st.ncomp[id]] then
			shared = true
		end
	end
	if not direct and not shared then
		return nil, "unreachable"
	end

	-- Abstract A* from START to GOAL through the entrance graph.
	local x0, y0, cs = st.x0, st.y0, st.cs
	local function world(id)
		local k, lc = floor(id / 4096), st.ncell[id]
		return x0 + (floor(k / st.ny) * C + floor(lc / C) + 0.5) * cs, y0 + ((k % st.ny) * C + lc % C + 0.5) * cs
	end
	local function h(id)
		local x, y = world(id)
		return sqrt((x - tx) ^ 2 + (y - ty) ^ 2)
	end
	agen = agen + 1
	local gen = agen
	hn = 0
	local function relax(v, gv, from)
		if astamp[v] ~= gen or gv < ag[v] then
			ag[v], apar[v], astamp[v] = gv, from, gen
			push(gv + (v == GOAL and 0 or h(v)), v)
		end
	end
	for _, id in ipairs(nodesOf(st, sk)) do
		local lc = st.ncell[id]
		if reached(S, lc) then
			relax(id, S.g[lc + 1], START)
		end
	end
	if direct then
		relax(GOAL, direct, START)
	end
	local found = false
	while hn > 0 do
		local u = pop()
		if aclosed[u] ~= gen then
			aclosed[u] = gen
			tick()
			if u == GOAL then
				found = true
				break
			end
			local gu = ag[u]
			if floor(u / 4096) == gk and reached(G, st.ncell[u]) then
				relax(GOAL, gu + G.g[st.ncell[u] + 1], u)
			end
			local adj = st.nadj[u]
			for e = 1, #adj, 2 do
				local v = adj[e]
				if aclosed[v] ~= gen then
					nodesOf(st, floor(v / 4096))
					relax(v, gu + adj[e + 1], u)
				end
			end
		end
	end
	if not found then
		return nil, "unreachable"
	end
	local hops = { GOAL }
	while hops[#hops] ~= START do
		hops[#hops + 1] = apar[hops[#hops]]
	end

	-- Refine each hop into grid cells (global coordinates) with a water flag running count.
	local PX, PY, PW = {}, {}, {}
	local function add(k, lc)
		local x, y = floor(k / st.ny) * C + floor(lc / C), (k % st.ny) * C + lc % C
		local n = #PX
		if n == 0 or PX[n] ~= x or PY[n] ~= y then
			PX[n + 1], PY[n + 1] = x, y
			PW[n + 1] = (PW[n] or 0) + (grid(st, k)[lc + 1] == 2 and 1 or 0)
		end
	end
	local function addAll(k, cells, from, to, step)
		for i = from, to, step do
			add(k, cells[i])
		end
	end
	local R = trees.R
	for i = #hops, 2, -1 do
		local a, b = hops[i], hops[i - 1]
		if a == START and b == GOAL then
			local cells = trace(S, gc, {})
			addAll(sk, cells, #cells, 1, -1)
		elseif a == START then
			local cells = trace(S, st.ncell[b], {})
			addAll(sk, cells, #cells, 1, -1)
		elseif b == GOAL then
			local cells = trace(G, st.ncell[a], {})
			addAll(gk, cells, 1, #cells, 1)
		else
			local ka, kb = floor(a / 4096), floor(b / 4096)
			if ka == kb and search(st, ka, st.ncell[a], R, st.ncell[b]) then
				local cells = trace(R, st.ncell[b], {})
				addAll(ka, cells, #cells, 1, -1)
			else -- neighbouring entrance cells across a cluster border
				add(ka, st.ncell[a])
				add(kb, st.ncell[b])
			end
		end
	end

	local keep = smooth(st, PX, PY, PW)
	local points = { { map = map, x = fx, y = fy } }
	for i = 2, #keep - 1 do
		local j = keep[i]
		points[#points + 1] = { map = map, x = x0 + (PX[j] + 0.5) * cs, y = y0 + (PY[j] + 0.5) * cs }
	end
	points[#points + 1] = { map = map, x = tx, y = ty }
	local length = 0
	for i = 2, #points do
		length = length + sqrt((points[i].x - points[i - 1].x) ^ 2 + (points[i].y - points[i - 1].y) ^ 2)
	end
	return points, length
end

local function start(job)
	expansions = 0
	return run(job.map, job.fromX, job.fromY, job.toX, job.toY)
end

-- Synchronous search, for tests and tools. Returns points, length (or nil, reason) and the expansion count.
function Path.FindSync(map, fromX, fromY, toX, toY)
	deadline, ops = huge, 0
	local job = { map = map, fromX = fromX, fromY = fromY, toX = toX, toY = toY }
	local co = coroutine.create(start)
	local ok, points, length = coroutine.resume(co, job)
	if not ok then
		error(points)
	end
	return points, length, expansions
end

-- Jobs run one at a time, each resumed once a frame until Path.budget ms of CPU is spent.
local queue = {}
local scheduled = false
local pump

local function schedule()
	if not scheduled and #queue > 0 then
		scheduled = true
		Path.after(pump)
	end
end

pump = function()
	scheduled = false
	local job = queue[1]
	if not job then
		return
	end
	local t0 = clock()
	deadline, ops = t0 + Path.budget, 0
	expansions = job.expansions or 0
	local ok, points, length = coroutine.resume(job.co, job)
	job.expansions = expansions
	job.frames = job.frames + 1
	job.cpu = job.cpu + clock() - t0
	deadline = huge
	if not ok or coroutine.status(job.co) == "dead" then
		table.remove(queue, 1)
		if not ok then
			geterrorhandler()(points)
		elseif not job.cancelled then
			job.callback(points, length, job)
		end
	end
	schedule()
end

-- Next-frame scheduling; tests replace it.
function Path.after(fn)
	C_Timer.After(0, fn)
end

-- Search coroutine-sliced over frames. callback(points, length, job) or callback(nil, reason, job), where points
-- are { map, x, y } from the start to the goal. Returns a handle for Path.Cancel.
function Path.Find(map, fromX, fromY, toX, toY, callback)
	local job = {
		map = map,
		fromX = fromX,
		fromY = fromY,
		toX = toX,
		toY = toY,
		callback = callback,
		co = coroutine.create(start),
		frames = 0,
		cpu = 0,
	}
	queue[#queue + 1] = job
	schedule()
	return job
end

function Path.Cancel(job)
	job.cancelled = true
	for i, queued in ipairs(queue) do
		if queued == job and i > 1 then
			table.remove(queue, i)
			return
		end
	end
end

function Path.HasData(map)
	return Data(map) ~= nil
end
